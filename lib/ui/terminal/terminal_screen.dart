// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../../util/dlog.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart' show SSHClient, SSHKeyPair;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ssh/foreground_service.dart';
import '../../ssh/host_key_verifier.dart';
import '../../ssh/ssh_connection.dart' show isSshClientDead;
import '../../ssh/ssh_connection_pool.dart';
import 'package:provider/provider.dart';
import '../../ai/ai_provider_service.dart';
import '../../ai/attachment_store.dart';
import '../../ai/voice_input_service.dart';
import '../../data/models/favorite_command.dart';
import '../../data/models/server.dart';
import '../../data/repositories/favorite_command_repository.dart';
import '../../data/repositories/mosh_process_repository.dart';
import '../../data/repositories/ssh_key_repository.dart';
import '../../data/secure_storage.dart';
import '../../data/terminal_settings.dart';
import 'debug_overlay.dart';
import '../../sftp/attach_path.dart';
import '../../sftp/sftp_entry.dart';
import '../../sftp/sftp_service.dart';
import '../../ssh/session_manager.dart';
import '../../ssh/reconnect_service.dart';
import '../../ssh/multiplexer/multiplexer_backend.dart';
import '../../ssh/multiplexer/none_backend.dart';
import '../../ssh/multiplexer/tmux_backend.dart';
import '../../data/repositories/server_repository.dart';
import '../../tunnel/tunnel_manager.dart';
import '../../ssh/jump_host_resolver.dart';
import '../../ssh/mosh_connection.dart';
import '../../ssh/ssp_v2/mosh_shell_v2.dart';
import '../../ssh/local_shell.dart';
import '../../ai/agent/agent_assembly.dart';
import '../../ai/agent/agent_exec_channel.dart';
import '../../ai/agent/exec_channel_factory.dart';
import '../../ai/agent/agent_loop.dart';
import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/agent_skill_manager.dart';
import '../../ai/agent/server_notes_manager.dart';
import '../../ai/agent/skill.dart';
import '../../ai/terminal_context.dart';
import '../../ui/ai/ai_panel.dart';
import '../home/home_screen.dart';
import '../sftp/sftp_inline_view.dart';
import 'package:xterm/core.dart';
import '../tunnel/tunnel_form_screen.dart';
import 'command_favorites_sheet.dart';
import 'terminal_widget.dart';
import 'tunnel_menu_visibility.dart';
import '../../ssh/shell_completion_service.dart';
import '../../ssh/command_history_service.dart';
import '../../ssh/completion_suggestion.dart';
import '../../l10n/l10n.dart';
import '../../platform_capabilities.dart';
import '../voice/voice_input_prompt.dart';
import 'key_bar.dart';
import 'split_manager.dart';
import 'split_pane_view.dart';
import 'floating_terminal_window.dart';
import 'floating_view_toggle.dart';
import 'layout_picker_sheet.dart';
import 'file_transfer/file_picker_sheet.dart';
import 'file_transfer/file_transfer_overlay.dart';
import '../../ssh/transport/remote_transport.dart'
    show TransportCapability, TransportKind;
import '../../ssh/transport/transport.dart';
import '../../ssh/aqt/aqt_bootstrap.dart';
import '../../ssh/aqt/aqt_port_spec.dart';
import '../../ssh/aqt/aqt_route.dart';
import '../../ssh/aqt/aqt_ssh_relay.dart';
import '../../ssh/aqt/aqt_server_installer.dart' show AqtInstallStatus;
import '../../ssh/aqt/aqt_transport_factory.dart' show AqtTransportFactory;
import '../../ssh/aqt/aqt_transport.dart' show AqtTransport;
import '../../ssh/aqt/aqt_transport.dart';
import '../../ssh/transport/remote_transport.dart' show TransportState;
import '../../app.dart' show appRouteObserver;
import '../ui_flags.dart';
import '../design/fly_tokens.dart';

class TerminalScreen extends StatefulWidget {
  /// Server to connect on first open. Null in restore mode (tabs already
  /// populated by SessionManager.restoreFromSaved; ReconnectService connects).
  final Server? initialServer;

  /// True when opened from HomeScreen's long-press "新建会话" action.
  /// The "+" tab button no longer needs this — it uses _addNewTab() instead.
  final bool forceNewTab;

  const TerminalScreen({
    super.key,
    this.initialServer,
    this.forceNewTab = false,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();

  /// Deep-link support — tracks how many [TerminalScreen] instances
  /// are currently mounted anywhere in the widget tree (not just "on top of
  /// the navigator stack": a dialog/settings page pushed above one still
  /// counts as mounted). The notify orchestrator uses this to decide whether
  /// it needs to push a new restore-mode `TerminalScreen` route at all, or
  /// whether one is already showing and only [SessionManager.setActiveTab]
  /// is needed.
  ///
  /// A plain mounted-count is a deliberate simplification over true
  /// "is-top-of-stack" tracking: pushing a second full-screen TerminalScreen
  /// on top of an existing one is never useful regardless of what else is
  /// stacked above it, so the coarser signal is sufficient for this use case.
  static int _mountedCount = 0;
  static bool get isMounted => _mountedCount > 0;
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver, RouteAware {
  String? _connectError;
  OverlayEntry? _floatingEntry;
  bool _aiPanelOpen = false;
  // Raw-pointer swipe tracking for tab switching (bypasses gesture arena).
  Offset? _tabSwipeStart;
  int _tabSwipePointerCount = 0;
  // True while any TerminalWidget is in text-selection mode. Only a mirror of
  // the widgets' state, kept so a rebuild happens when selection mode toggles;
  // the swipe guard reads [_selectionActiveNow] instead — see there.
  bool _tabSelectionActive = false;
  // True for 500 ms after a swipe-triggered tab switch.
  // Passed to TerminalWidget.suppressKeyboardOnActivation so the newly visible
  // tab does not auto-open the keyboard — the user was swiping, not typing.
  bool _tabSwitchedBySwipe = false;
  Timer? _swipeTimer;
  String _currentInputLine = '';
  bool _inEscapeSeq = false;
  bool _escapeSawCsi = false;
  List<CompletionSuggestion> _completionSuggestions = [];
  Timer? _completionDebounce;
  final _completionService = ShellCompletionService();
  final _historyService = CommandHistoryService();

  // Search overlay state.
  bool _searchVisible = false;
  final _searchCtrl = TextEditingController();
  List<int> _searchHitLines = [];
  int _searchHitIdx = 0;
  final Map<String, ScrollController> _scrollControllers = {};
  /// Tracks the last `SessionTab.lastTransportSwapAt` observed per tab so
  /// the post-frame `jumpTo(0)` fires exactly once per swap. Without this
  /// map, every rebuild after a swap would re-schedule the callback.
  final Map<String, DateTime> _seenSwapAt = {};
  final Map<String, GlobalKey<TerminalWidgetState>> _terminalWidgetKeys = {};

  /// SFTP 视图的 State 句柄，按 tab id 存。
  ///
  /// **每个 tab 一个**：`IndexedStack` 会把所有 tab（含其 SFTP 视图）都挂在
  /// 树上，共用一个 `GlobalKey` 会直接抛「同一 key 挂在两处」。事件到来时
  /// 只转发给**当前活跃 tab** 那一个（见 [initState] 的接线）。
  final Map<String, GlobalKey<SftpInlineViewState>> _sftpKeys = {};

  /// `ReconnectService` 单例句柄 —— 在 `initState` 抓一次。
  ///
  /// 它比本 State 长寿，`dispose` 里必须用它把两个 SFTP 回调清空（否则它
  /// 会一直持有已销毁的 State）。把引用存下来而不是在 `dispose` 里
  /// `context.read`：`dispose` 阶段碰 `context` 是踩雷区，存引用零风险。
  ReconnectService? _reconnectSvcForSftp;
  /// Tracks each tab's previous isReconnecting state so that _buildTabBody
  /// can detect the reconnect-success transition and invalidate a stale
  /// SFTPService (whose underlying SSH client is replaced on reconnect).
  final Map<String, bool> _wasReconnecting = {};

  /// `_agentLoopFor` 是同步方法（被 `loopFactory: AgentLoop Function()`
  /// 这个同步签名约束，`ai_panel.dart` 里有多处同步消费点），不能直接改
  /// 成 async 去 await `AgentSessionManager.takeMostRecent`。改用「提前一步
  /// 异步取值、缓存在 state 字段里，同步方法只读缓存」的写法：
  /// `_openAIPanel` 在真正创建 loop 之前 await 一次并存进这里，
  /// `_agentLoopFor` 用 `remove` 取出（一次性，避免下次误用旧值）。
  final Map<String, Map<String, dynamic>?> _pendingLoopRestore = {};

  // Active QUIC file transfer entries shown in the overlay.
  final List<FileTransferEntry> _activeTransfers = [];

  // Floating Edge Toggle (FET) state.
  double _fetCurrentOpacity = 0.6;
  Timer? _fetFadeTimer;
  Timer? _fetHideTimer;

  /// In restore mode (initialServer == null) we skip first-connection setup —
  /// ReconnectService.reconnectAll() handles it after runApp.
  bool get _isRestoreMode => widget.initialServer == null;

  SessionManager? _sessionMgrForSync;

  // ---------------------------------------------------------------------
  // 长期存活的 agent provider 专用句柄。
  //
  // `AgentLoop` 的寿命**长于本 State**：它由 `AgentSessionManager` 持有，
  // 关闭 AI 面板、切 tab、甚至退出本页之后都还在跑（`dispose()` 里那句
  // 「Exec channels now live in AgentSessionManager ... which outlive this
  // screen」说的就是这件事）。而 `serverListProvider` / `toolSpecsProvider`
  // 这些闭包是 loop 拿着、由模型在**任意时刻**回调的。
  //
  // 只要回调发生时本 State 已经 unmount，闭包里的 `context.read` 就会抛
  // `State.context` 空检查（`_dependents` 为 null）—— 表现成「bash 工具
  // 持续失败，报同一个客户端错误」，而且跟服务器端毫无关系。
  //
  // 所以在 initState 就把这几个**根 provider 单例**抓进字段：它们由
  // `main.dart` 的 `Provider.value` 提供，生命周期覆盖整个 App，比本 State
  // 长，闭包抓着它们不构成泄漏，也不需要 context。
  //
  // 只抓「长寿单例」。像 `TerminalSettings` 那种每次 build 都可能换实例的
  // 依赖不要往这里放。
  ServerRepository? _serverRepoForAgent;
  AgentSessionManager? _agentMgrForAgent;
  SecureStorageService? _storageForAgent;

  /// 装配 agent 用的 provider 句柄包。在 initState 抓一次,之后闭包只读它 ——
  /// 理由与上面那三个字段完全相同(loop 寿命长于本 State)。
  AgentAssemblyDeps? _agentDeps;

  @override
  void initState() {
    super.initState();
    TerminalScreen._mountedCount++;
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    if (!_isRestoreMode) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openInitialSession(),
      );
    } else {
      // Cold-start restore: ReconnectService skips local tabs (serverType ==
      // 'local') because PTY can't lose network.  But on cold start the PTY
      // was never started — start it here before the first frame is painted.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreLocalShells(),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _sessionMgrForSync = context.read<SessionManager>();
        _sessionMgrForSync!.addListener(_syncSplitOnTabChange);
        _fetOnUserActivity(context.read<TerminalSettings>());
      }
    });
    // 长寿 agent provider 要用的句柄一次性抓下来（见字段处注释）。
    // 放在 initState 同步段而不是上面的 post-frame：`serverListProvider`
    // 最早也要等 `_openAIPanel` 才会被调用，那时早已过第一帧，所以这里
    // context 一定可用；万一将来有更早的调用路径，`_refreshServerCache`
    // 里还有 `?? context.read` 兜底。
    _serverRepoForAgent = context.read<ServerRepository>();
    _agentMgrForAgent = context.read<AgentSessionManager>();
    _storageForAgent = context.read<SecureStorageService>();
    _agentDeps = AgentAssemblyDeps.fromContext(context);
    // `_execChannelFor` 读它。post-frame 里那次赋值仍然照旧（它还要
    // `addListener`），这里先同步填上，避免「帧还没来就被 agent 调用」
    // 的窗口回落到 `context.read`。
    _sessionMgrForSync ??= context.read<SessionManager>();
    // 必须放在这行之后：上面那个 postFrameCallback 里对 _sessionMgrForSync
    // 的赋值是异步的，此刻还没跑，这里才是同步代码里第一个能保证它非空的
    // 位置——放在更早的地方 addListener 会在 null 上短路，注册悄悄变成空跑。
    _sessionMgrForSync?.addListener(_consumeStagedCommands);
    // 首帧之后主动跑一次：push 进来时目标 tab 可能已经连好了，那种情况下
    // 不会再有新的 notifyTabChanged，光靠监听会一直等不到。
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _consumeStagedCommands());

    // SFTP 生命周期协同：ReconnectService 网络/前台事件转发给当前活跃的
    // SFTP 视图。回调字段归 ReconnectService 所有，本 State 在 dispose 时
    // 必须清空（它的生命周期比本页长）。
    final rs = context.read<ReconnectService>();
    _reconnectSvcForSftp = rs;
    rs.onNetworkTypeChanged = (newType, oldType) {
      _activeSftpState?.onNetworkChanged();
    };
    rs.onForegroundResumedForSftp = () {
      _activeSftpState?.onForegroundResumed();
    };
  }

  /// 当前活跃 tab 的 SFTP 视图 State（没开 SFTP 时为 null）。
  SftpInlineViewState? get _activeSftpState {
    final mgr = _sessionMgrForSync;
    final id = mgr?.activeTab?.id;
    if (id == null) return null;
    return _sftpKeys[id]?.currentState;
  }

  /// Whether any live TerminalWidget currently has the selection overlay up
  /// (handles + Copy toolbar). While it is, swiping must not switch tabs —
  /// the finger is there to drag a handle or reach the Copy button.
  ///
  /// Read straight off the widgets instead of trusting [_tabSelectionActive]:
  /// that mirror only moves when the selection controller notifies, and
  /// `isActive` can go false silently (anchor detached, buffer swapped), so
  /// mid-gesture the mirror can claim a selection that is already gone.
  /// Falls back to the mirror only when no state is reachable (keys not yet
  /// attached).
  bool _selectionActiveNow() {
    var sawLiveState = false;
    for (final key in _terminalWidgetKeys.values) {
      final state = key.currentState;
      if (state == null) continue;
      sawLiveState = true;
      if (state.isSelectionActive) return true;
    }
    return sawLiveState ? false : _tabSelectionActive;
  }

  /// Global hardware-keyboard handler for tab management shortcuts.
  /// Returns true (handled) only for specific Ctrl combos that must not
  /// reach xterm. All other keys return false so xterm processes them.
  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (!ctrl) return false;

    final mgr = _sessionMgrForSync;
    if (mgr == null) return false;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.tab:
        if (shift)
          mgr.prevTab();
        else
          mgr.nextTab();
        return true;
      case LogicalKeyboardKey.keyW:
        if (shift) {
          final idx = mgr.activeIndex;
          mgr.closeTab(idx);
          return true;
        }
        return false; // Ctrl+W → xterm (kill-word)
      case LogicalKeyboardKey.keyN:
        if (shift) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _addNewTab();
          });
          return true;
        }
        return false;
      case LogicalKeyboardKey.keyF:
        if (!shift) {
          setState(() => _searchVisible = !_searchVisible);
          if (!_searchVisible) {
            FocusManager.instance.primaryFocus?.unfocus();
            _searchCtrl.clear();
            _searchHitLines = [];
          }
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  ScrollController _scrollControllerFor(String tabId) {
    return _scrollControllers.putIfAbsent(tabId, ScrollController.new);
  }

  /// If [tab]'s `lastTransportSwapAt` has advanced since we last saw it,
  /// schedule a post-frame `scrollController.jumpTo(0)`. This proactively
  /// resets the xterm viewport after a RESUME ring-replay clear so the
  /// user does not see stale scrollback (h.jpg).
  void _maybeScheduleSwapScrollReset(SessionTab tab) {
    final swapAt = tab.lastTransportSwapAt;
    if (swapAt == null) return;
    if (_seenSwapAt[tab.id] == swapAt) return;
    _seenSwapAt[tab.id] = swapAt;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sc = _scrollControllers[tab.id];
      if (sc == null || !sc.hasClients) return;
      if (sc.offset != 0) {
        sc.jumpTo(0);
      }
    });
  }

  void _runSearch(String query, SessionTab tab) {
    if (query.isEmpty) {
      setState(() {
        _searchHitLines = [];
        _searchHitIdx = 0;
      });
      return;
    }
    final lower = query.toLowerCase();
    final buf = tab.terminal.buffer;
    final hits = <int>[];
    for (int i = 0; i < buf.height; i++) {
      final text = buf.lines[i].getText(0, buf.viewWidth).toLowerCase();
      if (text.contains(lower)) hits.add(i);
    }
    setState(() {
      _searchHitLines = hits;
      _searchHitIdx = hits.isEmpty ? 0 : hits.length - 1;
    });
    if (hits.isNotEmpty) _scrollToHit(tab, hits.last);
  }

  void _scrollToHit(SessionTab tab, int lineIdx) {
    final sc = _scrollControllers[tab.id];
    if (sc == null || !sc.hasClients) return;
    final buf = tab.terminal.buffer;
    final scrollBack = buf.scrollBack;
    if (scrollBack <= 0) return;
    final maxScroll = sc.position.maxScrollExtent;
    final offset = (lineIdx / scrollBack).clamp(0.0, 1.0) * maxScroll;
    sc.jumpTo(offset);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final mgr = _sessionMgrForSync;
    if (mgr == null) return;
    if (state == AppLifecycleState.resumed) {
      // Do NOT call roam() here — ReconnectService handles foreground recovery
      // via setForeground(true).  Unconditional roam() rebinds the UDP socket,
      // resets _roamDeadlineTimer, and causes spurious disconnects on resume.

      // B2: notify ReconnectService so it can mark dead AQT tabs for the
      // foreground fast-path (zero banner delay, single attempt).
      if (mounted) {
        context.read<ReconnectService>().onForegroundResumed();
      }
    }
  }

  bool _routeObserverSubscribed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeObserverSubscribed) {
      final route = ModalRoute.of(context);
      if (route != null) {
        appRouteObserver.subscribe(this, route);
        _routeObserverSubscribed = true;
      }
    }
  }

  // RouteAware: a new route was pushed on top of TerminalScreen (dialog,
  // settings, SFTP, etc.). Unfocus the active TerminalView immediately so
  // Flutter does not restore focus to it when the route pops — otherwise
  // xterm's _onFocusChange fires, consumes the keyboard token, and opens
  // the keyboard without any user gesture.
  @override
  void didPushNext() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  // RouteAware: a route on top of TerminalScreen was popped and this screen
  // is visible again. **这个回调对任何子路由都会触发**（设置页、隧道页、
  // 服务器表单、SFTP……不只是后台任务看板），所以判断依据只能是「槽里有
  // 没有东西」，不能假设来源是看板。
  //
  // 用途：后台任务看板「让模型接手」只把 prompt 投进
  // `AgentSessionManager` 的槽（看板是独立路由、可能从设置页进，
  // `Navigator.pop` 回不到终端，没法靠传参），真正打开 AI 面板要在这里
  // 补上。
  //
  // 只看当前活动 tab：槽按 serverId 存，用户从看板回来时想打开的就是他
  // 刚点那台机器的面板——如果那台机器现在没有活动 tab，看板上「让模型
  // 接手」按钮本来就是 disabled 的（见 `job_board_screen.dart` 的
  // `hasTabFor`），所以能走到这里、槽里又确实有值的，活动 tab 一定就是
  // 目标 tab。
  //
  // 用 `hasStagedPrompt` 而不是 `takeStagedPrompt` 探测——这里只是「要不要
  // 打开」的判断，真正的消费留给 `_openAIPanel` 内部那一次 take，避免两处
  // 都 take 导致第二次拿到 null、`initialQuery` 为空却也没能带上那句话。
  //
  // 同步回调不能 await，用 unawaited。
  @override
  void didPopNext() {
    final tab = _sessionMgrForSync?.activeTab;
    if (tab == null) return;
    if (!context.read<AgentSessionManager>().hasStagedPrompt(tab.server.id)) {
      return;
    }
    unawaited(_openAIPanel(tab));
  }

  @override
  void dispose() {
    TerminalScreen._mountedCount--;
    appRouteObserver.unsubscribe(this);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    _completionDebounce?.cancel();
    _swipeTimer?.cancel();
    _fetFadeTimer?.cancel();
    _fetHideTimer?.cancel();
    _floatingEntry?.remove();
    _sessionMgrForSync?.removeListener(_syncSplitOnTabChange);
    _sessionMgrForSync?.removeListener(_consumeStagedCommands);
    _searchCtrl.dispose();
    for (final sc in _scrollControllers.values) {
      sc.dispose();
    }
    _terminalWidgetKeys.clear();
    _sftpKeys.clear();
    // 清空转发给 SFTP 的 ReconnectService 回调 —— 它是长寿命单例，不清空
    // 就会一直持有本 State（内存泄漏），并在事件到来时访问已销毁的 State。
    // 只清自己装的那份引用，不碰别的实例。
    final rs = _reconnectSvcForSftp;
    if (rs != null) {
      rs.onNetworkTypeChanged = null;
      rs.onForegroundResumedForSftp = null;
    }
    _reconnectSvcForSftp = null;
    // Exec channels now live in AgentSessionManager — same
    // lifetime as the AgentLoops that use them, which outlive this screen.
    // Nothing to dispose here anymore.
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Session / tab management
  // ---------------------------------------------------------------------------

  Future<void> _openInitialSession() async {
    await _connectServer(widget.initialServer!, forceNew: widget.forceNewTab);
  }

  /// Cold-start restore: start any local PTY shells that were not running.
  Future<void> _restoreLocalShells() async {
    if (!mounted) return;
    // iOS 上本地 shell 不存在 —— DB 里若混入了 `local` 记录（跨设备导入、
    // 备份恢复），直接跳过，不要走到 `Pty.start('/system/bin/sh')` 去崩。
    if (!PlatformCapabilities.instance().hasLocalShell) return;
    final tabs = context.read<SessionManager>().tabs;
    for (final tab in tabs) {
      if (tab.server.serverType != 'local' || tab.localShell != null) continue;
      // Start the PTY directly without calling _connectServer, which would
      // call setActiveTab() and steal focus from the saved active tab.
      await _startLocalPty(tab);
    }
  }

  /// Starts (or restarts) the local PTY for [tab] without touching the active
  /// tab index. Wires stdout and an onDone handler that auto-restarts the shell
  /// if the PTY process is killed (e.g. Android background eviction).
  Future<void> _startLocalPty(SessionTab tab) async {
    if (!mounted) return;
    try {
      tab.localShell?.close();
      final ls = LocalShell();
      final w = tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 80;
      final h = tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 24;
      await ls.start(columns: w, rows: h);
      tab.localShell = ls;
      // Single restart handler — fires from whichever death-detection
      // path resolves first (exitCode future, stdout EOF, or a write
      // attempt after the shell was already marked dead). LocalShell
      // makes onDead idempotent so we don't restart twice.
      ls.onDead = () {
        if (tab.localShell == ls) {
          tab.localShell = null;
          if (mounted) {
            context.read<SessionManager>().notifyTabChanged();
            _startLocalPty(tab);
          }
        }
      };
      ls.stdout.listen((data) {
        if (mounted) tab.terminal.write(String.fromCharCodes(data));
      }, onDone: () => ls.notifyExited());
      final mtype = tab.server.multiplexerType;
      if (mtype != MultiplexerType.none) {
        tab.backend.dispose();
        tab.backend = switch (mtype) {
          MultiplexerType.tmux => TmuxBackend(),
          MultiplexerType.none => NoneBackend(),
        };
        final cmd = tab.backend.attachOrCreateCommand(tab.sessionKey);
        if (cmd.isNotEmpty) ls.write('$cmd\n');
        if (mounted) context.read<SessionManager>().notifyTabChanged();
      }
      final cmd = tab.server.startupCommand;
      if (cmd != null && cmd.isNotEmpty) ls.write('$cmd\n');
      tab.isFirstConnection = false;
      if (mounted) context.read<SessionManager>().notifyTabChanged();
    } catch (_) {}
  }

  /// One-time warning when the user refreshes a once-mode QUIC tab —
  /// once-mode tabs *cannot* preserve the remote session, so refresh
  /// will drop them into a fresh bash. Setting `useDaemon=true` on the
  /// server form makes refresh actually restore the original session.
  ///
  /// Returns true if the user wants to proceed with the refresh. Stores
  /// "don't show again" in SharedPreferences (key
  /// 'once_mode_refresh_warning_seen').
  Future<bool> _confirmOnceModeRefresh(SessionTab tab) async {
    // Only relevant for QUIC tabs in once mode.
    if (tab.server.transport != Transport.quic) return true;
    if (tab.server.useDaemon) return true;
    if (tab.transport == null) return true; // first connect

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('once_mode_refresh_warning_seen') == true) {
      return true;
    }

    if (!mounted) return false;
    var dontShowAgain = false;
    final l = context.l10n;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(l.refreshLosesSessionTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.refreshLosesSessionBody),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: dontShowAgain,
                    onChanged: (v) =>
                        setState(() => dontShowAgain = v ?? false),
                  ),
                  Text(l.dontShowAgain),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.continueRefresh),
            ),
          ],
        ),
      ),
    );
    if (dontShowAgain && proceed == true) {
      await prefs.setBool('once_mode_refresh_warning_seen', true);
    }
    return proceed ?? false;
  }

  /// Closes and reopens the connection for [tab] using the latest server config
  /// from the database. Supports protocol changes (SSH ↔ Mosh).
  Future<void> _refreshTab(SessionTab tab, int idx) async {
    if (!mounted) return;

    // E4: once-mode QUIC tabs cannot preserve session across refresh;
    // warn user once so they know to enable Daemon mode if they wanted
    // session continuity.
    if (!await _confirmOnceModeRefresh(tab)) return;
    if (!mounted) return;

    final mgr = context.read<SessionManager>();
    final moshProcessRepo = context.read<MoshProcessRepository>();

    // 用户主动 refresh：立即显示"正在刷新..." banner，不走 1.5s 静默窗口。
    // 自动 reconnect 的 banner timer 用 kBannerDelay 是为了静默瞬时网络抖动；
    // 用户显式触发的操作不需要静默，否则点击像无响应、易反复点。
    // 用 refreshing 而非 reconnectInProgress：后者语义是"连接异常 → 系统抢救"
    // 会让用户误以为出问题；refreshing 表达"你点的刷新在工作中"，符合主动
    // 操作的心智。所有协议统一：SSH / Mosh / QUIC / local PTY。
    tab.isReconnecting = true;
    tab.reconnectUiMessage = ReconnectUiMessage.localized(
      code: ReconnectUiMessageCode.refreshing,
      kind: ReconnectUiMessageKind.info,
      updatedAt: DateTime.now(),
    );
    mgr.notifyTabChanged();

    try {
      if (tab.server.serverType == 'local') {
        if (!PlatformCapabilities.instance().hasLocalShell) {
          if (mounted)
            setState(() {
              _connectError = context.l10n.localShellUnsupported;
            });
          return;
        }
        await _startLocalPty(tab);
        return;
      }

      // Fetch latest server config so protocol/address changes take effect.
      final serverRepo = context.read<ServerRepository>();
      final latestServer =
          await serverRepo.findById(tab.server.id) ?? tab.server;

      // User-initiated refresh trumps any auto-reconnect in flight. Without
      // this, _connectServer's isHandling guard turns refresh into a no-op
      // whenever the v2 liveness watchdog has registered the tab for retry.
      // abandonReconnect 也会清 pending banner timer，避免与上面手动设的
      // isReconnecting=true 冲突。
      context.read<ReconnectService>().abandonReconnect(tab.id);

      // Cancel QUIC transport timers to prevent race conditions, but DO NOT
      // null/close it yet — _connectServer needs the session info (token, port,
      // spki, tabId) for 0-RTT RESUME. Closing eagerly caused staleTransport=null
      // in _connectServer, making RESUME always fall back to HELLO (new PTY).
      if (tab.transport case final AqtTransport aqtT) {
        aqtT.cancelTimers();
      }

      if (tab.isMosh) {
        final shell = tab.moshShell;
        bool killed = true;
        if (shell is MoshShellV2) {
          killed = await shell.close();
        }
        tab.moshShell = null;
        tab.isMosh = false;
        if (mounted && killed) {
          moshProcessRepo.markKilledByTabId(tab.id);
        }
      }
      // NOTE: do NOT close tab.connection here. Closing the SSH bootstrap
      // channel kills the remote once-mode flyterm-server (SIGHUP on channel
      // close), making the original session physically unreachable. Even
      // when the user has a daemon running we want RESUME to use the
      // existing channel if it's still alive. _connectServer will reopen
      // the channel if needed.
      if (!mounted) return;
      mgr.notifyTabChanged();
      await _connectServer(
        latestServer,
        forceNew: false,
        targetTab: tab,
        preserveActiveTab: true,
        // 用户主动 refresh：即使 QUIC transport 还活着也强制走重连/RESUME，
        // 避免 isAlive=true 时 _connectServer 直接 reuse-tab return 让刷新
        // 变 no-op。
        forceReconnect: true,
      );
    } finally {
      // 清 banner：成功 → 用户已看到新内容；失败 → 错误已由 _connectServer
      // /_startLocalPty 显示，banner 不该留着；finally 保证两条路径都清。
      // 同步清 reconnectUiMessage：refreshing message 没设 ttl，不主动清会
      // 永久挂着（除非被新 message 覆盖，但非 mosh/QUIC 路径不会有覆盖）。
      // _connectServer 内部如果设了新 message（如 mosh handshake / reconnect
      // success），那是后续状态、不应被这里清掉；判断 code 还是 refreshing
      // 才清，避免误清后续 message。
      if (mounted) {
        tab.isReconnecting = false;
        if (tab.reconnectUiMessage?.code ==
            ReconnectUiMessageCode.refreshing) {
          tab.reconnectUiMessage = null;
        }
        mgr.notifyTabChanged();
      }
    }
  }

  /// Opens HomeScreen as a server picker and connects the chosen server as a
  /// new tab. This keeps the navigation stack clean: HomeScreen pops itself
  /// with the selected Server, so the stack stays [HomeScreen, TerminalScreen].
  Future<void> _addNewTab() async {
    final server = await Navigator.of(context).push<Server>(
      MaterialPageRoute(builder: (_) => const HomeScreen(forceNewTab: true)),
    );
    if (server != null && mounted) {
      await _connectServer(server, forceNew: true);
    }
  }

  Future<void> _connectServer(
    Server server, {
    bool forceNew = false,
    SessionTab? targetTab,
    bool preserveActiveTab = false,
    bool forceReconnect = false,
  }) async {
    final mgr = context.read<SessionManager>();
    final storage = context.read<SecureStorageService>();
    final moshProcessRepo = context.read<MoshProcessRepository>();

    // If the tab already exists and we're NOT forcing a new one,
    // reuse it (e.g. user pressed back then re-opened the same server).
    // Refresh must target the exact tab that was clicked.  Multiple tabs can
    // point at the same server.id, so using indexWhere(server.id) would always
    // return the first sibling and make refresh jump to that tab.
    final existingIdx =
        forceNew
            ? -1
            : targetTab != null
            ? mgr.tabs.indexWhere((t) => t.id == targetTab.id)
            : mgr.tabs.indexWhere((t) => t.server.id == server.id);
    if (existingIdx != -1) {
      if (!preserveActiveTab) mgr.setActiveTab(existingIdx);
      // Still connected — TerminalWidget will wire itself on first build.
      // Exception: if transport mosh-ness changed, update the tab's server and
      // fall through to reconnect so the new transport takes effect.
      final existingTab = mgr.tabs[existingIdx];
      // An active mosh tab has connection.shell == null (closeShell was called)
      // but is still alive via UDP.  Check isMosh to avoid a spurious reconnect.
      // QUIC tabs also have connection.shell == null (SSH is bootstrap-only);
      // use the transport liveness check instead.
      final isAlive =
          existingTab.server.serverType == 'local'
              ? (existingTab.localShell != null)
              : existingTab.isAqtTransport
              ? !(existingTab.transport as AqtTransport).isDead
              : existingTab.isMosh
              ? (existingTab.moshShell != null)
              : (existingTab.connection.shell != null);
      // If ReconnectService is already handling a reconnect for this tab,
      // don't start a second parallel connection. Just activate the tab and
      // let the service finish — it will call notifyReconnected() when done.
      final reconnectSvc = context.read<ReconnectService>();
      if (!isAlive && reconnectSvc.isHandling(existingTab.id)) return;
      if (isAlive) {
        final moshChanged = (existingTab.server.transport == Transport.mosh) != (server.transport == Transport.mosh);
        // forceReconnect：用户主动 refresh 必须真的重连，即使 transport
        // 还活着。否则 QUIC 路径会走 reuse-tab return → 刷新变 no-op、
        // banner 一闪而过、用户感知"点了没反应"。
        if (!moshChanged && !forceReconnect) {
          // Reinit the tmux control pipe in case the SSH connection was
          // refreshed by ReconnectService, or the sh -s session timed out.
          if (existingTab.inTmux) {
            await existingTab.backend.reinitControlPipe(
              existingTab.connection,
              existingTab.sessionKey,
            );
          }
          return;
        }
        // mosh transport toggled — close existing connection and reconnect with new settings.
        if (existingTab.isMosh) {
          final shell = existingTab.moshShell;
          bool killed = true;
          if (shell is MoshShellV2) {
            killed = await shell.close();
          }
          existingTab.moshShell = null;
          existingTab.isMosh = false;
          if (killed) {
            moshProcessRepo.markKilledByTabId(existingTab.id);
          }
        }
        await existingTab.connection.close();
      }
      // Connection dropped (or closed above) — fall through to reconnect.
    }

    final tab = existingIdx != -1 ? mgr.tabs[existingIdx] : mgr.addTab(server);

    // ── Local PTY shell ──────────────────────────────────────────────
    if (server.serverType == 'local') {
      if (!PlatformCapabilities.instance().hasLocalShell) {
        // iOS：本地 shell 不存在，不要碰 `Pty.start('/system/bin/sh')`。
        // 把错误写进 `_connectError`，`_buildTabBody` 已有的红字错误页会
        // 展示它 —— 不新增 UI 分支，也不 crash。
        if (mounted)
          setState(() {
            _connectError = context.l10n.localShellUnsupported;
          });
        return;
      }
      SshForegroundService.startOrUpdate(server.name);
      await _startLocalPty(tab);
      if (mounted)
        setState(() {
          _connectError = null;
        });
      return;
    }
    // ── SSH / Mosh ────────────────────────────────────────────────────

    String? privateKeyPem;
    String? password;
    if (server.authType == 'key' && server.keyId != null) {
      privateKeyPem = await storage.loadPrivateKey(server.keyId!);
    } else if (server.authType == 'password') {
      password = await storage.loadPassword(server.id);
      if (password == null && mounted) {
        password = await _promptPassword();
        if (password != null && password.isNotEmpty) {
          await storage.savePassword(server.id, password);
        }
      }
    }

    try {
      // When reusing an existing tab, soft-reset VT state from the previous
      // session to prevent scroll-region (DECSTBM) or SGR artefacts left by
      // mosh from bleeding into the new connection.
      if (existingIdx != -1) {
        // ESC[?1049l: exit alt-buffer  ESC[!p: DECSTR soft-reset (xterm stub)
        // ESC[?25h: explicitly show cursor — DECSTR is unimplemented in xterm
        // 4.x so cursorVisibleMode stays false from the previous session, making
        // !cursorVisibleMode=true route scroll gestures to SGR instead of
        // scrollback until the new server's first frame arrives.
        tab.terminal.write('\x1b[?1049l\x1b[!p\x1b[?25h');
      }
      final serverRepo = context.read<ServerRepository>();
      final jump = await resolveJumpParams(server, serverRepo, storage);
      final agentKeyPairs = await _buildAgentKeyPairs(server, storage);
      final hostKeyVerifier = context.read<HostKeyVerifier>();
      final connectionPool = context.read<SshConnectionPool>();
      final terminalSettings = context.read<TerminalSettings>();
      // QUIC: SSH 只做 bootstrap (flyterm-server)，PTY 走 UDP。不开 SSH shell
      // 避免 QUIC 失败时残留一个"假 SSH shell"被 widget rebuild 取到
      // (activeShell = t.connection.shell) → 用户输入被路由到 SSH PTY，
      // 看起来像 QUIC "降级"到 SSH 但实际无输出回显，造成 UI 状态错乱。
      // Mosh 路径仍保留 openShell=true，以保持握手时 SSH client 可用。
      final isQuicFirst = server.transport == Transport.quic;
      await tab.connection.connect(
        host: server.host,
        port: server.port,
        username: server.username,
        password: password,
        privateKeyPem: privateKeyPem,
        jumpHost: jump?.host,
        jumpPort: jump?.port,
        jumpUsername: jump?.username,
        jumpPassword: jump?.password,
        jumpPrivateKeyPem: jump?.privateKeyPem,
        agentKeyPairs: agentKeyPairs,
        openShell: !isQuicFirst,
        hostKeyVerifier: hostKeyVerifier,
        pool: connectionPool,
        keyId: server.keyId,
        jumpHostId: server.jumpHostId,
        addressFamily: server.addressFamily,
        sshCompression: terminalSettings.sshCompression,
      );
      // QUIC routing: bootstrap flyterm-server over the established SSH connection
      var quicConnected = false;
      final aqtStrategy = server.transport;
      if (aqtStrategy == Transport.quic) {
        // C4 — Try to adopt a prewarmed transport that completed RESUME
        // during app startup. If found and still connected, skip RESUME
        // and bootstrap entirely.
        {
          // Use cached _sessionMgrForSync (set in initState) — `_connectServer`
          // runs after multiple async gaps, so reaching for context here would
          // be lint-flagged and is the wrong pattern.
          final mgr = _sessionMgrForSync;
          final pre = mgr?.prewarmPool.take(tab.id);
          if (pre != null) {
            if (pre.currentState == TransportState.connected) {
              dlog('PREWARM', 'adopt tab=${tab.id}');
              tab.transport = pre;
              tab.clearRemoteTuiHintForNewTransport();
              quicConnected = true;
              // tab.startStreaming() and registerAqtTab are handled by the
              // shared tail below (line ~968 and ~979).
            } else {
              dlog('PREWARM', 'tab=${tab.id} state=${pre.currentState} — discard');
              await pre.close();
            }
          }
        }
        final sshClient = tab.connection.client;
        if (!quicConnected && sshClient != null && !sshClient.isClosed) {
          AqtBootstrapResult? bootstrapResult;
          final staleTransport = tab.transport;
          tab.transport = null;
          // DO NOT close yet — its session metadata (sessionToken, lastTabId,
          // lastSpki) is needed by tryResume. Close happens only AFTER RESUME
          // has been attempted (success: swap-then-close handled by transport
          // swap; failure: explicit close at end of HELLO path). See finally
          // block at the end of this section.

          final cols = tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 80;
          final rows = tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 24;

          try {
            // 0. Version check + silent upgrade before any bootstrap.
            //    This path bypasses AqtTransportFactory.connectWithCredentials,
            //    so we call maybeUpgrade here directly with the existing SSH client.
            await AqtTransportFactory.maybeUpgrade(
              sshClient,
              // ignore: use_build_context_synchronously
              mounted ? context : null,
              useDaemon: server.useDaemon,
              ports: AqtPortSpec.forServer(server.aqtPorts),
            );

            // 1. Get current daemon SPKI first (avoids stale once-mode SPKI in RESUME).
            //    Then attempt RESUME with the CORRECT current SPKI.
            try {
              bootstrapResult = await AqtTransportFactory.bootstrapFor(
                server,
                sshClient,
                // ignore: use_build_context_synchronously
                confirmContext: mounted ? context : null,
              );
            } catch (_) {}

            if (staleTransport is AqtTransport && bootstrapResult != null) {
              // Patch the stale transport's SPKI with the current daemon SPKI before RESUME.
              // Without this, RESUME uses the old once-mode ephemeral key → SPKI mismatch.
              staleTransport.lastSpki = bootstrapResult.info.spki;
              staleTransport.lastPort = bootstrapResult.info.port;
              try {
                final resumed = await AqtTransportFactory.tryResume(
                    staleTransport, server.host,
                    // Relayed sessions resume through this tab's SSH client.
                    openRelay: (p) =>
                        AqtSshRelay.start(sshClient, daemonPort: p));
                if (resumed != null) {
                  tab.transport = resumed;
                  tab.clearRemoteTuiHintForNewTransport();
                  quicConnected = true;
                }
              } catch (_) {}
            }

            // E3: if we still don't have a transport AND the staleTransport carries
            // a valid session token, last-chance probe an existing daemon. If one
            // is running its SPKI matches the original session — RESUME works.
            if (!quicConnected && staleTransport is AqtTransport &&
                staleTransport.sessionToken != null) {
              try {
                final daemonInfo = await probeExistingDaemon(sshClient).timeout(
                  const Duration(seconds: 3),
                  onTimeout: () => null,
                );
                if (daemonInfo != null) {
                  staleTransport.lastPort = daemonInfo.port;
                  staleTransport.lastSpki = daemonInfo.spki;
                  try {
                    final resumed = await AqtTransportFactory.tryResume(
                      staleTransport,
                      server.host,
                      openRelay: (p) =>
                          AqtSshRelay.start(sshClient, daemonPort: p),
                    );
                    if (resumed != null) {
                      tab.transport = resumed;
                      tab.clearRemoteTuiHintForNewTransport();
                      quicConnected = true;
                      dlog('AQT', 'E3 RESUME via existing daemon: success');
                    }
                  } catch (e) {
                    dlog('AQT', 'E3 RESUME via existing daemon failed: $e');
                  }
                }
              } catch (_) {
                // probe timeout / SSH error — fall through to once-mode bootstrap
              }
            }

            // 2. Full bootstrap fallback if RESUME failed or no prior session.
            // Catch AqtServerNotInstalledException and trigger
            // install flow (dialog → arch detect → SFTP upload → verify) once,
            // then retry bootstrap.
            var triedInstall = false;
            while (!quicConnected && bootstrapResult == null) {
              try {
                // No confirmContext: the port-restart question (if any) was
                // already asked by the first bootstrap above.
                bootstrapResult = await AqtTransportFactory.bootstrapFor(
                  server,
                  sshClient,
                );
              } on AqtServerNotInstalledException {
                if (triedInstall || !mounted) {
                  dlog('AQT', 'server not installed, no install prompt '
                      '(triedInstall=$triedInstall mounted=$mounted)');
                  break;
                }
                triedInstall = true;
                final result = await AqtTransportFactory.runInstallFlow(
                  client: sshClient,
                  server: server,
                  dialogContext: context,
                );
                if (result.status != AqtInstallStatus.success) {
                  dlog('AQT', 'install flow non-success: ${result.status} '
                      '${result.errorReason ?? ""}');
                  break;
                }
                // Loop and retry bootstrap with newly installed binary.
                continue;
              } catch (e) {
                dlog('AQT', 'bootstrap failed (non-install): $e');
                break;
              }
            }
            if (!quicConnected && bootstrapResult != null) try {
              // Same routing as the factory: direct UDP, else QUIC over
              // this tab's SSH client (not owned: it lives with the tab).
              final routed = await AqtTransportFactory.connectRouted(
                server: server,
                client: sshClient,
                info: bootstrapResult.info,
                ownsClient: false,
                cols: cols,
                rows: rows,
              );
              tab.transport = routed.value;
              tab.clearRemoteTuiHintForNewTransport();
              quicConnected = true;
            } catch (e) {
              dlog('AQT', 'QUIC connect failed: $e');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(context.l10n.quicConnectFailedHint(
                      AqtTransportFactory.describeConnectError(context, e))),
                  duration: const Duration(seconds: 8),
                  backgroundColor: Colors.orange[800],
                ));
              }
              // QUIC strict — do NOT fall through to SSH.
              // Rethrow so the connect loop surfaces this as a connection error.
              rethrow;
            } finally {
              bootstrapResult?.close();
            }
          } finally {
            // staleTransport always gets closed here — whether RESUME succeeded,
            // HELLO succeeded, or an exception was thrown. Safe because by this
            // point tab.transport has already been replaced (resumed/HELLO/null),
            // so there is no double-listener risk.
            if (tab.transport != staleTransport) {
              staleTransport?.close();
            }
          }
        }
      }

      // Mosh routing: try mosh if enabled and no jump host (skip when QUIC active)
      if (!quicConnected && server.transport == Transport.mosh && server.jumpHostId == null) {
        tab.reconnectUiMessage = ReconnectUiMessage.localized(
          code: ReconnectUiMessageCode.reconnectMoshHandshake,
          kind: ReconnectUiMessageKind.info,
          updatedAt: DateTime.now(),
        );
        if (mounted) context.read<SessionManager>().notifyTabChanged();
        final moshShell = await MoshHandshake.run(
          host: server.host,
          port: server.port,
          username: server.username,
          password: password,
          privateKeyPem: privateKeyPem,
          portRange: server.moshPortRange,
          reuseClient: tab.connection.client,
          terminalWidth:
              tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 80,
          terminalHeight:
              tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 24,
          addressFamily: server.addressFamily,
          sshCompression: terminalSettings.sshCompression,
          flytermSessionId: tab.id,
          flytermServerId: server.id,
          onServerStarted: (pid, udpPort) {
            return moshProcessRepo.upsertActive(
              id: '${tab.id}-$pid',
              serverId: server.id,
              tabId: tab.id,
              tmuxKey: tab.sessionKey,
              pid: pid,
              udpPort: udpPort,
              host: server.host,
              sshPort: server.port,
              username: server.username,
              portRange: server.moshPortRange,
            );
          },
          onServerKilled: (pid) {
            return moshProcessRepo.markKilled('${tab.id}-$pid');
          },
        );
        tab.moshShell = moshShell;
        tab.isMosh = true;
        // Fix 4: feed NetworkStability with each authenticated packet so
        // the status-dot stability reflects real mosh transport health.
        // Without this, recordOkPacket is never called and the dot stays
        // blue (isStable=true) even when mosh is silently stuck.
        // The first auth packet hard-resets the score to 50 (stable) so a
        // brand-new v2 connection doesn't sit on orange while +1 ticks
        // claw it back from any earlier missedDeadline penalty.
        var firstAuth = true;
        moshShell.onAuthenticatedPacket = (rtt) {
          if (firstAuth) {
            firstAuth = false;
            tab.networkStability.recordReconnectSuccess();
          } else {
            tab.networkStability.recordOkPacket(rtt);
          }
        };
        tab.onClose = () => moshProcessRepo.markKilledByTabId(tab.id);
        // Release the idle SSH PTY — mosh handles all I/O via UDP.
        // Keep the SSH client alive so TmuxHelper exec channels still work.
        tab.connection.closeShell();
        tab.reconnectUiMessage = ReconnectUiMessage.localized(
          code: ReconnectUiMessageCode.reconnectMoshConnected,
          kind: ReconnectUiMessageKind.success,
          updatedAt: DateTime.now(),
          ttl: const Duration(seconds: 2),
        );
        if (mounted) {
          context.read<SessionManager>().notifyTabChanged();
        }
      }
      tab.startStreaming(source: 'connectServer');
      // Wire watchdog callbacks for the first connection — ReconnectService
      // normally registers these inside _reconnect(), which is only reached on
      // the second+ connection. Without this, a first-connect tab's TCP drop
      // (SSH) or session death (Mosh) goes undetected until a connectivity event.
      if (mounted) {
        final reconnectSvc = context.read<ReconnectService>();
        reconnectSvc.registerMoshTab(tab);
        reconnectSvc.registerSshTab(tab);
        // For QUIC tabs: set onSessionDead so transport failures trigger reconnect.
        // Without this, QUIC dies silently — tab.onSessionDead is null by default.
        if (quicConnected) reconnectSvc.registerAqtTab(tab);
      }
      if (mounted)
        setState(() {
          _connectError = null;
        });
      SshForegroundService.startOrUpdate(server.name);

      // Active shell: prefer mosh when connected via SSP, fall back to SSH shell.
      final activeStdin = (tab.moshShell ?? tab.connection.shell)?.stdin;
      final mtype = server.multiplexerType;
      // QUIC uses its own PTY (not the SSH shell), so multiplexer detection
      // is meaningless — the QUIC PTY is a direct shell without tmux.
      if (!quicConnected && mtype != MultiplexerType.none) {
        // Dispose old backend before creating a new one (avoids pipe leak).
        tab.backend.dispose();
        tab.backend = switch (mtype) {
          MultiplexerType.tmux => TmuxBackend(),
          MultiplexerType.none => NoneBackend(),
        };
        if (mounted) context.read<SessionManager>().notifyTabChanged();
        final found = await tab.backend.detect(tab.connection);
        if (found) {
          // Fix: same PTY size issue as in ReconnectService — send the current
          // terminal size before tmux attaches so it renders at the right height.
          final w = tab.terminal.viewWidth;
          final h = tab.terminal.viewHeight;
          if (w > 0 && h > 0) {
            (tab.moshShell ?? tab.connection.shell)?.resizeTerminal(w, h, 0, 0);
          }
          activeStdin?.add(
            utf8.encode(
              '${tab.backend.attachOrCreateCommand(tab.sessionKey, isMosh: tab.isMosh)}\n',
            ),
          );
          // 200 ms is enough for the most common case (tmux server already
          // running, attach is a few-ms operation) and for the cold-start
          // case [enableMouse] now retries internally — so the
          // worst-case latency is still ~600 ms but the typical case lands
          // ~300 ms earlier than the previous unconditional 500 ms wait.
          await Future.delayed(const Duration(milliseconds: 200));
          // Enable mouse mode on the server via a silent exec channel.
          // Retries internally if tmux server isn't ready yet.
          await tab.backend.enableMouse(tab.connection);
          // Open persistent control pipe for low-latency scroll commands.
          await tab.backend.initControlPipe(tab.connection, tab.sessionKey);
          // tmux intercepts ESC[?1049h so local echo can't detect alt-buffer mode.
          // Disable predictions to prevent cursor-movement sequences corrupting TUI apps.
          // Dynamic dispatch covers both MoshShell (v1) and MoshShellV2.
          tab.moshShell?.suppressLocalEcho();
          // iTerm2 同款策略：capture-pane 抓取历史注入 xterm scrollback，
          // 使 SSH+tmux 会话连接后可向上滑动查看历史（无需进入 copy-mode）。
          // capture-pane 输出为干净的行文本（带 ANSI 颜色），不含光标定位序列，
          // 写入后 xterm native scroll 可直接访问。
          unawaited(() async {
            final history = await tab.backend.capturePane(
                tab.connection, tab.sessionKey);
            if (history.isNotEmpty && mounted) {
              tab.terminal.write(history);
            }
          }());
          if (mounted) context.read<SessionManager>().notifyTabChanged();
          final cmd = server.startupCommand;
          if (cmd != null && cmd.isNotEmpty) {
            activeStdin?.add(utf8.encode('$cmd\n'));
          }
        } else {
          tab.backend.dispose();
          tab.backend = NoneBackend();
          if (mounted) context.read<SessionManager>().notifyTabChanged();
          tab.terminal.write('\r\n${context.l10n.tmuxNotFoundClosed}\r\n');
          final cmd = server.startupCommand;
          if (cmd != null && cmd.isNotEmpty) {
            activeStdin?.add(utf8.encode('$cmd\n'));
          }
        }
      } else {
        final cmd = server.startupCommand;
        if (cmd != null && cmd.isNotEmpty) {
          activeStdin?.add(utf8.encode('$cmd\n'));
        }
      }
      tab.isFirstConnection = false;
    } catch (e) {
      if (mounted)
        setState(() {
          _connectError = e.toString();
        });
    }
  }

  /// Loads all stored key pairs for SSH agent forwarding.
  /// Only called when server.agentForwarding is true.
  Future<List<SSHKeyPair>> _buildAgentKeyPairs(
    Server server,
    SecureStorageService storage,
  ) async {
    if (!server.agentForwarding) return const [];
    try {
      final keyRepo = context.read<SSHKeyRepository>();
      final keys = await keyRepo.findAll();
      final pems = await storage.loadPrivateKeys(
        keys.map((k) => k.id).toList(),
      );
      final pairs = <SSHKeyPair>[];
      for (final pem in pems) {
        try {
          pairs.addAll(SSHKeyPair.fromPem(pem));
        } catch (e) {
          dlog('Agent', 'Failed to parse key PEM: $e');
        }
      }
      return pairs;
    } catch (e) {
      dlog('Agent', 'Failed to load agent keys: $e');
      return const [];
    }
  }

  Future<String?> _promptPassword() async {
    final ctrl = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final l = ctx.l10n;
          return AlertDialog(
            title: Text(l.enterPassword),
            content: TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: l.labelPassword),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: Text(l.confirm),
              ),
            ],
          );
        },
      );
    } finally {
      ctrl.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Split screen
  // ---------------------------------------------------------------------------

  void _syncSplitOnTabChange() {
    if (!mounted) return;
    final mgr = context.read<SessionManager>();
    final splitMgr = context.read<SplitManager>();
    final allTabIds = mgr.tabs.map((t) => t.id).toSet();
    final secondary = splitMgr.secondarySession;
    final floating = splitMgr.floatingSession;
    if (secondary != null && !allTabIds.contains(secondary.id)) {
      splitMgr.onTabClosed(secondary);
    }
    if (floating != null && !allTabIds.contains(floating.id)) {
      _floatingEntry?.remove();
      _floatingEntry = null;
      splitMgr.onTabClosed(floating);
    }
  }

  /// Open the visual 2×2 layout picker. The chosen [LayoutChoice] is
  /// reconciled against current [SplitManager] state — switching between
  /// any two layouts is a single tap.
  /// 终端页 `+` 菜单 —— 合并了原 `⋮` 的四项，`⋮` 已删除。
  ///
  /// 判据走 [buildPlusMenuItems]（纯函数、有测试钉住），这里只负责把
  /// enum 翻译成菜单项 + 定位 + 分派。
  Future<void> _openPlusMenu(
    BuildContext plusContext,
    SessionTab? tab,
    SplitManager splitMgr,
  ) async {
    final mgr = context.read<SessionManager>();
    final canUseRemoteActions =
        tab != null &&
        ((tab.connection.client != null &&
                tab.connection.client?.isClosed == false) ||
            tab.isMosh ||
            tab.moshShell != null ||
            tab.transport?.kind == TransportKind.aqt);
    final isLocalAlive =
        tab?.server.serverType == 'local' && tab?.localShell != null;

    final items = buildPlusMenuItems(
      canUseRemoteActions: canUseRemoteActions,
      isLocalAlive: isLocalAlive,
    );
    final l = context.l10n;
    final layout = _resolveCurrentLayout(splitMgr);

    // 锚点定位：把菜单贴在 `+` 图标左下角起算的位置。
    final box = plusContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(plusContext).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy + box.size.height,
      overlay.size.width - topLeft.dx - box.size.width,
      0,
    );

    final selected = await showMenu<String>(
      context: context,
      position: position,
      items: [
        for (var i = 0; i < items.length; i++) ...[
          if (i == dividerBeforeIndex(items)) const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: switch (items[i]) {
              PlusMenuItem.newTab => 'new_tab',
              PlusMenuItem.sftp => 'sftp',
              PlusMenuItem.layout => 'layout',
              PlusMenuItem.newTunnel => 'tunnel_new',
            },
            child: Row(
              children: [
                Icon(switch (items[i]) {
                  PlusMenuItem.newTab => Icons.add,
                  PlusMenuItem.sftp =>
                    tab?.viewMode == TabViewMode.sftp
                        ? Icons.terminal
                        : Icons.folder_open,
                  PlusMenuItem.layout => _iconForLayout(layout),
                  PlusMenuItem.newTunnel => Icons.swap_horiz,
                }),
                const SizedBox(width: 12),
                Text(switch (items[i]) {
                  PlusMenuItem.newTab => l.newConnection,
                  PlusMenuItem.sftp =>
                    tab?.viewMode == TabViewMode.sftp
                        ? l.sftpSwitchToTerminal
                        : l.sftpSwitchToSftp,
                  PlusMenuItem.layout =>
                    l.layoutWithCurrent(_layoutLabel(layout, l)),
                  PlusMenuItem.newTunnel => l.newTunnel,
                }),
              ],
            ),
          ),
        ],
      ],
    );
    if (!mounted || selected == null) return;

    switch (selected) {
      case 'new_tab':
        _addNewTab();
      case 'sftp':
        if (tab == null) return;
        if (tab.viewMode == TabViewMode.sftp) {
          mgr.toggleViewMode(tab);
        } else {
          _openSftp(tab);
        }
      case 'tunnel_new':
        if (tab == null) return;
        // 隧道管理的家已在首页「服务器｜隧道」分段（隧道管理项从 + 菜单
        // 移除）；新建仍保留这里的上下文入口。
        _openTunnelForm(tab);
      case 'layout':
        if (tab == null) return;
        _openLayoutPicker(tab, splitMgr);
    }
  }

  void _openLayoutPicker(SessionTab activeTab, SplitManager splitMgr) {
    final mgr = context.read<SessionManager>();
    final current = _resolveCurrentLayout(splitMgr);
    final floatAvailable =
        splitMgr.floatingSession != null || mgr.tabs.length > 1;
    LayoutPickerSheet.show(
      context: context,
      current: current,
      floatAvailable: floatAvailable,
      onPicked: (choice) => _applyLayoutChoice(choice, activeTab, splitMgr),
    );
  }

  /// Long-press on the divider: swap which pane has keyboard focus.
  /// Calls SplitManager.swapPanes (which re-orders pane references) and
  /// then promotes the new first pane to the active SessionManager tab.
  void _swapSplitPanes(SplitManager splitMgr) {
    final mgr = context.read<SessionManager>();
    final currentPrimary = mgr.activeTab;
    if (currentPrimary == null) return;
    final newActive = splitMgr.swapPanes(currentPrimary);
    if (newActive == null) return;
    final idx = mgr.tabs.indexWhere((t) => t.id == newActive.id);
    if (idx != -1) mgr.setActiveTab(idx);
  }

  IconData _iconForLayout(LayoutChoice c) {
    switch (c) {
      case LayoutChoice.single:
        return Icons.crop_square_outlined;
      case LayoutChoice.leftRight:
        return Icons.vertical_split;
      case LayoutChoice.topBottom:
        return Icons.horizontal_split;
      case LayoutChoice.floating:
        return Icons.picture_in_picture_alt;
    }
  }

  String _layoutLabel(LayoutChoice c, AppLocalizations l) {
    switch (c) {
      case LayoutChoice.single:
        return l.layoutSingle;
      case LayoutChoice.leftRight:
        return l.splitHorizontal;
      case LayoutChoice.topBottom:
        return l.splitVertical;
      case LayoutChoice.floating:
        return l.floatTerminal;
    }
  }

  LayoutChoice _resolveCurrentLayout(SplitManager splitMgr) {
    if (splitMgr.floatingSession != null) return LayoutChoice.floating;
    switch (splitMgr.splitMode) {
      case SplitMode.horizontal:
        return LayoutChoice.leftRight;
      case SplitMode.vertical:
        return LayoutChoice.topBottom;
      case SplitMode.off:
        return LayoutChoice.single;
    }
  }

  Future<void> _applyLayoutChoice(
    LayoutChoice choice,
    SessionTab activeTab,
    SplitManager splitMgr,
  ) async {
    // Selecting the layout that's already active is a no-op (the cell is
    // visually selected but tap still routes here).
    if (_resolveCurrentLayout(splitMgr) == choice) return;
    // Tearing down anything that conflicts with the new choice first.
    if (choice != LayoutChoice.floating && splitMgr.floatingSession != null) {
      _floatingEntry?.remove();
      _floatingEntry = null;
      splitMgr.clearFloating();
    }
    if (choice != LayoutChoice.leftRight &&
        choice != LayoutChoice.topBottom &&
        splitMgr.splitMode != SplitMode.off) {
      splitMgr.clearSplit();
    }
    switch (choice) {
      case LayoutChoice.single:
        return;
      case LayoutChoice.leftRight:
        await _activateSplit(SplitMode.horizontal, activeTab, splitMgr);
        return;
      case LayoutChoice.topBottom:
        await _activateSplit(SplitMode.vertical, activeTab, splitMgr);
        return;
      case LayoutChoice.floating:
        _activateFloat(activeTab, splitMgr);
        return;
    }
  }

  Future<void> _activateSplit(
    SplitMode mode,
    SessionTab activeTab,
    SplitManager splitMgr,
  ) async {
    final mgr = context.read<SessionManager>();
    final candidate = mgr.tabs.firstWhere(
      (t) => splitMgr.isAvailableForSplit(t, primary: activeTab),
      orElse: () => activeTab,
    );
    if (candidate == activeTab) {
      await _addNewTab();
      if (!mounted) return;
      final updatedMgr = context.read<SessionManager>();
      if (updatedMgr.tabs.length > 1) {
        final newTab = updatedMgr.tabs.last;
        // addTab() auto-switches _activeIndex to the new tab.
        // Restore the original primary tab so firstPane shows it correctly.
        final primaryIdx = updatedMgr.tabs.indexWhere(
          (t) => t.id == activeTab.id,
        );
        if (primaryIdx != -1) updatedMgr.setActiveTab(primaryIdx);
        splitMgr.setSplitMode(mode);
        splitMgr.setSecondary(newTab, primary: activeTab);
      }
      return;
    }
    splitMgr.setSplitMode(mode);
    splitMgr.setSecondary(candidate, primary: activeTab);
  }

  void _activateFloat(SessionTab activeTab, SplitManager splitMgr) {
    final mgr = context.read<SessionManager>();
    final candidate = mgr.tabs.firstWhere(
      (t) => splitMgr.isAvailableForFloat(t, primary: activeTab),
      orElse: () => activeTab,
    );
    if (candidate == activeTab) return;
    splitMgr.setFloating(candidate, primary: activeTab);
    _floatingEntry?.remove();
    _floatingEntry = FloatingTerminalWindow.createEntry(
      context: context,
      tab: candidate,
      onExpand: () {
        final idx = mgr.tabs.indexOf(candidate);
        if (idx != -1) mgr.setActiveTab(idx);
        _floatingEntry?.remove();
        _floatingEntry = null;
        splitMgr.clearFloating();
      },
      onClose: () {
        _floatingEntry?.remove();
        _floatingEntry = null;
        splitMgr.clearFloating();
      },
    );
    Overlay.of(context).insert(_floatingEntry!);
  }

  // ---------------------------------------------------------------------------
  // Shell completion
  // ---------------------------------------------------------------------------

  void _scheduleCompletion(SessionTab tab) {
    _completionDebounce?.cancel();
    if (_currentInputLine.trim().length < 2) {
      if (_completionSuggestions.isNotEmpty) {
        setState(() => _completionSuggestions = []);
      }
      return;
    }
    // TUI 程序（vim / top / less / htop…）里按键不是在输入 shell 命令：
    // 候选来自命令历史和远端 compgen，在 vim 的 ex 命令行里毫无意义，而浮层
    // 锚在光标处恰好盖住用户正在看的地方。`_currentInputLine` 在这种场景下
    // 本身也是脏的 —— 它累积按键，但 TUI 自己重绘屏幕，那个「当前输入行」
    // 不对应任何东西。
    //
    // 判据用 `foregroundOwnsInputLine` 而**不是** `remoteTuiHint`。
    //
    // 后者只认 `?25l` / `?1049h`，而 Claude Code 稳态下两个都不发：它在主
    // buffer 渲染以保留 scrollback，又要显示光标让用户看到输入位置。真机
    // 诊断实测 `tui:F xtCur:vis xtAlt:F`，补全浮层于是盖在它的输入框上。
    //
    // 这不是「判据分叉」—— 滚轮手势和输入辅助本来就是两个问题，强行共用
    // 一个判据才是这个 bug 的来源。两者的区别写在
    // `foreground_input_owner.dart` 的文档里。
    if (tab.foregroundOwnsInputLine) {
      // 必须**同时清空已有候选**：进 vim 之前弹出的那组浮层否则会一直挂着。
      if (_completionSuggestions.isNotEmpty) {
        setState(() => _completionSuggestions = []);
      }
      return;
    }
    if (!(context.read<TerminalSettings?>()?.commandCompletion ?? true)) return;
    if (_completionSuggestions.isNotEmpty) {
      setState(() => _completionSuggestions = []);
    }
    // Show history matches immediately (no network), then merge shell results
    // when they arrive (~200 ms debounce + compgen RTT).
    final historyNow =
        _historyService
            .filter(_currentInputLine)
            .map(
              (t) => CompletionSuggestion(
                text: t,
                source: CompletionSource.history,
              ),
            )
            .toList();
    if (historyNow.isNotEmpty) {
      setState(() => _completionSuggestions = historyNow);
    }
    _completionDebounce = Timer(const Duration(milliseconds: 200), () {
      _fetchCompletions(tab);
    });
  }

  Future<void> _fetchCompletions(SessionTab tab) async {
    final sshClient = tab.connection.client;
    // Lazy-load remote history on first completion request.
    unawaited(_historyService.loadFromServer(sshClient));

    final shellSuggestions = await _completionService.suggest(
      currentLine: _currentInputLine,
      sshClient: sshClient,
      cwd: tab.cwd,
    );
    if (!mounted || _currentInputLine.isEmpty) return;

    final historyMatches =
        _historyService
            .filter(_currentInputLine)
            .map(
              (t) => CompletionSuggestion(
                text: t,
                source: CompletionSource.history,
              ),
            )
            .toList();
    final seen = historyMatches.map((s) => s.text).toSet();
    final merged = [
      ...historyMatches,
      ...shellSuggestions.where((s) => !seen.contains(s.text)),
    ];
    setState(() => _completionSuggestions = merged);
  }

  // ---------------------------------------------------------------------------
  // AI panel
  // ---------------------------------------------------------------------------

  /// Smart context trimming: finds the last shell prompt, takes from there to
  /// end (current command + output), then pads backwards if room remains.
  /// Falls back to simple tail-truncation when no prompt line is found.
  /// Extract clean, ANSI-free text from the xterm rendered buffer.
  /// Unlike the raw [SessionTab.terminalContext] stream (which contains ANSI
  /// escape sequences), this reads what xterm has already rendered into cells —
  /// exactly what the user sees on screen.  Limits to [maxLines] from the end.
  static String _readTerminalText(Terminal terminal, {int maxLines = 200}) {
    final buffer = terminal.buffer;
    final totalLines = buffer.lines.length;
    if (totalLines == 0) return '';
    final startLine = (totalLines - maxLines).clamp(0, totalLines);
    final range = BufferRangeLine(
      CellOffset(0, startLine),
      CellOffset(
        terminal.viewWidth > 0 ? terminal.viewWidth - 1 : 79,
        totalLines - 1,
      ),
    );
    return buffer.getText(range).trimRight();
  }

  static String _truncateBuffer(String buffer, {int maxLines = 80}) {
    if (buffer.isEmpty) return buffer;
    final lines = buffer.split('\n');
    if (lines.length <= maxLines) return buffer;

    // Strip ANSI codes for prompt detection only.
    final ansiRe = RegExp(r'\x1b\[[0-9;]*[mKHABCDJfsufr]');
    final promptRe = RegExp(r'[$#>]\s*$');

    // Walk backwards to find the last prompt line.
    int promptIdx = -1;
    for (int i = lines.length - 1; i >= 0; i--) {
      if (promptRe.hasMatch(lines[i].replaceAll(ansiRe, ''))) {
        promptIdx = i;
        break;
      }
    }

    if (promptIdx < 0) {
      // No prompt found — simple tail.
      return lines.sublist(lines.length - maxLines).join('\n');
    }

    // Take from prompt to end; pad forward with earlier context if under budget.
    final tail = lines.sublist(promptIdx);
    if (tail.length >= maxLines) {
      return tail.sublist(tail.length - maxLines).join('\n');
    }
    final spare = maxLines - tail.length;
    final head = lines.sublist(
      (promptIdx - spare).clamp(0, promptIdx),
      promptIdx,
    );
    return [...head, ...tail].join('\n');
  }

  /// Returns true to intercept [data] (not forwarded to shell).
  /// Fires on Enter (\r) when the accumulated input is a dangerous command:
  /// sends \x15 (Ctrl+U) to kill the remote readline buffer, then shows the
  /// confirmation dialog.  If the user confirms, the command is resent.
  bool _interceptTerminalInput(String data, SessionTab tab) {
    if (data != '\r') return false;
    if (!context.read<TerminalSettings>().dangerousCommandGuard) return false;
    final cmd = _currentInputLine.trim();
    if (cmd.isEmpty || !_isDangerousCommand(cmd)) return false;
    _currentInputLine = '';
    _completionDebounce?.cancel();
    if (_completionSuggestions.isNotEmpty) {
      setState(() => _completionSuggestions = []);
    }
    _writeToTab(tab, '\x15');
    _showDryRunDialog(tab, cmd);
    return true;
  }

  void _onUserInput(String data, SessionTab tab) {
    for (final char in data.runes) {
      if (char == 0x0d || char == 0x0a) {
        if (_currentInputLine.trim().isNotEmpty) {
          tab.lastCommand = _currentInputLine.trim();
          _historyService.recordCommand(_currentInputLine.trim());
        }
        _currentInputLine = '';
        _completionDebounce?.cancel();
        if (_completionSuggestions.isNotEmpty) {
          setState(() => _completionSuggestions = []);
        }
      } else if (char == 0x1b) {
        _inEscapeSeq = true;
        _escapeSawCsi = false;
      } else if (_inEscapeSeq) {
        if (!_escapeSawCsi && (char == 0x5b || char == 0x4f)) {
          // ESC [ ... (CSI) / ESC O ... (SS3): do not end the escape at '['.
          _escapeSawCsi = true;
        } else if (!_escapeSawCsi || (char >= 0x40 && char <= 0x7e)) {
          _inEscapeSeq = false;
          _escapeSawCsi = false;
        }
      } else if (char == 0x7f) {
        if (_currentInputLine.isNotEmpty) {
          _currentInputLine = _currentInputLine.substring(
            0,
            _currentInputLine.length - 1,
          );
        }
        _scheduleCompletion(tab);
      } else if (char == 0x03) {
        _currentInputLine = '';
        _completionDebounce?.cancel();
        if (_completionSuggestions.isNotEmpty) {
          setState(() => _completionSuggestions = []);
        }
      } else if (char >= 0x20 && char < 0x7f) {
        _currentInputLine += String.fromCharCode(char);
        if (tab.shell == null && _currentInputLine.length == 1) {
          if (char == 0x25)
            tab.shell = 'zsh';
          else if (char == 0x24)
            tab.shell = 'bash';
          else if (char == 0x3e)
            tab.shell = 'fish';
        }
        _scheduleCompletion(tab);
      }
    }
  }

  void _acceptCompletion(CompletionSuggestion suggestion, SessionTab tab) {
    final text = suggestion.text;
    final String toInject;
    if (text.startsWith(_currentInputLine)) {
      toInject = text.substring(_currentInputLine.length);
    } else {
      toInject = '\x15$text'; // Ctrl+U clears line, then inject full
    }

    final moshOrSsh = tab.moshShell ?? tab.connection.shell;
    if (moshOrSsh != null || tab.transport != null) {
      _writeToTab(tab, toInject);
      _currentInputLine = text;
    } else if (tab.localShell != null) {
      tab.localShell!.write(toInject);
      _currentInputLine = text;
    }
    // Always clear — prevents a stuck popup from stealing subsequent taps.
    setState(() => _completionSuggestions = []);
  }

  /// Exec channel used by [_agentLoopFor]'s `bash` tool. One per server,
  /// reused across reopenings of the panel and across tabs on the same
  /// server. Owned by [AgentSessionManager] now — same
  /// lifetime as the [AgentLoop] that uses it, so the channel doesn't get
  /// disposed out from under a loop that outlives this screen.
  ///
  /// **不碰 `context`**：本方法经 `runnerProvider` / `prewarmProvider`
  /// 被长寿的 `AgentLoop` 调用，可能在本 State 已 dispose 之后才发生
  /// （面板关了、tab 切了、页面退了，loop 还在跑）。所有依赖都取
  /// initState 攒下的字段句柄。
  AgentExecChannel _execChannelFor(SessionTab tab) => execChannelForServer(
        mgr: _agentMgrForAgent ?? context.read<AgentSessionManager>(),
        server: tab.server,
        sessions: _sessionMgrForSync ?? context.read<SessionManager>(),
        storage: _storageForAgent ?? context.read<SecureStorageService>(),
      );

  /// 按 serverId 取一条 agent 专用 channel。用于多机调用的目标机器。
  ///
  /// 与 [_execChannelFor] 共用 `AgentSessionManager` 的缓存，所以同一台机器
  /// 无论从哪条路径进来都是同一个 channel 实例。
  ///
  /// 不碰 `context` 的理由同上。注意 `_serverById` 读的是 `_serverCache`
  /// （一个普通字段，不经过 Element），它在 State 死后依旧可读。
  AgentExecChannel _execChannelForServerId(String serverId) =>
      execChannelForServer(
        mgr: _agentMgrForAgent ?? context.read<AgentSessionManager>(),
        server: _serverById(serverId),
        sessions: _sessionMgrForSync ?? context.read<SessionManager>(),
        storage: _storageForAgent ?? context.read<SecureStorageService>(),
      );

  /// 服务器清单快照，供多机 agent 调用解析目标。
  ///
  /// 缓存而不是每次查库：`runnerProvider` 是同步回调，等不了一次异步查询。
  /// 在打开 AI 面板时刷新一次就够——会话期间新增服务器是低频操作，而且用户
  /// 新增之后通常会去连它（那会重开面板）。
  List<Server> _serverCache = const [];

  Future<void> _refreshServerCache() async {
    // 先抓仓库再 await：`context.read` 必须在任何 await **之前**求值，
    // 否则 await 期间本 State 被 dispose，回来时 context 已失效。
    // 字段里的句柄由 initState 抓取，之后不再依赖 context —— 这是本方法
    // 能被长寿 agent provider 安全调用的前提。
    final repo = _serverRepoForAgent ?? context.read<ServerRepository>();
    final list = await repo.findAll();
    if (!mounted) return;
    _serverCache = list;
  }

  Server _serverById(String id) =>
      _serverCache.firstWhere((s) => s.id == id,
          orElse: () => throw StateError('server $id not in cache'));

  /// 除去当前这台，还有别的 ssh 服务器吗？喂给 `_openAIPanel` 传进面板 UI 的
  /// `hasOtherServers:`（是否显示「切机器」一类入口），与 `buildAgentLoop`
  /// 内部那份同名判定（装配工具清单用）各算各的，互不依赖 —— 这份仍然留在
  /// `terminal_screen.dart` 是因为它只喂 UI，不属于搬去 `agent_assembly.dart`
  /// 的装配代码。
  ///
  /// 判据是 `serverType == 'ssh'` 的条目数 > 1。**不看 `creds_ok`** —— 那是
  /// `list_servers` 回填里的字段，拿它当门槛要为每一轮多做一次 keystore 读取。
  ///
  /// 数据源是 `_serverCache`（`_openAIPanel` 在建 loop 之前会
  /// `await _refreshServerCache()`）。
  bool get _hasOtherServers =>
      _serverCache.where((s) => s.serverType == 'ssh').length > 1;

  /// 返回这台服务器已有的 [AgentLoop](面板关了重开仍在 —— [AgentSessionManager]
  /// 持有它),没有就造一条。
  ///
  /// 装配本体搬进了 `agent_assembly.dart`(与全局 AI tab 共用)。这里只负责
  /// 把「终端页特有的那四样」填进去:当前 tab 的 cwd、那块屏幕、归属机器、
  /// 以及这台机器的 app 端笔记(`ServerNotesManager`)。
  AgentLoop _agentLoopFor(SessionTab tab) {
    final mgr = context.read<AgentSessionManager>();
    final serverId = tab.server.id;
    final existing = mgr.loopFor(serverId);
    if (existing != null) return existing;

    final sessions = context.read<SessionManager>();
    // **解析当前活动 tab,不要用传进来的那个。** loop 按 serverId 复用、寿命
    // 远长于任何一个 tab;捕获具体 tab 会让「在 tab A 开过面板、切到 tab B
    // 再开」拿到 A 的目录,也会让已关闭的 SessionTab 永远回收不掉。
    final contextTab = sessions.activeTabForServer(serverId) ?? tab;

    // C2 修复：下面 `machineNotes` 是存进 `AgentLoop` 的闭包，而 loop 的寿命
    // 远长于本 State（见上面 `_serverRepoForAgent` 字段那段注释 —— 这里是
    // 同一个坑的另一个实例）。原先这里是 `context.read<ServerNotesManager>()`
    // 写在闭包*内部*，等于每次调用才去查 —— 一旦本 State 已经 dispose
    // （进终端开过一次 AI、退出到服务器列表、再进同一台机器），
    // `agent_loop.dart` 的 `_refreshSystemPrompt` 调用这个闭包时会在一个
    // deactivated widget 上做祖先查找，直接抛异常，而那条调用路径没有 try
    // 包裹。改成在这里（方法体内、本 State 一定还 mounted）先取出引用，闭包
    // 只读这个局部变量——`ServerNotesManager` 是 main.dart 挂的全局单例，
    // 寿命覆盖整个 App、比本 State 长，闭包抓着它不构成泄漏，也不需要
    // context。**不要把它改回 `context.read`。**
    final notes = context.read<ServerNotesManager>();

    final loop = buildAgentLoop(
      deps: _agentDeps ?? AgentAssemblyDeps.fromContext(context),
      sessionKey: serverId,
      defaultServer: tab.server,
      serverCache: () => _serverCache,
      // 等价于搬运前 `serverListProvider` 末尾那句 `if (mounted) _serverCache
      // = list` —— 模型每调一次 `list_servers`，顺带把本地缓存刷新一次，
      // 下一轮 `hasOtherServers` / 工具清单就能看到新增或删除的服务器。
      // 没有这行也不算回归：`_openAIPanel` 每次开面板都会
      // `await _refreshServerCache()`，重开面板能自愈——但补上更严谨，
      // 也符合这次重构「零行为变化」的要求。
      onServersRefreshed: (list) {
        if (mounted) _serverCache = list;
      },
      languageTag: Localizations.localeOf(context).toLanguageTag(),
      languageName: context.l10n.promptLanguageName,
      cwdSnapshot: contextTab.cwd,
      terminalSnapshot: _readTerminalText(contextTab.terminal),
      cwdProvider: () => sessions.activeTabForServer(serverId)?.cwd,
      terminalTextProvider: () {
        final t = sessions.activeTabForServer(serverId);
        return t == null ? null : _readTerminalText(t.terminal);
      },
      machineNotes: () => notes.noteFor(serverId),
      // 两个来源,优先级有讲究:`takePendingRestore` 是用户在历史列表里**显式
      // 点开**的那一段,`_pendingLoopRestore` 是 app 重启时自动恢复的最近一段。
      // 显式选择必须压过自动恢复。
      restoreFrom: mgr.takePendingRestore(serverId) ??
          _pendingLoopRestore.remove(serverId),
    );
    return loop;
  }

  Future<void> _openAIPanel(SessionTab tab, {String? initialQuery}) async {
    await _refreshServerCache();
    if (!mounted) return;
    // `_agentLoopFor` 是同步方法、不能自己 await —— 只有「这台服务器还没有
    // 活跃 loop」时才会真的构造新 loop、用到这份存档，这里提前把它取出来
    // 缓存住。若已有活跃 loop，`_agentLoopFor` 会直接复用、不会消费这份值，
    // 留着也无妨（键是 serverId，下次真正创建时才会被 remove 取走）。
    final mgr = context.read<AgentSessionManager>();
    final skills = context.read<AgentSkillManager>();
    // C2 修复：与 `_agentLoopFor` 里的 `notes` 同一个理由——下面传进
    // `AIPanel.show` 的 `onWriteMachineNotes` 闭包只在面板开着时才会被调，
    // 风险比 `machineNotes` 低，但同样不该在闭包内部才 `context.read`。这里
    // （方法体内、本 State 一定还 mounted）先取出引用，闭包只读它。
    final notes = context.read<ServerNotesManager>();
    final serverId = tab.server.id;
    if (mgr.loopFor(serverId) == null) {
      _pendingLoopRestore[serverId] = await mgr.takeMostRecent(serverId);
      if (!mounted) return;
    }
    setState(() => _aiPanelOpen = true);
    // 调用方显式传的 initialQuery 优先于看板「让模型接手」投递的槽——
    // 传了 initialQuery 说明用户刚在终端里做了一个明确的动作（长按命令
    // 选「AI 解释」、点 AI 按钮打开面板），这比槽里那句可能滞留了很久
    // 的话更是他现在想要的。槽的生命周期本该是「点按钮到面板打开」这
    // 几百毫秒，但 `didPopNext` 只在有槽时才会调这个函数、且不保证
    // 用户回到终端后立刻做别的操作，所以不能假设两者时间紧邻。
    //
    // 不管用不用得上，槽都要在这里无条件 take 掉清空：如果 initialQuery
    // 非空导致槽被 `??` 短路跳过、留在原地，它会继续躺在那儿，威胁下一次
    // 真正的空调用（比如几小时后用户单纯点 AI 按钮，会平白多出一句不相关
    // 的话）。
    final staged = mgr.takeStagedPrompt(serverId);
    final effectiveQuery = initialQuery ?? staged;
    AIPanel.show(
      context,
      engine: tab.aiEngine,
      contextProvider:
          () =>
              TerminalContext(
                cwd: tab.cwd,
                shell: tab.shell,
                lastCommand: tab.lastCommand,
                terminalBuffer: _readTerminalText(tab.terminal),
              ).toContextString(),
      initialQuery: effectiveQuery,
      execChannel: _execChannelFor(tab),
      loopFactory: () => _agentLoopFor(tab),
      onOpenServerSettings:
          () => Navigator.pushNamed(
            context,
            '/server-form',
            arguments: tab.server,
          ),
      onOpenJobs:
          kShowJobBoard ? () => Navigator.pushNamed(context, '/jobs') : null,
      onRunCommand: (cmd) => _runCommand(tab, cmd),
      onSaveCommand: (cmd) => _showSaveFavoriteDialog(cmd),
      onExplainCommand: (cmd) {
        final svc = context.read<AIProviderService>();
        if (svc.hasProvider) {
          tab.aiEngine.query(
            '请用一两句话解释这条命令的作用和可能的风险：\n```\n$cmd\n```',
            provider: svc.provider!,
          );
        }
      },
      // 知识提议卡「存入」的落地：skill 走技能库（与 `save_skill` 工具共用
      // 同一个 `skills.save`），机器笔记走 app 端 `ServerNotesManager` 的
      // `appendNote`（见下面 onWriteMachineNotes）——不再读写远端
      // `~/.flyterm/AGENTS.md` 文件，那套远端读缓存/写回机制随本次改造一起
      // 删掉了。
      onSaveSkill: (name, description, body) => skills.save(
        name: name,
        description: description,
        body: body,
        source: SkillSource.ai,
      ),
      // I3 修复：改签名前这里是 `(String text)`，调用方（`agent_view.dart`）
      // 自己拼好「现有内容 + 新小节」整份文本再传进来，绕过了
      // `appendNote` 开头「存量本身超限」那道守卫——于是同一种超限场景，
      // `appendNote` 报的是「这事交给设置页」的人话，这条路径报的却是一个
      // 调用方砍不掉的 `overflowBytes` 数字（候选本身可能没那么大，超的是
      // 存量）。改成直接把 heading/body 丢给 `appendNote`，拼接和守卫都在
      // 一处，`appendNote` dartdoc 里「沉淀卡片与 save_note 工具都走这条」
      // 才算真的成立。
      onWriteMachineNotes: (heading, body) => notes.appendNote(
        serverId: tab.server.id,
        heading: heading,
        body: body,
      ),
      // 输入框 `@file` 的目录列表。**走 exec channel 的 SFTP ops，不用
      // tab.sftpSvc** —— 后者是浏览器的 UI 状态机（持有 currentPath /
      // entries / isLoading），调它的 listDirectory 会改掉用户 SFTP 界面的
      // 当前位置。这条与 agent 的 sftpOpsProvider 同一条路径（见上面那段
      // 注释），顺带拿到它的两个好处：QUIC 会话不需要第二条代码路径，
      // 同一台机器整个会话只开一条连接。
      listRemoteDir: (dir, {serverId}) async {
        final ch = serverId == null
            ? _execChannelFor(tab)
            : _execChannelForServerId(serverId);
        final ops = await sftpOpsFromClient(await ch.obtain());
        final names = await ops.listdir(dir);
        return [
          for (final n in names)
            if (n.filename != '.' && n.filename != '..')
              SftpEntry.fromSftpName(n, dir),
        ];
      },
      // `~` 的展开。**不能直接把 '~' 丢给 REALPATH** —— SFTP 不是 shell，
      // OpenSSH 的 sftp-server 不展开 `~`，`absolutePath('~/.ssh')` 会返回
      // `<cwd>/~/.ssh` 这种拼出来的废路径或直接报错。而 SFTP 会话的起点就是
      // 登录用户的 home，所以用 '.' 求出 home 再做字符串替换。
      resolveRemotePath: (path, {serverId}) async {
        final ch = serverId == null
            ? _execChannelFor(tab)
            : _execChannelForServerId(serverId);
        final ops = await sftpOpsFromClient(await ch.obtain());
        final home = await ops.absolutePath('.');
        if (path == '~') return home;
        if (path.startsWith('~/')) return '$home/${path.substring(2)}';
        return ops.absolutePath(path);
      },
      // `_serverCache` 在本方法开头已经 await 刷过了。
      servers: _serverCache,
      hasOtherServers: _hasOtherServers,
      // 附件的读/写都落在同一个 `AttachmentStore` 实例上——main.dart 装配的
      // 那份全局单例，`fileFor` 只是它的一个投影。可空读取：这个 provider
      // 是新加的，防止漏配置时崩溃退化成「附件按钮不出现」而不是炸整个面板。
      attachmentStore: context.read<AttachmentStore?>(),
      attachmentFileFor: context.read<AttachmentStore?>()?.fileFor,
      attachmentServerId: tab.server.id,
    ).then((_) {
      if (mounted) setState(() => _aiPanelOpen = false);
    });
  }

  // ---------------------------------------------------------------------------
  // Command execution helpers
  // ---------------------------------------------------------------------------

  /// Sends [data] to the active session — routes through RemoteTransport (QUIC)
  /// when set, falls back to legacy SSH/Mosh shell otherwise.
  void _writeToTab(SessionTab tab, String data) {
    final t = tab.transport;
    if (t != null) {
      t.write(Uint8List.fromList(utf8.encode(data)));
      return;
    }
    final sh = tab.moshShell ?? tab.connection.shell;
    try {
      (sh as dynamic).stdin.add(utf8.encode(data));
    } catch (_) {}
  }

  // Patterns that match destructive shell commands requiring confirmation.
  static bool _isDangerousCommand(String cmd) {
    final c = cmd.trim();
    if (RegExp(r'\brm\b').hasMatch(c)) {
      final hasR = RegExp(r'-\w*[rR]').hasMatch(c);
      final hasF = RegExp(r'-\w*f').hasMatch(c);
      final hasD = RegExp(r'-\w*d').hasMatch(c);
      // -r/-R alone is dangerous (recursive delete); -f + -d covers rm -fd
      if (hasR || (hasF && hasD)) return true;
    }
    if (RegExp(r'\bdd\b').hasMatch(c) && c.contains('if=')) return true;
    if (RegExp(r'\b(mkfs|fdisk|shred|parted|wipefs)\b').hasMatch(c))
      return true;
    if (c.contains(':(){ :|:')) return true;
    return false;
  }

  /// 消费 [SessionManager] 里的待执行命令（全局 AI tab 的「在服务器上执行」）。
  ///
  /// 挂在 `SessionManager` 的监听上而不是补各条连接路径：**所有**连接路径
  /// 最后都会调 `notifyTabChanged()`（本文件 L536/L541 以及 SSH 那几支），
  /// 所以一个监听就同时覆盖「push 进来时 tab 已连好」与「push 进来才开始连」
  /// 两种情形，不用去改那 4 处 startupCommand 分支。
  ///
  /// 必须走 [_runCommand] 而不是直接 `_writeToTab` —— 前者带高危命令拦截
  /// （`_isDangerousCommand` → dry-run 对话框）。从 AI 聊天里来的命令恰恰是
  /// 最该过这道闸的：用户没亲手敲，对它做什么的把握最低。
  void _consumeStagedCommands() {
    final mgr = _sessionMgrForSync;
    if (mgr == null || !mounted) return;
    for (final tab in mgr.tabs) {
      // isFirstConnection 还是 true 说明 shell 还没起来，这一轮先跳过 ——
      // 槽留着，等真正连上那次 notifyTabChanged 再来取。
      if (tab.isFirstConnection) continue;
      final cmd = mgr.takeStagedCommand(tab.server.id);
      if (cmd == null) continue;
      _runCommand(tab, cmd);
    }
  }

  void _runCommand(SessionTab tab, String cmd) {
    if (_isDangerousCommand(cmd)) {
      _showDryRunDialog(tab, cmd);
      return;
    }
    _executeCommand(tab, cmd);
  }

  void _executeCommand(SessionTab tab, String cmd) {
    _writeToTab(tab, '$cmd\n');
  }

  void _showDryRunDialog(SessionTab tab, String cmd) {
    showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                const SizedBox(width: 8),
                Text(context.l10n.highRiskCommandTitle),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.highRiskCommandBody),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    cmd,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(context.l10n.cancel),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  unawaited(_openAIPanel(
                    tab,
                    initialQuery: '请解释这条命令的作用和风险：\n```\n$cmd\n```',
                  ));
                },
                child: Text(context.l10n.aiExplain),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _writeToTab(tab, '$cmd\r');
                },
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: Text(context.l10n.execute),
              ),
            ],
          ),
    );
  }

  Future<void> _showSaveFavoriteDialog(String command) async {
    final ctrl = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final l = ctx.l10n;
          return AlertDialog(
            title: Text(l.saveFavoriteDialogTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    command,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  decoration: InputDecoration(
                    labelText: l.favoriteCommandNameLabel,
                  ),
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(l.save),
              ),
            ],
          );
        },
      );
      if (name != null && name.isNotEmpty && mounted) {
        final repo = context.read<FavoriteCommandRepository>();
        await repo.insert(FavoriteCommand.create(name: name, command: command));
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(context.l10n.commandSaved)));
        }
      }
    } finally {
      ctrl.dispose();
    }
  }

  void _openFavoritesSheet(SessionTab tab) {
    CommandFavoritesSheet.show(context, onRun: (cmd) => _runCommand(tab, cmd));
  }

  // ---------------------------------------------------------------------------
  // FET (Floating Edge Toggle) helpers
  // ---------------------------------------------------------------------------

  void _fetOnUserActivity(TerminalSettings settings) {
    if (!mounted) return;
    setState(() => _fetCurrentOpacity = settings.fetOpacity);
    _fetFadeTimer?.cancel();
    _fetHideTimer?.cancel();
    if (!settings.fetAutoFade) return;
    _fetFadeTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _fetCurrentOpacity = 0.3);
      _fetHideTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        context.read<TerminalSettings>().setFetHidden(true);
      });
    });
  }

  // ---------------------------------------------------------------------------
  // SFTP / Tunnel
  // ---------------------------------------------------------------------------

  /// 键盘条麦克风。
  ///
  /// 走和 AI 面板同一个 [toggleVoiceInputWith]——这里原先是一份手抄的
  /// 旧流程，AI 面板那边陆续补上的兜底（异常 try/catch、启动后校验、
  /// 系统语音兜底、异步失败回调）一条都没跟过来，于是键盘条这侧的语音
  /// 失败全是静默的。共用实现是唯一能让两处不再各自漂移的做法。
  ///
  /// 与 AI 面板唯一的差别是识别结果的去向：这里直接写进终端，不经过
  /// 输入框，因此用 `...With` 变体而不是 controller 版本。
  /// `context.read` 放在 try 内部求值，而不是写在参数位——这个方法是当成
  /// 裸 `VoidCallback` 调的、返回的 Future 没人 await，参数求值阶段抛出的
  /// 异常会直接进 zone 的未捕获处理器：控制台有、屏幕上什么都没有。那正是
  /// `toggleVoiceInputWith` 内部那圈 try/catch 要防的形状，只不过参数列表
  /// 在它上游。
  Future<void> _toggleVoice(SessionTab tab) async {
    try {
      final voice = context.read<VoiceInputService>();
      await toggleVoiceInputWith(
        context,
        voice,
        (words) => tab.terminal.onOutput?.call(words),
      );
    } catch (error, stack) {
      if (!mounted) return;
      await showVoiceInputError(
        context,
        stage: 'resolveService',
        error: error,
        stack: stack,
      );
    }
  }

  /// 拿到这个 tab 可用的 [SFTPService] —— 复用已有的，没有就建。
  ///
  /// 从 [_openSftp] 抽出来，因为**附文件需要传输能力但不需要切换视图**。
  /// 搬的是原样的代码：复用判断（按「client 是否可用」而非协议类型）、
  /// openDedicated 兜底、失败提示，一行未改。
  ///
  /// 返回 null 表示建不起来（凭据缺失、连接失败），此时**已经**给用户
  /// 提示过了，调用方直接 return 即可。
  Future<({SFTPService svc, String initialPath})?> _ensureSftpService(
      SessionTab tab) async {
    SFTPService svc;
    String initialPath;
    final tid = tab.id.length > 4 ? tab.id.substring(0, 4) : tab.id;

    Future<SFTPService> openDedicated() async {
      dlog('SFTP', '[$tid] openDedicated: 新开一条专用 SSH 连接');
      final storage = context.read<SecureStorageService>();
      String? privateKeyPem;
      String? password;
      if (tab.server.authType == 'key' && tab.server.keyId != null) {
        privateKeyPem = await storage.loadPrivateKey(tab.server.keyId!);
      } else if (tab.server.authType == 'password') {
        password = await storage.loadPassword(tab.server.id);
      }
      final serverRepo = context.read<ServerRepository>();
      final jump = await resolveJumpParams(tab.server, serverRepo, storage);
      // 凭据加载结果直接留痕 —— agent 侧走的是另一套更窄的加载逻辑
      // （AgentExecChannel.loadCredentials），两边日志对齐才能看出差异。
      dlog('SFTP', '[$tid] openDedicated creds: '
          'auth=${tab.server.authType} keyId=${tab.server.keyId} '
          'pem=${privateKeyPem != null} pw=${password != null} '
          'jump=${jump != null}');
      return SFTPService.forServer(
        tab.server,
        privateKeyPem: privateKeyPem,
        password: password,
        jump: jump,
        downloadDirProvider:
            context.read<TerminalSettings>().resolveDownloadDir,
        publishToPublicStore:
            () => context.read<TerminalSettings>().downloadsToPublicStore,
      );
    }

    // 复用决策：按「client 是否可用」而非「协议类型」判断。
    //   - SSH tab：tab.connection.client 一直在 → 复用，秒开
    //   - QUIC tab：ReconnectService.registerAqtTab 后台预热 SSH，
    //     用户从看到终端到点 SFTP 通常 > 3s，预热已完成 → 复用，秒开
    //   - Mosh tab / QUIC 预热未完成 / SSH client 死了 → openDedicated 兜底
    final reusableClient = tab.connection.client;
    // **必须走 [isSshClientDead]，不能只判 `isClosed`。**
    //
    // 判据分叉正是「agent 已拉黑、SFTP 照用」那个 bug 的成因，而它在这里
    // 原样复发过一次：`SFTPService.fromClient` 内部（`isReusedClientDead`）
    // 早就改用了共享登记处 [DeadSshClients]，**入口处这一行却还留着裸
    // `isClosed`**。于是一条被 agent 拉黑的半死连接（socket 还开着，服务端
    // 却已拒开新 channel）照样被判定「可复用」，随后
    // `SFTPService._getOps` 的健康守卫立刻抛 `SftpDisconnectedException`。
    //
    // 用户感知到的就是「正在操作时忽然断开」——与网络无关，所以空闲超时、
    // NAT 回收那套保活一条都防不住；而且**点重连也没用**，因为重连会再次
    // 选中同一条被拉黑的连接，要等 `_scheduleAuxRewarm` 换上新的才恢复。
    final dead = reusableClient != null && isSshClientDead(reusableClient);
    final canReuse = reusableClient != null && !dead;
    dlog('SFTP', '[$tid] open: transport=${tab.server.transport} '
        'canReuse=$canReuse auxClient='
        '${reusableClient == null ? "null" : (dead ? (reusableClient.isClosed ? "closed" : "marked-dead") : "alive")}');

    try {
      if (canReuse) {
        try {
          svc = SFTPService.fromClient(
            reusableClient,
            downloadDirProvider:
                context.read<TerminalSettings>().resolveDownloadDir,
            publishToPublicStore:
                () => context.read<TerminalSettings>().downloadsToPublicStore,
          );
          await svc.ensureConnected();
          // Priority: in-session memory → DB-persisted last path → HOME
          initialPath = tab.sftpCwd
              ?? tab.server.sftpLastPath
              ?? await svc.queryHome();
        } catch (e) {
          dlog('SFTP', 'reused SSH client failed, retrying fresh: $e');
          svc = await openDedicated();
          initialPath = tab.sftpCwd
              ?? tab.server.sftpLastPath
              ?? await svc.queryHome();
        }
      } else {
        svc = await openDedicated();
        initialPath = tab.sftpCwd
            ?? tab.server.sftpLastPath
            ?? await svc.queryHome();
      }
    } catch (e) {
      // 两条路径（复用 + openDedicated 兜底）都失败才会到这里 —— 说明问题
      // 不在「复用了一条死连接」，而在凭据或服务端。
      dlog('SFTP', '[$tid] open FAIL（复用与新开都失败）: '
          '${e.runtimeType}: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.sftpConnectFailed(e.toString())),
          ),
        );
      }
      return null;
    }
    dlog('SFTP', '[$tid] open OK path=$initialPath');
    return (svc: svc, initialPath: initialPath);
  }

  /// keybar 附件按钮：选文件 → 传到终端当前目录 → 把路径插进命令行。
  Future<void> _attachFile(SessionTab tab) async {
    final l = context.l10n;

    final picked = await FilePicker.platform.pickFiles();
    // 用户取消：什么都不做，也不提示 —— 取消是明确的意图，不需要反馈。
    if (picked == null || picked.files.isEmpty) return;
    final localPath = picked.files.first.path;
    final originalName = picked.files.first.name;
    if (localPath == null || !mounted) return;

    final r = await _ensureSftpService(tab);
    // _ensureSftpService 失败时已经提示过了，这里直接退出，别叠第二条。
    if (r == null || !mounted) return;
    final svc = r.svc;

    // cwd 未知时退回 home：上传目标必须是绝对路径，而 home 是唯一还能问到的
    // 绝对起点（tab.cwd 来自 OSC-7，shell 没上报过就是 null）。
    final cwd = tab.cwd;
    String? home;
    if (cwd == null) {
      try {
        home = await svc.queryHome();
      } catch (_) {
        home = '/';
      }
    }
    final targetDir = cwd ?? home ?? '/';

    // 改名 + 避重名。不覆盖是因为覆盖不可逆；不询问是因为那违背一步式。
    final safe = sanitizeAttachName(originalName);
    var finalName = safe;
    for (var n = 2; n <= 100; n++) {
      if (!await svc.exists(buildAttachPath(cwd: targetDir, name: finalName))) {
        break;
      }
      if (n > 99) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.attachFileNameTaken)));
        return;
      }
      finalName = nextAttachName(safe, n);
    }

    final remotePath = buildAttachPath(cwd: targetDir, name: finalName);
    try {
      await svc.uploadTo(localPath: localPath, remotePath: remotePath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.attachFileFailed('$e'))));
      return; // 关键：没传成功就绝不往终端插字符
    }
    if (!mounted) return;

    // 插**绝对路径**（就是上传目标 remotePath 那串）。
    //
    // 为什么是绝对路径：曾经 cwd 已知时插相对路径 `./name` —— 那对终端
    // shell 成立，但对 **AI agent** 不成立：agent 执行工具时的 cwd 未必等于
    // 终端 cwd，`./name` 会解析到别处，于是「上传成功、把路径喂给 AI 却读
    // 不到」。绝对路径在任何 cwd 下都对，shell 里同样是合法参数。理由详见
    // attach_path.dart 的 [buildInsertText]。
    //
    // **不再对 alt-screen 程序（vim / htop / AI agent TUI）区别对待。**
    // 曾经 alt-screen 下一律拒插，只弹一条「正在运行全屏程序，未插入路径」
    // 的提示 —— 那对 vim/less 是合理的（往全屏程序乱敲键会触发一串用户
    // 不理解的编辑动作），但对 **AI coding agent**（pi / Claude Code /
    // opencode）恰恰是误伤：它们的输入框就是普通文本输入，被丢掉的那串路径
    // 正是最需要的。判据是「用户主动点了上传按钮」—— 这个动作本身就是「我要
    // 把路径送进去」的明确意图，再替他拦一道是过度保护。
    //
    // 残留风险：vim 命令模式或某些全屏程序下，插入的字符会被当成按键。
    // 但这是用户自己点的，且路径是可撤销的一次文本输入，代价可接受。
    //
    // 用 remotePath 而不是再调 buildInsertText(cwd:..., name:..., home:...)：
    // 两者算出来逐字相同（targetDir 就是 cwd ?? home ?? '/'），直接用现成的
    // 那串，少一处可能不一致的重复计算。
    //
    // 走 terminal.paste() 而不是 _writeToShell()：前者在远端启用 ?2004 时会
    // 加 bracketed-paste 包装，并且经 terminal.onOutput 才能让
    // ActivityTracker.recordInput() 与命令历史累积继续工作。
    // 同款说明见 terminal_widget.dart 的 _pasteFromClipboard。
    tab.terminal.paste(remotePath);

    // 改了名一定要让用户看见 —— 否则他回头 ls 找不到自己传的那个名字，
    // 会以为传失败了。原名本来就安全时不提示。
    if (finalName != originalName) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.attachFileRenamed(finalName))));
    }
  }

  Future<void> _openSftp(SessionTab tab) async {
    final r = await _ensureSftpService(tab);
    if (r == null || !mounted) return;
    final svc = r.svc;
    final initialPath = r.initialPath;
    if (!mounted) return;
    // Cache the svc on the tab so _buildTabBody can use it without reconnect
    tab.sftpSvc = svc;
    tab.sftpCwd = initialPath;
    context.read<SessionManager>().setViewMode(tab, TabViewMode.sftp);
  }

  /// Get the interactive shell's current working directory via exec channel.
  Future<String> _fetchCwd(SessionTab tab, SSHClient client) async {
    final sessionCwd = await tab.backend.getSessionCwd(tab.connection, tab.sessionKey);
    if (sessionCwd != null) return sessionCwd;
    if (tab.inTmux) {
      // backend.getSessionCwd returned null (e.g. mosh+tmux with OSC-7 disabled).
      // Fall through to $HOME rather than '/' — avoids the confusing "empty
      // directory" view users see at root level.
      return await _execHome(client);
    }

    // Non-tmux: exec channel and PTY shell are siblings under the same sshd.
    // pgrep -P $PPID finds the sibling shell; /proc/<pid>/cwd is its CWD.
    // Final fallback: $HOME (works on Linux/macOS; mosh sessions land here
    // because mosh-server is a daemon, not a sibling of the exec channel).
    const script =
        r'for p in $(pgrep -P $PPID 2>/dev/null); do '
        r'[ "$p" = "$$" ] && continue; '
        r'comm=$(cat /proc/$p/comm 2>/dev/null); '
        r'case "$comm" in bash|zsh|sh|fish|dash|ksh) '
        r'cwd=$(readlink /proc/$p/cwd 2>/dev/null); '
        r'[ -n "$cwd" ] && printf "%s" "$cwd" && exit 0;; '
        r'esac; done; '
        r'printf "%s" "$HOME"';
    try {
      final bytes = await client
          .run(script)
          .timeout(const Duration(seconds: 3));
      final path = utf8.decode(bytes).trim();
      if (path.startsWith('/')) return path;
    } catch (_) {}
    return await _execHome(client);
  }

  /// Exec `echo $HOME` on [client] as a last-resort CWD fallback.
  static Future<String> _execHome(SSHClient client) async {
    try {
      final bytes = await client
          .run(r'printf "%s" "$HOME"')
          .timeout(const Duration(seconds: 3));
      final path = utf8.decode(bytes).trim();
      if (path.startsWith('/')) return path;
    } catch (_) {}
    return '/';
  }

  void _openTunnelForm(SessionTab tab) {
    final client = tab.connection.client;
    Navigator.of(context).pushNamed(
      '/tunnels/form',
      arguments: TunnelFormArgs(server: tab.server, existingClient: client),
    );
  }

  void _showFilePickerSheet() {
    final t = context.read<SessionManager>().activeTab?.transport;
    if (t == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FilePickerSheet(
        onUpload: (local, remote) async {
          final handle = await t.upload(local, remote);
          final filename = local.path.split('/').last;
          final entry = (
            filename: filename,
            progress: handle.progress,
            totalBytes: handle.totalBytes,
            onCancel: () async {
              await handle.cancel();
              if (mounted) {
                setState(
                  () => _activeTransfers
                      .removeWhere((e) => e.filename == filename),
                );
              }
            },
          );
          if (mounted) setState(() => _activeTransfers.add(entry));
        },
        onDownload: (remote) async {
          // Download to app documents dir — full path resolution in Stage 5.
          final _ = remote;
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionManager>(
      builder: (context, mgr, _) {
        final tab = mgr.activeTab;
        final micRecording = context.watch<VoiceInputService>().isListening;
        final terminalSettings = context.watch<TerminalSettings>();
        final inSftpMode = tab?.viewMode == TabViewMode.sftp;
        return PopScope(
          canPop: !inSftpMode,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final t = mgr.activeTab;
            if (t?.viewMode == TabViewMode.sftp) mgr.toggleViewMode(t!);
          },
          child: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            toolbarHeight: 36,
            titleSpacing: 0,
            leadingWidth: 28,
            leading: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
              icon: const Icon(Icons.arrow_back),
              tooltip: context.l10n.backAction,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Consumer<SplitManager>(
              builder:
                  (_, splitMgr, __) => _TabBar(
                    mgr: mgr,
                    splitMgr: splitMgr,
                    onAdd: _addNewTab,
                    onRefresh: _refreshTab,
                    onOpenMenu: (plusContext) =>
                        _openPlusMenu(plusContext, mgr.activeTab, splitMgr),
                  ),
            ),
            actions: const [],
          ),
          body:
              tab == null
                  ? const Center(child: CircularProgressIndicator())
                  : _KeyboardAwareBody(
                    keyboardInset: MediaQuery.of(context).viewInsets.bottom,
                    child: Stack(
                      children: [
                      Column(
                      children: [
                        // SplitManager Consumer is nested inside Consumer<SessionManager>.
                        // `tab` here is mgr.activeTab from the outer builder — guaranteed
                        // non-null (null guard is in body: above) and always current because
                        // any tab switch triggers SessionManager.notifyListeners() first.
                        Expanded(
                          child: Stack(
                            children: [
                              Consumer<SplitManager>(
                            builder: (_, splitMgr, __) {
                              if (splitMgr.splitMode != SplitMode.off &&
                                  splitMgr.secondarySession != null) {
                                final secondary = splitMgr.secondarySession!;
                                final useRow =
                                    splitMgr.splitMode == SplitMode.horizontal;
                                // The active pane is whichever one belongs to
                                // the SessionManager's active tab.
                                final activeIsFirstPane =
                                    mgr.activeTab?.id == tab.id;
                                return SplitPaneView(
                                  axis:
                                      useRow ? Axis.horizontal : Axis.vertical,
                                  ratio: splitMgr.splitRatio,
                                  onRatioChanged: splitMgr.setSplitRatio,
                                  onRatioReset:
                                      () => splitMgr.setSplitRatio(0.5),
                                  activeIsFirstPane: activeIsFirstPane,
                                  onSwapPanes: () => _swapSplitPanes(splitMgr),
                                  firstPane: _buildTabContent(tab, tab),
                                  secondPane: _buildTabContent(
                                    secondary,
                                    tab,
                                    forceVisible: true,
                                  ),
                                );
                              }
                              // IndexedStack keeps every tab's TerminalWidget alive
                              // so switching tabs never causes a rebuild+white-flash,
                              // even with the keyboard open.
                              //
                              // Edge-strip swipe: 28 px opaque strips on left/right
                              // instead of a full-area GestureDetector. Full-area
                              // wrapping caused two problems:
                              //   1. Gesture-arena competition with TerminalView →
                              //      recognizer delay → "laggy" feel.
                              //   2. PointerDown on the terminal area triggered focus
                              //      → keyboard opened on every swipe attempt.
                              // Opaque strips capture touches in the edge zone so the
                              // terminal never sees them; the terminal centre is
                              // completely unaffected.
                              // Listener bypasses the gesture arena entirely, so
                              // there is no recognizer-resolution delay (lag) and
                              // no conflict with Android's system back gesture on
                              // the left edge. translucent behavior lets the
                              // terminal receive pointer events normally.
                              return Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerDown:
                                    mgr.tabs.length > 1
                                        ? (e) {
                                          _tabSwipePointerCount++;
                                          // Selection mode disqualifies the
                                          // whole gesture, not just the moves
                                          // while the selection lasts: a drag
                                          // can invalidate the selection
                                          // halfway (scrollback push-out,
                                          // buffer swap), and with the start
                                          // point still recorded the rest of
                                          // that same swipe would switch tabs.
                                          if (_tabSwipePointerCount == 1 &&
                                              !_selectionActiveNow()) {
                                            _tabSwipeStart = e.localPosition;
                                          } else {
                                            _tabSwipeStart = null;
                                          }
                                        }
                                        : null,
                                onPointerMove:
                                    mgr.tabs.length > 1
                                        ? (e) {
                                          final s = _tabSwipeStart;
                                          if (s == null) return;
                                          if (_selectionActiveNow()) return;
                                          if (_tabSwipePointerCount > 1) return;
                                          final dx = e.localPosition.dx - s.dx;
                                          final dy = e.localPosition.dy - s.dy;
                                          if (dx.abs() > 60 &&
                                              dx.abs() > dy.abs() * 1.5) {
                                            _tabSwipeStart = null;
                                            _tabSwitchedBySwipe = true;
                                            _swipeTimer?.cancel();
                                            _swipeTimer = Timer(
                                              const Duration(milliseconds: 500),
                                              () => _tabSwitchedBySwipe = false,
                                            );
                                            if (dx < 0)
                                              mgr.nextTab();
                                            else
                                              mgr.prevTab();
                                          }
                                        }
                                        : null,
                                onPointerUp: (_) {
                                  _tabSwipePointerCount =
                                      (_tabSwipePointerCount - 1).clamp(0, 99);
                                  if (_tabSwipePointerCount == 0)
                                    _tabSwipeStart = null;
                                },
                                onPointerCancel: (_) {
                                  _tabSwipePointerCount =
                                      (_tabSwipePointerCount - 1).clamp(0, 99);
                                  if (_tabSwipePointerCount == 0)
                                    _tabSwipeStart = null;
                                },
                                child: IndexedStack(
                                  index: mgr.activeIndex,
                                  children:
                                      mgr.tabs
                                          .map((t) => _buildTabContent(t, tab))
                                          .toList(),
                                ),
                              );
                            },
                          ),
                              // FileTransferOverlay hidden until file transfer is fully implemented.
                              // FileTransferOverlay(transfers: _activeTransfers),
                            ],
                          ),
                        ),
                        if (_searchVisible)
                          _TerminalSearchBar(
                            controller: _searchCtrl,
                            hitCount: _searchHitLines.length,
                            hitIndex: _searchHitIdx,
                            onChanged: (q) => _runSearch(q, tab),
                            onPrev:
                                _searchHitLines.isEmpty
                                    ? null
                                    : () {
                                      setState(() {
                                        _searchHitIdx = (_searchHitIdx - 1)
                                            .clamp(
                                              0,
                                              _searchHitLines.length - 1,
                                            );
                                      });
                                      _scrollToHit(
                                        tab,
                                        _searchHitLines[_searchHitIdx],
                                      );
                                    },
                            onNext:
                                _searchHitLines.isEmpty
                                    ? null
                                    : () {
                                      setState(() {
                                        _searchHitIdx = (_searchHitIdx + 1)
                                            .clamp(
                                              0,
                                              _searchHitLines.length - 1,
                                            );
                                      });
                                      _scrollToHit(
                                        tab,
                                        _searchHitLines[_searchHitIdx],
                                      );
                                    },
                            onClose: () {
                              FocusManager.instance.primaryFocus?.unfocus();
                              setState(() {
                                _searchVisible = false;
                                _searchCtrl.clear();
                                _searchHitLines = [];
                              });
                            },
                          ),
                        // Keybar 显隐：跟 _buildTabBody 里 TerminalWidget 的渲染
                        // 判断完全一致（activeShell != null || !isFirstConnection）。
                        // 这是协议无关的「这个 tab 是否在显示终端」判断 —— 不需要
                        // 显式列举 SSH/Mosh/QUIC/local 各种 transport，QUIC RESUME
                        // 路径（不开 SSH shell）也能正确显示。
                        if ((tab.moshShell != null ||
                                tab.connection.shell != null ||
                                tab.localShell != null ||
                                !tab.isFirstConnection) &&
                            tab.viewMode != TabViewMode.sftp)
                          KeyBar(
                            terminal: tab.terminal,
                            onAITap: () => unawaited(_openAIPanel(tab)),
                            onAttachTap: () =>
                                unawaited(_attachFile(tab)),
                            onMicTap: () => _toggleVoice(tab),
                            onFavoritesTap: () => _openFavoritesSheet(tab),
                            onShowKeyboard:
                                terminalSettings.keyboardTrigger ==
                                        KeyboardTriggerMode.iconButton
                                    ? () {
                                      final keyboardVisible =
                                          MediaQuery.of(
                                            context,
                                          ).viewInsets.bottom >
                                          0;
                                      if (keyboardVisible) {
                                        FocusManager.instance.primaryFocus
                                            ?.unfocus();
                                      } else {
                                        _terminalWidgetKeys[tab.id]
                                            ?.currentState
                                            ?.requestKeyboard();
                                      }
                                    }
                                    : null,
                            aiActive: _aiPanelOpen,
                            micActive: micRecording,
                          ),
                      ],
                    ), // end Column
                    // ── Floating Edge Toggle overlay ──────────────────────────
                    // Placed here (above the Column) so its LayoutBuilder always
                    // measures the full body height — independent of whether the
                    // KeyBar is visible or hidden (SFTP mode). Putting the FET
                    // inside the IndexedStack caused the y-position to shift when
                    // KeyBar toggled, because the IndexedStack height changed.
                    if (tab != null && terminalSettings.fetEnabled)
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (ctx, constraints) {
                            final widgetH =
                                terminalSettings.fetHidden ? 56.0 : 36.0;
                            final maxY = (constraints.maxHeight - widgetH)
                                .clamp(0.0, double.infinity);
                            final y = terminalSettings.fetY * maxY;
                            return Stack(
                              children: [
                                Positioned(
                                  right: terminalSettings.fetHidden ? 0 : 8,
                                  top: y,
                                  child: FloatingViewToggle(
                                    isSftpMode: tab.viewMode == TabViewMode.sftp,
                                    opacity: _fetCurrentOpacity,
                                    isCollapsed: terminalSettings.fetHidden,
                                    onToggle: () {
                                      _fetOnUserActivity(terminalSettings);
                                      if (tab.viewMode == TabViewMode.sftp) {
                                        context
                                            .read<SessionManager>()
                                            .toggleViewMode(tab);
                                      } else if (tab.sftpSvcIsUsable) {
                                        context
                                            .read<SessionManager>()
                                            .setViewMode(
                                              tab, TabViewMode.sftp);
                                      } else {
                                        _openSftp(tab);
                                      }
                                    },
                                    onCollapseTap: () async =>
                                        terminalSettings.setFetHidden(false),
                                    onPanUpdate: (details) {
                                      if (maxY <= 0) return;
                                      final newY =
                                          (terminalSettings.fetY * maxY +
                                                  details.delta.dy)
                                              .clamp(0.0, maxY);
                                      terminalSettings.setFetY(newY / maxY);
                                      _fetOnUserActivity(terminalSettings);
                                    },
                                    onPanEnd: (details) async {
                                      if (details.velocity.pixelsPerSecond.dx >
                                          800) {
                                        await terminalSettings
                                            .setFetHidden(true);
                                      }
                                    },
                                  ),
                                ),
                                if (!terminalSettings.fetOnboardingShown &&
                                    !terminalSettings.fetHidden)
                                  Positioned(
                                    right: 52,
                                    top: y + 6,
                                    child: _OnboardingBubble(
                                      text: context.l10n.sftpOnboardingHint,
                                      onDismiss: () => terminalSettings
                                          .setFetOnboardingShown(true),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ], // end Stack children
                  ), // end Stack (= _KeyboardAwareBody.child value)
                  ), // end _KeyboardAwareBody
          ),
        );
      },
    );
  }

  /// Body widget for a single tab inside IndexedStack.
  /// Hidden tabs still exist in the tree (Offstage) so they preserve state.
  Widget _buildTabBody(
    SessionTab t,
    SessionTab activeTab, {
    bool forceVisible = false,
  }) {
    // QUIC tab：即使 connection.shell 非 null（首次 bootstrap 残留或老逻辑残留），
    // 也不要把它传给 TerminalWidget。否则 widget.shell 非 null + widget.transport
    // 暂为 null 时 _writeToShell 会把用户输入写到 SSH PTY → 真实降级。
    final isQuicTab = t.server.transport == Transport.quic;
    final activeShell = t.moshShell ??
        (isQuicTab ? null : t.connection.shell) ??
        t.localShell;
    // Show terminal for any tab that has connected at least once — even while
    // reconnecting (shell temporarily null). This keeps reconnect messages
    // visible instead of covering them with a spinner, and avoids the
    // spinner/error-screen flip-flop during exponential-backoff retries.
    if (activeShell != null || !t.isFirstConnection) {
      // ── Reconnect-success detection ──────────────────────────────────────
      // When a tab's SSH/QUIC connection is re-established, the old SSH
      // client that SFTPService was built on is replaced. Detect the
      // isReconnecting false→true→false cycle and invalidate the cached
      // svc so the next SFTP open creates a fresh connection. The user
      // sees the same directory they were in before (sftpCwd preserved).
      final nowReconnecting = t.isReconnecting;
      if ((_wasReconnecting[t.id] ?? false) && !nowReconnecting) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) t.invalidateSftpSvc();
        });
      }
      _wasReconnecting[t.id] = nowReconnecting;

      final settings = context.watch<TerminalSettings>();
      _maybeScheduleSwapScrollReset(t);
      final terminalWidget = TerminalWidget(
        key: _terminalWidgetKeys.putIfAbsent(
          t.id,
          GlobalKey<TerminalWidgetState>.new,
        ),
        terminal: t.terminal,
        shell: activeShell,
        transport: t.transport,
        onOrphanedInput: t.bufferPendingInput,
        isActive: t == activeTab,
        suppressKeyboardOnActivation: _tabSwitchedBySwipe,
        scrollController: _scrollControllerFor(t.id),
        isMosh: t.isMosh,
        remoteTuiHint: t.remoteTuiHint,
        keyboardTriggerMode: settings.keyboardTrigger,
        interceptInput: (data) => _interceptTerminalInput(data, t),
        onUserInput: (data) => _onUserInput(data, t),
        copyModeScroll: t.backend.capabilities.copyModeScroll,
        onExitScrollMode:
            t.backend.capabilities.copyModeScroll
                ? () async {
                  // Mosh + SSH dead: skip cancel — 'q' would leak to foreground
                  // app on every tap until SSH reconnects (cancel is a no-op
                  // outside copy-mode, so the next tap after reconnect is safe).
                  if (t.isMosh && !t.connection.isConnected) return;
                  t.backend.exitScrollMode();
                }
                : null,
        onRefreshClient:
            t.backend.capabilities.copyModeScroll
                ? () => t.backend.refreshClient()
                : null,
        onScrollUp:
            t.backend.capabilities.copyModeScroll
                ? (lines) => t.backend.scrollUp(lines)
                : null,
        onScrollDown:
            t.backend.capabilities.copyModeScroll
                ? (lines) => t.backend.scrollDown(lines)
                : null,
        onSelectionModeChanged:
            (active) => setState(() {
              _tabSelectionActive = active;
              // Entering selection mode kills any start point already recorded
              // by this gesture — long-press → "Select" happens with the
              // finger still down, so the swipe start is from before the
              // handles existed.
              if (active) _tabSwipeStart = null;
            }),
        getNetworkRtt: () => t.networkStability.smoothedRtt,
        onSgrSent: (_) => t.recordSgrSend(),
        onTransportResize: t.onTransportResized,
        // Completion popup only ever applies to the active tab — other tabs
        // stay mounted (Offstage) behind the IndexedStack but must not show
        // a stale/foreign suggestion list.
        completions: t == activeTab ? _completionSuggestions : const [],
        onAcceptCompletion:
            t == activeTab ? (s) => _acceptCompletion(s, t) : null,
        completionInput: t == activeTab ? _currentInputLine : '',
      );
      final stackChildren = <Widget>[
        terminalWidget,
        if (_activeReconnectUiMessage(t) != null)
          Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: _ReconnectMessageOverlay(
              message: _activeReconnectUiMessage(t)!,
              isMosh: t.isMosh,
            ),
          ),
      ];
      // Mount the floating debug overlay only when the user has flipped
      // the secret 7-tap toggle in settings. Top-right anchor, IgnorePointer
      // so it never blocks terminal gestures.
      if (settings.debugOverlay) {
        stackChildren.add(
          Positioned(top: 4, right: 4, child: DebugOverlay(tab: t)),
        );
      }
      final terminalStack = Stack(children: stackChildren);

      // ── SFTP Offstage: keep both views alive to preserve state ───────────
      // Once an active (non-disposed) SFTPService exists, wrap both the
      // terminal and SFTP views in Offstage so neither is unmounted when the
      // user toggles. This preserves the directory listing, scroll position,
      // search state, and selection across every switch.
      //
      // The Offstage is only added when sftpSvc is non-null and alive. When
      // invalidateSftpSvc() is called (tab reconnect or tab close) svc becomes
      // null → this guard removes the Offstage → SftpInlineView is disposed
      // cleanly. On the next SFTP open, _openSftp creates a fresh svc and the
      // Offstage is re-mounted with a new SftpInlineView keyed by tab id.
      final svc = t.sftpSvc;
      if (svc != null && !svc.isDisposed) {
        return Stack(
          children: [
            Offstage(
              offstage: t.viewMode == TabViewMode.sftp,
              child: terminalStack,
            ),
            Offstage(
              offstage: t.viewMode != TabViewMode.sftp,
              child: SftpInlineView(
                key: _sftpKeys.putIfAbsent(
                    t.id, () => GlobalKey<SftpInlineViewState>()),
                server: t.server,
                svc: svc,
                initialPath: t.sftpCwd ?? '/',
                onPathChanged: (path) =>
                    context.read<SessionManager>().setSftpCwd(t, path),
                onCloseRequested: () =>
                    context.read<SessionManager>().toggleViewMode(t),
                onReconnectRequested: () {
                  t.invalidateSftpSvc();
                  _openSftp(t);
                },
                // 自动重连要限流：视图会随重连被重建，它自己那个「已重连过」
                // 标志会跟着清零，光靠视图层挡不住循环。tab 比视图长寿，
                // 冷却窗口记在它身上才刹得住。
                onAutoReconnectRequested: () {
                  final now = DateTime.now();
                  final last = t.lastSftpAutoReconnect;
                  if (last != null &&
                      now.difference(last) < const Duration(seconds: 30)) {
                    dlog('SFTP', '自动重连被限流（30s 内已试过），'
                        '保留手动「重新连接」按钮');
                    return;
                  }
                  t.lastSftpAutoReconnect = now;
                  dlog('SFTP', '连接已断开 → 自动重连一次');
                  t.invalidateSftpSvc();
                  _openSftp(t);
                },
              ),
            ),
          ],
        );
      }
      return terminalStack;
    }
    // Inactive connecting tabs show a blank placeholder (they're Offstage anyway).
    if (t != activeTab && !forceVisible) return const SizedBox.expand();
    // Active tab: show connecting spinner or error.
    // t.connectionError covers restore-mode failures (set by ReconnectService);
    // _connectError covers normal-mode failures (set by _connectServer).
    final errorMsg = t.connectionError ?? _connectError;
    if (errorMsg != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                errorMsg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: Text(context.l10n.back),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(context.l10n.connectingTo(t.server.host)),
        ],
      ),
    );
  }

  /// Body widget for a single tab in the IndexedStack.
  /// FET overlay is mounted at the outer body-Stack level (above this),
  /// so FET position is unaffected by KeyBar visibility changes.
  Widget _buildTabContent(
    SessionTab t,
    SessionTab activeTab, {
    bool forceVisible = false,
  }) {
    return _buildTabBody(t, activeTab, forceVisible: forceVisible);
  }

  ReconnectUiMessage? _activeReconnectUiMessage(SessionTab tab) {
    final message = tab.reconnectUiMessage;
    if (message == null) return null;
    if (message.isExpired) return null;
    return message;
  }
}

class _ReconnectMessageOverlay extends StatefulWidget {
  const _ReconnectMessageOverlay({required this.message, required this.isMosh});

  final ReconnectUiMessage message;
  final bool isMosh;

  @override
  State<_ReconnectMessageOverlay> createState() =>
      _ReconnectMessageOverlayState();
}

class _ReconnectMessageOverlayState extends State<_ReconnectMessageOverlay> {
  Timer? _hideTimer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant _ReconnectMessageOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.updatedAt != widget.message.updatedAt ||
        oldWidget.message.text != widget.message.text) {
      _visible = true;
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    final ttl = widget.message.ttl;
    if (ttl == null) return;
    final remaining = widget.message.updatedAt
        .add(ttl)
        .difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _visible = false;
      return;
    }
    _hideTimer = Timer(remaining, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final text = _localizedReconnectText(context, widget.message);
    final color = switch (widget.message.kind) {
      ReconnectUiMessageKind.success => const Color(0xFF66BB6A),
      ReconnectUiMessageKind.warning => const Color(0xFFFFB74D),
      ReconnectUiMessageKind.error => const Color(0xFFEF5350),
      ReconnectUiMessageKind.info =>
        widget.isMosh ? const Color(0xFF42A5F5) : const Color(0xFF66BB6A),
    };
    final icon = switch (widget.message.kind) {
      ReconnectUiMessageKind.success => Icons.check_circle_outline,
      ReconnectUiMessageKind.warning => Icons.warning_amber_rounded,
      ReconnectUiMessageKind.error => Icons.error_outline,
      ReconnectUiMessageKind.info => Icons.sync,
    };

    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xDD101615),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.8)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ReconnectAnimatedIcon(
                icon: icon,
                color: color,
                active: widget.message.kind == ReconnectUiMessageKind.info,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFE8F5E9),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _localizedReconnectText(
    BuildContext context,
    ReconnectUiMessage message,
  ) {
    final l = context.l10n;
    final args = message.args;
    String stringArg(String key) => args[key]?.toString() ?? '';
    int intArg(String key) {
      final value = args[key];
      if (value is int) return value;
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }
    // Translate a _friendlyError key (e.g. "timeout", "refused") to
    // a localised string. Falls back to the raw value for unknown keys.
    String localizeError(String key) => switch (key) {
          'timeout' => l.reconnectErrTimeout,
          'refused' => l.reconnectErrRefused,
          'reset' => l.reconnectErrReset,
          'unreachable' => l.reconnectErrUnreachable,
          'dns' => l.reconnectErrDns,
          'auth' => l.reconnectErrAuth,
          'permission' => l.reconnectErrPermission,
          'socket' => l.reconnectErrSocket,
          _ => key, // plain-text fallback for unknown / truncated messages
        };

    return switch (message.code) {
      ReconnectUiMessageCode.text => message.text,
      ReconnectUiMessageCode.reconnectInProgress => l.reconnectInProgress,
      ReconnectUiMessageCode.refreshing => l.refreshing,
      ReconnectUiMessageCode.reconnectSuccess => l.reconnectSuccess,
      ReconnectUiMessageCode.reconnectFailedWithError =>
        l.reconnectFailedWithError(localizeError(stringArg('error'))),
      ReconnectUiMessageCode.reconnectRetryCountdown => l
          .reconnectRetryCountdown(
            intArg('seconds'),
            intArg('round'),
            intArg('attempt'),
            intArg('total'),
          ),
      ReconnectUiMessageCode.reconnectNetworkUnstableRetry =>
        l.reconnectNetworkUnstableRetry,
      ReconnectUiMessageCode.reconnectCascadeWarning => l
          .reconnectCascadeWarning(
            stringArg('protocol'),
            intArg('count'),
            intArg('minutes'),
          ),
      ReconnectUiMessageCode.reconnectLoopDetected => l.reconnectLoopDetected(
        stringArg('protocol'),
      ),
      ReconnectUiMessageCode.reconnectMoshHandshake => l.reconnectMoshHandshake,
      ReconnectUiMessageCode.reconnectMoshConnected => l.reconnectMoshConnected,
      ReconnectUiMessageCode.reconnectMoshFallback => l.reconnectMoshFallback,
      ReconnectUiMessageCode.reconnectMoshFallbackWithReason => l
          .reconnectMoshFallbackWithReason(stringArg('reason')),
      ReconnectUiMessageCode.reconnectMoshDisconnectedRestoring =>
        l.reconnectMoshDisconnectedRestoring,
      ReconnectUiMessageCode.reconnectMoshSessionRestored =>
        l.reconnectMoshSessionRestored,
      ReconnectUiMessageCode.reconnectMoshRestoreFailedRehandshake =>
        l.reconnectMoshRestoreFailedRehandshake,
      ReconnectUiMessageCode.tmuxNotFoundDisabled => l.tmuxNotFoundDisabled,
    };
  }
}

class _ReconnectAnimatedIcon extends StatefulWidget {
  const _ReconnectAnimatedIcon({
    required this.icon,
    required this.color,
    required this.active,
  });

  final IconData icon;
  final Color color;
  final bool active;

  @override
  State<_ReconnectAnimatedIcon> createState() => _ReconnectAnimatedIconState();
}

class _ReconnectAnimatedIconState extends State<_ReconnectAnimatedIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.active) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _ReconnectAnimatedIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = Icon(widget.icon, color: widget.color, size: 15);
    if (!widget.active) return child;
    return RotationTransition(turns: _controller, child: child);
  }
}

class _TabBar extends StatefulWidget {
  final SessionManager mgr;
  final SplitManager splitMgr;
  final VoidCallback onAdd;
  final Future<void> Function(SessionTab tab, int idx) onRefresh;

  /// 点了 `+` 时回调，参数是 `+` 自身的 BuildContext（作菜单定位锚点）。
  ///
  /// 菜单内容与定位都在 [TerminalScreen] 里构造 —— SFTP viewMode / 布局 /
  /// canUseRemoteActions 等状态全在其作用域内，_TabBar 不该知道这些。
  final void Function(BuildContext plusContext) onOpenMenu;

  const _TabBar({
    required this.mgr,
    required this.splitMgr,
    required this.onAdd,
    required this.onRefresh,
    required this.onOpenMenu,
  });

  @override
  State<_TabBar> createState() => _TabBarState();
}

class _TabBarState extends State<_TabBar> {
  // Index of the tab currently in "move mode"; null = normal.
  int? _moveTabIndex;
  final Map<String, GlobalKey> _tabKeys = {};
  int? _lastEnsuredActiveIndex;

  void _enterMoveMode(int i) => setState(() => _moveTabIndex = i);

  void _exitMoveMode() {
    if (_moveTabIndex != null) setState(() => _moveTabIndex = null);
  }

  GlobalKey _keyForTab(String id) =>
      _tabKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'tab-$id'));

  void _scheduleEnsureActiveVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final idx = widget.mgr.activeIndex;
      if (idx < 0 || idx >= widget.mgr.tabs.length) return;
      final ctx = _tabKeys[widget.mgr.tabs[idx].id]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final mgr = widget.mgr;
    final splitMgr = widget.splitMgr;
    final tabs = mgr.tabs;
    _tabKeys.removeWhere((id, _) => !tabs.any((t) => t.id == id));
    if (_lastEnsuredActiveIndex != mgr.activeIndex) {
      _lastEnsuredActiveIndex = mgr.activeIndex;
      _scheduleEnsureActiveVisible();
    }

    // Guard: if tab list shrank, clear stale move index.
    if (_moveTabIndex != null && _moveTabIndex! >= tabs.length) {
      _moveTabIndex = null;
    }

    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              padding: EdgeInsets.zero,
              onReorder: (oldIndex, newIndex) {
                mgr.moveTab(oldIndex, newIndex);
                _exitMoveMode();
              },
              proxyDecorator:
                  (child, index, animation) => Material(
                    elevation: 6,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                    child: child,
                  ),
              itemCount: tabs.length,
              itemBuilder: (ctx, i) {
                final tab = tabs[i];
                final isActive = i == mgr.activeIndex;
                final isSecondary =
                    splitMgr.splitMode != SplitMode.off &&
                    splitMgr.secondarySession?.id == tab.id;
                final isFloating = splitMgr.floatingSession?.id == tab.id;
                final inMoveMode = _moveTabIndex == i;

                final tabBody = Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // Highlight the tab that is ready to be dragged.
                    color:
                        inMoveMode
                            ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.15)
                            : null,
                    borderRadius: inMoveMode ? BorderRadius.circular(4) : null,
                    border:
                        inMoveMode
                            ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 1.5,
                            )
                            : Border(
                              bottom: BorderSide(
                                color:
                                    isActive
                                        ? Theme.of(context).colorScheme.primary
                                        : isSecondary
                                        ? Theme.of(context).colorScheme.primary
                                            .withValues(alpha: 0.4)
                                        : Colors.transparent,
                                width: 2,
                              ),
                            ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(
                        protocol: tab.transport?.kind == TransportKind.aqt
                            ? DotProtocol.quic
                            : (tab.isMosh ? DotProtocol.mosh : DotProtocol.ssh),
                        isInitial:
                            tab.isFirstConnection &&
                            !tab.isReconnecting &&
                            tab.connectionError == null,
                        isDisconnected: tab.connectionError != null,
                        isReconnecting: tab.isReconnecting,
                        isStable: tab.networkStability.isStable,
                        tooltip: tab.transport is AqtTransport &&
                                (tab.transport as AqtTransport).route ==
                                    AqtRoute.viaSsh
                            ? context.l10n.aqtRouteViaSshTooltip
                            : null,
                      ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 80),
                        child: Text(
                          tab.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (isSecondary) ...[
                        const SizedBox(width: 3),
                        const Icon(
                          Icons.vertical_split,
                          size: 10,
                          color: Colors.white38,
                        ),
                      ],
                      if (isFloating) ...[
                        const SizedBox(width: 3),
                        const Icon(
                          Icons.picture_in_picture_alt,
                          size: 10,
                          color: Colors.white38,
                        ),
                      ],
                      // × close — active tab only (suppressed during move mode)
                      if (isActive && !inMoveMode)
                        InkWell(
                          onTap: () {
                            if (isSecondary)
                              splitMgr.onTabClosed(tab);
                            else if (splitMgr.splitMode != SplitMode.off) {
                              splitMgr.clearSplit();
                            }
                            mgr.closeTab(i);
                            if (mgr.tabs.isEmpty) {
                              SshForegroundService.stop();
                              Navigator.of(context).pop();
                            }
                          },
                          child: const Padding(
                            padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
                            child: Icon(Icons.close, size: 13),
                          ),
                        ),
                    ],
                  ),
                );

                if (inMoveMode) {
                  // Wrap entire highlighted tab in drag listener.
                  // Tap (no movement) cancels move mode via the outer
                  // GestureDetector; actual drag wins the arena once
                  // movement exceeds slop.
                  return KeyedSubtree(
                    key: _keyForTab(tab.id),
                    child: GestureDetector(
                      onTap: _exitMoveMode,
                      child: ReorderableDragStartListener(
                        index: i,
                        child: tabBody,
                      ),
                    ),
                  );
                }

                // Normal mode: tap to switch, long-press for menu.
                return KeyedSubtree(
                  key: _keyForTab(tab.id),
                  child: GestureDetector(
                    onTap: () {
                      if (_moveTabIndex != null) {
                        _exitMoveMode();
                        return;
                      }
                      if (isSecondary) {
                        final oldPrimary = mgr.activeTab;
                        mgr.setActiveTab(i);
                        if (oldPrimary != null) splitMgr.swapPanes(oldPrimary);
                      } else {
                        mgr.setActiveTab(i);
                      }
                    },
                    onLongPressStart: (details) async {
                      if (i >= mgr.tabs.length) return;
                      final result = await showMenu<String>(
                        context: context,
                        position: RelativeRect.fromLTRB(
                          details.globalPosition.dx,
                          details.globalPosition.dy,
                          details.globalPosition.dx + 160,
                          details.globalPosition.dy + 80,
                        ),
                        items: [
                          PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                const Icon(Icons.edit_outlined, size: 16),
                                const SizedBox(width: 8),
                                Text(context.l10n.rename),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'move',
                            child: Row(
                              children: [
                                const Icon(Icons.open_with, size: 16),
                                const SizedBox(width: 8),
                                Text(context.l10n.tabMove),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'refresh',
                            child: Row(
                              children: [
                                const Icon(Icons.refresh, size: 16),
                                const SizedBox(width: 8),
                                Text(context.l10n.tabRefresh),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'close',
                            child: Row(
                              children: [
                                const Icon(Icons.close, size: 16),
                                const SizedBox(width: 8),
                                Text(context.l10n.close),
                              ],
                            ),
                          ),
                        ],
                      );
                      if (!context.mounted) return;
                      if (result == 'rename') {
                        final ctrl = TextEditingController(text: tab.title);
                        final newName = await showDialog<String>(
                          context: context,
                          builder:
                              (dlg) => AlertDialog(
                                title: Text(context.l10n.rename),
                                content: TextField(
                                  controller: ctrl,
                                  autofocus: true,
                                  onSubmitted: (v) => Navigator.pop(dlg, v),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dlg),
                                    child: Text(context.l10n.cancel),
                                  ),
                                  TextButton(
                                    onPressed:
                                        () => Navigator.pop(dlg, ctrl.text),
                                    child: Text(context.l10n.confirm),
                                  ),
                                ],
                              ),
                        );
                        ctrl.dispose();
                        if (!context.mounted) return;
                        if (newName != null) mgr.renameTab(i, newName);
                      } else if (result == 'move') {
                        _enterMoveMode(i);
                      } else if (result == 'refresh') {
                        unawaited(widget.onRefresh(tab, i));
                      } else if (result == 'close') {
                        if (isSecondary)
                          splitMgr.onTabClosed(tab);
                        else if (isActive &&
                            splitMgr.splitMode != SplitMode.off) {
                          splitMgr.clearSplit();
                        }
                        mgr.closeTab(i);
                        if (mgr.tabs.isEmpty) {
                          SshForegroundService.stop();
                          Navigator.of(context).pop();
                        }
                      }
                    },
                    child: tabBody,
                  ),
                );
              },
            ),
          ),
          Builder(
            builder: (plusContext) => InkWell(
              onTap: () => widget.onOpenMenu(plusContext),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(8, 0, 12, 0),
                child: Icon(Icons.add, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Wraps the terminal body with a snap-to-target bottom inset.
//
// History: an earlier version of this widget animated the bottom padding from
// the previous inset to the new one over 220 ms easeOutCubic to match the
// system keyboard curve (commit dd02f22). That looked polished but produced
// a one-frame flicker on every keyboard show/hide: xterm's grid follows the
// parent's constraints, so during the 220 ms animation the terminal viewHeight
// recomputed on each frame and the underlying xterm Buffer reflowed 13+
// times in rapid succession — each reflow briefly drew stale rows into the
// new grid before content settled.
//
// The fix: snap the padding directly to keyboardInset. xterm's grid reflows
// EXACTLY ONCE per keyboard state transition (open or close). The system
// keyboard still animates up/down naturally; the area newly reserved by the
// bottom padding is what the keyboard animates INTO, so the visual transition
// remains smooth without intermediate xterm reflows.
//
// RepaintBoundary insulates the terminal's render layer from any upstream
// rebuilds that don't change keyboardInset.
class _KeyboardAwareBody extends StatelessWidget {
  final double keyboardInset;
  final Widget child;

  const _KeyboardAwareBody({required this.keyboardInset, required this.child});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: child,
      ),
    );
  }
}

class _TerminalSearchBar extends StatelessWidget {
  const _TerminalSearchBar({
    required this.controller,
    required this.hitCount,
    required this.hitIndex,
    required this.onChanged,
    required this.onPrev,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final int hitCount;
  final int hitIndex;
  final void Function(String) onChanged;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              // 统一形态。改动前这里自己写了 `contentPadding`（vertical 8）
              // 与 `circular(6)` 圆角 —— 高度恰好也是 40dp，所以看不出问题；
              // 但圆角（6）与标准（4）不同，而且是「每个页面自己调数字」的
              // 又一个实例。
              decoration: searchFieldDecoration(hintText: 'Search…'),
            ),
          ),
          const SizedBox(width: 4),
          if (hitCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '${hitIndex + 1}/$hitCount',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            onPressed: onPrev,
            tooltip: 'Previous',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            onPressed: onNext,
            tooltip: 'Next',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: onClose,
            tooltip: 'Close',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

/// Identifies which protocol the tab is using, for colour selection.
enum DotProtocol { ssh, mosh, quic }

/// Single 6dp status dot. Encodes connection state via colour + pulse animation.
///
/// Colour palette (5 protocol colours + 3 health overlays):
///   • grey     — never connected (`isInitial`).
///   • red      — disconnected / failed (`isDisconnected`).
///   • orange   — connected but unstable / packet loss (`!isStable`).
///   • green    — stable SSH session.
///   • blue     — stable mosh session.
///   • cyan     — stable QUIC session.
///
/// Animation:
///   • Pulsing fade (1 Hz) only while `isReconnecting`. The dot keeps its
///     protocol colour during the pulse, so a reconnect cycle looks like
///     protocol-color solid → red solid → protocol-color blinking →
///     protocol-color solid, with no unrelated transient colour mid-cycle.
class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.protocol,
    required this.isInitial,
    required this.isDisconnected,
    required this.isReconnecting,
    required this.isStable,
    this.tooltip,
  });

  final DotProtocol protocol;

  /// Shown on long-press / hover — e.g. that this QUIC session runs through
  /// the SSH channel. Null = no tooltip.
  final String? tooltip;

  /// True when the tab has never successfully connected and no error has
  /// occurred yet (建连前 / pristine state).  Shows a light grey dot.
  final bool isInitial;
  final bool isDisconnected;
  final bool isReconnecting;
  final bool isStable;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  static const _grey = Color(0xFF9E9E9E);
  static const _red = Color(0xFFEF5350);
  static const _orange = Color(0xFFFF8000);
  static const _green = Color(0xFF66BB6A);
  static const _blue = Color(0xFF42A5F5);
  static const _cyan = Color(0xFF26C6DA); // QUIC

  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _opacity = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    if (widget.isReconnecting) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.isReconnecting && !old.isReconnecting) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.isReconnecting && old.isReconnecting) {
      _ctrl.stop();
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _protocolColor {
    switch (widget.protocol) {
      case DotProtocol.mosh:
        return _blue;
      case DotProtocol.quic:
        return _cyan;
      case DotProtocol.ssh:
        return _green;
    }
  }

  Color get _color {
    if (widget.isInitial) return _grey;
    if (widget.isDisconnected) return _red;
    // Reconnecting takes precedence over !isStable: while a reconnect is in
    // flight we want the protocol colour + blink animation (instead of orange
    // static) so the transition <proto> → red → <proto> blinking → <proto>
    // feels continuous, with no unrelated amber/orange colour mid-cycle.
    if (widget.isReconnecting) return _protocolColor;
    if (!widget.isStable) return _orange;
    return _protocolColor;
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _color),
    );
    final shown =
        widget.isReconnecting ? FadeTransition(opacity: _opacity, child: dot) : dot;
    final tip = widget.tooltip;
    return tip == null ? shown : Tooltip(message: tip, child: shown);
  }
}

/// A brief tooltip bubble shown when the FET button first appears,
/// explaining drag and swipe-to-hide gestures. Auto-dismisses after 3 s.
class _OnboardingBubble extends StatelessWidget {
  const _OnboardingBubble({required this.text, required this.onDismiss});
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    Future.delayed(const Duration(seconds: 3), onDismiss);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
