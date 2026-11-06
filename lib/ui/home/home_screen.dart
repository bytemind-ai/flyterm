// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models/server.dart';
import '../../data/repositories/server_repository.dart';
import '../../ssh/session_manager.dart';
import '../../ssh/jump_host_resolver.dart';
import '../../ssh/transport/transport.dart' show Transport;
import '../../data/secure_storage.dart';
import '../../data/terminal_settings.dart';
import '../../sftp/sftp_service.dart';
import '../terminal/terminal_screen.dart';
import '../tunnel/tunnel_form_screen.dart';
import '../../commerce/feature_gate.dart';
import '../../tunnel/tunnel_manager.dart';
import '../tunnel/tunnel_grouping.dart';
import '../tunnel/tunnel_list_screen.dart';
import '../../l10n/l10n.dart';
import '../design/fly_tokens.dart';
import '../../platform_capabilities.dart';
import '../../update/update_checker.dart';
import '../../update/play_in_app_updater.dart';
import '../commerce/update_prompt_dialog.dart';
import '../../ai/agent/agent_exec_channel.dart';
import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/command_runner.dart';
import '../../ai/agent/exec_channel_factory.dart';
import '../../ai/agent/server_notes_manager.dart';
import '../ui_flags.dart';
import 'job_badge_loader.dart';

/// 首页顶部「服务器｜隧道」分段。
enum _HomeSegment { servers, tunnels }

class HomeScreen extends StatefulWidget {
  /// When true (opened via tab-bar "+"), always open a new tab
  /// even if the server already has an active connection.
  final bool forceNewTab;

  /// 重查服务器列表的信号。由 `AppShell` 在**从设置 tab 切回**时触发。
  ///
  /// 为什么需要它：设置页的配置导入直接往 DB 写服务器记录，不 reload 就看
  /// 不到。这条路径原先由 AppBar 齿轮的 `await pushNamed('/settings')` 之后
  /// 那次 `_reload()` 保住（见 `home_settings_refresh_test.dart` 守护的回归），
  /// 齿轮变成 tab 之后换成这个信号。
  ///
  /// **只在从设置 tab 切回时触发**，不是每次切到服务器 tab——AI tab 不会改
  /// 服务器记录，从那边切回去重查 DB 是白查。
  final Listenable? reloadSignal;

  /// 重扫后台任务的信号。由 `AppShell` 在**每次**切到服务器 tab 时触发。
  ///
  /// 与 [reloadSignal] 分开而不是共用一个：job 数是实时性信号（几秒钟前的
  /// 就已经没意义），服务器记录只有配置导入会改。两者的刷新频率天然不同，
  /// 合并会让其中一个被另一个的节奏拖累。
  final Listenable? visibilitySignal;

  /// 直接注入 job 计数，**仅供测试**。
  ///
  /// 真实扫描要 `AgentSessionManager` + `SecureStorageService` + 真的 SSH
  /// 通道，widget 测试里搭不起来。与 `JobBoardScreen.hasTabFor` 同一个性质
  /// 的缝：非 null 时跳过扫描、直接用这份数据渲染。
  final Map<String, int>? debugJobCounts;

  /// 直接注入"每台机器的隧道数"，**仅供测试**。
  ///
  /// 真实数据来自 `TunnelManager`；但 `TunnelManager` 的条目要经真实 SSH
  /// 才会加入，widget 测试里造不出来。与 `debugJobCounts` 同一性质的缝。
  final Map<String, int>? debugTunnelCounts;

  const HomeScreen({
    super.key,
    this.forceNewTab = false,
    this.reloadSignal,
    this.visibilitySignal,
    this.debugJobCounts,
    this.debugTunnelCounts,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<Server>> _serversFuture;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  _HomeSegment _segment = _HomeSegment.servers;
  final _tunnelSearchCtrl = TextEditingController();
  String _tunnelQuery = '';

  /// 服务器列表是 FutureBuilder，计数在加载完成后才有。
  int _loadedServerCount = 0;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.reloadSignal?.addListener(_reload);
    widget.visibilitySignal?.addListener(_onBecameVisible);
    unawaited(_scanJobs());
    // 启动 3 秒后异步检查更新；结果有非空就弹 dialog。
    Future.delayed(const Duration(seconds: 3), _checkForUpdates);
  }

  void _onBecameVisible() => unawaited(_scanJobs());

  @override
  void dispose() {
    widget.reloadSignal?.removeListener(_reload);
    widget.visibilitySignal?.removeListener(_onBecameVisible);
    _searchCtrl.dispose();
    _tunnelSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkForUpdates() async {
    if (!mounted) return;
    // iOS 走 `UpdateChecker.noop()` —— 不是「还没实现」，是**刻意禁用**。
    //
    // `GitHubReleaseChecker.iosDefault()` 的 appStoreUrl 还是占位符
    // （idTBD，上架前拿不到）；而真正能用的分支要跳 App Store，那属于
    // 引导站外更新，违反审核指南 3.1.1。TestFlight 阶段要开更新提示时，
    // 把这里改回 iOS 分支并把 `iosDefault()` 的 App Store id 填实。
    final UpdateChecker checker = Platform.isAndroid
        ? PlayInAppUpdater.androidDefault()
        : UpdateChecker.noop();
    final info = await checker.check();
    if (!mounted || info == null) return;
    await UpdatePromptDialog.show(context, info: info, checker: checker);
  }

  void _reload() {
    final future = context.read<ServerRepository>().findAll();
    future.then((list) {
      if (mounted) setState(() => _loadedServerCount = list.length);
    });
    setState(() { _serversFuture = future; });
  }

  /// serverId → 运行中的 job 数。key 不存在 = 没扫 / 扫失败，不显示徽标。
  Map<String, int> _jobCounts = const {};

  /// 扫后台任务。
  ///
  /// [includeCold] 为 false（默认，切到 tab 时自动触发）只扫**已有活连接**的
  /// 机器——复用已有通道跑一条命令，无握手。冷机器要走完整 SSH 握手（命令
  /// 超时上限 20 秒），常驻扫全部等于后台轮询，而那个方案在
  /// `job_board_controller.dart` 的类文档里被明确否决过。
  ///
  /// [includeCold] 为 true 只在用户下拉刷新时——显式动作，用户知道自己在等。
  Future<void> _scanJobs({bool includeCold = false}) async {
    // 徽标都不显示了，还为它扫描纯属浪费 —— 连带着下拉刷新（它唯一的职责
    // 就是重扫 job，见其调用点注释）在看板关闭时也变成纯粹的 no-op。
    if (!kShowJobBoard) return;
    if (widget.debugJobCounts != null) return;
    final servers = await _serversFuture;
    if (!mounted) return;

    // 可空读取而不是 `try/catch ProviderNotFoundException`：仓库里这个场景
    // 已有既定写法（`ai_panel.dart` / `global_ai_screen.dart` 读
    // `TerminalSettings?` 就是这么干的），而且不必拿异常当控制流。
    //
    // 为什么要容忍缺 provider：真实 App（`main.dart`）这三个总是挂全的，只有
    // 搭最小 provider 树的测试（`app_shell_test.dart` /
    // `home_settings_refresh_test.dart`，都早于 job 徽标功能）才会读到 null。
    // 扫不了就静默跳过 —— 不该让缺一个无关 provider 把整棵 widget 树炸掉。
    final sessions = context.read<SessionManager?>();
    final mgr = context.read<AgentSessionManager?>();
    final storage = context.read<SecureStorageService?>();
    if (sessions == null || mgr == null || storage == null) return;

    AgentExecChannel chan(Server s) => execChannelForServer(
        mgr: mgr, server: s, sessions: sessions, storage: storage);

    final counts = await loadRunningJobCounts(
      servers: servers,
      shouldScan: (s) =>
          includeCold || sessions.activeTabForServer(s.id) != null,
      run: (s, cmd) {
        final ch = chan(s);
        return SshCommandRunner(ch.obtain, onDeadChannel: ch.invalidate)
            .run(cmd);
      },
    );
    if (!mounted) return;
    setState(() {
      // 冷机器的结果**不跨 tab 切换保留**：每次切回来整份替换，而不是 merge。
      // 宁可不显示也不显示陈旧数据 —— 一个几分钟前的 job 数比没有数字更误导。
      _jobCounts = counts;
    });
  }

  List<Server> _filter(List<Server> servers) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return servers;
    return servers.where((s) =>
      s.name.toLowerCase().contains(q) ||
      s.host.toLowerCase().contains(q) ||
      s.username.toLowerCase().contains(q),
    ).toList();
  }

  int _serverCount() {
    // 服务器列表是 FutureBuilder，计数在加载完成后才有；用已缓存的数量，
    // 未加载时显示 0，加载完自动重建。
    return _loadedServerCount;
  }

  Future<void> _onSegmentChanged(Set<_HomeSegment> sel) async {
    final next = sel.first;
    if (next == _HomeSegment.tunnels && _segment != _HomeSegment.tunnels) {
      final ok = await FeatureGate.checkOrShow(context, reason: 'pro_tunnel');
      if (!ok) return;
      if (!mounted) return;
    }
    setState(() => _segment = next);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final jobCounts = widget.debugJobCounts ?? _jobCounts;
    final tunnelCounts = widget.debugTunnelCounts ??
        tunnelCountsByServer(
            context.watch<TunnelManager?>()?.tunnels ?? const []);
    final segment = widget.forceNewTab ? _HomeSegment.servers : _segment;
    return Scaffold(
      appBar: AppBar(
        // 紧凑导航栏，**不是 iOS 大标题** —— 34pt 大标题占掉近 1/4 屏，
        // 与「一屏尽可能多事实」的立场直接冲突。仪表盘把标题压到一行。
        title: Text(widget.forceNewTab ? l.newConnection : l.appTitle),
        // 齿轮没了 —— 设置变成了底部 tab。原先那段「从设置返回后 _reload()」
        // 的职责转给 `widget.reloadSignal`（由 AppShell 在从设置 tab 切回时
        // fire），守护的仍是 `home_settings_refresh_test.dart` 那条回归：
        // 配置导入直接往 DB 写服务器，不 reload 就看不到。
        actions: [
          if (!widget.forceNewTab && kShowJobBoard)
            IconButton(
              // 故意不用 `Icons.play_circle_outline`——那是行内徽标的图标。
              // 两者在 AppBar 和列表里会同屏出现，同一个图标会让人分不清
              // 「这是扫描入口」还是「这台机器有任务在跑」；
              // `server_tile_job_badge_test.dart` 也要求徽标图标在页面里
              // 是唯一的，复用会直接撞上那条断言。
              icon: const Icon(Icons.list_alt_outlined, size: 20),
              tooltip: l.serversScanJobs,
              // 行内徽标只回答「这台机器上有东西在跑吗」。看日志、杀任务、
              // 让模型接手都还在 /jobs 那一页，它零修改。
              onPressed: () => Navigator.of(context).pushNamed('/jobs'),
            ),
        ],
        bottom: PreferredSize(
          // 非 forceNewTab：分段行 + 搜索框；forceNewTab：仅搜索框（那层
          // 只干"选机器建 tab"一件事，不该出现隧道入口）。
          preferredSize: Size.fromHeight(widget.forceNewTab ? 46 : 92),
          child: Column(
            children: [
              if (!widget.forceNewTab)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: SegmentedButton<_HomeSegment>(
                    segments: [
                      ButtonSegment(
                        value: _HomeSegment.servers,
                        label: Text('${l.navServers} ${_serverCount()}'),
                      ),
                      ButtonSegment(
                        value: _HomeSegment.tunnels,
                        label: Text(
                            '${l.tunnels} ${context.watch<TunnelManager?>()?.tunnels.length ?? 0}'),
                      ),
                    ],
                    selected: {segment},
                    onSelectionChanged: _onSegmentChanged,
                    showSelectedIcon: false,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  FlySpace.md,
                  0,
                  FlySpace.md,
                  FlySpace.sm,
                ),
                child: TextField(
                  controller: segment == _HomeSegment.servers
                      ? _searchCtrl
                      : _tunnelSearchCtrl,
                  style: FlyText.body,
                  cursorColor: FlyColors.active,
                  // 统一形态（高度 40dp，与全局标准一致）。
                  //
                  // 改动前这里写了 `contentPadding: vertical: 7`，把输入框
                  // 压到 38dp —— 比标准矮 2dp，比 AI 历史搜索矮 10dp。
                  // 图标槽的 32×32 约束也一并交给 `searchFieldDecoration`
                  // （它用 40，与输入框等高）。
                  decoration: searchFieldDecoration(
                    hintText: segment == _HomeSegment.servers
                        ? l.searchServers
                        : l.tunnels,
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 17,
                      color: FlyColors.textTertiary,
                    ),
                    onClear: (segment == _HomeSegment.servers
                            ? _searchQuery
                            : _tunnelQuery)
                        .isEmpty
                        ? null
                        : () {
                            if (segment == _HomeSegment.servers) {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            } else {
                              _tunnelSearchCtrl.clear();
                              setState(() => _tunnelQuery = '');
                            }
                          },
                  ),
                  onChanged: (v) => setState(() {
                    if (segment == _HomeSegment.servers) {
                      _searchQuery = v;
                    } else {
                      _tunnelQuery = v;
                    }
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(
        index: segment.index,
        children: [
          _buildServersBody(context, jobCounts, tunnelCounts),
          TunnelListView(
            query: _tunnelQuery,
          ),
        ],
      ),
      floatingActionButton: widget.forceNewTab
          ? null
          : (segment == _HomeSegment.servers
              ? FloatingActionButton(
                  onPressed: _addServer,
                  child: const Icon(Icons.add),
                )
              : FloatingActionButton.extended(
                  onPressed: () => Navigator.of(context).pushNamed(
                        '/tunnels/form',
                        arguments: const TunnelFormArgs(),
                      ),
                  icon: const Icon(Icons.add),
                  label: Text(l.newTunnel),
                )),
    );
  }

  Widget _buildServersBody(
    BuildContext context,
    Map<String, int> jobCounts,
    Map<String, int> tunnelCounts,
  ) {
    return Consumer<SessionManager>(
      builder: (context, mgr, _) {
        return FutureBuilder<List<Server>>(
          future: _serversFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final allServers = snap.data ?? [];
            final servers = _filter(allServers);

            return RefreshIndicator(
              // 下拉 = 扫全部（含冷机）。这是显式动作，用户知道自己
              // 在等什么 —— 与自动扫只碰 warm 机器的分寸区分开。
              onRefresh: () => _scanJobs(includeCold: true),
              child: ListView(
                // 列表再短也要能下拉 —— 否则只有一两台服务器时刷新手势
                // 落空。
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (allServers.isEmpty)
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.5,
                      child: _EmptyState(onAdd: _addServer),
                    )
                  else if (servers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 120),
                      child: Center(
                        child: Text(
                          context.l10n.noSearchResults,
                          style: FlyText.body.copyWith(
                            color: FlyColors.textTertiary,
                          ),
                        ),
                      ),
                    )
                  else
                    ..._buildGroups(servers, mgr, jobCounts, tunnelCounts),
                  // 给 FAB 让出空间，避免最后一行被挡住。
                  const SizedBox(height: 88),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 按分组名切段。无分组时整列表作为一段（不带 header）。
  ///
  /// 搜索态不分组：命中的行散在多个组里时，分组只会把结果拆得七零八落，
  /// 反而更难扫读。改造前就是这个行为，保留。
  List<Widget> _buildGroups(
    List<Server> servers,
    SessionManager mgr,
    Map<String, int> jobCounts,
    Map<String, int> tunnelCounts,
  ) {
    final hasGroups = servers.any(
      (s) => s.groupName != null && s.groupName!.isNotEmpty,
    );

    Widget group(List<Server> list) => _ServerGroup(
          servers: list,
          mgr: mgr,
          jobCounts: jobCounts,
          tunnelCounts: tunnelCounts,
          onConnect: _connect,
          onLongPress: _showContextMenu,
        );

    if (!hasGroups || _searchQuery.isNotEmpty) return [group(servers)];

    final Map<String, List<Server>> groups = {};
    for (final s in servers) {
      final key = (s.groupName != null && s.groupName!.isNotEmpty)
          ? s.groupName!
          : '';
      (groups[key] ??= []).add(s);
    }
    final namedGroups = groups.keys.where((k) => k.isNotEmpty).toList()..sort();
    final ungrouped = groups[''] ?? [];

    final out = <Widget>[];
    for (final g in namedGroups) {
      out.add(_GroupHeader(label: g, count: groups[g]!.length));
      out.add(group(groups[g]!));
    }
    if (ungrouped.isNotEmpty) {
      out.add(_GroupHeader(label: context.l10n.ungrouped, count: ungrouped.length));
      out.add(group(ungrouped));
    }
    return out;
  }

  /// Long-press bottom sheet: consolidates all server actions.
  void _showContextMenu(Server server) {
    final l = context.l10n;
    final mgr = context.read<SessionManager>();
    final isActive = mgr.tabs.any((t) => t.server.id == server.id);

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.computer),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(server.name,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(
                        '${server.username}@${server.host}:${server.port}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (isActive)
              ListTile(
                leading: const Icon(Icons.add_to_queue),
                title: Text(l.newSession),
                onTap: () {
                  Navigator.pop(ctx);
                  _connectForce(server);
                },
              ),
            if (server.serverType != 'local')
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(l.sftpFileBrowser),
                onTap: () {
                  Navigator.pop(ctx);
                  _openSftp(server);
                },
              ),
            if (server.serverType != 'local')
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: Text(l.newTunnel),
                onTap: () {
                  Navigator.pop(ctx);
                  _openTunnelForm(server);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l.edit),
              onTap: () {
                Navigator.pop(ctx);
                _editServer(server);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(l.delete, style: const TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteServer(server);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _openSftp(Server server) async {
    final storage = context.read<SecureStorageService>();
    final serverRepo = context.read<ServerRepository>();
    String? privateKeyPem;
    String? password;
    if (server.authType == 'key' && server.keyId != null) {
      privateKeyPem = await storage.loadPrivateKey(server.keyId!);
    } else if (server.authType == 'password') {
      password = await storage.loadPassword(server.id);
    }
    final jump = await resolveJumpParams(server, serverRepo, storage);
    if (!mounted) return;
    SFTPService svc;
    try {
      svc = await SFTPService.forServer(server,
          privateKeyPem: privateKeyPem,
          password: password,
          jump: jump,
          downloadDirProvider:
              context.read<TerminalSettings>().resolveDownloadDir,
          publishToPublicStore:
              () => context.read<TerminalSettings>().downloadsToPublicStore);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.sftpConnectFailed(e.toString()))),
        );
      }
      return;
    }
    if (!mounted) return;
    final mgr = context.read<SessionManager>();
    // Find or create a tab for this server.
    final existingIdx = mgr.tabs.indexWhere((t) => t.server.id == server.id);
    final tab = existingIdx != -1 ? mgr.tabs[existingIdx] : mgr.addTab(server);
    if (existingIdx != -1) mgr.setActiveTab(existingIdx);
    // Attach the SFTP service and show it inline.
    tab.sftpSvc = svc;
    tab.sftpCwd = await svc.queryHome().catchError((_) => '/');
    // Mark as no longer first connection so the SFTP view renders immediately
    // without waiting for a terminal SSH session.
    tab.isFirstConnection = false;
    mgr.setViewMode(tab, TabViewMode.sftp);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(initialServer: server),
      ),
    );
  }

  void _openTunnelForm(Server server) {
    Navigator.of(context).pushNamed(
      '/tunnels/form',
      arguments: TunnelFormArgs(server: server),
    );
  }

  Future<void> _connect(Server server) async {
    if (widget.forceNewTab) {
      // Called from TerminalScreen._addNewTab() via push<Server>.
      // Pop back and return the chosen server so TerminalScreen connects it
      // as a new tab. This keeps the stack as [HomeScreen, TerminalScreen].
      Navigator.of(context).pop(server);
      return;
    }
    final mgr = context.read<SessionManager>();
    final existingIdx =
        mgr.tabs.indexWhere((t) => t.server.id == server.id);
    if (existingIdx != -1 && Navigator.of(context).canPop()) {
      mgr.setActiveTab(existingIdx);
      Navigator.of(context).pop();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => TerminalScreen(initialServer: server)),
    );
  }

  /// Force new tab regardless of existing connections (from context menu).
  Future<void> _connectForce(Server server) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => TerminalScreen(
                initialServer: server,
                forceNewTab: true,
              )),
    );
  }

  Future<void> _addServer() async {
    await Navigator.of(context).pushNamed('/server-form');
    _reload();
  }

  Future<void> _editServer(Server server) async {
    await Navigator.of(context)
        .pushNamed('/server-form', arguments: server);
    _reload();
  }

  Future<void> _deleteServer(Server server) async {
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.deleteServerTitle),
        content: Text(l.confirmDeleteServer(server.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.delete)),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<ServerRepository>().delete(server.id);
      // C1 修复：repo.delete 的事务里虽然连带删了 server_notes 行，但
      // ServerNotesManager 是全量缓存在内存的（noteFor 必须同步，见其类
      // 文档），不主动告诉它就不会失效——总览列表会继续显示这条笔记，
      // 标题还会退化成裸 serverId，直到下次冷启动重新 load()。delete 对
      // 不存在的条目是幂等的，这里不需要先判断笔记是否存在。
      if (mounted) {
        await context.read<ServerNotesManager>().delete(server.id);
      }
      _reload();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 列表骨架
// ─────────────────────────────────────────────────────────────

/// 一组服务器，渲染成一段「划格」区域。
///
/// 形态上刻意**不是**浮起卡片：没有独立底色、没有圆角、没有阴影。分区感
/// 由 header 标签 + 上下留白建立，行与行之间用 0.5px hairline 划开 —— 这是
/// 仪表盘的层级做法，改版前就是这样，本次保留。
class _ServerGroup extends StatelessWidget {
  const _ServerGroup({
    required this.servers,
    required this.mgr,
    required this.jobCounts,
    required this.tunnelCounts,
    required this.onConnect,
    required this.onLongPress,
  });

  final List<Server> servers;
  final SessionManager mgr;
  final Map<String, int> jobCounts;
  final Map<String, int> tunnelCounts;
  final void Function(Server) onConnect;
  final void Function(Server) onLongPress;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < servers.length; i++) ...[
          _ServerRow(
            server: servers[i],
            mgr: mgr,
            jobCount: jobCounts[servers[i].id],
            tunnelCount: tunnelCounts[servers[i].id] ?? 0,
            onConnect: onConnect,
            onLongPress: onLongPress,
          ),
          if (i < servers.length - 1) const _RowDivider(),
        ],
      ],
    );
  }
}

/// 行间 hairline。从图标右侧开始内缩 —— 让 icon 列在视觉上是一条连续的
/// 竖带，不被横线打断。
class _RowDivider extends StatelessWidget {
  const _RowDivider();

  /// 与 [_ServerRow] 的图标列对齐：12(左内边距) + 32(图标底) + 10(间距) = 54。
  static const double _indent = 54;

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(left: _indent, right: FlySpace.md),
        child: Divider(
          height: kHairline,
          thickness: kHairline,
          color: FlyColors.divider,
        ),
      );
}

/// Section header —— 等宽大写微标签 + 计数。
///
/// 这是产品最鲜明的视觉签名之一（`PRODUCTION (3)`），**刻意保留**。仪表盘
/// 靠这种低饱和、小号、带字距的标签做分区，比色块或大字更省空间、也更精确。
///
/// 中文分组名不走 uppercase、不加字距、不套等宽 —— CJK 没有大小写概念，
/// 套上去只会让中英分组标题风格分裂。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  static bool _isAscii(String s) {
    for (final c in s.codeUnits) {
      if (c > 0x7E) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ascii = _isAscii(label);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FlySpace.md,
        FlySpace.xl,
        FlySpace.md,
        FlySpace.sm,
      ),
      child: Row(
        children: [
          Text(
            ascii ? label.toUpperCase() : label,
            style: ascii
                ? FlyText.micro.copyWith(color: FlyColors.textTertiary)
                : FlyText.panelTitle.copyWith(color: FlyColors.textTertiary),
          ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: FlyText.micro.copyWith(
              color: FlyColors.textTertiary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 服务器行
// ─────────────────────────────────────────────────────────────

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.server,
    required this.mgr,
    required this.jobCount,
    required this.tunnelCount,
    required this.onConnect,
    required this.onLongPress,
  });

  final Server server;
  final SessionManager mgr;

  /// 这台机器上运行中的后台任务数。null = 没扫 / 扫失败 → 不显示徽标。
  final int? jobCount;

  /// 这台机器名下配置的隧道条数（含临时/保存）。0 = 不显示徽标。
  final int tunnelCount;
  final void Function(Server) onConnect;
  final void Function(Server) onLongPress;

  static String _relativeTime(DateTime? when) {
    if (when == null) return '';
    final d = DateTime.now().difference(when);
    if (d.isNegative) return '';
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    if (d.inDays < 30) return '${(d.inDays / 7).floor()}w ago';
    return '${(d.inDays / 30).floor()}mo ago';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final activeTabs = mgr.tabs.where((t) => t.server.id == server.id).toList();
    final isActive = activeTabs.isNotEmpty;
    final isLocal = server.serverType == 'local';
    // iOS 上本地 shell 不存在（`PlatformCapabilities.hasLocalShell`）。
    // DB 里可能混入 local 记录（跨设备导入 / 备份恢复）—— 照常渲染但
    // 标记为不可用，不让用户点进去看到 red-screen。
    final isLocalUnsupported =
        isLocal && !PlatformCapabilities.instance().hasLocalShell;

    // 副行：username@host:port · group · 相对时间
    String? subInfo;
    if (isLocalUnsupported) {
      subInfo = l.localShellUnsupported;
    } else if (isLocal) {
      subInfo = '/system/bin/sh';
    } else {
      final parts = <String>[
        '${server.username}@${server.host}:${server.port}',
        if (server.groupName?.isNotEmpty ?? false) server.groupName!,
      ];
      final rel = _relativeTime(server.lastConnectedAt);
      if (rel.isNotEmpty) parts.add(rel);
      subInfo = parts.join(' · ');
    }

    return InkWell(
      // 不可用的 local 记录：点击不连接（连了也只会红屏），改弹提示。
      onTap: isLocalUnsupported
          ? () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.localShellUnsupported)),
              );
            }
          : () => onConnect(server),
      onLongPress: () => onLongPress(server),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FlySpace.md,
          9,
          FlySpace.md,
          9,
        ),
        child: Row(
          children: [
            // 图标底：sharp 的 4px 圆角方框 + 微亮底 + hairline 描边。
            //
            // 保留「描边方框」而不是换成实心圆角方块：描边在今天仍是仪表盘
            // 的语汇（线条精确、几乎无填充），实心彩块是消费级列表的做法。
            // 但**底色随连接态变化** —— 已连接时整块转 mint，让「哪台连着」
            // 在扫视时第一个跳出来。
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isActive
                    ? FlyColors.active.withValues(alpha: 0.14)
                    : FlyColors.panelElevated,
                borderRadius: FlyRadius.controlRadius,
                border: Border.all(
                  color: isActive
                      ? FlyColors.active.withValues(alpha: 0.5)
                      : FlyColors.divider,
                  width: kHairline,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                isLocal ? Icons.phone_android : Icons.dns_outlined,
                size: 17,
                color: isActive ? FlyColors.active : FlyColors.textSecondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FlyText.body.copyWith(
                            fontWeight: FontWeight.w600,
                            // 不可用的本地记录降级成灰 —— 让「点不进去」
                            // 这件事在颜色上就能看出来。
                            color: isLocalUnsupported
                                ? FlyColors.textTertiary
                                : FlyColors.textPrimary,
                          ),
                        ),
                      ),
                      if (server.jumpHostId != null) ...[
                        const SizedBox(width: FlySpace.xs),
                        Tooltip(
                          message: l.viaJumpHost,
                          child: const Icon(
                            Icons.east,
                            size: 12,
                            color: FlyColors.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  // 副行：等宽字体。装的是 user@host:port，属机器数据 ——
                  // 等宽让长度不一的 IP 对齐，是功能性需要。
                  Text(
                    subInfo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FlyText.secondary.copyWith(
                      fontFamily: FlyText.monoFamily,
                      fontSize: 11,
                      color: FlyColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: FlySpace.sm),
            _RowTrailing(
              transport: server.transport,
              isLocal: isLocal,
              isLocalUnsupported: isLocalUnsupported,
              activeCount: activeTabs.length,
              jobCount: jobCount,
              tunnelCount: tunnelCount,
              cs: cs,
            ),
          ],
        ),
      ),
    );
  }
}

/// 行尾元信息：协议标签 + 活跃数 / 任务数。
class _RowTrailing extends StatelessWidget {
  const _RowTrailing({
    required this.transport,
    required this.isLocal,
    required this.isLocalUnsupported,
    required this.activeCount,
    required this.jobCount,
    required this.tunnelCount,
    required this.cs,
  });

  final Transport transport;
  final bool isLocal;
  final bool isLocalUnsupported;
  final int activeCount;
  final int? jobCount;
  final int tunnelCount;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (kShowJobBoard && (jobCount ?? 0) > 0) ...[
          // job 徽标：琥珀 + play 图标 + 数字。数字不能省 —— 它回答的是
          // 「有几件事在跑」，只给图标就得让用户进看板才知道。
          // 与活跃数（mint + 数字）在颜色和图标上都分开：两个挨着的数字
          // 若同色同形，读出来就是一个四位数
          // （`server_tile_job_badge_test` 守护图标唯一性）。
          Tooltip(
            message: l.jobsRunningBadge(jobCount!),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_circle_outline,
                  size: 13,
                  color: FlyColors.pending,
                ),
                const SizedBox(width: 3),
                Text(
                  '$jobCount',
                  style: FlyText.micro.copyWith(
                    color: FlyColors.pending,
                    letterSpacing: 0,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
          if (activeCount > 0) const SizedBox(width: FlySpace.sm + 2),
        ],
        if (activeCount > 0) ...[
          // 活跃数：mint 圆点 + 数字。
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: FlyColors.active,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: FlySpace.xs),
          Text(
            '$activeCount',
            style: FlyText.micro.copyWith(
              color: FlyColors.active,
              letterSpacing: 0,
              fontSize: 10.5,
            ),
          ),
          const SizedBox(width: FlySpace.sm + 2),
        ],
        if (!isLocal && tunnelCount > 0) ...[
          // 隧道徽标：只读（不可点），回答"这台配了几条隧道"。
          // 排在与 job / 活跃数相邻处，用 cable 图标 + 数字，与 job 的
          // play 图标、活跃数的 mint 圆点在形状上区分开。
          Tooltip(
            message: l.tunnelCountBadge(tunnelCount),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cable,
                  size: 13,
                  color: FlyColors.textSecondary,
                ),
                const SizedBox(width: 3),
                Text(
                  l.tunnelCountBadge(tunnelCount),
                  style: FlyText.micro.copyWith(
                    color: FlyColors.textSecondary,
                    letterSpacing: 0,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: FlySpace.sm + 2),
        ],
        // 协议标签：等宽大写 + 极淡描边。用描边而非填充 —— chip 上填充
        // 会和状态色抢注意力，而协议只是背景信息。
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
          decoration: BoxDecoration(
            border: Border.all(color: _protoColor(), width: 0.8),
            borderRadius: FlyRadius.chipRadius,
          ),
          child: Text(
            _protoLabel(),
            style: FlyText.micro.copyWith(
              color: _protoColor(),
              fontSize: 9.5,
            ),
          ),
        ),
      ],
    );
  }

  String _protoLabel() {
    if (isLocalUnsupported) return 'N/A';
    if (isLocal) return 'LOCAL';
    return switch (transport) {
      Transport.ssh => 'SSH',
      Transport.mosh => 'MOSH',
      Transport.quic => 'QUIC',
    };
  }

  /// 协议色与 `TerminalScreen._StatusDot` 同源，避免「列表里 QUIC 一个颜色、
  /// 终端里另一个颜色」的认知错位。
  Color _protoColor() {
    if (isLocalUnsupported) return FlyColors.warning;
    if (isLocal) return FlyColors.textTertiary;
    return switch (transport) {
      Transport.ssh => FlyColors.protoSsh,
      Transport.mosh => FlyColors.protoMosh,
      Transport.quic => FlyColors.protoQuic,
    };
  }
}

// ─────────────────────────────────────────────────────────────
// 空态
// ─────────────────────────────────────────────────────────────

/// 无服务器时的空态。
///
/// 保持克制：一个图标、一句说明、一个动作。不用插画、不用大字标题 —— 空态
/// 是仪表盘上最「空」的一屏，越简洁越不显突兀。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FlySpace.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.dns_outlined,
            size: 40,
            color: FlyColors.textTertiary,
          ),
          const SizedBox(height: FlySpace.lg),
          Text(
            l.noServers,
            textAlign: TextAlign.center,
            style: FlyText.body.copyWith(color: FlyColors.textSecondary),
          ),
          const SizedBox(height: FlySpace.xl),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 16),
            label: Text(l.addServer),
            style: FilledButton.styleFrom(
              backgroundColor: FlyColors.active,
              foregroundColor: FlyColors.background,
              textStyle: FlyText.body.copyWith(fontWeight: FontWeight.w600),
              padding: const EdgeInsets.symmetric(
                horizontal: FlySpace.lg,
                vertical: FlySpace.sm + 2,
              ),
              shape: const RoundedRectangleBorder(
                borderRadius: FlyRadius.controlRadius,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
