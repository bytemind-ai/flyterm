// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_exec_channel.dart';
import '../../ai/agent/agent_loop.dart';
import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/server_notes_manager.dart' show ServerNoteSaveResult;
import '../../ai/agent/tool_registry.dart';
import '../../ai/ai_engine.dart';
import '../../ai/ai_provider_service.dart';
import '../../ai/attachment.dart';
import '../../ai/attachment_store.dart';
import '../../ai/provider_switch.dart';
import '../../data/models/agent_session.dart';
import '../../data/models/server.dart';
import '../../data/repositories/agent_session_repository.dart';
import '../../data/repositories/ai_provider_repository.dart';
import '../../data/secure_storage.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import '../settings/agent_settings_screen.dart';
import 'agent_view.dart';
import 'direct_chat_view.dart';
import 'export_preview_screen.dart';
import 'widgets/session_export_source.dart';
import 'mention.dart';
import 'widgets/model_picker_sheet.dart';
import 'widgets/panel_chrome.dart';
import 'widgets/session_history_view.dart';

/// 面板打开时的高度（占父容器的比例）。
///
/// 从 0.5 提到 0.62：半屏只够看一两轮，而用户每开一次面板几乎总要再往上
/// 拖一把才看得清上文 —— 手机上这个多余手势按次收费。0.62 大约是 6:4，
/// 与终端上下文（看报错、对照输出）同时可见的诉求对得上，又不至于一开就
/// 把身后的终端盖没。
const double _kInitialSheetSize = 0.62;
const double _kMinSheetSize = 0.25;

/// 上限：面板顶上方要留一条能点的空地，那是关闭它的唯一手势（点遮罩）。
///
/// 从 0.9 收到 0.88。0.9 在 640pt 的窄屏上只剩 64pt 的可点区，勉强够到
/// Material 的最小触摸目标，但那是「刚好达标」而非「好点」；而且
/// `DraggableScrollableSheet` 拖到上限后会跟手回弹，留出余量后这条手势
/// 不再贴着屏幕顶边，误触系统手势区的概率也低。
const double _kMaxSheetSize = 0.88;

/// Bottom-sheet shell hosting either [AgentView] (agent mode) or
/// [DirectChatView] (direct mode). Owns sheet sizing, keyboard-height
/// adaptation, header chrome, and the decision of which mode to show —
/// nothing about chat/agent content itself lives here anymore.
class AIPanel extends StatefulWidget {
  final AIEngine engine;

  /// Called each time a query is submitted to get the latest terminal snapshot.
  /// Replaces the old fixed-string terminalContext so session summary and error
  /// analysis always see the current terminal output, not a stale open-time copy.
  final String Function()? contextProvider;
  final String? initialQuery;

  /// Called when user taps "执行" on a code block. The command is sent to terminal.
  final void Function(String command)? onRunCommand;

  /// Called when user taps "收藏" on a code block.
  final void Function(String command)? onSaveCommand;
  final void Function(String command)? onExplainCommand;

  /// null 表示当前会话没有可用的执行通道 → 只能直连。
  final AgentExecChannel? execChannel;

  /// 由调用方从 AgentSessionManager 取得或创建。null 表示调用方压根没打算
  /// 支持 agent 模式（老测试 / 未来其他调用点）——此时即便 execChannel 给了，
  /// 也不会进 agent 分支，避免 `!` 解包崩溃。
  final AgentLoop Function()? loopFactory;

  final VoidCallback? onOpenServerSettings;

  /// 纯转发给 `AgentView`（常驻任务条点击跳看板用），见其类文档。
  final VoidCallback? onOpenJobs;

  /// 以下两个纯转发给 `AgentView`（知识提议卡「存入」用），本类不解读它们的
  /// 语义 —— 装配逻辑全在 `terminal_screen.dart`。`onWriteMachineNotes` 的
  /// 签名是 `(heading, body)` 而不是整份文本——见 `AgentView` 上同名字段的
  /// 文档（I3）。
  final Future<void> Function(String name, String description, String body)?
  onSaveSkill;
  final Future<ServerNoteSaveResult> Function(String heading, String body)?
  onWriteMachineNotes;

  /// 以下四个同样纯转发给 `AgentView`（输入框 `@` 引用用），装配逻辑全在
  /// `terminal_screen.dart`。
  final RemoteDirLister? listRemoteDir;
  final RemotePathResolver? resolveRemotePath;
  final List<Server> servers;
  final bool hasOtherServers;

  /// 以下三个纯转发给 `AgentView`（附件读/写用），装配逻辑全在
  /// `terminal_screen.dart`。见 `AgentView` 上对应字段的文档。
  final File? Function(Attachment)? attachmentFileFor;
  final AttachmentStore? attachmentStore;
  final String? attachmentServerId;

  const AIPanel({
    super.key,
    required this.engine,
    this.contextProvider,
    this.initialQuery,
    this.onRunCommand,
    this.onSaveCommand,
    this.onExplainCommand,
    this.execChannel,
    this.loopFactory,
    this.onOpenServerSettings,
    this.onOpenJobs,
    this.onSaveSkill,
    this.onWriteMachineNotes,
    this.listRemoteDir,
    this.resolveRemotePath,
    this.servers = const [],
    this.hasOtherServers = false,
    this.attachmentFileFor,
    this.attachmentStore,
    this.attachmentServerId,
  });

  static Future<void> show(
    BuildContext context, {
    required AIEngine engine,
    String Function()? contextProvider,
    String? initialQuery,
    void Function(String)? onRunCommand,
    void Function(String)? onSaveCommand,
    void Function(String)? onExplainCommand,
    AgentExecChannel? execChannel,
    AgentLoop Function()? loopFactory,
    VoidCallback? onOpenServerSettings,
    VoidCallback? onOpenJobs,
    Future<void> Function(String name, String description, String body)?
    onSaveSkill,
    Future<ServerNoteSaveResult> Function(String heading, String body)?
    onWriteMachineNotes,
    RemoteDirLister? listRemoteDir,
    RemotePathResolver? resolveRemotePath,
    List<Server> servers = const [],
    bool hasOtherServers = false,
    File? Function(Attachment)? attachmentFileFor,
    AttachmentStore? attachmentStore,
    String? attachmentServerId,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AIPanel(
        engine: engine,
        contextProvider: contextProvider,
        initialQuery: initialQuery,
        onRunCommand: onRunCommand,
        onSaveCommand: onSaveCommand,
        onExplainCommand: onExplainCommand,
        execChannel: execChannel,
        loopFactory: loopFactory,
        onOpenServerSettings: onOpenServerSettings,
        onOpenJobs: onOpenJobs,
        onSaveSkill: onSaveSkill,
        onWriteMachineNotes: onWriteMachineNotes,
        listRemoteDir: listRemoteDir,
        resolveRemotePath: resolveRemotePath,
        servers: servers,
        hasOtherServers: hasOtherServers,
        attachmentFileFor: attachmentFileFor,
        attachmentStore: attachmentStore,
        attachmentServerId: attachmentServerId,
      ),
    );
  }

  @override
  State<AIPanel> createState() => _AIPanelState();
}

class _AIPanelState extends State<AIPanel> {
  late final DraggableScrollableController _sheetCtrl;
  final _directChatKey = GlobalKey<DirectChatViewState>();
  double _lastKeyboardHeight = 0;
  bool _keyboardBaselineSet = false;

  /// sheet 父容器的高度，由 `build` 里的 LayoutBuilder 填。见 [_dragSheet]。
  double _availableHeight = 0;

  /// null while [_resolveMode] hasn't finished its (async) qualification
  /// check yet — body shows a spinner for that one frame.
  AIPanelMode? _mode;

  /// One-line reason shown above the chat when we degraded to direct mode.
  /// Never a dialog, never a thrown error — the user came here to ask a
  /// question, not to read a diagnostic.
  String? _degradeNotice;

  /// Whether the degrade reason was "no credentials" — only then does the
  /// notice get a "go to settings" action; a tool-support shortfall isn't
  /// fixed by the server-edit screen.
  bool _degradeNoticeIsCredentials = false;

  /// true = 面板正显示历史列表而不是对话。
  ///
  /// 面板内切换视图，不是再叠一层 sheet —— 理由见 [SessionHistoryView] 的类
  /// 文档（两层 DraggableScrollableSheet 会抢拖拽手势）。
  bool _showHistory = false;

  /// 历史列表的数据。每次进列表、以及标星/删除之后都重新读一次表 —— 列表很
  /// 短（每台服务器最多 `kSessionsPerServer` 段），重读比在内存里维护一份
  /// 镜像更不容易出错。
  List<AgentSession> _sessions = const [];

  @override
  void initState() {
    super.initState();
    _sheetCtrl = DraggableScrollableController();
    // 必须延到第一帧之后再跑。
    //
    // `_resolveMode` 虽然是 async，但在「没配 provider」「不支持 tools」「没有
    // channel」这几条路上**全程同步**——`await channel.isAvailable()` 那一句
    // 根本不执行（它在 if 里）。于是方法体里的 `context.l10n` 就在 initState
    // 的调用栈里访问 InheritedWidget，Flutter 对此抛 assertion。debug 下是红屏，
    // release 下 assert 被剥离、侥幸能取到值，所以一直没人发现。
    //
    // `_mode` 为 null 时 body 已经是个 spinner，延一帧看不出来。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resolveMode();
    });
  }

  /// 决定这次打开面板走哪个模式。
  ///
  /// **AI 助手对用户只有一个入口**，没有模式选择。能用 agent 就用 agent；
  /// 模型不支持 tool calling、或这台服务器没有可用凭据时，自动退回直连
  /// 问答并在顶部给一行说明 —— 不弹错误框，用户来这里是想问问题，不是来
  /// 看报错的。
  Future<void> _resolveMode() async {
    final svc = context.read<AIProviderService>();
    final channel = widget.execChannel;
    final loopFactory = widget.loopFactory;

    // 没配 provider 时，直连模式自己会在提交时给出 aiNoProvider 提示——这里
    // 不需要再叠一条降级横幅。
    if (!svc.hasProvider) {
      if (!mounted) return;
      setState(() => _mode = AIPanelMode.direct);
      return;
    }

    final supportsTools = svc.provider!.supportsTools;
    // channel.isAvailable() 有网络/存储 IO，只在前置条件都满足时才调用。
    var credsOk = false;
    if (supportsTools && channel != null && loopFactory != null) {
      credsOk = await channel.isAvailable();
    }
    final ok =
        supportsTools && channel != null && loopFactory != null && credsOk;
    // initialQuery 不再强制降级到直连。`AgentView` 现在收这个参数并在首次
    // 构建后 `loop.send()` 出去 —— 而「分析终端里这个错误」恰恰是 agent
    // 模式更擅长的事：直连只能看用户贴过去的那段 buffer，agent 可以自己
    // 翻日志、看配置、查端口。早先为了「宁可降级也别丢请求」而强制直连，
    // 等于把用户从强的模式赶去弱的模式。
    if (!mounted) return;
    setState(() {
      _mode = ok ? AIPanelMode.agent : AIPanelMode.direct;
      if (ok) {
        _degradeNotice = null;
        _degradeNoticeIsCredentials = false;
      } else if (!supportsTools) {
        _degradeNotice = context.l10n.agentNoToolSupport;
        _degradeNoticeIsCredentials = false;
      } else {
        // supportsTools true → 卡在 channel/凭据（或防御性地：调用方没传
        // loopFactory）上，统一按「无凭据」文案处理。
        _degradeNotice = context.l10n.agentNoCredentials;
        _degradeNoticeIsCredentials = channel != null;
      }
    });

    _maybeForceRuleReview();
  }

  /// agent 模式首次启用：强制把默认放行清单摊开给用户看一眼。
  ///
  /// 那份清单是「无感排查」的全部来源，也是本设计里唯一带我们主观判断的
  /// 地方 —— 用户有权在它第一次生效之前知道它放行了什么。
  ///
  /// 2026-10-14 起清单搬到了「自动执行清单」子页，这里 push 的 hub 会显示
  /// 一段说明 + 一个「去过目」按钮把用户送进那一页（见 `AgentSettingsScreen`
  /// 的 `firstReview` 文档）。过目标记在用户**从清单页返回**时才落下 ——
  /// 只看到按钮不算看过清单。
  ///
  /// 模式切换按钮去掉之后，进入 agent 模式只剩「初始判定」这一条路径，
  /// 所以只需在 [_resolveMode] 末尾调用一次。（曾经有过手动切换那条路，
  /// 当时漏了在它上面也挂一次，导致清单能被绕过。）
  void _maybeForceRuleReview() {
    if (_mode != AIPanelMode.agent) return;
    if (widget.execChannel == null) return;
    final mgr = context.read<AgentSessionManager>();
    // 过目标记现在是**全局**的：放行清单变全局之后，「用 agent 前先过目
    // 一次」这件事也只该发生一次，不是每台服务器一次。
    if (mgr.hasReviewedRules) return;

    // 不能直接 push —— 这里可能是从 initState 的异步延续调用的，那时改
    // 导航栈等于在 build 期间动它。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          // 不带 serverId：那一页现在是全局设置页。
          builder: (_) => const AgentSettingsScreen(firstReview: true),
        ),
      );
      // 回来之后不需要重算模式 —— 规则集变了不影响资格判定，
      // AgentView 每轮都从 manager 现读规则。
      if (!mounted) return;
    });
  }

  /// 「分析错误」/「会话总结」——**只剩直连模式用**。
  ///
  /// agent 模式下这两个按钮撤掉了：它们真正提供的能力不是「省一次打字」（那个
  /// 用户自己能做），而是把**当前**屏幕附进问题里。现在那件事由 `read_terminal`
  /// 工具承担，模型需要看屏幕时自己要 —— 这比依赖「用户记得点按钮而不是直接
  /// 打字」可靠，也让头部少两个图标。
  ///
  /// 直连模式没有工具可用，删掉就是纯损失，所以保留。
  void _analyzeError() => _directChatKey.currentState?.analyzeError();

  void _summary() => _directChatKey.currentState?.requestSummary();

  /// 「新建会话」：归档当前这一段，然后开一段新的。
  ///
  /// 按当前模式分派 —— 直连模式没有「会话归档」这个概念，仍然是清空
  /// [AIEngine.clearHistory]；agent 模式的历史不在 engine 里，得把当前段写进
  /// [AgentSessionManager] 的表再关掉当前 loop。下次 `_agentLoopFor` 会用一份
  /// 空 `restoreFrom` 重新装配，是干净会话。
  ///
  /// 归档 await 掉再 `closeLoop`。这里**不是**在防竞态：`archiveCurrent` 读
  /// `loop.events`、`toArchive()` 都发生在它第一个 await 之前，所以不等也不会
  /// 读到被 dispose 的 loop。等的作用是让「先归档、再开新的」这个顺序在代码里
  /// 就是显式的，并且写入真的落地之后界面才换成空会话。
  Future<void> _newSession() async {
    if (_mode == AIPanelMode.agent) {
      final channel = widget.execChannel;
      if (channel == null) return;
      final mgr = context.read<AgentSessionManager>();
      final serverId = channel.server.id;
      await mgr.archiveCurrent(serverId);
      if (!mounted) return;
      mgr.closeLoop(serverId);
      // 必须重建：closeLoop 之后 loopFactory 才会给出新的空 loop，
      // 不 setState 的话界面上那段旧对话会一直挂着。
      //
      // 同时退出历史列表视图。这个按钮在列表打开时也是可点的（头部一直渲染
      // 它），而 `_buildBody` 的第一件事就是「_showHistory 为真则返回列表」
      // —— 不复位的话，归档和 closeLoop 都真的发生了，界面却还停在列表上，
      // 零反馈。用户报的「新会话按钮在打开历史会话时不可用」就是这个。
      setState(() => _showHistory = false);
    } else {
      widget.engine.clearHistory();
    }
  }

  /// 读一遍表，切到历史列表视图。
  Future<void> _openHistory() async {
    final channel = widget.execChannel;
    if (channel == null) return;
    final mgr = context.read<AgentSessionManager>();
    final rows = await mgr.sessionsFor(channel.server.id);
    if (!mounted) return;
    setState(() {
      _sessions = rows;
      _showHistory = true;
    });
  }

  /// 列表里点开某一段：先把当前段归档，再让下一个 loop 用它装配。
  ///
  /// 归档在前是必须的 —— 不归档就直接换，当前这段既不在表里也不在内存里，
  /// 就是一次静默丢失。
  Future<void> _openSession(int id) async {
    final channel = widget.execChannel;
    if (channel == null) return;
    final mgr = context.read<AgentSessionManager>();
    final serverId = channel.server.id;

    await mgr.archiveCurrent(serverId);
    if (!mounted) return;
    final archive = await mgr.takeById(id);
    if (!mounted) return;
    if (archive == null) {
      // 那一段在别处被删了，或者 archive 反序列化失败。刷新列表让用户看到
      // 现状，而不是切进一个空会话让他以为内容丢了。
      final rows = await mgr.sessionsFor(serverId);
      if (!mounted) return;
      setState(() => _sessions = rows);
      return;
    }
    // seed 在 closeLoop 之前：这样任何时刻 pendingRestore 都已就位，中间哪怕
    // 发生一次意料之外的重建，拿到的也是正确那份归档。
    mgr.seedRestore(serverId, archive);
    mgr.closeLoop(serverId);
    if (!mounted) return;
    setState(() => _showHistory = false);
  }

  /// 导出历史里的某一段。
  ///
  /// 与 [_openSession] 不同：**不切换当前会话**。用户想导出旧会话时，多半
  /// 不想因此丢掉眼前正在跑的这一段。用 `archiveById` 而不是 `takeById`——
  /// 后者会把这一行认领为活跃段，导致当前正在跑的会话之后的落盘错位到这一
  /// 行上（见 `agent_session_manager.dart` 里 `archiveById` 上的注释）。
  Future<void> _exportSession(int id) async {
    final mgr = context.read<AgentSessionManager>();
    // 活跃段那一行改走内存。它按 `updated_at DESC` 排在列表**第一条**，是最
    // 容易被点到的那一条；而回表读到的是 3 秒节流落盘的版本，会缺最近几轮，
    // 且用户完全看不出来 —— 静默的数据缺失比少一个入口糟糕得多。
    //
    // 头部那个导出图标已于 2026-10 移除，历史列表每行是唯一入口；活跃段
    // 那一行仍然要按上面的理由改走内存。
    //
    // 取数来源的判断收在 `exportEventsFor` 里，与全局 AI 页共用一份 ——
    // 两个入口各写一遍时已经漂移过一次。
    final serverId = widget.execChannel?.server.id;
    final activeRowId =
        serverId == null ? null : mgr.activeRowIdFor(serverId);
    final isActive = serverId != null &&
        activeRowId == id &&
        widget.loopFactory != null;

    final archive = isActive ? null : await mgr.archiveById(id);
    if (!mounted) return;
    // 这一行已不存在：原行为是直接什么都不做（不是弹一个空导出）。
    if (!isActive && archive == null) return;

    final source = exportEventsFor(
      id: id,
      activeRowId: isActive ? id : null,
      liveEvents: isActive ? widget.loopFactory!().events : const [],
      archive: archive,
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExportPreviewScreen(
          events: source.events,
          // 活跃段用服务器名（与改造前 `_exportCurrent` 一致），
          // 历史某段用 `session_$id`。
          filenameHint: isActive
              ? (widget.execChannel?.server.name ?? 'session')
              : 'session_$id',
        ),
      ),
    );
  }

  /// 弹出切模型 sheet。
  ///
  /// 候选的可用性要先异步查一遍 key（`providerUsable`），所以整个流程是
  /// 先取数、再弹 sheet，而不是在 builder 里同步判断。
  Future<void> _switchModel() async {
    final repo = context.read<AIProviderRepository>();
    final storage = context.read<SecureStorageService>();
    final svc = context.read<AIProviderService>();
    // 取数逻辑与全局 AI 页共用，见 `buildModelChoices` 的 dartdoc。
    final choices = await buildModelChoices(context);
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      builder: (_) => ModelPickerSheet(
        choices: choices,
        onPick: (config) async {
          await switchProvider(
            config: config,
            repo: repo,
            storage: storage,
            svc: svc,
            // 可空读取：widget 测试大多不搭 `TerminalSettings` provider，
            // 写成不可空会让这里抛 ProviderNotFoundException，连带把后面
            // 那段「必须重算模式」整个跳过 —— 表现是切到不支持 tools 的
            // 模型后仍停在 agent 模式。与 `agent_view.dart` 里 devMode 那
            // 处同一个理由。
            debugOverlay:
                context.read<TerminalSettings?>()?.debugOverlay ?? false,
          );
          if (!mounted) return;
          // 必须重算模式：以前换 provider 得退出面板再进才会跑 _resolveMode，
          // 现在面板内能切，不重算就会出现「面板还在 agent 模式、provider
          // 已经抛不支持工具」的错位。
          await _resolveMode();
        },
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    if (!_keyboardBaselineSet) {
      _keyboardBaselineSet = true;
      _lastKeyboardHeight = keyboardHeight;
      return;
    }
    if (keyboardHeight == _lastKeyboardHeight) return;
    _lastKeyboardHeight = keyboardHeight;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheetCtrl.isAttached) return;
      // 键盘高度**不参与**这里的计算，它只用来判断键盘是不是弹起来了。
      //
      // 曾经写成 `(screenH - keyboardHeight - 48) / screenH`，理由是「让面板
      // 正好停在键盘上方」。但 `showModalBottomSheet` 的 route 根本不避让键盘
      // （Flutter 的 bottom_sheet.dart 里没有任何 viewInsets 处理），sheet 的
      // 高度永远是从屏幕底边往上量的 —— 键盘盖住的就是它自己的下半截，而把
      // 输入框顶到键盘上方那一下由 [PanelInputRow] 自己的 viewInsets padding
      // 完成。于是那个公式把键盘扣了第二遍：400px 高的面板里，330px 归键盘、
      // 剩下的归输入行，对话区被 Expanded 挤成 0 高度还溢出。用户报的
      // 「输入时上拉的面积被缩小了」就是这个。
      //
      // 正打字的时候恰恰是最需要看见上文的时候，所以直接顶到上限。
      _sheetCtrl.animateTo(
        keyboardHeight > 100 ? _kMaxSheetSize : _kInitialSheetSize,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _sheetCtrl.dispose();
    super.dispose();
  }

  Widget _buildBody(ScrollController scrollController) {
    if (_mode == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_mode == AIPanelMode.agent) {
      // 历史列表放在 Selector 之外：这个视图不需要档位，没必要为它订阅。
      if (_showHistory) {
        return SessionHistoryView(
          sessions: _sessions,
          onOpen: (id) {
            // fire-and-forget：按钮回调。失败路径在 _openSession 里自己处理。
            _openSession(id);
          },
          onToggleStar: (id, v) async {
            await context.read<AgentSessionManager>().setStarred(id, v);
            // 重读表而不是就地改内存那份 —— 标星会影响滚动删除的配额，重读
            // 才能看到真实结果。
            await _openHistory();
          },
          onDelete: (id) async {
            await context.read<AgentSessionManager>().deleteSession(id);
            await _openHistory();
          },
          onExport: (id) {
            // fire-and-forget：按钮回调。
            _exportSession(id);
          },
          // 与下面 `_agentLoopFor` 用的是同一个 serverKey。没有 channel 时
          // （非 agent 模式）取不到 serverId，用全局额度 —— 那条路径不会走到
          // 这里（本分支已在 agent 模式下），只是不给一个会撒谎的默认值。
          quota: sessionQuotaFor(
              widget.execChannel?.server.id ?? kGlobalServerId),
        );
      }
      final channel = widget.execChannel;
      // bypassMode 必须**订阅**，不能 `context.read`。
      //
      // 这里曾经写的是 read，注释是「现读而不是缓存：用户可能在会话中途去
      // 设置里改了档」——但 read 达不到那个意图：它不建立依赖，`_buildBody`
      // 不会因为改档而重建，bypassMode 就冻在打开面板那一刻的值上。用户报的
      // 「改了权限模式没反应、退出重进才看到新值」就是这个：设置页自己刷新
      // 得好好的（值也确实存了），只有已经打开的这个面板没跟上。
      //
      // 用 Selector 而不是在 `build()` 顶层 watch，理由与 [_buildHeader] 同：
      // 这个 manager 在 agent loop 运行期间（工具调用、审批、流式 token）
      // notifyListeners 触发得非常频繁，顶层 watch 会让整个面板跟着重建。
      // Selector 从 bool 改选 PermissionMode 枚举：现在需要区分三档而不只是
      // 「是不是 plan」——审批卡的「本轮不再问」按钮要知道是否 bypass 档。
      // 收窄订阅的初衷不变：只有档位真的翻转时才重建，而不是随
      // notifyListeners 的高频调用整个面板跟着重建。
      //
      // 重建时 `loopFactory()` 会被再调一次是安全的：生产实现
      // （`terminal_screen.dart` 的 `_agentLoopFor`）复用已注册的 loop，
      // 不会凭空换掉会话。
      return Selector<AgentSessionManager, PermissionMode>(
        selector: (_, mgr) => channel == null
            ? PermissionMode.ask
            : mgr.modeFor(channel.server.id),
        builder: (_, mode, __) => AgentView(
          loop: widget.loopFactory!(),
          providerName: context.read<AIProviderService>().provider!.displayName,
          onOpenServerSettings: widget.onOpenServerSettings,
          onOpenJobs: widget.onOpenJobs,
          initialQuery: widget.initialQuery,
          // onRunCommand / onSaveCommand 不再往 agent 模式传：那里的代码块
          // 不挂动作按钮（命令走审批）。两个字段仍为直连模式保留 —— 见
          // `CodeBlockBuilder.showActions`。
          // 必须往下传：sheet 的伸缩手势靠它感知内部列表的滚动位置。
          // 不传的话 agent 模式下只有顶部那根小横条能拖。
          scrollController: scrollController,
          bypassMode: mode == PermissionMode.bypass,
          onSaveSkill: widget.onSaveSkill,
          onWriteMachineNotes: widget.onWriteMachineNotes,
          listRemoteDir: widget.listRemoteDir,
          resolveRemotePath: widget.resolveRemotePath,
          servers: widget.servers,
          hasOtherServers: widget.hasOtherServers,
          attachmentFileFor: widget.attachmentFileFor,
          attachmentStore: widget.attachmentStore,
          attachmentServerId: widget.attachmentServerId,
        ),
      );
    }
    return Column(
      children: [
        if (_degradeNotice != null)
          _DegradeBanner(
            text: _degradeNotice!,
            onAction: _degradeNoticeIsCredentials
                ? widget.onOpenServerSettings
                : null,
          ),
        Expanded(
          child: DirectChatView(
            key: _directChatKey,
            engine: widget.engine,
            contextProvider: widget.contextProvider,
            initialQuery: widget.initialQuery,
            onRunCommand: widget.onRunCommand,
            onSaveCommand: widget.onSaveCommand,
            onExplainCommand: widget.onExplainCommand,
            scrollController: scrollController,
          ),
        ),
      ],
    );
  }

  /// bypass 是「开了就忘」的设置：一旦打开，它的存在感只剩三级设置页里那
  /// 一条状态文案。真正该提醒用户的时机是他正看着 agent 干活的这个面板——
  /// 风险在这里发生。
  ///
  /// 用 [Selector] 而不是在 `build()` 顶层 `context.watch` —— 后者会让整个
  /// `_AIPanelState`（消息列表、输入框……）跟着 `AgentSessionManager` 的每
  /// 一次 `notifyListeners()` 重建，而这个 manager 在 agent loop 运行期间
  /// （工具调用、审批、流式 token）触发得非常频繁。`Selector` 把订阅收窄到
  /// 「这台服务器是否 bypass」这一个 bool，只有它真的翻转时才重建，重建范
  /// 围也只到 `PanelHeader` 这一小块。
  Widget _buildHeader() {
    final channel = widget.execChannel;
    // 这两个只给直连模式。agent 模式改由 `read_terminal` 工具承担「看当前
    // 屏幕」，见 [_analyzeError] 的说明。
    final isAgent = _mode == AIPanelMode.agent;
    final onAnalyzeError = (!isAgent && widget.contextProvider != null)
        ? _analyzeError
        : null;
    final onSummary = (!isAgent && widget.contextProvider != null)
        ? _summary
        : null;
    if (channel == null) {
      // 没有 execChannel = 直连模式：没有会话归档，所以不给历史入口。
      return PanelHeader(
        onClear: () {
          // fire-and-forget：这是个按钮回调，归档失败已经在 archiveCurrent
          // 内部吞掉并记了日志。
          _newSession();
        },
        onAnalyzeError: onAnalyzeError,
        onSummary: onSummary,
        modelLabel: context.watch<AIProviderService>().provider?.displayName,
        onSwitchModel: _switchModel,
      );
    }
    return Selector<AgentSessionManager, bool>(
      selector: (_, mgr) =>
          mgr.modeFor(channel.server.id) == PermissionMode.bypass,
      builder: (_, bypassActive, __) => PanelHeader(
        onClear: () {
          // fire-and-forget：理由同上。
          _newSession();
        },
        onAnalyzeError: onAnalyzeError,
        onSummary: onSummary,
        // agent 模式完全不渲染那两个按钮，而不是渲染成禁用态 —— 它们已经交给
        // `read_terminal` 工具，留个灰图标只是白占格子。
        showPresets: !isAgent,
        // 归档只发生在 agent 模式 —— 直连模式的历史在 engine 里，没有分段。
        //
        // 做成开关：进了列表得有退路。列表本身没有返回按钮（它是面板内的视图，
        // 不是一层路由），再点一次这个图标就回到对话。
        //
        // 打开列表后头部会整体变脸（左侧图标换成 arrow_back、标题换成
        // 「历史会话」），见 `PanelHeader.historyOpen`；那个返回键走的也是
        // 这个回调，所以这里必须把开关语义保留在「再点一次就退出」上。
        onHistory: _mode == AIPanelMode.agent
            ? () {
                if (_showHistory) {
                  setState(() => _showHistory = false);
                } else {
                  // fire-and-forget：按钮回调。
                  _openHistory();
                }
              }
            : null,
        historyOpen: _showHistory,
        bypassActive: bypassActive,
        modelLabel: context.watch<AIProviderService>().provider?.displayName,
        onSwitchModel: _switchModel,
      ),
    );
  }

  /// 跟手改 sheet 大小。
  ///
  /// 用 [DraggableScrollableController.jumpTo] 而不是 `animateTo(Duration.zero)`
  /// —— 后者踩了 SDK 的 `assert(duration != Duration.zero)`（debug 构建下拖一
  /// 下就抛异常，release 靠 assert 被剥离侥幸能动），而且每个 drag 事件都要
  /// 新建一个 AnimationController 再立刻停掉。jumpTo 就是 SDK 给这个场景准备
  /// 的入口。
  void _dragSheet(DragUpdateDetails d) {
    if (!_sheetCtrl.isAttached) return;
    // 分母得是 sheet **父容器**的高度 —— size 是相对它的比例。
    //
    // 不能用 `context.size`：modal sheet 给的是 loose 约束，那个值等于面板此刻
    // 自己的高度，越拖越大、灵敏度跟着漂，拖 150px 能长 300px。也不能用
    // `MediaQuery.size.height`：`useSafeArea` 的 sheet 比屏幕矮着状态栏那一截。
    final availH = _availableHeight;
    if (availH <= 0) return;
    _sheetCtrl.jumpTo(
      (_sheetCtrl.size - d.delta.dy / availH).clamp(
        _kMinSheetSize,
        _kMaxSheetSize,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder 只为拿这个约束：sheet 的比例参照的就是它，拖拽换算得按它
    // 走（见 [_dragSheet]）。
    return LayoutBuilder(
      builder: (context, constraints) {
        _availableHeight = constraints.maxHeight;
        return DraggableScrollableSheet(
          expand: false,
          controller: _sheetCtrl,
          initialChildSize: _kInitialSheetSize,
          minChildSize: _kMinSheetSize,
          maxChildSize: _kMaxSheetSize,
          builder: (_, scrollController) {
            return Column(
              children: [
                // 把手**和**头部那一行一起接进同一个拖拽手势。
                //
                // 以前只有把手接了，而那个把手的可命中区域只有 20px 高 —— 于是
                // 实际能伸缩面板的地方只剩消息列表（走 DraggableScrollableSheet
                // 自己的滚动联动），用户报的「必须在输出屏幕上滑才能上拉」就是
                // 这么来的。头部那一行有 46px 高、横跨整个面板宽度，是最自然的
                // 把手；里面的 IconButton 只认 tap，垂直拖拽仍归这里。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: _dragSheet,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [const PanelHandle(), _buildHeader()],
                  ),
                ),
                Expanded(child: _buildBody(scrollController)),
              ],
            );
          },
        );
      },
    );
  }
}

class _DegradeBanner extends StatelessWidget {
  final String text;
  final VoidCallback? onAction;

  const _DegradeBanner({required this.text, this.onAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          if (onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(context.l10n.agentGoToServerSettings),
            ),
        ],
      ),
    );
  }
}
