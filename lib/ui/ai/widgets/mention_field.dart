// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../ai/agent/builtin_skill_manager.dart';
import '../../../ai/agent/skill.dart';
import '../../../ai/attachment.dart';
import '../../../data/models/favorite_command.dart';
import '../../../data/models/server.dart';
import '../../../l10n/l10n.dart';
import '../../../sftp/sftp_entry.dart';
import '../mention.dart';
import '../file_index.dart';
import 'attachment_bar.dart';
import 'mention_overlay.dart';
import 'panel_chrome.dart';

/// 把 [PanelInputRow] 包上 `@` 引用能力。
///
/// **只在 agent 模式挂。** `PanelInputRow` 是 agent 模式与直连模式共用的
/// （`direct_chat_view` 也用它），而 `@file` / `@server` 的意义完全来自 agent
/// 的工具语义 —— 直连模式没有 `read_file`、没有 `server` 参数。所以补全逻辑
/// 放在这一层，`PanelInputRow` 一行不改。
///
/// **浮层是 Column 的一员，不是 Stack + Positioned。** 宿主 `agent_view` 的
/// body 本来就是 Column（消息列表在 Expanded 里、输入行在最后），插一员进去
/// 列表会自然收缩让位：不需要测量输入框高度、不会遮挡输入框、键盘弹起时也
/// 不用重算位置。
class MentionField extends StatefulWidget {
  final TextEditingController ctrl;
  final VoidCallback onSubmit;
  final String? hintText;

  final List<Server> servers;
  final List<SkillIndexEntry> skills;
  final List<FavoriteCommand> commands;

  /// 点击附件按钮。null = 不渲染附件按钮。透传给 [PanelInputRow]。
  final VoidCallback? onAttachTap;

  /// false 时附件按钮置灰（当前模型不支持图片输入）。透传给 [PanelInputRow]。
  final bool attachEnabled;

  /// 按钮灰着时点它。透传给 [PanelInputRow]，语义见那里的文档。
  final VoidCallback? onAttachBlockedTap;

  /// 待发送的附件。null = 没有待发附件，不渲染预览条。
  ///
  /// 与 `@` 浮层**共用输入框上方那个位置**，两者不会同时出现 —— 浮层只在
  /// 光标处于 `@` 上下文时才弹，见 [build] 里的条件。
  final Attachment? pendingAttachment;

  /// [pendingAttachment] 的缩略图文件。null 时 [AttachmentBar] 显示占位图标。
  final File? pendingThumbnailFile;

  /// 点预览条的 ✕。[pendingAttachment] 非 null 时才会被渲染进 [AttachmentBar]。
  final VoidCallback? onRemoveAttachment;

  /// 与 `agentToolSpecsFor(hasOtherServers: ...)` 同一个判据。
  final bool hasOtherServers;

  /// 列一个远端目录。null = 这个会话没有可用的 SFTP 通道（本地 shell），
  /// file 分组不出现。
  final RemoteDirLister? listRemoteDir;

  /// 把 `~` 起头的路径解析成绝对路径。与 [listRemoteDir] 同生共死。
  final RemotePathResolver? resolveRemotePath;

  /// 当前会话的工作目录，`./` 前缀的基准。null = 取不到（此时 `./` 提示改用
  /// 绝对路径）。
  ///
  /// **`./` 不能走 [resolveRemotePath]。** 那条实现是 SFTP 的
  /// `absolutePath('.')`，返回的是 SFTP 会话的初始目录（通常是 home），与
  /// 用户在终端里 `cd` 到的位置无关。`./` 的语义定为「当前会话 cwd」，所以
  /// 必须由宿主把 `tab.cwd` 传进来。
  final String? cwd;

  const MentionField({
    super.key,
    required this.ctrl,
    required this.onSubmit,
    required this.servers,
    required this.skills,
    required this.commands,
    this.hasOtherServers = false,
    this.listRemoteDir,
    this.resolveRemotePath,
    this.cwd,
    this.hintText,
    this.onAttachTap,
    this.attachEnabled = true,
    this.onAttachBlockedTap,
    this.pendingAttachment,
    this.pendingThumbnailFile,
    this.onRemoveAttachment,
  });

  @override
  State<MentionField> createState() => _MentionFieldState();
}

class _MentionFieldState extends State<MentionField> {
  static const _kDebounce = Duration(milliseconds: 250);
  static const _kFileRenderLimit = 50;

  MentionQuery? _q;
  List<MentionCandidate> _candidates = const [];

  /// 已加载的目录 → 它的条目。键是 `<serverId|>abs` —— **serverId 必须进
  /// 键**：两台机器上都有 `/var/log`，共用一个键会让第二台机的列表把第一台
  /// 的覆盖掉，用户看到的是另一台机器的文件，而路径看起来完全正确。
  ///
  /// 当前机的 serverId 段为空串，与跨机的键天然不撞。
  ///
  /// 面板关一次就弃：远端文件会变，缓存活得越久越可能拿旧
  /// 列表插一个已经不存在的路径。
  final Map<String, List<SftpEntry>> _cache = {};

  /// `~` / `.` 的解析结果缓存，键同样是 `<serverId|>原样写法`。
  final Map<String, String> _resolved = {};

  /// 后台索引的 generation。递增一次就作废在途的那次递归 ——
  /// 与 [_reqSeq] 同源的手法，但管的是另一件事：[_reqSeq] 管单次 `listdir`
  /// 的结果落地，这个管整棵递归树。
  ///
  /// 面板关闭、切机器、**索引根变化**三种情况都要递增（最后一种最易漏：
  /// `/etc` 的递归会继续烧网络，而用户已经在看 `/var`）。
  int _indexSeq = 0;

  /// 每个 serverId 当前正在索引的根。
  ///
  /// **必须有它。** 没有的话每个中间目录都会变成一棵新树的根：用户从 `/` 打
  /// 到 `/etc/ng` 会依次起 `/`、`/etc` 两棵树，而第二棵把第一棵的工作重做
  /// 一遍 —— 请求数翻倍，正是本项要消灭的东西。
  ///
  /// 判据是「新的 dir 是否在旧根之下」而不是「是否相等」：`/etc` 是 `/` 的
  /// 后代，在 `/` 的树里已经会被递归到，不需另起。
  final Map<String, String> _indexRoot = {};

  /// 索引写进 [_cache] 之后的重绘合并。递归是逐层落地的，一层一个
  /// `setState` 会让候选列表在几百毫秒里抖几十次；合并到帧上只重绘一次。
  bool _indexRepaintScheduled = false;

  String _cacheKey(String? serverId, String path) => '${serverId ?? ''}|$path';

  /// `firstWhere` 的 orElse 哨兵。用 `identical` 判定，不靠字段值 —— 服务器
  /// 名理论上可以是任何字符串，拿某个「不可能的名字」当哨兵迟早会撞。
  static const _kNoServer = Server(
    id: '',
    name: '',
    host: '',
    port: 0,
    username: '',
    authType: 'password',
  );

  Timer? _debounce;

  /// in-flight 请求的序号。回调落地时若已不是最新，丢弃结果 —— 用户打字比
  /// 网络快，旧请求后到会把新目录的列表覆盖掉。
  int _reqSeq = 0;

  MentionFileState _fileState = MentionFileState.idle;
  String? _fileError;
  int _moreCount = 0;

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(MentionField old) {
    super.didUpdateWidget(old);
    if (old.ctrl != widget.ctrl) {
      old.ctrl.removeListener(_onChanged);
      widget.ctrl.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // 递增 generation：递归树在下一层边界就停，不再烧网络。（写进 `_cache`
    // 的那部分随本 State 一起被 GC。）
    _indexSeq++;
    widget.ctrl.removeListener(_onChanged);
    super.dispose();
  }

  void _close() {
    _debounce?.cancel();
    if (_q == null) return;
    setState(() {
      _q = null;
      _candidates = const [];
      _fileState = MentionFileState.idle;
      _fileError = null;
      _moreCount = 0;
    });
  }

  void _onChanged() {
    final sel = widget.ctrl.selection;
    final q = sel.isValid
        ? parseMention(widget.ctrl.text, sel.baseOffset)
        : null;
    if (q == null) {
      _close();
      return;
    }

    // slash：零远端请求，纯本地匹配。
    if (q.kind == TriggerKind.slash) {
      _debounce?.cancel();
      // 内置在前：它们是产品自带的流程入口，用户打 `/` 最可能要的就是
      // 这两条。
      final allSkills = [
        ...context.read<BuiltinSkillManager>().entries,
        ...widget.skills,
      ];
      // 句中的 slash 与路径在语法上完全同形，只能靠名字表分开 —— 精确没
      // 命中就不弹浮层（`看下 /var/log` 里 `var` 不是技能名，浮层必须关）。
      // 判据全在纯函数里，见 `slashExactMatch` 的文档。
      if (!q.atStart &&
          !slashExactMatch(
            query: q.query,
            skills: allSkills,
            commands: widget.commands,
          )) {
        _close();
        return;
      }
      final local = matchLocal(
        kind: TriggerKind.slash,
        query: q.query,
        servers: widget.servers,
        skills: allSkills,
        commands: widget.commands,
        hasOtherServers: widget.hasOtherServers,
      );
      // 匹配不到就关。**这条不是优化，是必需的**：整条消息以路径开头
      // （`/var/log/nginx 看一下`）时，没有它浮层会一直赖在屏幕上。
      if (local.isEmpty) {
        _close();
        return;
      }
      setState(() {
        _q = q;
        _candidates = local;
        _fileState = MentionFileState.idle;
        _fileError = null;
        _moreCount = 0;
      });
      return;
    }

    final sp = splitServerPath(q.query);

    // 冒号之前：纯本地匹配服务器名，一个包都不发。
    if (!sp.hasColon) {
      final local = matchLocal(
        kind: TriggerKind.at,
        query: q.query,
        servers: widget.servers,
        skills: [
          ...context.read<BuiltinSkillManager>().entries,
          ...widget.skills,
        ],
        commands: widget.commands,
        hasOtherServers: widget.hasOtherServers,
      );
      final split = splitDirPrefix(q.query);
      // query 里还没有 '/' —— 只列服务器，不发远端请求。
      if (split.dir.isEmpty) {
        _debounce?.cancel();
        setState(() {
          _q = q;
          _candidates = local;
          _fileState = MentionFileState.idle;
          _fileError = null;
          _moreCount = 0;
        });
        return;
      }
      _startDirLoad(q, split.dir, split.prefix, null, local);
      return;
    }

    // 冒号之后：目标机的文件浏览。机器名必须先匹配得上，否则一个包都不发。
    final target = widget.servers.firstWhere(
      (s) => s.serverType == 'ssh' && s.name == sp.server,
      orElse: () => _kNoServer,
    );
    if (identical(target, _kNoServer)) {
      _debounce?.cancel();
      setState(() {
        _q = q;
        _candidates = const [];
        _fileState = MentionFileState.idle;
        _fileError = context.l10n.mentionUnknownServer(sp.server);
        _moreCount = 0;
      });
      return;
    }

    // 冒号后为空 → 列该机 home。**有意偏离**当前机那条路的规则（那边是
    // 「没有 `/` 就不发请求」）：冒号已经明确表达了「我要浏览这台机」，此时
    // 不给东西看反而要用户再多打一个字符。
    final split = sp.path.isEmpty
        ? (dir: '.', prefix: '')
        : splitDirPrefix(sp.path);
    if (split.dir.isEmpty) {
      // `web-02:va` —— 路径段还没出现 `/`，等用户打完再发。
      _debounce?.cancel();
      setState(() {
        _q = q;
        _candidates = const [];
        _fileState = MentionFileState.idle;
        _fileError = null;
        _moreCount = 0;
      });
      return;
    }
    _startDirLoad(q, split.dir, split.prefix, target.id, const []);
  }

  /// 起一次后台索引（若这个根还没起过）。
  ///
  /// 在 [_loadDir] 单层加载落地**之后**调用（不是之前 —— 见那里的注释）。
  /// **不 await**：索引是后台加速层，用户等的是候选，不是索引。建好一层就
  /// 刷一次候选，用户看到的是候选逐层冒出来，而不是先转一个三秒的圈。
  ///
  /// [root] 必须是绝对路径：调用方已把 `~` / `.` / 冒号形态解析掉了。
  void _ensureIndex(String root, String? serverId) {
    final sk = serverId ?? '';
    final current = _indexRoot[sk];
    // 已经在为某棵树干活，且新的 dir 在它里面 → 什么都不用做，那棵树会
    // （或已经）递归到它。
    if (current != null && _isUnder(root, current)) return;

    final lister = widget.listRemoteDir;
    if (lister == null) return;
    _indexRoot[sk] = root;
    final seq = ++_indexSeq;
    buildFileIndex(
      root: root,
      serverId: serverId,
      listDir: lister,
      // 写进 `_cache`，与逐层加载共用一张表：谁先到谁赢，后来的覆盖（远端
      // 文件会变，旧的本就该被覆盖）。两张表会出现「同一目录两份数据、谁新
      // 谁旧」的问题，而增量补齐必然让两份不一致。
      //
      // **必须经 [_cacheKey] 包一层。** `_cache` 的键是 `<serverId>|abs`，而
      // `buildFileIndex` 以为它拿到的是「纯路径 → 条目」。直接传 `_cache`
      // 会同时错两件事：索引写进去的键没有前缀（[_applyLocalDir] 永远查不到），
      // 而它的「已在缓存就跳过」也永远落空（于是又把刚列过的那层重列一遍）。
      sink: _ScopedCacheView(_cache, (p) => _cacheKey(serverId, p)),
      isCancelled: () => seq != _indexSeq || !mounted,
      onDirReady: (_) {
        if (!mounted || seq != _indexSeq) return;
        _scheduleIndexRepaint();
      },
    ).catchError((_) {
      // 递归自身不该抛（单层失败已在 `buildFileIndex` 里吞掉），但万一抛了
      // 也不能让它漏成未捕获异常 —— 索引失败不是用户的事，退化成逐层即可。
    });
  }

  /// [child] 是不是 [root] 本身或它下面的路径。
  ///
  /// 逐字符前缀比会误判：`/etc2` 以 `/etc` 开头但不是它的后代。所以在
  /// 前缀之后要求下一个字符是 `/`（或者根本没有下一个字符）。
  static bool _isUnder(String child, String root) {
    if (child == root) return true;
    if (!child.startsWith(root)) return false;
    // 根是 '/' 时它自带分隔符，不用再看 root.length 处是不是 '/'。
    if (root.endsWith('/')) return true;
    return child.length > root.length && child[root.length] == '/';
  }

  /// 把索引的逐层落地合并成一次重绘。
  ///
  /// 重绘干的事与 [_onChanged] 同源：重新算一遍当前 query 的候选集。抽成
  /// 独立方法而不是复用 listener，是因为后者会先 `parseMention` 再重放
  /// 远端分支，而此刻我们只需要「本地重新出一次候选」。
  void _scheduleIndexRepaint() {
    if (_indexRepaintScheduled) return;
    _indexRepaintScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _indexRepaintScheduled = false;
      if (!mounted) return;
      final q = _q;
      // 只在 file 上下文里刷 —— 索引与 slash 那一档无关。
      if (q == null || q.kind != TriggerKind.at) return;
      final sp = splitServerPath(q.query);
      final prefix = sp.hasColon ? sp.path : q.query;
      final split = splitDirPrefix(prefix);
      if (split.dir.isEmpty) return;
      _applyLocalDir(q, split.dir, split.prefix, sp.hasColon);
    });
  }

  /// 用 [_cache] 里的条目出候选 —— **零远端往返**。
  ///
  /// 逐层加载与后台索引都落在这同一个终点上：前半段（解析根、查缓存）在
  /// [_startDirLoad] 里，命中就到这里；索引写完一层也到这里。
  ///
  /// [alreadyAbs] 为 true 表示 [dir] 已经是绝对路径（跨机形态），不需要
  /// 再查 [_resolved]。
  ///
  /// 返回是否命中。未命中时调用方接着走今天的逐层路径 —— 这就是「渐进
  /// 增强、不是替换」：索引覆盖不到的地方退化成今天的行为，下限不掉。
  bool _applyLocalDir(
    MentionQuery q,
    String dir,
    String prefix,
    bool alreadyAbs,
  ) {
    final serverId = _serverIdFor(q.query);
    final absKnown = alreadyAbs ? dir : (_resolved[_cacheKey(serverId, dir)] ?? dir);
    final cached = _cache[_cacheKey(serverId, absKnown)];
    if (cached == null) return false;
    setState(() {
      _q = q;
      _candidates = [
        ..._fileCandidates(cached, prefix, serverId, q),
        ..._candidates.where((c) => c.kind != MentionKind.file),
      ];
      _fileState = MentionFileState.idle;
      _fileError = null;
    });
    return true;
  }

  /// 从 query 里解析出目标机 id。当前机返回 null。
  String? _serverIdFor(String query) {
    final sp = splitServerPath(query);
    if (!sp.hasColon) return null;
    final target = widget.servers.firstWhere(
      (s) => s.serverType == 'ssh' && s.name == sp.server,
      orElse: () => _kNoServer,
    );
    return identical(target, _kNoServer) ? null : target.id;
  }

  /// 起一次目录加载：先查缓存，没有就进 loading 并 debounce。
  ///
  /// [serverId] 为 null = 当前会话那台机。[localCandidates] 是要与文件候选
  /// 并排显示的本地候选（跨机时为空——那时浮层里只有文件）。
  void _startDirLoad(
    MentionQuery q,
    String dir,
    String prefix,
    String? serverId,
    List<MentionCandidate> localCandidates,
  ) {
    if (widget.listRemoteDir == null) {
      setState(() {
        _q = q;
        _candidates = localCandidates;
        _fileState = MentionFileState.unavailable;
        _fileError = null;
        _moreCount = 0;
      });
      return;
    }

    // IME composing（中文拼音尚未确认）期间不发远端请求：拼音串的每个字母
    // 都会触发一次 listener，而中间那些状态不是用户想查的目录。
    final composing = widget.ctrl.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      setState(() {
        _q = q;
        _candidates = [
          ..._candidates.where((c) => c.kind == MentionKind.file),
          ...localCandidates,
        ];
      });
      return;
    }

    final rk = _cacheKey(serverId, dir);
    final absKnown = _resolved[rk] ?? dir;
    final cached = _cache[_cacheKey(serverId, absKnown)];
    if (cached != null) {
      setState(() {
        _q = q;
        _candidates = [
          ..._fileCandidates(cached, prefix, serverId, q),
          ...localCandidates,
        ];
        _fileState = MentionFileState.idle;
        _fileError = null;
      });
      return;
    }

    setState(() {
      _q = q;
      _candidates = localCandidates;
      _fileState = MentionFileState.loading;
      _fileError = null;
      _moreCount = 0;
    });
    _debounce?.cancel();
    _debounce = Timer(_kDebounce, () => _loadDir(dir, prefix, serverId, q));
  }

  Future<void> _loadDir(
    String dir,
    String prefix,
    String? serverId,
    MentionQuery q,
  ) async {
    final lister = widget.listRemoteDir;
    if (lister == null) return;
    final seq = ++_reqSeq;
    try {
      // `~` / `.` 起头先解析成绝对路径，再拿绝对路径去 listdir。不能把未展开
      // 的写法直接丢给远端 —— 那会得到一个「目录不存在」的二次错误，掩盖
      // 真正的原因。
      //
      // 两种前缀走**两条不同的路**：`~` 交给 SFTP 的 absolutePath；`.` 只能
      // 用宿主传进来的 cwd —— absolutePath('.') 返回的是 SFTP 会话的初始目录
      // （通常就是 home），与用户在终端里 cd 到哪儿无关。
      //
      // **跨机（`serverId != null`）时 `.` 不走 cwd 分支**——那份 `widget.cwd`
      // 是当前会话那台机的终端 cwd，对目标机没有任何意义。跨机的 `.` 来自
      // `@web-02:` 冒号后为空时的「列该机 home」，与 `~` 走同一条 resolver
      // 路径（`resolveRemotePath('.', serverId: ...)` 落到 SFTP 的
      // `absolutePath('.')`，即该机 home）。
      final resolvedKey = _cacheKey(serverId, dir);
      var abs = _resolved[resolvedKey];
      if (abs == null) {
        if (serverId == null && (dir == '.' || dir.startsWith('./'))) {
          final cwd = widget.cwd;
          if (cwd == null || cwd.isEmpty) {
            if (mounted && seq == _reqSeq) {
              setState(() {
                _fileState = MentionFileState.idle;
                _fileError = context.l10n.mentionNeedAbsolutePath;
              });
            }
            return;
          }
          abs = dir == '.' ? cwd : '$cwd/${dir.substring(2)}';
        } else if (dir == '.' || dir.startsWith('~')) {
          final resolver = widget.resolveRemotePath;
          if (resolver == null) {
            if (mounted && seq == _reqSeq) {
              setState(() {
                _fileState = MentionFileState.idle;
                _fileError = context.l10n.mentionNeedAbsolutePath;
              });
            }
            return;
          }
          // resolver 单独包一层 try/catch，与下面 lister 的异常分开处理：
          // 「resolveRemotePath 抛异常或超时（~/ 展开失败）」与
          // 「resolveRemotePath == null」归为同一类——退化为
          // 「不可解析」，提示改用绝对路径，而不是走通用的
          // mentionDirLoadFailed 文案（那是给 lister 失败准备的，语义是
          // 「目录读取失败」，resolver 失败时目录还没展开，根本没到能读的
          // 阶段）。
          try {
            abs = await resolver(dir, serverId: serverId);
          } catch (_) {
            if (mounted && seq == _reqSeq) {
              setState(() {
                _fileState = MentionFileState.idle;
                _fileError = context.l10n.mentionNeedAbsolutePath;
              });
            }
            return;
          }
        } else {
          abs = dir;
        }
        _resolved[resolvedKey] = abs;
      }

      final entries = await lister(abs, serverId: serverId);
      if (!mounted || seq != _reqSeq) return;
      _cache[_cacheKey(serverId, abs)] = entries;

      // 索引**在单层加载落地之后**才起，不跟它赛跑。
      //
      // 同步起（在 `_startDirLoad` 里）会让同一层被列两次：单层那次与索引
      // 那次在缓存都是空的时候并发发出，索引的「已在缓存就跳过」屦不到。
      // 移动网络下那就是白花一次往返，而且恰好是本项要消灭的那一次。
      //
      // 放在这里之后，此刻 `abs` 已在 `_cache`，索引从根起时第一层直接命
      // 中缓存、不再重列，只往下扩展 —— 「索引未就绪时行为与今天逐字一
      // 致」那条成功判定也就是这么保住的。
      _ensureIndex(abs, serverId);
      setState(() {
        _candidates = [
          ..._fileCandidates(entries, prefix, serverId, q),
          ..._candidates.where((c) => c.kind != MentionKind.file),
        ];
        _fileState = MentionFileState.idle;
        _fileError = null;
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _fileState = MentionFileState.idle;
        _fileError = context.l10n.mentionDirLoadFailed(e.toString());
      });
    }
  }

  /// 目录排在文件前面 —— 下钻是浏览路径上的动作，比选中某个文件更靠前。
  ///
  /// [serverId] 非 null 时 `insertText` 要带回 `<机器名>:` 前缀，否则选中一个
  /// 跨机文件会插出一个**看起来完全正确、却指向当前机器**的路径——这是这次
  /// 改动里最容易静默出错的地方。
  List<MentionCandidate> _fileCandidates(
    List<SftpEntry> entries,
    String prefix,
    String? serverId,
    MentionQuery q,
  ) {
    final serverPrefix = serverId == null
        ? ''
        : '${splitServerPath(q.query).server}:';
    final p = prefix.toLowerCase();
    final hit =
        entries
            .where((e) => p.isEmpty || e.name.toLowerCase().startsWith(p))
            .toList()
          ..sort((a, b) {
            if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
            return a.name.compareTo(b.name);
          });
    _moreCount = hit.length > _kFileRenderLimit
        ? hit.length - _kFileRenderLimit
        : 0;
    return [
      for (final e in hit.take(_kFileRenderLimit))
        MentionCandidate(
          kind: MentionKind.file,
          label: e.name,
          insertText: '$serverPrefix${e.path}',
          isDir: e.isDir,
        ),
    ];
  }

  void _pick(MentionCandidate c) {
    final q = _q;
    if (q == null) return;

    // 目录：下钻，不插入。写回 `<path>/` 且不补空格，结果仍
    // 落在同一个 `@` 上下文里，controller 的 listener 会接着触发下一次加载。
    final isDrill = c.kind == MentionKind.file && c.isDir;

    // 服务器：**同样不补空格**，但理由不同。补了空格 `parseMention` 就不再
    // active、浮层关闭——用户根本没有机会接着打冒号，`@机器:路径` 那条路
    // 直接断掉。代价是「只想引用服务器」的用户要自己敲一下空格，一次按键，
    // 换来冒号那条路存在。
    final keepOpen = isDrill || c.kind == MentionKind.server;

    final r = applyMention(
      text: widget.ctrl.text,
      q: q,
      insertText: isDrill ? '${c.insertText}/' : c.insertText,
      trailingSpace: !keepOpen,
    );
    widget.ctrl.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.cursor),
    );
    if (!keepOpen) _close();
  }

  /// 光标停在一个**完整的服务器名**上（无冒号）时，提示还能打冒号。
  ///
  /// 判据是「精确等于某个服务器名」而不是「有候选」：`@web` 时列表里有
  /// web-01/web-02 两条，那时提示冒号没有意义——用户还没选定是哪台。
  String? _colonHint(BuildContext context) {
    final q = _q;
    if (q == null || q.kind != TriggerKind.at) return null;
    final sp = splitServerPath(q.query);
    if (sp.hasColon) return null;
    final exact = widget.servers.any(
      (s) => s.serverType == 'ssh' && s.name == q.query,
    );
    return exact ? context.l10n.mentionServerColonHint : null;
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      // 预览条与 `@` 浮层共用这个位置，两者不会同时出现：浮层只在光标
      // 处于 `@` 上下文时才弹（`_q != null`），所以只在没有浮层时才看
      // 是否有待发附件。
      if (_q != null)
        MentionOverlay(
          candidates: _candidates,
          onPick: _pick,
          fileState: _fileState,
          errorText: _fileError,
          moreCount: _moreCount,
          hintText: _colonHint(context),
        )
      else if (widget.pendingAttachment != null)
        AttachmentBar(
          attachment: widget.pendingAttachment!,
          thumbnailFile: widget.pendingThumbnailFile,
          onRemove: widget.onRemoveAttachment ?? () {},
        ),
      PanelInputRow(
        ctrl: widget.ctrl,
        onSubmit: widget.onSubmit,
        hintText: widget.hintText,
        onAttachTap: widget.onAttachTap,
        attachEnabled: widget.attachEnabled,
        onAttachBlockedTap: widget.onAttachBlockedTap,
      ),
    ],
  );
}

/// 把「纯路径 → 条目」的读写投影到一张带前缀键的表上。
///
/// `buildFileIndex` 的契约是 `Map<String, List<SftpEntry>>`，键是绝对目录
/// 路径；而 `MentionField._cache` 用的是 `<serverId>|abs`（跨机必须分得开，
/// 否则两台机的 `/var/log` 会互相覆盖）。这一层把两者接上，只做键变换，
/// 不复制数据 —— 索引写进去的东西，逐层加载那边立刻查得到。
class _ScopedCacheView extends MapBase<String, List<SftpEntry>> {
  _ScopedCacheView(this._inner, this._scopeKey);

  final Map<String, List<SftpEntry>> _inner;
  final String Function(String path) _scopeKey;

  @override
  List<SftpEntry>? operator [](Object? key) =>
      _inner[_scopeKey(key as String)];

  @override
  void operator []=(String key, List<SftpEntry> value) =>
      _inner[_scopeKey(key)] = value;

  @override
  void clear() => _inner.clear();

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  List<SftpEntry>? remove(Object? key) => _inner.remove(_scopeKey(key as String));
}
