// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart' show Database;
import '../../data/models/server.dart';
import '../../data/models/sftp_path.dart';
import '../../data/terminal_settings.dart';
import '../../data/repositories/sftp_path_repository.dart';
import '../../l10n/l10n.dart';
import '../../sftp/sftp_entry.dart';
import '../../sftp/sftp_error.dart';
import '../../sftp/sftp_name_sort.dart';
import '../../sftp/sftp_service.dart';
import '../../sftp/sftp_upload_plan.dart';
import 'sftp_image_viewer_screen.dart';
import 'sftp_markdown_preview_screen.dart';
import 'sftp_path_store.dart';
import 'sftp_text_editor_screen.dart';
import 'sftp_breadcrumb.dart';
import 'sftp_sort_prefs.dart';
import 'sftp_transfer_progress.dart';
import 'file_kind_style.dart';
import '../design/fly_tokens.dart';

/// Embeddable SFTP browser body. No Scaffold/AppBar — the host widget
/// (TerminalScreen in sftp view mode) provides its own AppBar so the
/// terminal session stays alive during SFTP browsing.
class SftpInlineView extends StatefulWidget {
  const SftpInlineView({
    super.key,
    required this.server,
    required this.svc,
    this.initialPath = '/',
    this.onPathChanged,
    this.onCloseRequested,
    this.onReconnectRequested,
    this.onAutoReconnectRequested,
    this.scanDirectory = SftpUploadPlan.scan,
    this.pickDirectory = _defaultPickDirectory,
    this.loadSortPrefs = SftpSortPrefs.load,
    this.pathStore,
  });

  final Server server;
  final SFTPService svc;
  final String initialPath;
  final ValueChanged<String>? onPathChanged;
  final VoidCallback? onCloseRequested;

  /// 本地目录扫描。**可注入** —— `testWidgets` 跑在 FakeAsync 时钟下，真实的
  /// `dart:io` 文件操作会挂住（实测：10 秒超时；同样的操作包在
  /// `tester.runAsync` 里就正常）。注入一个返回固定结果的实现即可在
  /// widget 测试里验证「冲突确认」那段流程，而不必让测试去碰真文件系统。
  ///
  /// 生产代码不传它，走默认的真实扫描。
  final Future<SftpUploadPlan> Function(
    String root, {
    bool Function()? isCancelled,
  }) scanDirectory;

  /// 选本地目录。**可注入** —— `FilePicker.platform` 是静态单例，测试里无法
  /// 替换；而「选好目录之后」的冲突确认流程才是值得测的部分。
  /// 返回 null 表示用户取消。
  final Future<String?> Function() pickDirectory;

  /// 目录历史 / 书签的 faucet。**可注入**：`testWidgets` 跑在 FakeAsync 时钟
  /// 下，真实 sqflite 调用永远不完成（实测 `ok=false`，随后 DB 关闭时抛
  /// `database_closed`），所以 widget 测试必须注入一个假 store。
  ///
  /// 生产代码不传它 —— `initState` 里从 `Database` provider 懒建。
  final SftpPathStore? pathStore;

  static Future<String?> _defaultPickDirectory() =>
      FilePicker.platform.getDirectoryPath();

  /// 读取排序偏好。**可注入** —— 真机上 `SharedPreferences.getInstance()` 是
  /// 平台通道往返（几十到几百毫秒），而 widget 测试里它几乎同步返回；
  /// 想验证「慢读取不得覆盖用户刚做出的选择」这个竞态，需要一个能被人为拖慢
  /// 的入口。
  final Future<({SortKey key, bool ascending})> Function() loadSortPrefs;
  /// Called when the user taps the reconnect button after a connection
  /// failure. The host (TerminalScreen) should dispose the old svc, create
  /// a fresh one, and call setViewMode(sftp) with the new svc mounted.
  final VoidCallback? onReconnectRequested;

  /// 与 [onReconnectRequested] 同样的动作，但由本视图**自动**触发（底层连接
  /// 断开时）。分成两个回调是因为宿主要对自动触发做限流，而用户手动点的那
  /// 一下不该受限流约束 —— 用户明确表达了意图，就该照做。
  final VoidCallback? onAutoReconnectRequested;

  @override
  State<SftpInlineView> createState() => SftpInlineViewState();
}

/// 公开的 State 类型。
///
/// **刻意公开**：宿主 `TerminalScreen` 持有 `GlobalKey<SftpInlineViewState>`
/// 以便把 `ReconnectService` 的「切网 / 回前台」事件转发给当前活跃的 SFTP
/// 视图。测试也借这个类型直接驱动 [onNetworkChanged] / [onForegroundResumed]。
class SftpInlineViewState extends State<SftpInlineView>
    with SingleTickerProviderStateMixin {
  SFTPService get _svc => widget.svc;

  // ── 目录历史 / 书签 ───────────────────────────────────────────────────────
  /// 当前 server 的 path store。优先用注入的（widget 测试），否则在
  /// `didChangeDependencies` 里从 `Database` provider 懒建。
  SftpPathStore? _pathStore;

  /// 已经记录过的路径。**用来去重**：`_onChanged` 每次 `notifyListeners`
  /// 都会跑（loading 开始/结束、软链解析……），不做去重就会往数据库里灌
  /// 一堆同样的 upsert。
  String? _lastRecordedPath;

  // ── Speed Dial ───────────────────────────────────────────────────────────
  static const _kFabSize = 56.0;
  static const _kMiniFabSize = 40.0;
  static const _kFabMargin = 16.0;
  static const _kItemGap = 12.0;

  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  bool _menuOpen = false;

  // ── Selection state ──────────────────────────────────────────────────────
  /// Paths of currently selected entries. Non-empty = selection mode active.
  final Set<String> _selectedPaths = {};
  bool get _isSelecting => _selectedPaths.isNotEmpty;

  // ── Search state ─────────────────────────────────────────────────────────
  bool _searchActive = false;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  // ── Sort state ───────────────────────────────────────────────────────────
  /// 当前排序维度 + 方向。默认名称升序（`SftpSortPrefs` 的默认值）。
  /// `initState` 里异步从 shared_preferences 填充，填充后 `setState`。
  /// 用户是否已经**亲手**改过排序。
  ///
  /// `initState` 里那次异步读取（[_loadSortPrefs]）必须让位于用户操作：
  /// `SharedPreferences.getInstance()` 是平台通道往返，在真机上要几十到几百
  /// 毫秒。而 SFTP 视图正是在切到该 tab 时挂载的（同时还并发一次 listDirectory），
  /// 这段窗口里用户完全可能已经点开了排序面板并选了一项 —— 慢读取回来时若
  /// 无条件 `_sort = prefs`，就把用户的刚做出的选择**覆盖回旧值**，界面看起来
  /// 就是「点了排序没反应」。
  ///
  /// widget 测试里 mock 的 prefs 几乎同步返回，所以这个窗口抓不到；真机上才
  /// 会暴露。
  bool _sortTouchedByUser = false;

  ({SortKey key, bool ascending}) _sort = (
    key: SortKey.name,
    ascending: true,
  );

  /// 已查到的软链目标。按 path 缓存，避免重复往返。
  ///
  /// **只查可见行**（由 itemBuilder 触发），不在 listDirectory 时批量查 ——
  /// 一个目录几百条软链全查是纯浪费，用户一次只看得到十几行。
  final Map<String, String?> _linkTargets = {};
  final Set<String> _linkTargetsInFlight = {};

  void _resolveLinkTarget(SftpEntry entry) {
    if (entry.linkState != SftpLinkState.ok) return;
    if (_linkTargets.containsKey(entry.path)) return;
    if (!_linkTargetsInFlight.add(entry.path)) return;
    _svc.readlink(entry.path).then((target) {
      if (!mounted) return;
      setState(() {
        _linkTargets[entry.path] = target;
        _linkTargetsInFlight.remove(entry.path);
      });
    }).catchError((e) {
      if (!mounted) return;
      setState(() {
        _linkTargets[entry.path] = null;
        _linkTargetsInFlight.remove(entry.path);
      });
    });
  }

  /// 排序后的当前目录内容。**不改 `_svc.entries` 本身** —— agent 路径依赖它
  /// 的默认顺序（服务层 `sortedEntries` 已经保证了这点，这里只是它的调用方）。
  List<SftpEntry> get _sortedEntries =>
      _svc.sortedEntries(key: _sort.key, ascending: _sort.ascending);

  List<SftpEntry> get _displayedEntries {
    if (_searchQuery.isEmpty) return _sortedEntries;
    final q = _searchQuery.toLowerCase();
    final filtered =
        _svc.entries.where((e) => e.name.toLowerCase().contains(q)).toList();
    // 过滤结果也要排序：否则搜索时的顺序与浏览时不一致，用户会以为排序
    // 在搜索态失效了。
    return sortEntries(filtered, key: _sort.key, ascending: _sort.ascending);
  }

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChanged);
    _loadSortPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _svc.listDirectory(widget.initialPath);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensurePathStore();
  }

  /// 解析出可用的 [SftpPathStore]。
  ///
  /// 注入优先（widget 测试）；否则读 `Database` provider 懒建 repository ——
  /// 这样不必在 `main.dart` 里注册 `SftpPathRepository`（那里牵动较多文件）。
  /// `Database` 取不到时静默放弃：历史记录是锦上添花，不该让整个浏览器崩掉。
  void _ensurePathStore() {
    if (_pathStore != null) return;
    final injected = widget.pathStore;
    if (injected != null) {
      _pathStore = injected;
      return;
    }
    final db = context.read<Database?>();
    if (db == null) return;
    _pathStore = SftpPathStore(
      repo: SftpPathRepository(db),
      serverId: widget.server.id,
    );
  }

  Future<void> _loadSortPrefs() async {
    final prefs = await widget.loadSortPrefs();
    if (!mounted) return;
    // **用户已经动过了就别覆盖。** 那次读取只是「恢复上次的偏好」，优先级
    // 低于用户刚刚的操作（见 [_sortTouchedByUser] 的文档）。
    if (_sortTouchedByUser) return;
    setState(() => _sort = prefs);
  }

  /// 本视图实例是否已自动重连过。宿主侧另有时间限流兜底（见
  /// `SessionTab.lastSftpAutoReconnect`）—— 这一层只防同一个视图里的重复触发。
  bool _autoReconnectDone = false;

  void _onChanged() {
    if (mounted) {
      setState(() {});
      widget.onPathChanged?.call(_svc.currentPath);
      _recordVisitIfNeeded();
      _maybeAutoReconnect();
    }
  }

  /// 目录成功列出后把当前路径记进历史。
  ///
  /// 只在**确实成功**时记录：
  ///  - `isLoading` 为真时不记 —— `listDirectory` 开头就 notify 一次，那个
  ///    时刻 `currentPath` 还是上一次的值（首次时是默认的 '/'）。
  ///  - `error != null` 时不记 —— 失败时 `currentPath` 不会更新，但初次进入
  ///    就失败时它仍是默认值 '/'，不想把 '/' 当成一次真实访问。
  ///  - 路径没变不重复写：`refresh` / 软链解析等都会再 notify。
  void _recordVisitIfNeeded() {
    final store = _pathStore;
    if (store == null) return;
    if (_svc.isLoading || _svc.error != null) return;
    final path = _svc.currentPath;
    if (path == _lastRecordedPath) return;
    _lastRecordedPath = path;
    // fire-and-forget：记录历史不该阻塞 UI，也不该因为写库失败就弹错。
    store.recordVisit(path).catchError((_) {});
  }

  /// 底层 SSH 被 sshd 的 idle timeout 悄悄关掉是常态 —— QUIC 会话尤其明显：
  /// 主通道一直活着，辅助 SSH 却会静静超时。让用户对着「空目录 + 重新连接」
  /// 按钮手动点一下，等于把实现细节甩给用户。这里替他点第一下。
  ///
  /// 只在**确认是连接断开**时触发（[SFTPService.isDisconnected]）：权限不足、
  /// 路径不存在这类错误重连一百次也没用，自动重连反而掩盖真正的问题。
  void _maybeAutoReconnect() {
    if (_autoReconnectDone) return;
    // **判据只有「是不是连接断了」一条。**
    //
    // 这里曾经还有个 `|| _svc.entries.isNotEmpty` —— 它把最常见的场景整个
    // 排除掉了：用户正浏览着某个目录时连接断掉，`listDirectory` 的 catch
    // 只记错误、**不清空 entries**，于是列表一直非空，自动重连永远不触发。
    // 真机表现就是「断了之后不会自己恢复，必须手动点重连」。那个守卫只在
    // 「空列表 + 断线」时才放行，而那恰恰是最罕见的情形。
    //
    // 重连不会丢失浏览位置：`SessionTab.invalidateSftpSvc` 刻意保留
    // `sftpCwd`，新连接从同一个目录起步。
    if (!_svc.isDisconnected) return;
    final cb = widget.onAutoReconnectRequested;
    if (cb == null) return;
    _autoReconnectDone = true;
    // 推到下一帧：此刻还在 notifyListeners 的回调里，直接重连会在 build
    // 期间改状态树。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb();
    });
  }

  /// 网络**类型**变了 —— 连接确定已失效（TCP 句柄在切网时作废），
  /// **直接**走既有重连路径，不做探活往返。
  ///
  /// 复用 [SftpInlineView.onAutoReconnectRequested]：宿主 `TerminalScreen`
  /// 在那条回调上挂了 30 秒限流，这里**不要**绕过它。
  ///
  /// 生产调用方：`TerminalScreen` 的 `ReconnectService.onNetworkTypeChanged`。
  /// 测试也可直接驱动它（State 类型是公有的）。
  void onNetworkChanged() {
    if (!mounted) return;
    widget.onAutoReconnectRequested?.call();
  }

  /// App 回到前台 —— **只探活，探不通才重连**。
  ///
  /// 「探通就不动」是关键：后台期间 keepalive 定时器停摆，连接**可能**已死，
  /// 但用户切出去看一眼通知再回来时它往往还活着，无差别重建会让列表闪一下。
  ///
  /// 生产调用方：`TerminalScreen` 的
  /// `ReconnectService.onForegroundResumedForSftp`。
  Future<void> onForegroundResumed() async {
    if (!mounted) return;
    final alive = await _svc.probeAlive();
    if (!mounted || alive) return;
    widget.onAutoReconnectRequested?.call();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _svc.removeListener(_onChanged);
    // Do NOT call _svc.dispose() here — SFTPService lifetime is owned by
    // SessionTab.sftpSvc, not by this view. SessionManager.closeTab() and
    // SessionTab.invalidateSftpSvc() handle disposal when the tab closes or
    // the connection needs to be re-established.
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Expose refresh() for AppBar refresh button or external callers.
  ///
  /// 走 [SFTPService.refresh]（silent），不进入 loading 态 —— 手动刷新与
  /// 下拉刷新应当有相同的体验：保留旧列表直到新数据到达。
  void refresh() {
    _svc.refresh();
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchQuery = '';
        _searchCtrl.clear();
      }
    });
  }

  // ── Speed Dial ───────────────────────────────────────────────────────────

  void _toggleSpeedDial() {
    if (_menuOpen) {
      _closeSpeedDial();
    } else {
      setState(() => _menuOpen = true);
      _animCtrl.forward();
    }
  }

  void _closeSpeedDial() {
    _animCtrl.reverse().then((_) {
      if (mounted) setState(() => _menuOpen = false);
    });
  }

  /// 选目录 → 扫描 → 预检冲突 → 弹一次确认 → 整批上传。
  ///
  /// **选择不持久化。** 缓存「以后都覆盖」很危险：用户下次可能忘了开关是
  /// 开着的，而覆盖不可逆。要覆盖就每次明确选。
  ///
  /// 三态用 `bool?` 承载：`true`=全部覆盖、`false`=全部跳过、`null`=取消。
  /// 不用两个对话框 —— 一个对话框三个按钮足够，且不会出现「先问了跳过、
  /// 又追问覆盖」的重复打扰。
  Future<void> _uploadDirectory() async {
    final dir = await widget.pickDirectory();
    if (dir == null || !mounted) return;
    await uploadDirectoryInto(dir);
  }

  /// 「选好目录之后」的那半段：扫描 → 探测冲突 → 确认一次 → 整批上传。
  ///
  /// 从 [_uploadDirectory] 拆出来是因为 `FilePicker.platform` 是静态单例、
  /// 测试里没法替换，而这段流程（尤其是三态确认对话框与 skip-set 的映射）
  /// 才是真正值得测的东西。
  @visibleForTesting
  Future<void> uploadDirectoryInto(String dir) async {
    final SftpUploadPlan plan;
    try {
      plan = await widget.scanDirectory(dir);
    } catch (_) {
      // 扫描失败（比如目录在选完之后被删）——服务层也会再扫一次并记录
      // 错误，这里静默返回即可，不额外弹窗。
      return;
    }
    if (!mounted) return;
    if (plan.files.isEmpty && plan.directories.isEmpty) return;

    final conflicts = await _svc.detectConflicts(
      remoteRoot: _svc.currentPath,
      relativePaths: plan.files.map((f) => f.relativePath).toList(),
    );
    if (!mounted) return;

    var overwrite = true;
    if (conflicts.isNotEmpty) {
      final l = context.l10n;
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.sftpConflictTitle(conflicts.length)),
          content: Text(l.sftpConflictBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(l.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.sftpConflictSkipAll),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.sftpConflictOverwriteAll),
            ),
          ],
        ),
      );
      if (choice == null) return; // 取消
      overwrite = choice;
    }

    await _svc.uploadDirectory(
      localRoot: dir,
      remoteRoot: _svc.currentPath,
      skipRelativePaths: overwrite ? const {} : conflicts,
      // 把刚扫好的结果传进去 —— 服务层再扫一遍是纯浪费（而且 widget 测试里
      // 真实 dart:io 扫描会挂住）。
      plan: plan,
    );
  }

  List<Widget> _buildSpeedDialStack(double bottomPad) {
    final l = context.l10n;
    final items = [
      _SpeedDialItem(
        icon: Icons.upload_file,
        label: l.sftpUploadFileAction,
        onTap: () {
          _closeSpeedDial();
          _svc.pickAndUpload();
        },
      ),
      _SpeedDialItem(
        icon: Icons.drive_folder_upload,
        label: l.sftpUploadFolderAction,
        onTap: () {
          _closeSpeedDial();
          _uploadDirectory();
        },
      ),
      _SpeedDialItem(
        icon: Icons.note_add_outlined,
        label: l.sftpCreateFileAction,
        onTap: () {
          _closeSpeedDial();
          _showNewFileDialog();
        },
      ),
      _SpeedDialItem(
        icon: Icons.create_new_folder_outlined,
        label: l.sftpCreateFolderAction,
        onTap: () {
          _closeSpeedDial();
          _showNewFolderDialog();
        },
      ),
    ];

    return [
      // Scrim barrier — tap outside to close
      if (_menuOpen)
        Positioned.fill(
          child: GestureDetector(
            onTap: _closeSpeedDial,
            behavior: HitTestBehavior.opaque,
            child: AnimatedBuilder(
              animation: _animCtrl,
              builder:
                  (_, __) => ColoredBox(
                    color: Colors.black.withValues(alpha: _animCtrl.value * 0.45),
                  ),
            ),
          ),
        ),

      // Mini FABs + labels (rendered bottom→up, index 0 = closest to main FAB)
      //
      // 关闭且动画归零后**不再构建它们** —— 比只靠 IgnorePointer 更彻底：
      // 不仅挡住点击，连布局与命中测试的开销也一并省掉。
      // 保留 `_menuOpen` 判断而不只依赖动画值，是因为收起动画播完之前
      // `_menuOpen` 仍为 true，那段窗口里用户看得到、也该点得到。
      if (_menuOpen || _animCtrl.value > 0)
        for (int i = 0; i < items.length; i++)
          _buildMiniFabItem(i, items[i], bottomPad),

      // Main FAB — rotates + → ×
      Positioned(
        right: _kFabMargin,
        bottom: _kFabMargin + bottomPad,
        child: FloatingActionButton(
          heroTag: 'sftp_main_fab',
          onPressed: _svc.isLoading ? null : _toggleSpeedDial,
          child: AnimatedBuilder(
            animation: _animCtrl,
            builder:
                (_, __) => Transform.rotate(
                  angle: _animCtrl.value * (math.pi / 4),
                  child: const Icon(Icons.add),
                ),
          ),
        ),
      ),
    ];
  }

  Widget _buildMiniFabItem(int i, _SpeedDialItem item, double bottomPad) {
    final bottom =
        _kFabMargin +
        bottomPad +
        _kFabSize +
        _kItemGap +
        i * (_kMiniFabSize + _kItemGap);

    // Stagger: each item animates slightly after the previous one
    final delay = i * 0.10;
    final end = (delay + 0.65).clamp(0.0, 1.0);
    final anim = CurvedAnimation(
      parent: _animCtrl,
      curve: Interval(delay, end, curve: Curves.easeOut),
    );

    return Positioned(
      right: _kFabMargin,
      bottom: bottom,
      child: AnimatedBuilder(
        animation: anim,
        builder:
            (ctx, child) => IgnorePointer(
              // **关闭时必须挡住命中测试。** `Opacity(0)` 只是不画，元素仍在
              // 命中测试树里 —— 关着的时候这 4 个 mini FAB（连带它们的标签）
              // 会静静地吃掉落在这个区域的点击：排序按钮、`..`、靠下的列表项
              // 看起来就是「点了没反应」。而且因为它们贴着屏幕底部偏上，正好
              // 盖住列表下半部分，所以表现为「有时候」。
              ignoring: anim.value == 0,
              child: Opacity(
                opacity: anim.value,
                child: Transform.translate(
                  offset: Offset(0, (1 - anim.value) * 18),
                  child: child,
                ),
              ),
            ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Material(
              color: const Color(0xFF2C2C2E),
              borderRadius: BorderRadius.circular(6),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(item.label, style: const TextStyle(fontSize: 13)),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: _kMiniFabSize,
              height: _kMiniFabSize,
              child: FloatingActionButton.small(
                heroTag: 'sftp_dial_$i',
                onPressed: item.onTap,
                child: Icon(item.icon, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Selection helpers ────────────────────────────────────────────────────

  void _clearSelection() => setState(() => _selectedPaths.clear());

  void _selectAll() =>
      setState(() => _selectedPaths.addAll(_svc.entries.map((e) => e.path)));

  void _toggleEntry(SftpEntry entry) => setState(() {
    if (_selectedPaths.contains(entry.path)) {
      _selectedPaths.remove(entry.path);
    } else {
      _selectedPaths.add(entry.path);
    }
  });

  // ── Entry actions ────────────────────────────────────────────────────────

  /// Files at or above this size are not downloaded implicitly on tap — the
  /// user confirms first. Below it, a tap goes straight to the OS opener:
  /// making someone tap twice for a 20 KB PDF is friction with no upside,
  /// while a stray tap on a 2 GB ISO is a real cost on mobile data.
  static const _kAutoOpenMaxBytes = 10 * 1024 * 1024;

  void _onEntryTap(SftpEntry entry) {
    if (entry.isDir) {
      if (_searchActive) _toggleSearch();
      _svc.listDirectory(entry.path);
    } else if (entry.isImageFile) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SFTPImageViewerScreen(entry: entry, svc: _svc),
        ),
      );
    } else if (entry.isMarkdownFile) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SftpMarkdownPreviewScreen(entry: entry, svc: _svc),
        ),
      );
    } else if (entry.isEditableText) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SFTPTextEditorScreen(entry: entry, svc: _svc),
        ),
      );
    } else {
      // Anything we can't render in-app: hand it to the system.
      _openWithSystem(entry);
    }
  }

  /// Download [entry] and hand it to the OS. Large files ask first.
  Future<void> _openWithSystem(SftpEntry entry) async {
    if (entry.size >= _kAutoOpenMaxBytes) {
      final l = context.l10n;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.sftpOpenWithSystem),
          content: Text(
            l.sftpConfirmLargeOpen(entry.name, entry.displaySize),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.open),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _downloadFile(entry, autoOpen: true);
  }

  Future<void> _downloadFile(SftpEntry entry, {bool autoOpen = false}) async {
    final savePath = await _svc.downloadFile(entry.path);
    if (!mounted) return;
    final l = context.l10n;
    if (savePath != null) {
      if (autoOpen) {
        // The tap itself was the intent to open, so open immediately instead
        // of relying on the user to hit the snackbar action.
        final result = await OpenFilex.open(savePath);
        if (!mounted) return;
        if (result.type != ResultType.done) {
          // No app on the device claims the type. Fall back to the ordinary
          // "saved" snackbar so the file isn't silently lost.
          _showSavedSnackBar(entry, savePath);
        }
        return;
      }
      _showSavedSnackBar(entry, savePath);
    } else if (_svc.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: _errorText(
            _svc.lastError ?? _svc.error!,
            prefix: l.sftpDownloadFailed(''),
          ),
        ),
      );
    }
  }

  void _showSavedSnackBar(SftpEntry entry, String savePath) {
    final l = context.l10n;
    final publicPath = _svc.lastPublishedPublicPath;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(publicPath != null
            ? l.downloadSavedToPublic(publicPath)
            : l.sftpSaved(entry.name)),
        action: SnackBarAction(
          label: l.open,
          onPressed: () => OpenFilex.open(savePath),
        ),
      ),
    );
  }

  Future<void> _downloadFolder(SftpEntry entry) async {
    final savePath = await _svc.downloadFolder(entry.path);
    if (!mounted) return;
    final l = context.l10n;
    if (savePath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.sftpSaved('${entry.name}/')),
          action: SnackBarAction(
            label: l.open,
            onPressed: () => OpenFilex.open(savePath),
          ),
        ),
      );
    } else if (_svc.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: _errorText(
            _svc.lastError ?? _svc.error!,
            prefix: l.sftpDownloadFailed(''),
          ),
        ),
      );
    }
  }

  void _showEntryActions(SftpEntry entry) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final l = ctx.l10n;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.check_box_outlined),
                title: Text(l.sftpBatchSelect),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _selectedPaths.add(entry.path));
                },
              ),
              const Divider(height: 1),
              if (entry.isDir)
                ListTile(
                  leading: const Icon(Icons.download),
                  title: Text(l.sftpDownloadFolder),
                  onTap: () {
                    Navigator.pop(ctx);
                    _downloadFolder(entry);
                  },
                ),
              if (!entry.isDir)
                ListTile(
                  leading: const Icon(Icons.download),
                  title: Text(l.sftpDownload),
                  onTap: () {
                    Navigator.pop(ctx);
                    _downloadFile(entry);
                  },
                ),
              // Only offered where the tap gesture doesn't already do it, so
              // the sheet stays honest about what's available.
              if (entry.isOpenableBySystem &&
                  entry.size >= _kAutoOpenMaxBytes)
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: Text(l.sftpOpenWithSystem),
                  onTap: () {
                    Navigator.pop(ctx);
                    _downloadFile(entry, autoOpen: true);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: Text(l.rename),
                onTap: () {
                  Navigator.pop(ctx);
                  _showRenameDialog(entry);
                },
              ),
              if (entry.permissions != null)
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(l.permissions),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showChmodDialog(entry);
                  },
                ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red.shade300),
                title: Text(
                  l.delete,
                  style: TextStyle(color: Colors.red.shade300),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDelete(entry);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Dialogs ──────────────────────────────────────────────────────────────

  Future<void> _showRenameDialog(SftpEntry entry) async {
    final ctrl = TextEditingController(text: entry.name);
    try {
      final newName = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final l = ctx.l10n;
          return AlertDialog(
            title: Text(l.rename),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(labelText: l.sftpNewName),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(l.confirm),
              ),
            ],
          );
        },
      );
      if (newName == null || newName.isEmpty || !mounted) return;
      final parentPath = entry.path.substring(0, entry.path.lastIndexOf('/'));
      final newPath = parentPath.isEmpty ? '/$newName' : '$parentPath/$newName';
      final ok = await _svc.rename(entry.path, newPath);
      if (!ok && mounted && _svc.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.sftpRenameFailed(_svc.error!))),
        );
      }
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _confirmDelete(SftpEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = ctx.l10n;
        return AlertDialog(
          title: Text(l.delete),
          content: Text(l.sftpConfirmDeleteEntry(entry.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                l.delete,
                style: TextStyle(color: Colors.red.shade300),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed == true && mounted) {
      final ok = await _svc.delete(entry.path, isDir: entry.isDir);
      if (!ok && mounted && _svc.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: _errorText(
              _svc.lastError ?? _svc.error!,
              prefix: context.l10n.sftpDeleteFailed(''),
            ),
          ),
        );
      }
    }
  }

  Future<void> _confirmDeleteSelected() async {
    final count = _selectedPaths.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = ctx.l10n;
        return AlertDialog(
          title: Text(l.delete),
          content: Text(l.sftpConfirmDeleteSelected(count)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                l.delete,
                style: TextStyle(color: Colors.red.shade300),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final toDelete =
        _svc.entries.where((e) => _selectedPaths.contains(e.path)).toList();
    _clearSelection();
    final ok = await _svc.deleteAll(toDelete);
    if (!ok && mounted && _svc.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sftpDeleteFailed(_svc.error!))),
      );
    }
  }

  Future<void> _downloadSelected() async {
    final toDownload =
        _svc.entries.where((e) => _selectedPaths.contains(e.path)).toList();
    _clearSelection();
    for (final entry in toDownload) {
      if (!mounted) return;
      if (entry.isDir) {
        await _svc.downloadFolder(entry.path);
      } else {
        await _svc.downloadFile(entry.path);
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.sftpDownloadsCompleted(toDownload.length)),
        ),
      );
    }
  }

  Future<void> _showNewFolderDialog() async {
    final ctrl = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final l = ctx.l10n;
          return AlertDialog(
            title: Text(l.sftpNewFolderTitle),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(labelText: l.sftpFolderName),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(l.create),
              ),
            ],
          );
        },
      );
      if (name == null || name.isEmpty || !mounted) return;
      final newPath =
          _svc.currentPath == '/' ? '/$name' : '${_svc.currentPath}/$name';
      final ok = await _svc.mkdir(newPath);
      if (!ok && mounted && _svc.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.sftpCreateFailed(_svc.error!))),
        );
      }
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _showNewFileDialog() async {
    final ctrl = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final l = ctx.l10n;
          return AlertDialog(
            title: Text(l.sftpNewFileTitle),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(labelText: l.sftpFileName),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(l.create),
              ),
            ],
          );
        },
      );
      if (name == null || name.isEmpty || !mounted) return;
      final newPath =
          _svc.currentPath == '/' ? '/$name' : '${_svc.currentPath}/$name';
      final ok = await _svc.createFile(newPath);
      if (!ok && mounted && _svc.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.sftpCreateFailed(_svc.error!))),
        );
      }
    } finally {
      ctrl.dispose();
    }
  }

  /// Chmod dialog: shows rwxrwxrwx toggles with live octal preview.
  Future<void> _showChmodDialog(SftpEntry entry) async {
    if (entry.permissions == null) return;
    int perms = entry.permissions! & 0x1FF; // rwxrwxrwx only

    final newPerms = await showDialog<int>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setS) {
              String b(int mask, String c) => (perms & mask) != 0 ? c : '-';
              final permStr =
                  '${b(0x100, 'r')}${b(0x80, 'w')}${b(0x40, 'x')}'
                  '${b(0x20, 'r')}${b(0x10, 'w')}${b(0x8, 'x')}'
                  '${b(0x4, 'r')}${b(0x2, 'w')}${b(0x1, 'x')}';
              final octal = perms.toRadixString(8).padLeft(3, '0');

              final l = ctx.l10n;
              Widget bitToggle(String label, int bit) {
                final mask = 1 << bit;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: (perms & mask) != 0,
                      visualDensity: VisualDensity.compact,
                      onChanged:
                          (v) => setS(() {
                            perms = v! ? perms | mask : perms & ~mask;
                          }),
                    ),
                    Text(label, style: const TextStyle(fontSize: 12)),
                  ],
                );
              }

              Widget permRow(String label, int shift) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 52,
                      child: Text(label, style: const TextStyle(fontSize: 13)),
                    ),
                    bitToggle(l.sftpRead, shift + 2),
                    bitToggle(l.sftpWrite, shift + 1),
                    bitToggle(l.sftpExecute, shift),
                  ],
                ),
              );

              return AlertDialog(
                title: Text(l.sftpPermissionsTitle(entry.name)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$octal  $permStr',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 16),
                    permRow(l.sftpOwner, 6),
                    permRow(l.sftpGroup, 3),
                    permRow(l.sftpOther, 0),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(l.cancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, perms),
                    child: Text(l.apply),
                  ),
                ],
              );
            },
          ),
    );

    if (newPerms == null || !mounted) return;
    // Preserve setuid/setgid/sticky bits (0xE00); replace only rwxrwxrwx.
    final fullMode = (entry.permissions! & 0xE00) | newPerms;
    final ok = await _svc.chmod(entry.path, fullMode);
    if (!ok && mounted && _svc.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sftpChmodFailed(_svc.error!))),
      );
    }
  }

  Future<void> _jumpToPath() async {
    final store = _pathStore;
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => _JumpToPathDialog(
        currentPath: _svc.currentPath,
        store: store,
      ),
    );
    if (input == null || input.isEmpty || !mounted) return;
    final path = input.startsWith('/') ? input : '/$input';
    _svc.listDirectory(path);
  }

  /// 排序 bottom sheet：三个维度 + 升/降序切换。
  ///
  /// 每次打开都重新 `SftpSortPrefs.load()` —— sheet 里的选中态是**权威快照**，
  /// 而不是 `_sort` 的镜像：万一外部（另一个视图实例）改了偏好，这里显示的
  /// 就是磁盘上的真实值。
  Future<void> _showSortSheet() async {
    final l = context.l10n;
    // **同步用内存里的 `_sort` 打开 sheet，不要先 await 磁盘。**
    //
    // 原来这里先 `await SftpSortPrefs.load()` 再弹 —— 那个 await 期间界面上
    // 没有任何反馈，只要它慢一点（或平台通道不可用而永远不返回），用户看到
    // 的就是「点了排序按钮没反应」。偏好读取只影响**哪一项高亮**，不该挡在
    // 交互前面；内存值本来就是它自己的最后状态，直接用即可。
    final current = _sort;
    final result = await showModalBottomSheet<({SortKey key, bool ascending})>(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final k in SortKey.values)
                  ListTile(
                    leading: Icon(
                      current.key == k
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(
                      switch (k) {
                        SortKey.name => l.sftpSortByName,
                        SortKey.size => l.sftpSortBySize,
                        SortKey.time => l.sftpSortByTime,
                      },
                    ),
                    onTap:
                        () => Navigator.pop(
                          ctx,
                          (key: k, ascending: current.ascending),
                        ),
                  ),
                const Divider(height: 1),
                // 方向项：**写「动作」而不是「状态」**。
                //
                // 原来这里显示的是当前状态（「升序」），用户读成一个标签而
                // 不是按钮，点了之后列表变了却不知道为什么。现在副标题报出
                // 当前状态，标题写清点下去会发生什么。
                ListTile(
                  leading: Icon(
                    current.ascending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                  ),
                  title: Text(
                    current.ascending
                        ? l.sftpSortToggleToDesc
                        : l.sftpSortToggleToAsc,
                  ),
                  subtitle: Text(
                    '${l.sftpSortDirectionLabel}：'
                    '${current.ascending ? l.sftpSortAscending : l.sftpSortDescending}',
                  ),
                  onTap:
                      () => Navigator.pop(ctx, (
                        key: current.key,
                        ascending: !current.ascending,
                      )),
                ),
              ],
            ),
          ),
    );
    if (result == null || !mounted) return;
    // 先切 UI，再落盘。落盘失败不该影响这次排序 —— 它只是一份「下次记住」
    // 的偏好，不是本次操作的成败条件。
    _sortTouchedByUser = true;
    setState(() => _sort = result);
    unawaited(
      SftpSortPrefs.save(key: result.key, ascending: result.ascending),
    );
  }

  // ── AppBar builders ──────────────────────────────────────────────────────

  AppBar _buildNormalAppBar() {
    final svc = _svc;
    return AppBar(
      automaticallyImplyLeading: false,
      title: _searchActive
          ? GestureDetector(
              onTap: _jumpToPath,
              child: Text(
                svc.currentPath,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            )
          : SftpBreadcrumb(
              path: svc.currentPath,
              onSegmentTap: (p) => _svc.listDirectory(p),
            ),      actions: _searchActive
          ? [
              // Search field replaces the search icon button in-place.
              // Fixed height prevents the AppBar from resizing while typing.
              //
              // **这里是搜索框统一化（2026-10-13）的唯一例外，且是刻意的**：
              // 它嵌在 AppBar 的 action 槽里（槽高由 toolbar 决定），必须
              // 钉死高度，否则一边输入 AppBar 一边变高。页面级搜索框的标准
              // 高度是 40dp（见 `searchFieldDecoration`），但那要求父容器
              // 不是 AppBar。kSearchFieldAppBarHeight 就是「嵌在 AppBar 里」
              // 这一档的命名值。
              //
              // 仍向统一形态靠拢的部分：去掉写死的 contentPadding（交给
              // theme 在固定高度内自适应）与自定的圆角（改用
              // `FlyRadius.controlRadius`）；保留暗色填充（AppBar 上需要
              // 与背景拉开）。
              SizedBox(
                width: 180,
                height: kSearchFieldAppBarHeight,
                child: Center(child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: context.l10n.sftpSearchHint,
                    isDense: true,
                    // 不写 contentPadding —— 交给 theme。写死的话又会回到
                    // 「每个页面自己调数字」。
                    border: const OutlineInputBorder(
                      borderRadius: FlyRadius.controlRadius,
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.white10,
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            // 三件都要：IconButton 自带 48 的 minimumSize，
                            // 只给 constraints 拦不住（同 `searchFieldDecoration`
                            // 里 onClear 的说明）。这里没走那个函数是因为
                            // AppBar 嵌装这套填充/无边框样式是它独有的。
                            constraints: kSearchIconConstraints,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _searchQuery = '';
                              _searchCtrl.clear();
                            }),
                          )
                        : null,
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v),
                ),
              )), // end Center + SizedBox
              IconButton(
                icon: const Icon(Icons.search_off),
                onPressed: _toggleSearch,
              ),
            ]
          : [
              // 手输路径的入口。**不能只靠面包屑** —— 面包屑只能去已访问过的
              // 祖先目录，而「跳到任意路径」（贴一个 `/etc/nginx` 进去）是既有
              // 能力，拆面包屑时差点把它丢了。
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: context.l10n.sftpJumpToPath,
                onPressed: _jumpToPath,
              ),
              IconButton(
                icon: const Icon(Icons.sort),
                tooltip: context.l10n.sftpSortTooltip,
                onPressed: _showSortSheet,
              ),
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: context.l10n.sftpSearchHint,
                onPressed: _toggleSearch,
              ),
            ],
    );
  }

  AppBar _buildSelectionAppBar() => AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      onPressed: _clearSelection,
    ),
    title: Text(context.l10n.sftpSelectedCount(_selectedPaths.length)),
    actions: [
      TextButton(
        onPressed: _selectAll,
        child: Text(context.l10n.sftpSelectAll),
      ),
    ],
  );

  // ── Selection action bar (bottom) ────────────────────────────────────────

  Widget _buildSelectionActions() => SafeArea(
    top: false,
    child: Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Text(
            context.l10n.sftpSelectedItems(_selectedPaths.length),
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: context.l10n.sftpDownload,
            onPressed: _downloadSelected,
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, color: Colors.red.shade300),
            tooltip: context.l10n.delete,
            onPressed: _confirmDeleteSelected,
          ),
        ],
      ),
    ),
  );

  // ── Subtitle ─────────────────────────────────────────────────────────────

  Widget _buildLeadingIcon(SftpEntry entry) {
    final icon = Icon(fileIcon(entry), color: fileIconColor(entry));
    if (!entry.isSymlink) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        const Positioned(
          right: -2,
          bottom: -2,
          child: Icon(symlinkBadgeIcon, size: 10, color: symlinkBadgeColor),
        ),
      ],
    );
  }

  Widget? _buildSubtitle(SftpEntry entry) {
    final parts = <String>[];
    if (entry.linkState == SftpLinkState.dangling) {
      parts.add(context.l10n.sftpSymlinkDangling);
    } else {
      final target = _linkTargets[entry.path] ?? entry.linkTarget;
      if (target != null) parts.add(context.l10n.sftpSymlinkTarget(target));
    }
    final perm = entry.permissionsString;
    if (perm.isNotEmpty) parts.add(perm);
    if (!entry.isDir && entry.size > 0) parts.add(entry.displaySize);
    if (entry.modTime.millisecondsSinceEpoch > 0) {
      parts.add(entry.modTime.toLocal().toString().substring(0, 16));
    }
    if (parts.isEmpty) return null;
    return Text(parts.join('  '), style: const TextStyle(fontSize: 11));
  }

  /// 排序诊断条。**只在开发者模式（设置里 7 连击开启的 debugOverlay）下显示。**
  ///
  /// 为什么需要它：排序「点了没反应」被归因过两次异步竞态，两次都没修好。
  /// 根子在于真机上看不见任何中间量 —— `_sort` 到底变没变、排序后的列表到底
  /// 是什么顺序、视图是不是被悄悄重建了，全靠猜。`dlog` 在 release 里被
  /// tree-shake（而本项目禁止 debug 构建），`DebugOverlay` 又挂在终端那棵树上、
  /// SFTP 视图可见时它正好被 Offstage 盖掉，两条现成的路都不通。
  ///
  /// 三行各自回答一个分叉：
  ///   - `s=` 当前排序维度/方向 —— 点一次排序它若不变，问题在面板返回值
  ///   - `top:` 排序**之后**的前三项 —— 它变了而列表没变，问题在渲染层；
  ///     它也不变，问题在排序函数的输入
  ///   - `st=`/`svc=` State 与 SFTPService 的身份 —— 跳变说明视图被重建
  ///     或底层连接被换掉（本类没有 didUpdateWidget，换 svc 不会重绑监听）
  Widget? _buildSortDiag() {
    final settings = context.watch<TerminalSettings?>();
    if (settings == null || !settings.debugOverlay) return null;
    final shown = _displayedEntries;
    final dirCount = shown.where((e) => e.isDir).length;
    final top = shown.take(3).map((e) => e.name).join(' | ');
    final st = identityHashCode(this).toRadixString(16);
    final svcId = identityHashCode(_svc).toRadixString(16);
    const style = TextStyle(
      fontSize: 10,
      height: 1.3,
      fontFamily: 'monospace',
      color: Colors.yellowAccent,
    );
    return Container(
      width: double.infinity,
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            's=${_sort.key.name}/${_sort.ascending ? "asc" : "desc"}  '
            'n=${shown.length}(d$dirCount/f${shown.length - dirCount})  '
            'st=$st svc=$svcId  '
            // 断线诊断：disc=Y 表示 svc 认为底层连接已断；auto=Y 表示这个
            // 视图实例已经自动重连过一次（`_autoReconnectDone`，宿主另有
            // 30s 限流）。「断了但 auto=N」说明自愈没被触发。
            'disc=${_svc.isDisconnected ? "Y" : "N"} '
            'auto=${_autoReconnectDone ? "Y" : "N"}',
            style: style,
          ),
          Text('top: $top', style: style),
        ],
      ),
    );
  }

  /// 把异常变成可读文案。原文保留在可展开的详情里 ——
  /// 协议码常常是排查唯一线索，不能被分类吞掉。
  Widget _errorText(Object e, {String? prefix}) {
    final err = SftpError.classify(e);
    final l = context.l10n;
    final msg = switch (err.kind) {
      SftpErrorKind.permissionDenied => l.sftpErrPermissionDenied,
      SftpErrorKind.notFound => l.sftpErrNotFound,
      SftpErrorKind.diskFull => l.sftpErrDiskFull,
      SftpErrorKind.disconnected => l.sftpErrDisconnected,
      SftpErrorKind.alreadyExists => l.sftpErrAlreadyExists,
      SftpErrorKind.unknown => err.raw,
    };
    final body = prefix == null ? msg : '$prefix$msg';
    if (err.kind == SftpErrorKind.unknown) return Text(body);
    // 分类给出人话，原文另起一行作为可追溯的细节 —— 协议码常常是排查
    // 唯一线索，不能被分类吞掉。用两行 Text 而不是可展开控件：这段文字
    // 住在 SnackBar 里，那里没有稳定的展开/滚动语义。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(body),
        Text(
          '${l.sftpErrRawDetail}: ${err.raw}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  /// 把一个不可滚动的居中提示包成可滚动的，供 [RefreshIndicator] 使用。
  ///
  /// `RefreshIndicator` 只在子组件可滚动（并且把下拉手势沿 scroll axis
  /// 上报）时才能触发。空目录 / 错误态本来是 `Center`，装在
  /// `SingleChildScrollView` 里配上 [AlwaysScrollableScrollPhysics]，内容
  /// 不足一屏也能下拉。`LayoutBuilder` + `ConstrainedBox(minHeight)` 让内容
  /// 在有多余空间时仍垂直居中 —— 直接 `Center` 包 ScrollView 会丢掉居中。
  Widget _buildScrollableMessage({required List<Widget> children}) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 空目录 / 无搜索结果。
  ///
  /// 用 [ListView] 而不是 `Column`：`RefreshIndicator` 需要可滚动的子组件，
  /// 否则空目录时下拉手势直接失效（用户会以为刷新坏了）。
  Widget _buildEmptyState() {
    final svc = _svc;
    // **搜索态也显示 `..`。** 它不是搜索结果，而是「离开这里」的出口；
    // 过滤后空手时把它藏起来，用户就只剩面包屑一条路，很容易感觉
    // 「点了上级没反应」。
    final showDotDot = svc.currentPath != '/';
    final emptyText = svc.entries.isEmpty
        ? context.l10n.sftpEmptyDirectory
        : context.l10n.noSearchResults;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // Show ".." even when directory is empty so the user can always
        // navigate up without the AppBar.
        if (showDotDot)
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('..'),
            dense: true,
            visualDensity: VisualDensity.compact,
            onTap: _goToParent,
          ),
        SizedBox(
          height: 160,
          child: Center(child: Text(emptyText)),
        ),
      ],
    );
  }

  /// 去上一级。**两个分支（空态 / 有内容）共用这一份** —— 之前是两份拷贝，
  /// 于是行为悄悄分叉了：列表分支会退出搜索态，空态那份不会。用户搜到一个
  /// 空结果后点 `..`，搜索词还在，看起来就像「点了没反应、没刷新」。
  void _goToParent() {
    final cur = _svc.currentPath;
    if (cur == '/' || cur.isEmpty) return;
    final parent = cur.substring(0, cur.lastIndexOf('/'));
    if (_searchActive) _toggleSearch();
    _svc.listDirectory(parent.isEmpty ? '/' : parent);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final svc = _svc;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return PopScope(
      canPop: !_isSelecting && !_menuOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_isSelecting) {
            _clearSelection();
          } else {
            _closeSpeedDial();
          }
        }
      },
      child: Scaffold(
        // Keep FAB fixed at the bottom — keyboard is only used inside
        // dialogs (rename, path input) that manage their own layout.
        resizeToAvoidBottomInset: false,
        appBar: _isSelecting ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: Stack(
        children: [
          // Main content
          Column(
            children: [
              if (svc.transferState != null)
                SftpTransferProgress(
                  state: svc.transferState!,
                  onCancel: svc.cancelTransfer,
                ),
              ?_buildSortDiag(),
              Expanded(
                child:
                    svc.isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : RefreshIndicator(
                            onRefresh: svc.refresh,
                            child:
                                svc.error != null && svc.entries.isEmpty
                                ? _buildScrollableMessage(
                                    children: [
                                      // **走分类器**，不要直接显示 svc.error ——
                                      // 那是 dartssh2 的原始异常文本或内部
                                      // message，用户看不懂。lastError 是原始
                                      // 异常对象（阶段 A 加的），优先用它；
                                      // 拿不到时退回字符串。
                                      _errorText(
                                        svc.lastError ?? svc.error!,
                                      ),
                                      if (widget.onReconnectRequested !=
                                          null) ...[
                                        const SizedBox(height: 16),
                                        ElevatedButton.icon(
                                          icon: const Icon(Icons.refresh),
                                          label: Text(context.l10n.reconnect),
                                          onPressed:
                                              widget.onReconnectRequested,
                                        ),
                                      ],
                                    ],
                                  )
                                : _displayedEntries.isEmpty
                                ? _buildEmptyState()
                                : ListView.builder(
                                    // Extra bottom padding so last item isn't hidden by FAB
                                    padding:
                                        _isSelecting
                                            ? null
                                            : EdgeInsets.only(
                                              bottom:
                                                  _kFabSize +
                                                  _kFabMargin * 2 +
                                                  bottomPad,
                                            ),
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    itemCount:
                                        _displayedEntries.length +
                                        // ".." virtual entry: shown when not searching
                                        // and not already at the filesystem root.
                                        (svc.currentPath != '/' ? 1 : 0),
                                    itemBuilder: (context, i) {
                                      // ".." entry navigates to the parent directory.
                                      final showDotDot =
                                          svc.currentPath != '/';
                                      if (showDotDot && i == 0) {
                                        return ListTile(
                                          leading: const Icon(Icons.folder),
                                          title: const Text('..'),
                                          dense: true,
                                          onTap: _goToParent,
                                        );
                                      }
                                      final entry =
                                          _displayedEntries[showDotDot
                                              ? i - 1
                                              : i];
                                      if (entry.isSymlink) {
                                        _resolveLinkTarget(entry);
                                      }
                                      final isSelected = _selectedPaths.contains(
                                        entry.path,
                                      );
                                      return ListTile(
                                        dense: true,
                                        visualDensity: VisualDensity.compact,
                                        leading:
                                            _isSelecting
                                                ? Checkbox(
                                                    value: isSelected,
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    onChanged: (_) =>
                                                        _toggleEntry(entry),
                                                  )
                                                : _buildLeadingIcon(entry),
                                        title: Text(entry.name),
                                        subtitle: _buildSubtitle(entry),
                                        selected: isSelected,
                                        onTap:
                                            _isSelecting
                                                ? () => _toggleEntry(entry)
                                                : () => _onEntryTap(entry),
                                        onLongPress: () =>
                                            _showEntryActions(entry),
                                      );
                                    },
                                  ),
                          ),
              ),
              if (_isSelecting) _buildSelectionActions(),
            ],
          ),

          // Speed dial (hidden in selection mode)
          if (!_isSelecting) ..._buildSpeedDialStack(bottomPad),
        ],
        ),
      ),
    );
  }
}

class _SpeedDialItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SpeedDialItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

/// 「跳转到路径」对话框：上半是输入框 + 历史补全建议，下半是「最近 / 已收藏」
/// 两个页签。
///
/// 补全**只查本地历史**（见 `SftpPathStore.suggest`）—— 远端实时 listdir 补全
/// 会在移动网络上每敲一个字符发一次往返，且与输入法候选栏打架。
///
/// [store] 为 null（拿不到数据库 / widget 测试未注入）时退化为纯输入框，历史
/// 相关的下半部分整块隐藏。
class _JumpToPathDialog extends StatefulWidget {
  const _JumpToPathDialog({required this.currentPath, required this.store});

  final String currentPath;
  final SftpPathStore? store;

  @override
  State<_JumpToPathDialog> createState() => _JumpToPathDialogState();
}

class _JumpToPathDialogState extends State<_JumpToPathDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.currentPath);

  List<String> _suggestions = const [];
  List<SftpPath> _recent = const [];
  List<SftpPath> _pinned = const [];
  bool _showPinned = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onQueryChanged);
    _loadHistory();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onQueryChanged);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final store = widget.store;
    if (store == null) return;
    final recent = await store.recent();
    final pinned = await store.pinned();
    if (!mounted) return;
    setState(() {
      _recent = recent;
      _pinned = pinned;
    });
  }

  Future<void> _onQueryChanged() async {
    final store = widget.store;
    if (store == null) return;
    final q = _ctrl.text.trim();
    final suggestions = await store.suggest(q);
    if (!mounted) return;
    setState(() => _suggestions = suggestions);
  }

  Future<void> _togglePin(SftpPath p) async {
    final store = widget.store;
    if (store == null) return;
    await store.setPinned(p.path, !p.pinned);
    await _loadHistory();
    await _onQueryChanged();
  }

  Future<void> _removePath(SftpPath p) async {
    final store = widget.store;
    if (store == null) return;
    await store.remove(p.path);
    await _loadHistory();
    await _onQueryChanged();
  }

  void _choose(String path) => Navigator.pop(context, path);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final store = widget.store;
    final items = _showPinned ? _pinned : _recent;
    // 补全建议只在用户**已经开始输入**时出现：不输入时下方「最近」列表已经
    // 是同一批内容，两处都画只是重复。
    final typed = _ctrl.text.trim();
    final userTyping = typed.isNotEmpty && typed != widget.currentPath;
    final visibleSuggestions = userTyping
        ? _suggestions
            .where((s) => s != typed && s != widget.currentPath)
            .toList()
        : const <String>[];

    return AlertDialog(
      title: Text(l.sftpJumpToPath),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(hintText: '/path/to/dir'),
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
            ),
            if (store != null && visibleSuggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l.sftpPathSuggestions,
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in visibleSuggestions)
                      InkWell(
                        onTap: () => _choose(s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              const Icon(Icons.history, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  s,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (store != null) ...[
              const Divider(),
              Row(
                children: [
                  _TabChip(
                    label: l.sftpRecentPaths,
                    selected: !_showPinned,
                    onTap: () => setState(() => _showPinned = false),
                  ),
                  const SizedBox(width: 8),
                  _TabChip(
                    label: l.sftpPinnedPaths,
                    selected: _showPinned,
                    onTap: () => setState(() => _showPinned = true),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _showPinned
                        ? l.sftpNoPinnedPaths
                        : l.sftpNoRecentPaths,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in items)
                        InkWell(
                          onTap: () => _choose(p.path),
                          onLongPress: () => _togglePin(p),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Icon(
                                  p.pinned
                                      ? Icons.push_pin
                                      : Icons.folder_outlined,
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    p.path,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  iconSize: 16,
                                  visualDensity: VisualDensity.compact,
                                  tooltip: p.pinned
                                      ? l.sftpUnpinPath
                                      : l.sftpPinPath,
                                  icon: Icon(
                                    p.pinned
                                        ? Icons.star
                                        : Icons.star_border,
                                  ),
                                  onPressed: () => _togglePin(p),
                                ),
                                IconButton(
                                  iconSize: 16,
                                  visualDensity: VisualDensity.compact,
                                  tooltip: l.sftpRemovePath,
                                  icon: const Icon(Icons.close),
                                  onPressed: () => _removePath(p),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(l.jump),
        ),
      ],
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? scheme.primary : null,
            fontWeight: selected ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }
}
