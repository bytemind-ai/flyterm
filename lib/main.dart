// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'util/dlog.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'ai/ai_provider_service.dart';
import 'ai/ai_provider.dart';
import 'ai/attachment_store.dart';
import 'ai/providers/provider_http.dart';
import 'ai/agent/agent_events.dart';
import 'ai/agent/agent_session_manager.dart';
import 'ai/agent/agent_skill_manager.dart';
import 'ai/agent/ai_command_manager.dart';
import 'ai/agent/builtin_skill_manager.dart';
import 'ai/agent/server_notes_manager.dart';
import 'ai/agent/approval_notification.dart';
import 'ai/voice_input_service.dart';
import 'data/database.dart';
import 'data/keybar_settings.dart';
import 'data/secure_storage.dart';
import 'data/terminal_settings.dart';
import 'data/repositories/agent_session_repository.dart';
import 'data/repositories/agent_skill_repository.dart';
import 'data/repositories/ai_provider_repository.dart';
import 'data/repositories/favorite_command_repository.dart';
import 'data/repositories/known_host_repository.dart';
import 'data/repositories/mosh_process_repository.dart';
import 'data/repositories/server_notes_repository.dart';
import 'data/repositories/server_repository.dart';
import 'data/repositories/ssh_key_repository.dart';
import 'data/repositories/tab_session_repository.dart';
import 'data/repositories/tunnel_repository.dart';
import 'l10n/app_localizations.dart';
import 'ssh/host_key_verifier.dart';
import 'ssh/session_manager.dart';
import 'ssh/transport/composite_transport_factory.dart';
import 'ssh/transport/transport_factory.dart';
import 'ssh/reconnect_service.dart';
import 'ssh/foreground_service.dart';
import 'ssh/keep_alive_controller.dart';
import 'ssh/notification_service.dart';
import 'ssh/ssh_connection_pool.dart';
import 'tunnel/tunnel_manager.dart';
import 'ssh/mosh_connection.dart';
import 'ui/dialogs/host_key_dialog.dart';
import 'ui/notifications/notify_orchestrator.dart';
import 'ui/terminal/split_manager.dart';
import 'app_control/app_control_service.dart';
import 'consent/consent_manager.dart';
import 'telemetry/sentry_init.dart';
import 'telemetry/crash_zone.dart';
import 'ssh/aqt/aqt_session_state.dart';
import 'ssh/aqt/aqt_transport_factory.dart';
import 'ssh/aqt/resume_issue_log.dart';
import 'ssh/aqt/prewarm_pool.dart';
import 'ssh/aqt/session_resume_coordinator.dart';
import 'ssh/aqt/aqt_ffi.dart' show AqtRestored, AqtTabGone;

/// C4 — Master switch for cold-start RESUME prewarm.
const bool kColdStartPrewarm = true;

/// Global navigator key — owned by the MaterialApp in [App]. Lets the
/// SSH layer surface dialogs (e.g. the host-key TOFU prompt) without
/// having to thread a BuildContext through every connect call site.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.black,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Phase 0.1：先 load 同意状态（决定 Sentry 是否启用），然后 fire-and-forget
  // 启动 Sentry —— Sentry SDK init 涉及网络握手 ~100-300ms，撑了首帧。
  // crash_zone.dart 注释：Sentry.captureException 在未 init 时是 no-op，
  // 早期事件捕不到是可接受 trade-off。
  await ConsentManager.instance.load();
  unawaited(initSentryIfAllowed());
  await runWithCrashCapture(() async {
    try {
      await _initApp();
    } catch (e, st) {
      dlog('Startup', 'FlyTerm startup error: $e\n$st');
      runApp(_StartupErrorApp(error: '$e'));
    }
  });
}

Future<void> _initApp() async {
  SshForegroundService.init();
  await NotificationService.init();

  final db = await AppDatabase.open();
  final storage = SecureStorageService();
  final terminalSettings = TerminalSettings(storage);
  final keybarSettings = KeybarSettings();
  // 提成变量而不是在 provider 里内联 new：AppControlService 的 layout_set
  // 工具要操作同一个实例，两处各建一个会让 AI 改的布局和 UI 显示的对不上。
  final splitManager = SplitManager();
  // S2 — parallelize independent disk reads.
  await Future.wait([
    terminalSettings.load(),
    keybarSettings.seedIfEmpty(),
  ]);

  // 后台保活：把 TerminalSettings.backgroundKeepAlive 同步进前台服务。
  //
  // 这段接线曾经被有意拔掉过（开关留在设置页、但没有任何消费者），后果不
  // 只是「通知栏少一条」—— 前台服务是「app 切后台后 QUIC 连接还活着」的
  // 唯一依靠，也就是锁屏通知能收到的前提。开关关着而用户以为开着，等于
  // 整个通知功能不可用。现在恢复，并把同步逻辑抽到 `KeepAliveController`
  // （可注入、有测试，不再靠人肉读这段装配代码）。
  //
  // 必须在下面 terminal_screen / reconnect_service 任何一次
  // `startOrUpdate()` 之前完成首次 apply —— 否则首次连接时 `_enabled` 还
  // 是 false，那次连接不会起服务，要等到用户切一次设置才生效。
  final keepAlive = KeepAliveController(service: const SshForegroundServicePort());
  await keepAlive.apply(keepAlive: terminalSettings.backgroundKeepAlive);
  // 通用 listener（不是只监听 keepAlive 字段）：`apply` 自己幂等，值没变
  // 时完全不碰服务，所以不必在这个回调里过滤。
  terminalSettings.addListener(() {
    keepAlive.apply(keepAlive: terminalSettings.backgroundKeepAlive).ignore();
  });

  final serverRepo = ServerRepository(db);
  final moshProcessRepo = MoshProcessRepository(db);
  final keyRepo = SSHKeyRepository(db);
  final tabSessionRepo = TabSessionRepository(db);

  // Restore saved tabs (Chrome-style: reopen last session on launch).
  // S2 — fan out findById across all saved tabs in parallel instead of
  // running N serial DB queries. sqflite handles concurrent reads on the
  // same Database via its serialized queue, so order is preserved.
  final savedTabs = await tabSessionRepo.load();
  final servers = await Future.wait(
    savedTabs.map((r) => serverRepo.findById(r.serverId)),
  );
  final List<TabRestoreEntry> restoreEntries = [];
  int savedActiveIdx = 0;
  for (var i = 0; i < savedTabs.length; i++) {
    final server = servers[i];
    if (server == null) continue; // server deleted — skip stale record
    final record = savedTabs[i];
    restoreEntries.add(
      TabRestoreEntry(
        tabId: record.id,
        server: server,
        tmuxKey: record.tmuxKey,
        sftpLastPath: record.sftpLastPath,
      ),
    );
    if (record.isActive) savedActiveIdx = restoreEntries.length - 1;
  }

  // Kill any mosh-server processes that survived a previous crash/force-quit.
  _cleanOrphanedMoshPids(serverRepo, moshProcessRepo, storage);

  final aiProviderRepo = AIProviderRepository(db);
  final favCmdRepo = FavoriteCommandRepository(db);
  final prefs = await SharedPreferences.getInstance();

  final transportFactory = CompositeTransportFactory();

  final sessionManager = SessionManager(
    prefs: prefs,
    tabSessionRepo: tabSessionRepo,
    transportFactory: transportFactory,
  );
  if (restoreEntries.isNotEmpty) {
    sessionManager.restoreFromSaved(restoreEntries, savedActiveIdx);
  }

  // 用户在一段**已连上**的会话里打开保活开关时，要立刻起服务，而不是等到
  // 下一次连接（那等于「我开了但它没反应」）。取当前活跃 tab 的服务器名；
  // `startOrUpdate` 自己会判断服务是否已在跑（在跑就只更新文字）。
  keepAlive.setSessionStarter(
      () => sessionManager.activeTab?.server.name ??
          (sessionManager.tabs.isNotEmpty
              ? sessionManager.tabs.first.server.name
              : null));

  // AqtSessionStore（Keychain 里存 JSON blob）已删除，QUIC 会话
  // 状态现在是单一入口 AqtSessionStateRepository（token 走 secure storage，
  // 其余字段走 SQLite `aqt_session_state`，见该类文档）。这里构造一次，
  // _prewarmAqtSession 与 ReconnectService 共用同一个实例——避免出现
  // "改了一处存储忘了另一处"的半吊子更新。
  final aqtSessionStateRepo =
      AqtSessionStateRepository(db, FlutterAqtSecureStore());

  // 服务端推送通知的 widget 层编排。必须在下面 ReconnectService.reconnectAll()
  // /任何 QUIC 连接建立之前 start()，否则 AqtTransport.onNotify 触发时
  // SessionManager 上还没有监听者，事件会被静默丢弃在 registerAqtTab 的
  // 转发调用里（cb 列表为空，没人处理，也不会报错——这类"注册晚了"的问题
  // 不会在测试里报错，只会在真机上表现为"通知没出现"，所以刻意提前到这里）。
  final notifyOrchestrator = NotifyOrchestrator(
    sessionManager: sessionManager,
    navigatorKey: appNavigatorKey,
  )..start();

  // RESUME 的唯一发起入口。挂在 sessionManager 上，让 prewarm 与
  // ReconnectService 的各条重连路径共享同一个实例 —— 合并只有在共享实例时
  // 才成立。
  //
  // doResume 内部把成功的 transport 交给 prewarmPool，调用方用 take() 取走。
  // 这样职责分明：coordinator 决定「发不发」，pool 决定「谁拿到」。多个调用
  // 方合并成一次 RESUME 后只有一条 transport，take 的移交语义保证不会出现
  // 双重所有权。
  // late：下面的 resume coordinator 要用它开 SSH 通道，而它在更后面才构造。
  late final ReconnectService reconnectService;
  sessionManager.resumeCoordinator = SessionResumeCoordinator(
    doResume: (tabId) async {
      final st = await aqtSessionStateRepo.load(tabId);
      if (st == null) {
        // 没有可用的会话凭据 —— 对调用方而言等价于「服务端说会话没了」：
        // 都该去开新会话，而不是等一个不会到来的恢复。
        return ResumeOutcome.newSession();
      }
      final tab = sessionManager.tabs.where((t) => t.id == tabId).firstOrNull;
      final host = tab?.server.host;
      if (host == null) return ResumeOutcome.newSession();

      final seq = appendResumeIssue(site: 'coordinator', tabId: tabId);
      final r = await AqtTransportFactory.tryResumeWithInfoDetailed(
        host: host,
        port: st.port,
        spki: Uint8List.fromList(st.spki),
        sessionToken: Uint8List.fromList(st.sessionToken),
        tabId: st.aqtTabId,
        // budget 由这里统一决定，不接受调用方传入 —— 两个不同 budget 的
        // 请求被合并时用谁的？没有好答案。统一之后这个问题不存在。
        budget: const Duration(seconds: 5),
        route: st.route,
        openRelay: (p) => reconnectService.openAqtRelay(tab!, p),
      );
      switch (r) {
        case AqtResumeSuccess(:final transport):
          appendResumeResult(
            seq: seq,
            outcome: 'OK',
            replayBytes: transport.lastResumeScreenBytes,
          );
          final d = transport.takeResumeDisposition();
          // transport 交给 pool，由 take() 移交给第一个来取的调用方。
          sessionManager.prewarmPool.store(tabId, transport);
          return switch (d) {
            AqtRestored() => ResumeOutcome.restored(),
            AqtTabGone(:final exitStatus) =>
              ResumeOutcome.tabGone(exitStatus: exitStatus),
            _ => ResumeOutcome.newSession(),
          };
        case AqtResumeFailed(:final reason):
          appendResumeResult(seq: seq, outcome: 'FAIL ${reason.name}');
          // 失效凭据要就地清掉，否则下次冷启动还会拿它先试一次必然失败的
          // RESUME（白等一个超时）。判据只认这两种「服务端身份已变」：
          //
          //   sessionNotFound  服务端明确说 session 没了（daemon 重启 / tab 关闭）
          //   handshakeFailed  TLS 握手失败，通常是 SPKI 变了（daemon 重启换了 cert）
          //
          // networkTimeout / unknown 保留凭据 —— 那可能只是网络差，凭据还有效，
          // 删了反而逼用户重新走一遍 SSH bootstrap。
          //
          // 这段逻辑原本长在 ReconnectService 的 coldHydrate 分支里，只有那
          // 一条路径受益。挪进 doResume 之后所有发起点共享同一套判断 ——
          // 「什么时候该丢弃凭据」本来就不该各处各写一份。
          if (reason == AqtResumeFailReason.sessionNotFound ||
              reason == AqtResumeFailReason.handshakeFailed) {
            await aqtSessionStateRepo.remove(tabId);
          }
          // 连不上 ≠ 会话没了。但对调用方来说这一轮没拿到 transport，
          // 后续该走它自己的回退链（SSH / 新建会话）。
          return ResumeOutcome.newSession();
      }
    },
  );

  // C4 — Fire-and-forget RESUME for the last-active QUIC tab during
  // app startup. By the time the user reaches terminal_screen the
  // transport may already be connected → 0s perceived RESUME.
  if (kColdStartPrewarm && restoreEntries.isNotEmpty) {
    final firstEntry = restoreEntries[savedActiveIdx];
    if (firstEntry.server.transport == Transport.quic) {
      unawaited(_prewarmAqtSession(
        tabId: firstEntry.tabId,
        pool: sessionManager.prewarmPool,
        coordinator: sessionManager.resumeCoordinator!,
      ));
    }
  }

  final initialRoute = restoreEntries.isNotEmpty ? '/terminal' : '/home';

  final knownHostRepo = KnownHostRepository(db);
  final hostKeyVerifier = DefaultHostKeyVerifier(
    repo: knownHostRepo,
    prompt: ({
      required String host,
      required int port,
      required String keyType,
      required String fingerprintMd5,
      required HostKeyPromptKind kind,
      String? expectedFingerprintMd5,
    }) async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) {
        // App not yet rendered (shouldn't happen — verifier only fires
        // mid-connection, after MaterialApp is mounted). Fail closed.
        return HostKeyDecision.reject;
      }
      return HostKeyDialog.show(
        ctx,
        host: host,
        port: port,
        keyType: keyType,
        fingerprintMd5: fingerprintMd5,
        kind: kind,
        expectedFingerprintMd5: expectedFingerprintMd5,
      );
    },
  );

  final sshConnectionPool = SshConnectionPool();

  reconnectService = ReconnectService(
    sessionManager,
    storage,
    serverRepo,
    keyRepo,
    hostKeyVerifier: hostKeyVerifier,
    connectionPool: sshConnectionPool,
    terminalSettings: terminalSettings,
    moshProcessRepo: moshProcessRepo,
    aqtSessionStateRepo: aqtSessionStateRepo,
  )..start();

  // 所有 tab 关闭时停止前台服务
  sessionManager.addListener(() {
    if (sessionManager.tabs.isEmpty) {
      SshForegroundService.stop();
    }
  });

  final aiProviderService = AIProviderService(prefs);

  final attachmentRoot = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/agent_attachments');
  final attachmentStore = AttachmentStore(attachmentRoot);
  final agentSessionRepo = AgentSessionRepository(
    db,
    onAttachmentsOrphaned: attachmentStore.deleteAll,
  );
  final agentSessionManager = AgentSessionManager(prefs, agentSessionRepo);

  // 孤儿附件清扫：不 await，不阻塞启动。纯旁路，失败下次启动再来。
  unawaited(() async {
    try {
      final referenced = await agentSessionRepo.allAttachmentPaths();
      await attachmentStore.sweepOrphans(referenced: referenced);
    } catch (e) {
      dlog('attachments', 'sweep failed: $e');
    }
  }());

  // 这两个 repo 除了喂给 Manager，还被「配置备份」直接用来读写（导出/导入
  // agent_skills 与 server_notes 两张表）。所以它们必须独立注册成 provider ——
  // 2026-10-08 之前是内联构造的，导致 ConfigBackupTile 里
  // `context.read<AgentSkillRepository>()` 抛 ProviderNotFoundException，
  // 导出按钮点了没反应。
  final agentSkillRepo = AgentSkillRepository(db);
  final serverNotesRepo = ServerNotesRepository(db);

  final agentSkillManager = AgentSkillManager(agentSkillRepo);
  await agentSkillManager.reload();

  final serverNotesManager = ServerNotesManager(serverNotesRepo);
  // 顺序要紧：先搬旧缓存再 load，否则刚搬进去的那批这一轮读不到，要等到
  // 下次冷启动才出现在 prompt 里。
  await serverNotesManager.migrateFromPrefs(prefs);
  await serverNotesManager.load();

  final builtinSkillManager = BuiltinSkillManager(prefs);
  await builtinSkillManager.load();

  final aiCommandManager = AiCommandManager(FavoriteCommandRepository(db));
  await aiCommandManager.reload();

  // 旧的单 key 归档搬进表。一次性、幂等（搬完删 key）。放在启动路径上是刻意的：
  // 拖到第一次打开面板才做，会让「升级后立刻打开面板」这条最常见的路径看到空历史。
  await agentSessionManager.migrateLegacyArchives(
    (await serverRepo.findAll()).map((s) => s.id).toList(),
  );

  // 审批通知：复用服务端推送通知建好的展示链路
  // （NotificationService.show / flyterm_events HIGH 频道），只新增这一个
  // 调用点。前台抑制判定用 notifyOrchestrator 的只读 getter；去重发生在
  // AgentSessionManager 内部（进程内 Set，不接 NotifySeenStore —— 审批没
  // 有离线补投语义）。
  //
  // 通知 id 用进程内单调计数器（`ApprovalNotificationIds`），不再用
  // `Object.hash(serverId, seq)` —— 后者可能让两条真实存在的审批撞同一个
  // Android 通知 id，后一条静默覆盖前一条。见 `approval_notification.dart`。
  final approvalIds = ApprovalNotificationIds();
  agentSessionManager.onApprovalPending = (serverId, ev) {
    final appInForeground = notifyOrchestrator.appInForeground;
    if (!shouldNotifyApproval(
      appInForeground: appInForeground,
      visibleServerId: notifyOrchestrator.visibleServerId,
      serverId: serverId,
    )) {
      return;
    }
    unawaited(_showApprovalNotification(
      ids: approvalIds,
      event: ev,
      appInForeground: appInForeground,
    ));
  };

  final voiceInputService = VoiceInputService();
  final tunnelRepo = TunnelRepository(db);
  final tunnelManager = TunnelManager(
    repository: tunnelRepo,
    serverRepo: serverRepo,
  );

  // 必须在 provider 构造之前设置：`IOHttpClientAdapter` 会缓存 HttpClient
  // 实例，之后再翻转这个开关对已存在的 provider 无效。`debugOverlay` 本身
  // 是纯内存开关、不持久化（见 `TerminalSettings.toggleDebugOverlay`），
  // 冷启动时必然是 false —— 这行只是让「provider 构造前读一次 debugOverlay」
  // 这条规则在所有装配路径上保持一致；真正能让计数生效的路径是运行期打开
  // developer mode 后，走 `switchProvider()`（`provider_switch.dart`）切一次
  // 模型。
  debugCountConnections = terminalSettings.debugOverlay;

  // Load default AI provider at startup
  final defaultConfig = await aiProviderRepo.findDefault();
  if (defaultConfig != null) {
    final apiKey = await storage.loadAIKey(defaultConfig.id) ?? '';
    if (apiKey.isNotEmpty || defaultConfig.type == 'ollama') {
      aiProviderService.setProvider(
        AIProviderFactory.create(defaultConfig, apiKey),
      );
    }
  }

  // Voice input is initialized lazily when the user taps the microphone.
  // Initializing at startup can trigger/consume the runtime permission flow
  // without UI context, then leave the mic button in an unavailable state with
  // no guidance. Keep startup silent and handle permission prompts on demand.

  runApp(
    MultiProvider(
      providers: [
        // `GlobalAIScreen` 自己造全局 AIEngine 要用它。之前没挂是因为所有
        // 需要 prefs 的服务都在 main 里构造好再 .value 进来；全局 AI 的
        // engine 由页面持有（页面 dispose 时要 saveHistory），所以得让页面
        // 能拿到 prefs。
        Provider<SharedPreferences>.value(value: prefs),
        Provider<TransportFactory>.value(value: transportFactory),
        Provider.value(value: db),
        ChangeNotifierProvider.value(value: terminalSettings),
        ChangeNotifierProvider.value(value: keybarSettings),
        Provider.value(value: storage),
        Provider.value(value: serverRepo),
        Provider.value(value: moshProcessRepo),
        Provider(create: (_) => SSHKeyRepository(db)),
        Provider.value(value: aiProviderRepo),
        Provider.value(value: favCmdRepo),
        ChangeNotifierProvider.value(value: sessionManager),
        ChangeNotifierProvider.value(value: aiProviderService),
        Provider.value(value: attachmentStore),
        ChangeNotifierProvider.value(value: agentSessionManager),
        ChangeNotifierProvider.value(value: agentSkillManager),
        ChangeNotifierProvider.value(value: builtinSkillManager),
        Provider.value(value: agentSkillRepo),
        ChangeNotifierProvider.value(value: serverNotesManager),
        Provider.value(value: serverNotesRepo),
        ChangeNotifierProvider.value(value: aiCommandManager),
        ChangeNotifierProvider.value(value: voiceInputService),
        Provider.value(value: reconnectService),
        Provider.value(value: knownHostRepo),
        Provider<HostKeyVerifier>.value(value: hostKeyVerifier),
        Provider<SshConnectionPool>.value(value: sshConnectionPool),
        Provider.value(value: tunnelRepo),
        ChangeNotifierProvider.value(value: tunnelManager),
        ChangeNotifierProvider.value(value: splitManager),
        ChangeNotifierProvider.value(value: ConsentManager.instance),
        // app 自身控制的门面。**进程级单例** —— 撤销栈跟着全局走，见
        // AgentAssemblyDeps.appControl 的注释。
        //
        // 注册为可空类型：agent_assembly 用 `context.read<AppControlService?>()`
        // 读它，与 TerminalSettings? / AttachmentStore? 同一写法，让不搭这个
        // provider 的 widget 测试不至于抛 ProviderNotFoundException。
        Provider<AppControlService?>.value(
          value: AppControlService(
            settings: terminalSettings,
            servers: serverRepo,
            sessions: sessionManager,
            tunnels: tunnelManager,
            keybar: keybarSettings,
            storage: storage,
            layout: splitManager,
            keys: keyRepo,
            commands: favCmdRepo,
            commandManager: aiCommandManager,
            skills: agentSkillManager,
            knownHosts: knownHostRepo,
            // 不插这一行，deleteServer 的两件事会静默失效：删完机器后内存
            // 缓存里那条笔记还在（总览列表显示一条删不掉的幽灵），而 undo
            // 也恢复不回笔记 —— 可它的类文档承诺的是「整个 Server 原样
            // 写回」。字段可空是为了测试好构造，不是说生产可以不传。
            serverNotes: serverNotesManager,
          ),
        ),
      ],
      child: App(initialRoute: initialRoute),
    ),
  );

  // Non-blocking: connect restored tabs (ReconnectService handles first-time
  // connections the same as reconnections — startup command runs on first connect).
  if (restoreEntries.isNotEmpty) reconnectService.reconnectAll();

  // Non-blocking: loads saved tunnels and reconnects autoStart ones
  tunnelManager.restoreFromDb(serverRepo, storage);

  // Android 13+ 运行时通知权限。放在 runApp 之后、fire-and-forget——拒绝
  // 也不影响首帧，只是退化为"前台 SnackBar 仍工作，后台系统通知不出现"。
  unawaited(NotificationService.requestPermission());
}

/// 审批通知的标题。
///
/// `ask_user` 要单独处理：它的 [ToolCallEvent.description] 被复用成分类标签
/// （见该字段的 dartdoc），不是「模型给的这次调用的说明」。这里若沿用旧逻辑
/// `ev.description.isEmpty ? 'FlyTerm' : ev.description`，通知标题会变成裸的
/// 一个分类词（比如「实例」），配合副标题「ask: 先处理哪个？」，反而比这次
/// 改动之前（标题恒为 `'FlyTerm'`）更让人摸不着头脑——`ask_user` 根本不是
/// 「需要批准」，它是在等一个回答。所以 ask_user 走独立文案：已有的
/// l10n 键 `agentAwaitingAnswer`（「等你回答」）。这里没有 `BuildContext`
/// （回调挂在 `_initApp` 里，早于 `runApp`），拿不到 `AppLocalizations.of`，
/// 只能用 `lookupAppLocalizations` 按系统 locale 直查；查不到（不支持的
/// locale）时退回 `'FlyTerm'`，也不能显示裸标签。
String _approvalNotificationTitle(ToolCallEvent ev) {
  if (ev.toolName == 'ask_user') {
    try {
      final locale = WidgetsBinding.instance.platformDispatcher.locale;
      return lookupAppLocalizations(locale).agentAwaitingAnswer;
    } catch (_) {
      return 'FlyTerm';
    }
  }
  return ev.description.isEmpty ? 'FlyTerm' : ev.description;
}

/// 弹一条审批通知，并在系统通知弹不出来时降级为应用内提示。
///
/// ## 为什么要看 [NotificationService.show] 的返回值
///
/// `false` 表示「确定弹不出来」（权限被拒 / 频道被关），而 Android 的
/// `notify()` 在这种情况下**不抛异常**——把「没抛异常」当成「已展示」正是
/// QUIC notify 路径专门堵过的洞（见 `notify_orchestrator.dart`）。审批这条路
/// 之前用 `unawaited(...)` 把返回值丢了，于是权限被拒时审批通知静默消失、
/// 没有任何前台降级，用户只看到 agent 停在那里。
///
/// 审批没有离线补投语义（进程重启 loop 就没了），所以补偿只能是「当场改用
/// 应用内提示」——见 [shouldFallbackToInApp]。后台时不降级（提示挂在用户看
/// 不见的页面上，解决不了任何事），审批卡本身还在面板里等着。
Future<void> _showApprovalNotification({
  required ApprovalNotificationIds ids,
  required ToolCallEvent event,
  required bool appInForeground,
}) async {
  final shown = await NotificationService.show(
    eventId: ids.next(),
    text: _approvalNotificationTitle(event),
    subtitle: event.displayCommand,
    // agent 会话绑服务器不绑 tab，既有深链是按 tab 找的。
    // v1 点通知只唤起 app，不跳转到具体会话。
    tabId: null,
  );
  if (!shouldFallbackToInApp(
    systemNotificationShown: shown,
    appInForeground: appInForeground,
  )) {
    return;
  }
  final ctx = appNavigatorKey.currentContext;
  // `ctx.mounted` 而不只是 `ctx == null`：这是 `await` 之后的异步间隙，用户
  // 可能在这一帧里退出了 app / pop 掉了整个页面树 —— 那时 currentContext 仍
  // 非 null，但元素已从树上摘下，对它 showSnackBar 会抛。
  if (ctx == null || !ctx.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(ctx);
  messenger?.showSnackBar(SnackBar(
    content: Text(
      '${_approvalNotificationTitle(event)}\n${event.displayCommand}',
    ),
    duration: const Duration(seconds: 5),
  ));
}

/// C4 — 冷启动时为「上次活跃的那个 QUIC tab」在后台发起恢复。
///
/// 由 [_initApp] fire-and-forget 调用。成功的话用户走到 terminal_screen 时
/// transport 已经连上，感知延迟为 0。
///
/// 这里曾经自己 claim / 发 RESUME / release，用 [PrewarmPool.claimColdResume]
/// 跟 `reconnectAll()` 的 cold-hydrate 分支做两方去重 —— 生产日志里 23 次
/// 同秒双连接就是没有它之前的样子。那套 claim 现在被 coordinator 取代：
/// 去重从「两方约定」变成「所有发起点共享一个 in-flight」，而且
/// coordinator 不需要调用方记得 release（whenComplete 里自己清）。
///
/// **transport 仍然经 pool 移交**：coordinator 只合并发起，不管所有权。
Future<void> _prewarmAqtSession({
  required String tabId,
  required PrewarmPool pool,
  required SessionResumeCoordinator coordinator,
}) async {
  try {
    final outcome = await coordinator.ensureResumed(tabId);
    if (!outcome.isRestored) {
      dlog('PREWARM', 'tab=$tabId 未恢复（新会话或 tab 已退出）');
      return;
    }
    // doResume 成功时把 transport 存进了 pool。这里**不 take** —— 留给
    // terminal_screen 进入该 tab 时取走；30 秒没人要就回收。
    if (pool.has(tabId)) {
      dlog('PREWARM', 'tab=$tabId ✓ adopted');
      Timer(const Duration(seconds: 30), () {
        if (pool.has(tabId)) {
          dlog('PREWARM', 'tab=$tabId evict (30s unused)');
          pool.evictAndClose(tabId);
        }
      });
    }
  } catch (e) {
    dlog('PREWARM', 'tab=$tabId error: $e');
  }
}

/// Scans for servers that have a saved mosh_pid and SSH-kills them.
/// Fire-and-forget — errors are silently ignored.
void _cleanOrphanedMoshPids(
  ServerRepository serverRepo,
  MoshProcessRepository moshProcessRepo,
  SecureStorageService storage,
) {
  moshProcessRepo
      .findAllActiveOrPending()
      .then((processes) async {
        for (final process in processes) {
          final server = await serverRepo.findById(process.serverId);
          if (server == null) {
            // Server was deleted — mosh-server process is unreachable and
            // will never be killed. Mark as killed so it stops accumulating.
            await moshProcessRepo.markKilled(process.id);
            continue;
          }
          String? privateKeyPem;
          String? password;
          if (server.authType == 'key' && server.keyId != null) {
            privateKeyPem = await storage.loadPrivateKey(server.keyId!);
          } else if (server.authType == 'password') {
            password = await storage.loadPassword(server.id);
          }
          final killed = await MoshHandshake.killOrphanedPid(
            host: server.host,
            port: server.port,
            username: server.username,
            password: password,
            privateKeyPem: privateKeyPem,
            pid: process.pid,
          );
          // Only clear the persisted PID after kill was actually sent. If SSH
          // is unavailable, keep the PID so the next app start can retry
          // instead of losing track of the orphaned mosh-server.
          if (killed) {
            await moshProcessRepo.markKilled(process.id);
          }
        }
        await moshProcessRepo.deleteKilled();
      })
      .catchError((_) {});
}

/// Shown instead of a white screen when app initialization throws.
class _StartupErrorApp extends StatelessWidget {
  final String error;
  const _StartupErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FlyTerm 启动失败',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '请截图发给开发者，或尝试清除 App 数据后重新安装。',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      error,
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
