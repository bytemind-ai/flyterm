// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/agent/agent_assembly.dart';
import '../../ai/agent/agent_loop.dart';
import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/exec_channel_factory.dart';
import '../../ai/agent/skill.dart' show SkillSource;
import '../../ai/agent/tool_registry.dart' show PermissionMode;
import '../../ai/ai_engine.dart';
import '../../ai/ai_provider_service.dart';
import '../../ai/provider_switch.dart';
import '../../data/models/agent_session.dart';
import '../../data/models/server.dart';
import '../../data/repositories/agent_session_repository.dart';
import '../../data/repositories/ai_provider_repository.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/secure_storage.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import '../../sftp/sftp_entry.dart';
import '../../sftp/sftp_service.dart' show SftpOps, sftpOpsFromClient;
import '../../ssh/session_manager.dart';
import '../terminal/terminal_screen.dart';
import '../ui_flags.dart';
import 'agent_view.dart';
import 'direct_chat_view.dart';
import 'export_preview_screen.dart';
import 'widgets/session_export_source.dart';
import 'widgets/ai_launchpad.dart';
import 'widgets/launchpad_data.dart';
import 'widgets/model_picker_sheet.dart';
import 'widgets/panel_chrome.dart';
import 'widgets/session_history_view.dart';

/// 底部 AI tab 的宿主。
///
/// ## 这个会话不属于任何一台机器
///
/// `sessionKey` 是 [AIEngine.kGlobalServerId]，`defaultServer` 是 null。
/// 于是「打哪台」降级成每次工具调用的参数（`server`，在这个会话里是必填），
/// 而不是会话的属性。这正是它与终端页 AI 面板的根本区别：那边是「帮我看
/// **这台**」，这边是「帮我查**哪台**有问题」。
///
/// 模型不支持 tool calling（或 provider 树不完整）时退回直连问答。
///
/// ## engine 的归属
///
/// direct 模式的 engine 由本页持有（而不是挂在 provider 树上）：
/// `AIEngine.dispose()` 会 `_saveHistory()`，归页面管才有确定的保存时机。
/// `AppShell` 用 `IndexedStack` 常驻三页，所以这个 State 在 App 生命周期内
/// 只建一次、只 dispose 一次。
///
/// agent 的 loop 则**不**归本页持有 —— 它由 [AgentSessionManager] 持有，
/// 寿命长于本页，这样切到别的 tab 再回来不会打断正在跑的一轮。
class GlobalAIScreen extends StatefulWidget {
  const GlobalAIScreen({super.key});

  @override
  State<GlobalAIScreen> createState() => _GlobalAIScreenState();
}

class _GlobalAIScreenState extends State<GlobalAIScreen> {
  late final AIEngine _engine;

  /// 事件列表的滚动控制器。
  ///
  /// **必须传下去**：`AgentView._scrollToBottom` 第一行就是
  /// `if (sc == null) return;` —— 不传的话自动滚动整条路径是死的，agent
  /// 流式输出时面板永远停在用户上次的位置，得手动往下拖。终端页的内嵌面板
  /// 一早就传了（它借用 `DraggableScrollableSheet` 的 controller），全局页
  /// 漏了，于是同一个 widget 在两个入口表现得不一样。
  ///
  /// 这里自己 new 一个而不是借 sheet 的：本页是整屏（`AppShell` 的 tab），
  /// 外层没有 `DraggableScrollableSheet`，没有现成的 controller 可借。
  final _scrollController = ScrollController();

  /// 装配 agent 用的句柄包。在 `didChangeDependencies` 抓一次（不是
  /// `initState` —— 本页由 `AppShell` 的 `IndexedStack` 常驻，但 provider
  /// 树在首帧之前未必就绪）。null = provider 树不完整，只能走 direct。
  AgentAssemblyDeps? _deps;

  /// 这条全局 agent 会话。null = 还没来得及建（agent 可用之后由
  /// [_requestLoopIfNeeded] 自动创建，不再需要用户先点一下建议 chip）。
  AgentLoop? _loop;

  /// 服务器清单快照，喂给 `buildAgentLoop` 的 `serverCache`。
  List<Server> _servers = const [];

  /// 入口区「接着上次」的数据。空列表 = 无历史（与首次使用同一条渲染路径）。
  ///
  /// 刷新时机见 [_refreshRecentSessions] 的文档 —— **不用一次性预取**。
  List<LaunchpadSession> _recentSessions = const [];

  /// 闸门：`_agentReady` 为真但 [_loop] 还是 null 时，在 [build] 里触发一次
  /// `_ensureLoop()`。
  ///
  /// **为什么需要闸门**：`build()` 可能因为任何原因被反复调用（父级
  /// rebuild、键盘弹出改变 `MediaQuery` 等），而 `_ensureLoop()` 内部要
  /// `await deps.servers.findAll()`——没有这个闸门，闸门检查的条件
  /// `_loop == null` 在整个 await 期间都成立，于是每一次 build 都会重新
  /// 发起一条并发的创建请求。并发请求本身不会产生两条 loop（`register`
  /// 内部 `closeLoop` 再登记，后到的会覆盖先到的），但那是误打误撞不出事，
  /// 不是设计上的保证，而且徒增异步噪音。
  ///
  /// 复位时机只有一处：[_clear] 把 [_loop] 置回 null 之后，必须把这个闸门
  /// 也拨回 false——否则归档/新建会话之后，下一次 `build()` 会因为闸门仍是
  /// true 而永远不再请求新 loop，body 卡死在 loading 转圈上。
  bool _loopRequested = false;

  /// 刚执行过「新建会话」—— 紧接着那一次 [_ensureLoop] 不要去 `takeMostRecent`。
  ///
  /// ## 没有它会发生什么
  ///
  /// [_clear] 先 `archiveCurrent`（把当前会话写进表，`updated_at` 刷成**此刻**），
  /// 再 `closeLoop` 并把 [_loop] 置 null。常驻渲染随即触发 [_ensureLoop]，而它
  /// 的 `takeMostRecent` 走的是 `ORDER BY updated_at DESC LIMIT 1` —— 排第一的
  /// 恰恰是刚刚归档的那一段。于是新 loop 用它恢复，**用户点了「新建会话」，
  /// 对话却原样回来了**。
  ///
  /// ## 为什么是「跳过调用」而不是「调用后丢弃结果」
  ///
  /// `takeMostRecent` 有副作用：它会把 `_activeRowId[serverId]` 指向读到的那一
  /// 行。即便丢掉返回值，活跃行也已经被错误地指回旧段，之后这段新会话一落盘
  /// 就写到旧段那一行上去了。
  ///
  /// ## 为什么终端页的 AI 面板没有这个毛病
  ///
  /// 那边 `restoreFrom` 取的是 `_pendingLoopRestore` —— 由 `_openAIPanel` 在建
  /// loop **之前**一次性 await 好并 `remove` 消费掉的值，天然没有「关掉会话后
  /// 又被重新读回来」的路径。本页把 `takeMostRecent` 直接放进 [_ensureLoop]，
  /// 才需要这个标志把那条语义补回来。
  bool _skipRestoreOnce = false;

  /// true = 正显示历史会话列表而不是对话。
  ///
  /// 范式照搬 `ai_panel.dart` 的 `_showHistory`：面板内切换视图，不是再叠一层
  /// 路由或 sheet。这里连「叠一层」的顾虑都不存在（本页就是一整屏，没有
  /// `ai_panel.dart` 那种两层拖拽手势打架的问题），但保持同样的写法是为了让
  /// 两处「历史会话」的实现读起来是同一套范式，而不是因为宿主形态不同就各写
  /// 一遍。
  bool _showHistory = false;

  /// 历史列表的数据。每次进列表、以及标星/删除之后都重新读一次表 —— 原因见
  /// `ai_panel.dart` 同名字段的注释：列表很短，重读比在内存里维护一份镜像更
  /// 不容易出错。
  List<AgentSession> _sessions = const [];

  @override
  void initState() {
    super.initState();
    _engine = AIEngine(
      context.read<SharedPreferences>(),
      serverId: AIEngine.kGlobalServerId,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_deps != null) return;
    try {
      _deps = AgentAssemblyDeps.fromContext(context);
    } on ProviderNotFoundException {
      // provider 树不完整（widget 测试、或将来某个精简入口）。静默退回
      // direct —— 用户来这里是想问问题，不是来看装配诊断的。
      _deps = null;
    }
  }

  @override
  void dispose() {
    _engine.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 这次该走 agent 还是 direct。
  ///
  /// 判据只有两条，都与「有没有机器」无关 —— 这正是全局会话与终端页 AI 面板
  /// 的根本区别：那边还要 `channel.isAvailable()` 确认当前这台连得上，而这边
  /// 压根没有「当前这台」。一台机器都没保存时照样进 agent：模型会读到 prompt
  /// 里那句「没有已保存的服务器」并告诉用户去添加，这比默默降级成一个解释不了
  /// 自己为什么没工具的直连对话要好。
  bool get _agentReady {
    final svc = context.read<AIProviderService>();
    return _deps != null && svc.hasProvider && svc.provider!.supportsTools;
  }

  /// 取（或首次创建）这条全局 agent 会话。
  ///
  /// `sessionKey` 用 [AIEngine.kGlobalServerId] —— 它与任何真实 serverId 都
  /// 不会相撞（`agent_sessions.server_id` 存的就是这个字面量），于是归档、
  /// 历史列表、信任档全都自动按「全局」单独成组，不需要给
  /// `AgentSessionManager` 加第二个索引维度。
  ///
  /// `defaultServer: null` 是整个设计的落点：没有归属机器，`server` 因此在
  /// 工具清单里变成必填。
  /// 返回 null = 本 State 在 await 期间被 dispose，调用方直接放弃这次启动。
  ///
  /// **不要写成 `Future<AgentLoop>` 再在中途 `return _loop!`** —— 那个字段
  /// 在首次进 agent 模式时就是 null，一个 `!` 会把「用户切走得太快」变成崩溃。
  Future<AgentLoop?> _ensureLoop() async {
    final deps = _deps!;
    final existing = deps.agentMgr.loopFor(AIEngine.kGlobalServerId);
    if (existing != null) {
      _servers = await deps.servers.findAll();
      return existing;
    }
    // 两件事都必须在同步构造之前 await 好 —— `buildAgentLoop` 是同步的。
    _servers = await deps.servers.findAll();
    // 优先用已经显式 seed 进去的历史段（来自 [_openSession]：用户在历史
    // 列表里点开了某一条）；只有没有的时候才去拿「最近一段」做隐式恢复
    // （app 重启场景）。
    //
    // 顺序不能反过来写成「先 takeMostRecent，再用 `pendingRestore ??
    // restore` 兜底」——`takeMostRecent` 内部会把 `_activeRowId[serverId]`
    // 指向表里 `updated_at` 最新的那一行。`_openSession` 刚刚
    // `archiveCurrent` 过上一段（把它的 `updated_at` 刷成了"此刻"），这会
    // 让 `takeMostRecent` 读到的恰恰是**刚被归档的旧段**，而不是用户点开的
    // 那一条——`_activeRowId` 因此被错误地改回旧段那一行，之后这段新打开
    // 的历史一落盘，写的却是旧段那一行，是一次悄悄的数据错位。短路掉
    // `takeMostRecent` 的调用，`_activeRowId` 才能保持 `takeById`（在
    // `_openSession` 里）已经设对的那个值。
    //
    // [_skipRestoreOnce] 是同一个根因的第二种表现：`_clear`（新建会话）走的
    // 路径上 `pending` 为 null，于是会落到 `takeMostRecent` —— 而它读到的同样
    // 是刚被 `archiveCurrent` 刷新过时间戳的那一段。上面这段注释原先只覆盖了
    // `_openSession` 那条路，新建会话这条是后来才补上的。
    final pending = deps.agentMgr.takePendingRestore(AIEngine.kGlobalServerId);
    final Map<String, dynamic>? restore;
    if (pending != null) {
      restore = pending;
    } else if (_skipRestoreOnce) {
      // 刚新建过会话：这一次就是要一个干净的空 loop。标志用完即清，下一次
      // 冷启动恢复照常。
      restore = null;
      _skipRestoreOnce = false;
    } else {
      restore = await deps.agentMgr.takeMostRecent(AIEngine.kGlobalServerId);
    }
    if (!mounted) return null;
    return buildAgentLoop(
      deps: deps,
      sessionKey: AIEngine.kGlobalServerId,
      defaultServer: null,
      serverCache: () => _servers,
      // 等价于搬运前 `serverListProvider` 末尾那句 `if (mounted) _serverCache
      // = list`。本页靠 `IndexedStack` 常驻、没有「重开面板」这个自愈点，
      // 不接上这行，会话期间新增的服务器会一直不出现在 system prompt 内联
      // 的机器名单里，直到用户点「清空历史」。
      //
      // 刻意**不** `setState`——`_servers` 只喂给 `serverCache` 闭包和
      // `AgentView.servers`，这两处都在下一次读取时自然看到新值，在模型
      // 回调的中途触发整页重建既没必要，还可能打断正在流式输出的那一轮。
      onServersRefreshed: (list) {
        if (mounted) _servers = list;
      },
      languageTag: Localizations.localeOf(context).toLanguageTag(),
      languageName: context.l10n.promptLanguageName,
      restoreFrom: restore,
    );
  }

  /// 闸门检查 + 实际发起创建。只应该被 [build] 调用——其余入口
  /// （[_openSession]）需要的是"创建并立刻拿到那条 loop"，直接调
  /// [_ensureLoop] 就够了，不需要经过这个闸门。
  ///
  /// **提前创建 loop 是安全且零成本的**：`buildAgentLoop` 只是把一组闭包
  /// 喂给 `AgentLoop` 的构造函数——`providerProvider` / `runnerProvider` /
  /// `sftpOpsProvider` 等等全部是懒执行的闭包，构造期间不会被调用；真正
  /// 发请求的只有 `AgentLoop` 构造体里那一句同步的 `systemPromptProvider(...)`
  /// 拼 system 消息字符串，不碰网络。`mgr.register(sessionKey, loop)` 也只是
  /// 把这条 loop 存进一个 `Map`。确认过 `_persistActive`（`archiveCurrent` 的
  /// 落地实现）开头就有 `if (loop.events.isEmpty) { skip:empty; return; }`——
  /// 一条还没发送过任何消息的空 loop 被 `archiveCurrent` 时不会写进
  /// `agent_sessions` 表，所以"提前创建又被用户划走"不会在历史列表里留下
  /// 空会话的碎片。
  void _requestLoopIfNeeded() {
    if (!_agentReady || _loop != null || _loopRequested) return;
    _loopRequested = true;
    unawaited(() async {
      final loop = await _ensureLoop();
      if (loop == null || !mounted) {
        // State 在 await 期间被 dispose，或者 provider 树中途变得不完整。
        // 复位闸门纯属防御——`!mounted` 时这个 State 已经没有下一次 build
        // 了，复位与否都不影响任何人；留着是为了不让这段逻辑里"闸门永远
        // 只能从 false 变 true 一次"这个隐含假设在未来被打破时留一个坑。
        _loopRequested = false;
        return;
      }
      setState(() => _loop = loop);
      unawaited(_refreshRecentSessions());
    }());
  }

  /// 重新读「接着上次」。
  ///
  /// 刷新点是**确切的归档事件**，不是启动时预取一次 —— 后者会让「刚结束一段
  /// 对话、点新建会话」回到空态时，那段不在列表里。全局会话的归档只发生在
  /// 这个类内部，所以触发点是完备的：`_loop` 被换新的三个出口 + 删除/标星。
  ///
  /// 失败时**保留旧列表**，不抛 —— 入口区是入口，不是依赖。
  Future<void> _refreshRecentSessions() async {
    final deps = _deps;
    if (deps == null) return;
    try {
      final rows = await deps.agentMgr.sessionsFor(AIEngine.kGlobalServerId);
      if (!mounted) return;
      // 先在 `setState` 外把行算好：`machinesFromArchive` 要解 JSON，不该
      // 在重建回调里做。
      //
      // 显式跳过 `id == null` 而不是 `s.id!`：从表里读出来的行理论上一定有
      // id，但一个 null 断言会**扔掉整批**（异常被外层 catch 吞掉，旧列表
      // 保留），而跳过只丢那一行。
      final recent = <LaunchpadSession>[];
      for (final s in rows) {
        if (recent.length >= 3) break;
        final id = s.id;
        if (id == null) continue;
        recent.add(
          LaunchpadSession(
            id: id,
            title: s.title,
            machines: machinesFromArchive(s.archive),
            updatedAt: s.updatedAt,
          ),
        );
      }
      setState(() {
        _recentSessions = recent;
      });
    } catch (_) {
      // 保留旧列表。
    }
  }

  List<LaunchpadMachine> _machinesNow(SessionManager sessions) {
    final ssh = _servers.where((s) => s.serverType == 'ssh').toList();
    bool live(Server s) => sessions.activeTabForServer(s.id) != null;
    ssh.sort((a, b) {
      if (live(a) != live(b)) return live(a) ? -1 : 1;
      final at = a.lastConnectedAt, bt = b.lastConnectedAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return [
      for (final s in ssh.take(5))
        LaunchpadMachine(id: s.id, name: s.name, connected: live(s)),
    ];
  }

  int get _sshTotal => _servers.where((s) => s.serverType == 'ssh').length;

  /// 有机器 → 绑第一台（列表已按「连接中优先 → lastConnectedAt 倒序」排过）
  /// 的具体请求；没机器 → 泛化能力 chips。**两种形态互斥。**
  List<String> _suggestionsNow(SessionManager sessions) {
    final machines = _machinesNow(sessions);
    final l = context.l10n;
    if (machines.isEmpty) {
      return [
        l.aiGlobalAgentSuggest1,
        l.aiGlobalAgentSuggest2,
        l.aiGlobalAgentSuggest3,
        l.aiGlobalAgentSuggest4,
      ];
    }
    final m = machines.first.name;
    return [
      l.aiHomeSuggestDisk(m),
      l.aiHomeSuggestLoad(m),
      l.aiHomeSuggestLogs(m),
    ];
  }

  /// 弹出切模型 sheet。
  ///
  /// 与 `ai_panel.dart` 共用 [buildModelChoices] 取数。`onPick` 之后**不**调
  /// `ai_panel.dart` 那种 `_resolveMode()` —— 那是异步的，要重新查
  /// `providerUsable` 之类的东西来决定 agent / direct。本页的等价判据
  /// `_agentReady` 是个同步 getter（`svc.hasProvider && supportsTools`），
  /// 下一帧 `build()` 重新读一次就是最新结果，不需要一个专门的重算方法——
  /// 只需要让这个 State **rebuild 一次**。
  ///
  /// 这正是下面这行 `setState(() {})` 存在的全部理由：`GlobalAIScreen` 从不
  /// `watch` `AIProviderService`（`_agentReady` 用的是 `context.read`），所以
  /// `switchProvider` 内部的 `svc.notifyListeners()` 不会触发这个 State 的
  /// 重建。没有这一行，`_buildBody` 会一直渲染旧模式算出的那个
  /// `AgentView`/`DirectChatView`——包括「新用户第一次配 provider」这个最常见
  /// 的路径：配完模型回到空状态，点建议 chip 进的还是旧模式。
  /// 给 `@file` 补全用的 SFTP ops。null = 没指定机器，或那台机器已经不在
  /// 列表里了。
  ///
  /// 走 [execChannelForServer] 而不是另开连接：它按 serverId 在
  /// [AgentSessionManager] 里缓存，所以这条和 agent 跑工具用的是**同一条**
  /// channel —— 目标机如果已经连着，`@` 浮层就是秒回，不会为了列个目录再
  /// 握一次手。
  Future<SftpOps?> _opsForServerId(String? serverId) async {
    if (serverId == null) return null;
    final deps = _deps;
    if (deps == null) return null;
    Server? target;
    for (final s in _servers) {
      if (s.id == serverId) {
        target = s;
        break;
      }
    }
    if (target == null) return null;
    final ch = execChannelForServer(
      mgr: deps.agentMgr,
      server: target,
      sessions: deps.sessions,
      storage: deps.storage,
    );
    return sftpOpsFromClient(await ch.obtain());
  }

  Future<void> _switchModel() async {
    final repo = context.read<AIProviderRepository>();
    final storage = context.read<SecureStorageService>();
    final svc = context.read<AIProviderService>();
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
            // 写成不可空会让这里抛 ProviderNotFoundException。与
            // `ai_panel.dart` 同处同一个理由。
            debugOverlay:
                context.read<TerminalSettings?>()?.debugOverlay ?? false,
          );
          // 触发重建，让 `_agentReady` 用新 provider 重新求值 —— 见本方法
          // 上方的 dartdoc。
          if (mounted) setState(() {});
        },
      ),
    );
  }

  /// 「新建会话」：归档当前这一段，然后开一段新的。
  ///
  /// 范式照搬 `ai_panel.dart` 的 `_newSession`，按当前模式分派 —— direct
  /// 模式没有「会话归档」这个概念，仍然是清空 [AIEngine.clearHistory]；
  /// agent 模式的历史不在 engine 里，必须先把当前段写进
  /// [AgentSessionManager] 的表、再关掉当前 loop，否则会出现报告里描述的
  /// 那个 bug：`setState` 让 UI 看起来清空了，但既没归档、旧 loop 也还活在
  /// manager 里 —— 下次 `_ensureLoop()` 的 `loopFor` 命中旧 loop，整段对话
  /// 原样回来。
  ///
  /// 归档 await 掉再 `closeLoop`：不是在防竞态（`archiveCurrent` 读
  /// `loop.events`、`toArchive()` 都发生在它第一个 await 之前，不等也不会读到
  /// 被 dispose 的 loop），作用是让「先归档、再开新的」这个顺序在代码里就是
  /// 显式的，并且写入真的落地之后界面才换成空会话。
  ///
  /// 签名从同步 `void` 改成 `Future<void>`：按钮回调处 fire-and-forget 调用，
  /// 理由见 `ai_panel.dart` 对应位置的注释——这是个按钮回调，归档失败已经在
  /// `archiveCurrent` 内部吞掉并记了日志，调用方不需要等它。
  ///
  /// 两个分支都不再需要显式"回到空状态"的标志位——方案 B 下空状态不是一个
  /// 要手动翻转的开关，而是 `AgentView` / `DirectChatView` 的 `emptyBuilder`
  /// 在"列表/事件流为空"时的自然结果：归档 + 清掉 loop（或 `clearHistory`）
  /// 之后，列表本来就是空的，占位内容自己会出现。这正是方案 B 比"整页替换"
  /// 更干净的地方——这里不用再手摇一个状态位去配合它。
  Future<void> _clear() async {
    if (_agentReady) {
      final mgr = _deps!.agentMgr;
      await mgr.archiveCurrent(AIEngine.kGlobalServerId);
      if (!mounted) return;
      mgr.closeLoop(AIEngine.kGlobalServerId);
      setState(() {
        _loop = null;
        // 闸门复位：没有这一行，下一次 `build()` 会看到 `_loopRequested`
        // 仍是 true 而永远不再调 `_ensureLoop()`，body 会卡死在
        // loading 转圈上——见 `_loopRequested` 字段文档。
        _loopRequested = false;
        // 紧接着那次 `_ensureLoop()` 不许去 `takeMostRecent` —— 它会把刚才
        // `archiveCurrent` 存进去的那一段原样读回来，用户点了「新建会话」
        // 却发现对话纹丝不动。见 `_skipRestoreOnce` 字段文档。
        _skipRestoreOnce = true;
        // 历史列表打开时「新建会话」按钮也可点 —— 不复位的话归档和
        // closeLoop 都真的发生了，界面却还停在列表上，零反馈。
        // `ai_panel.dart` 的 `_newSession` 注释里记了这个用户报过的 bug，
        // 这里原样避开。
        _showHistory = false;
      });
      unawaited(_refreshRecentSessions());
    } else {
      // 不需要 setState：`clearHistory()` 自己 `notifyListeners()`，
      // `DirectChatView` 已经常驻在树里、经由 `ListenableBuilder` 监听同一个
      // `_engine`，清空后它会自己重建成空列表（从而显示 `emptyBuilder`）。
      _engine.clearHistory();
    }
  }

  /// 读一遍表，切到历史列表视图。范式照搬 `ai_panel.dart` 的 `_openHistory`。
  Future<void> _openHistory() async {
    final deps = _deps;
    if (deps == null) return;
    final rows = await deps.agentMgr.sessionsFor(AIEngine.kGlobalServerId);
    if (!mounted) return;
    setState(() {
      _sessions = rows;
      _showHistory = true;
    });
  }

  /// 列表里点开某一段：先把当前段归档，再让下一个 loop 用它装配。
  ///
  /// 归档在前是必须的 —— 不归档就直接换，当前这段既不在表里也不在内存里，
  /// 就是一次静默丢失。`seedRestore` 必须在 `closeLoop` 之前 —— 这样任何
  /// 时刻 `pendingRestore` 都已就位，中间哪怕发生一次意料之外的重建，拿到
  /// 的也是正确那份归档。顺序照抄 `ai_panel.dart` 的 `_openSession`，不自己
  /// 重排。
  ///
  /// 与 `ai_panel.dart` 不同的一点：那边 `loopFactory()` 在每次 `_buildBody`
  /// 都会被重新调用，所以 `setState(() => _showHistory = false)` 之后下一帧
  /// 自然渲染出带着新 loop 的 `AgentView`。这里的 `_loop` 是本 State 自己持有
  /// 的字段（见类文档「engine 的归属」），不会自己刷新，所以这里必须显式
  /// 调 [_ensureLoop] 拿到那个带着刚 seed 进去的历史的新 loop 直接赋给
  /// `_loop`——不经过 `_requestLoopIfNeeded` 的闸门（那是给"自动预建"用的，
  /// 这里是"用户点开了一条具体的历史"，必须同步拿到结果才能关掉历史列表）。
  Future<void> _openSession(int id) async {
    final deps = _deps;
    if (deps == null) return;
    final mgr = deps.agentMgr;

    await mgr.archiveCurrent(AIEngine.kGlobalServerId);
    if (!mounted) return;
    final archive = await mgr.takeById(id);
    if (!mounted) return;
    if (archive == null) {
      // 那一段在别处被删了，或者 archive 反序列化失败。刷新列表让用户看到
      // 现状，而不是切进一个空会话让他以为内容丢了。
      final rows = await mgr.sessionsFor(AIEngine.kGlobalServerId);
      if (!mounted) return;
      setState(() => _sessions = rows);
      return;
    }
    mgr.seedRestore(AIEngine.kGlobalServerId, archive);
    mgr.closeLoop(AIEngine.kGlobalServerId);
    if (!mounted) return;
    final loop = await _ensureLoop();
    if (loop == null || !mounted) return;
    setState(() {
      _loop = loop;
      _showHistory = false;
    });
    unawaited(_refreshRecentSessions());
  }

  /// 导出历史里的某一段。**不切换当前会话** —— 用户想导出旧会话时，多半不
  /// 想因此丢掉眼前正在跑的这一段。
  ///
  /// 取数来源判断（活跃段走内存、其余回表）收在 `exportEventsFor` 里，
  /// 与 `ai_panel.dart` 共用一份 —— 静默的数据缺失比少一个入口糟糕得多。
  /// 用 `archiveById` 而不是 `takeById`：后者会把这一行认领为活跃段，导致
  /// 当前正在跑的会话之后的落盘错位到这一行上。
  Future<void> _exportSession(int id) async {
    final deps = _deps;
    if (deps == null) return;
    final mgr = deps.agentMgr;
    // 取数来源的判断收在 `exportEventsFor` 里，与终端页 AI 面板共用一份。
    // 全局会话的活跃段 id 用 `kGlobalServerId` 查。
    final activeRowId = mgr.activeRowIdFor(AIEngine.kGlobalServerId);
    final isActive = activeRowId == id && _loop != null;

    final archive = isActive ? null : await mgr.archiveById(id);
    if (!mounted) return;
    // 这一行已不存在：原行为是直接不动作。
    if (!isActive && archive == null) return;

    final source = exportEventsFor(
      id: id,
      activeRowId: isActive ? id : null,
      liveEvents: isActive ? _loop!.events : const [],
      archive: archive,
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExportPreviewScreen(
          events: source.events,
          // 活跃段沿用改造前 `_exportCurrent` 的固定名；历史某段用 `session_$id`。
          filenameHint: isActive ? 'global_session' : 'session_$id',
        ),
      ),
    );
  }

  /// 「在服务器上执行」：选一台机器，把命令投进槽，再进那台机器的终端。
  ///
  /// 这是全局 AI tab 不沦为玩具的关键一步 —— 从「问 AI」到「真的跑起来」
  /// 是两步，不是让用户自己复制粘贴。
  ///
  /// 打开某台机器的终端（入口区机器 chip 的动作）。
  ///
  /// 与 `_runOnServer` 同一条路径（`TerminalScreen(initialServer:)`）——
  /// `_connectServer` 在 `forceNew == false` 时会**复用现有 tab**，所以已连的
  /// 机器不会开出重复 tab，只是切过去。
  ///
  /// 查不到就静默不动作：机器可能在渲染到点击之间被删掉，为这个窄窗口弹错
  /// 不值得。
  void _openTerminal(String machineId) {
    Server? target;
    for (final s in _servers) {
      if (s.id == machineId) {
        target = s;
        break;
      }
    }
    if (target == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TerminalScreen(initialServer: target)),
    );
  }

  /// 命令**不在这里发送**：投槽之后由 `TerminalScreen` 取走并走它那条带
  /// 高危命令拦截的 `_runCommand`。见 `SessionManager.stageCommand` 的 dartdoc。
  Future<void> _runOnServer(String command) async {
    final servers = await context.read<ServerRepository>().findAll();
    if (!mounted) return;
    final sessions = context.read<SessionManager>();

    bool isLive(Server s) => sessions.activeTabForServer(s.id) != null;

    final candidates = servers.where((s) => s.serverType == 'ssh').toList()
      ..sort((a, b) {
        // 已连接的排前面 —— 那是用户最可能想执行的地方，也是唯一不用等
        // 握手的。
        if (isLive(a) != isLive(b)) return isLive(a) ? -1 : 1;
        final at = a.lastConnectedAt;
        final bt = b.lastConnectedAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });

    if (candidates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.noServers)));
      return;
    }

    final picked = await showModalBottomSheet<Server>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                ctx.l10n.aiRunOnServer,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (_, i) {
                  final s = candidates[i];
                  return ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(s.name),
                    subtitle: Text('${s.username}@${s.host}:${s.port}'),
                    trailing: isLive(s)
                        ? const Icon(
                            Icons.circle,
                            size: 8,
                            color: Color(0xFF00C896),
                          )
                        : null,
                    onTap: () => Navigator.pop(ctx, s),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (picked == null || !mounted) return;
    sessions.stageCommand(picked.id, command);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TerminalScreen(initialServer: picked)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final agent = _agentReady;
    // 闸门检查 + （必要时）发起创建。放在 `build()` 顶部而不是
    // `didChangeDependencies`：provider 配置是运行期随时可能变化的
    // （`_switchModel` 配完模型会 `setState(() {})` 触发重建），只有每次
    // build 都重新检查一次，才能在"刚配完模型、agent 从不可用变可用"这一刻
    // 跟上——这也是为什么闸门本身（`_loopRequested`）而不是调用时机才是
    // 真正防止重复发起的机制。
    _requestLoopIfNeeded();
    // 当前模型名。与终端页面板同源（`AIProvider.displayName`），保证两处的
    // 第二行文字一致。可空：没配 provider 时是 null（直连模式也会提示未配置）。
    final modelLabel = context.watch<AIProviderService>().provider?.displayName;
    return Scaffold(
      appBar: AppBar(
        // 模型切换入口与终端页 AI 面板**同一个组件**，不再用 `Icons.tune`
        // 裸图标 —— 两处必须长得一样，且标题区顺手把「当前用哪个模型」
        // 常驻显示出来（原来全局页根本不显示，用户跑半天不知道用的哪个）。
        title: ModelTitleTile(
          title: l.aiAssistant,
          modelLabel: modelLabel,
          onSwitchModel: _switchModel,
        ),
        automaticallyImplyLeading: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        // 第一行 `titleMedium` + 第二行 `labelSmall` 比默认 AppBar 标题高，
        // 不加高会溢出。与包住它的两行结构对齐。
        toolbarHeight: 64,
        // agent / direct 两种模式的头部按钮不同：agent 模式有「归档 + 历史」
        // 这套会话管理，是搬自 `ai_panel.dart` `PanelHeader` 的范式（**去掉了
        // 导出** —— 用户反馈首页不需要；导出仍在历史列表每行与终端页面板里）；
        // direct 模式没有会话归档这个概念（历史就在 `AIEngine` 里），
        // 只留「清空历史」一个按钮。
        //
        // 两个分支原来的那个 `Icons.tune`（切模型）图标已删除：切模型入口
        // 现在是上面的标题区，图标与它重复。
        actions: agent
            ? [
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: l.aiSessionHistory,
                  // 开关：进了列表得有退路，再点一次这个图标就回到对话。
                  // 照搬 `ai_panel.dart` `onHistory` 的写法。
                  onPressed: () {
                    if (_showHistory) {
                      setState(() => _showHistory = false);
                    } else {
                      // fire-and-forget：按钮回调，失败路径在 _openHistory
                      // 里自己处理。
                      _openHistory();
                    }
                  },
                ),
                IconButton(
                  // 不用垃圾桶图标 —— 这个动作是「归档当前 + 开新的」，不是
                  // 「删除」，理由见 `ai_panel.dart` `onClear` 图标上的注释。
                  icon: const Icon(Icons.add_comment_outlined),
                  tooltip: l.aiNewSession,
                  onPressed: () {
                    // fire-and-forget：按钮回调，归档失败已经在
                    // archiveCurrent 内部吞掉并记了日志。
                    _clear();
                  },
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l.aiGlobalClearHistory,
                  onPressed: () {
                    // fire-and-forget：direct 分支里 `_clear` 同步完成
                    // （`_engine.clearHistory()` 不是 async），但签名已经统一
                    // 成 `Future<void>`，这里和 agent 分支保持同一种调用方式。
                    _clear();
                  },
                ),
              ],
      ),
      body: _buildBody(agent),
    );
  }

  Widget _buildBody(bool agent) {
    final l = context.l10n;
    // 历史列表放在最前面判断：无论对话是否已经开始，只要用户点开了历史就
    // 优先显示它。与 `ai_panel.dart` 的 `_buildBody` 同一个判断顺序。
    if (agent && _showHistory) {
      return SessionHistoryView(
        sessions: _sessions,
        onOpen: (id) {
          // fire-and-forget：按钮回调。失败路径在 _openSession 里自己处理。
          _openSession(id);
        },
        onToggleStar: (id, v) async {
          await _deps!.agentMgr.setStarred(id, v);
          // 重读表而不是就地改内存那份 —— 标星会影响滚动删除的配额，重读
          // 才能看到真实结果。理由与 `ai_panel.dart` 同名回调相同。
          await _openHistory();
          unawaited(_refreshRecentSessions());
        },
        onDelete: (id) async {
          await _deps!.agentMgr.deleteSession(id);
          await _openHistory();
          unawaited(_refreshRecentSessions());
        },
        onExport: (id) {
          // fire-and-forget：按钮回调。
          _exportSession(id);
        },
        // 全局 tab 的额度比普通服务器宽（100 vs 50）。写死常量会让这边显示
        // 一个与实际保留数不符的数字。
        quota: kSessionsGlobal,
      );
    }
    if (agent) {
      final loop = _loop;
      if (loop == null) {
        // `build()` 顶部的 `_requestLoopIfNeeded()` 已经（在尚未发起过的
        // 前提下）发起了创建；这里只负责在它就绪之前给一个反馈，而不是让
        // 用户盯着一屏空白猜 App 是不是卡死了。真正建不出来的情形
        // （provider 树不完整）`agent` 本身就是 false，走不到这一支。
        return const Center(child: CircularProgressIndicator());
      }
      final svc = context.read<AIProviderService>();
      return AgentView(
        loop: loop,
        providerName: svc.provider?.displayName ?? '',
        scrollController: _scrollController,
        servers: _servers,
        hasOtherServers: _servers.any((s) => s.serverType == 'ssh'),
        bypassMode:
            _deps!.agentMgr.modeFor(AIEngine.kGlobalServerId) ==
            PermissionMode.bypass,
        onOpenJobs: kShowJobBoard
            ? () => Navigator.pushNamed(context, '/jobs')
            : null,
        // `@file` 的目录列举与 `~` 解析。
        //
        // 与终端页那两个同名回调的唯一区别是 **`serverId` 为 null 时没有可
        // 去处**：那边 null 表示「当前会话那台机」，而全局会话压根没有「当前
        // 这台」。返回空列表而不是抛 —— `@` 浮层会因此只少掉文件分组，机器
        // 名分组照常显示，用户选一台之后浮层带上 `<机器名>:` 前缀再回调进来，
        // serverId 就非 null 了（见 `mention.dart` 里 RemoteDirLister 的文档）。
        //
        // 这条路径正好和工具层「`server` 参数必填」是同一套心智：全局会话里
        // 要碰哪台机器，都得先说清楚是哪台。
        listRemoteDir: (dir, {serverId}) async {
          final ops = await _opsForServerId(serverId);
          if (ops == null) return const [];
          final names = await ops.listdir(dir);
          return [
            for (final n in names)
              if (n.filename != '.' && n.filename != '..')
                SftpEntry.fromSftpName(n, dir),
          ];
        },
        // **不能直接把 `~` 丢给 REALPATH** —— SFTP 不是 shell，OpenSSH 的
        // sftp-server 不展开 `~`，`absolutePath('~/.ssh')` 会返回
        // `<cwd>/~/.ssh` 这种拼出来的废路径。而 SFTP 会话的起点就是登录用户
        // 的 home，所以用 `.` 求出 home 再做字符串替换。
        resolveRemotePath: (path, {serverId}) async {
          final ops = await _opsForServerId(serverId);
          // 解析不了就把原样退回去。调用方（`mention_field._loadDir`）对
          // 「解析失败」已有降级路径（提示需要绝对路径），这里抛异常只会让
          // 它走更粗糙的那条 catch。
          if (ops == null) return path;
          final home = await ops.absolutePath('.');
          if (path == '~') return home;
          if (path.startsWith('~/')) return '$home/${path.substring(2)}';
          return ops.absolutePath(path);
        },
        // 知识提议卡「存入」的 skill 分支：这是改造前就有的缺口（那时叫
        // `onWriteAgentsMd`），不是本轮回归，但顺手接上——全局会话没有
        // 「当前这台机器」，`save_skill` 本来就是跨机的，不需要机器归属，
        // 接上只是几行。用户点「存入」之前一直吃一个裸的 `Bad state:
        // onSaveSkill 未装配` SnackBar。
        onSaveSkill: (name, description, body) => _deps!.skills.save(
          name: name,
          description: description,
          body: body,
          source: SkillSource.ai,
        ),
        // `onWriteMachineNotes` 故意不接。`KnowledgeTarget.serverNote` 的
        // 候选要写去某一台机器的 `server_notes` 行，但 `KnowledgeCandidate`
        // 没有携带机器信息（见 `knowledge.dart`）——全局会话本身也没有
        // 「当前这台」的概念。接一个瞎猜的落点（比如「最近连过的那台」）
        // 比保持现状的报错更危险：报错至少不会把笔记写错机器。真要支持，
        // 得先在提炼/候选阶段给 serverNote 候选附上 serverId，这是一次
        // 独立的改动，不在本轮范围内。
        attachmentStore: _deps!.attachments,
        attachmentFileFor: _deps!.attachments?.fileFor,
        attachmentServerId: AIEngine.kGlobalServerId,
        // 空状态降格成事件流区域的占位内容（方案 B）——输入框不在这里面，
        // 它由 `AgentView` 自己常驻在底部，`send` 直接走 `loop.send`，与手输
        // 同一条路径。
        emptyBuilder: (send) => ListenableBuilder(
          // 只包住入口区：连接状态要活（●/○），但不让整页在每次连接/断开时重建。
          listenable: context.read<SessionManager>(),
          builder: (_, __) {
            final sessions = context.read<SessionManager>();
            return AiLaunchpad(
              title: l.aiGlobalAgentEmptyTitle,
              recentSessions: _recentSessions,
              machines: _machinesNow(sessions),
              totalMachineCount: _sshTotal,
              suggestions: _suggestionsNow(sessions),
              onOpenSession: _openSession,
              onOpenMachine: _openTerminal,
              onSend: send,
            );
          },
        ),
      );
    }
    return DirectChatView(
      engine: _engine,
      onRunCommand: _runOnServer,
      // 同上：空状态降格成消息列表区域的占位内容，输入框始终在底部。
      emptyBuilder: (send) => _EmptyState(
        title: l.aiGlobalEmptyTitle,
        suggestions: [
          l.aiGlobalSuggest1,
          l.aiGlobalSuggest2,
          l.aiGlobalSuggest3,
        ],
        onPick: send,
      ),
    );
  }
}

/// 还没开始对话时的引导页：一句话 + 三个建议 chip。
///
/// 文案由宿主传入 —— agent 与 direct 两种模式的开场白不同（「想看哪台机器」
/// vs「有什么可以帮你」），但布局完全一样，没有理由写两份。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.suggestions,
    required this.onPick,
  });

  final String title;
  final List<String> suggestions;
  final void Function(String) onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 40,
              color: cs.primary.withOpacity(0.7),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 24),
            for (final s in suggestions)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ActionChip(label: Text(s), onPressed: () => onPick(s)),
              ),
          ],
        ),
      ),
    );
  }
}
