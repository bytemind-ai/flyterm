// 历史列表里导出**当前活跃那一段**时，导的必须是内存里的 loop.events，
// 而不是回表读到的归档。
//
// 落盘是 3 秒尾沿节流的（AgentSessionManager._kPersistThrottle），所以表里那
// 一行随时可能落后于内存好几轮。而活跃段按 `updated_at DESC` 排在历史列表
// **第一条**（AgentSessionRepository.listForServer），恰恰是最容易被点到的
// 那一条 —— 走回表读就会静默导出一份缺尾巴的记录，用户看不出来。
//
// 头部曾经有个导出图标，2026-10 已经移除（用户反馈低频、不值得占格子）；
// 导出现在的唯一入口就是历史列表每一行的菜单，所以这条路径必须是对的。
//
// **每一处触发 SQLite 的操作都必须包在 tester.runAsync 里**，包括 tap ——
// `_openHistory` / `_exportSession` 都会 await 库操作，裸 tap 会让测试挂满
// 十分钟然后超时，而不是报错。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/agent_session.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/agent_session_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/ai_panel.dart';
import 'package:flyterm/ui/ai/export_preview_screen.dart';
import 'package:flyterm/ui/ai/widgets/session_history_view.dart';

import '../../ai/agent/_fakes.dart';

class _FakeStorage implements SecureStorageService {
  @override
  Future<String?> loadPassword(String serverId) async => 'fake-password';
  @override
  Future<String?> loadPrivateKey(String keyId) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _server = Server(
  id: 'srv-1',
  name: 'test-server',
  host: 'example.com',
  port: 22,
  username: 'root',
  authType: 'password',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSessionRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'agent_rules_reviewed_global': true,
    });
    db = await AppDatabase.open(inMemory: true);
    repo = AgentSessionRepository(db);
  });

  tearDown(() async => db.close());

  /// 挂起面板，返回被 loopFactory 捕获的那个 loop。
  Future<AgentLoop> pumpPanel(
    WidgetTester tester,
    AgentSessionRepository repo,
    List<AIResponse> replies,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final aiSvc = AIProviderService(prefs);
    final provider = FakeProvider(replies);
    aiSvc.setProvider(provider);
    final agentMgr = AgentSessionManager(prefs, repo);
    final channel = AgentExecChannel(server: _server, storage: _FakeStorage());

    AgentLoop? captured;
    AgentLoop loopFactory() => captured ??= makeLoop(provider: provider);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AIProviderService>.value(value: aiSvc),
          ChangeNotifierProvider<AgentSessionManager>.value(value: agentMgr),
          ChangeNotifierProvider<VoiceInputService>.value(
            value: VoiceInputService(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AIPanel(
              engine: AIEngine(prefs, serverId: _server.id),
              contextProvider: () => 'buffer',
              execChannel: channel,
              loopFactory: loopFactory,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(captured, isNotNull, reason: '应已进入 agent 模式');

    // 生产路径上是 terminal_screen.dart:1973 在造完 loop 后 register 的 ——
    // 不注册，manager 不监听 loop 的 notifyListeners，就永远不会落盘，
    // 「活跃行」也就不存在，测的就不是真实处境。
    //
    // 但必须放在 pump 之后、不能塞进 loopFactory：factory 是在 build 期间
    // 被调用的，register 里的 notifyListeners 会撞上
    // "setState() called during build"。
    agentMgr.register(_server.id, captured!);
    await tester.pumpAndSettle();
    return captured!;
  }

  /// 进历史列表 → 点第 [index] 条的导出菜单，返回打开的预览页。
  Future<ExportPreviewScreen> tapExportAt(
    WidgetTester tester,
    int index,
  ) async {
    // 这几处 tap 都会触发库操作，必须走 runAsync；而且 tap 只是发出手势，
    // 回调里的 `await sessionsFor` / `await archiveById` 要到之后的 event
    // loop 轮次才完成 —— 所以 runAsync 内还得让出一段真实时间，否则
    // setState 尚未发生就 pumpAndSettle，列表根本没挂上来。
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.history));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byType(SessionHistoryView), findsOneWidget);

    // 每一行历史自己有 more_vert。历史入口已经不在头部菜单里了，但列表里
    // 依然可能同时存在多个 more_vert（每行一个），所以还是限定在
    // SessionHistoryView 内最稳妥。
    await tester.runAsync(() async {
      await tester.tap(
        find
            .descendant(
              of: find.byType(SessionHistoryView),
              matching: find.byIcon(Icons.more_vert),
            )
            .at(index),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await tester.runAsync(() async {
      await tester.tap(find.text(l.aiExportSession).last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    return tester.widget<ExportPreviewScreen>(find.byType(ExportPreviewScreen));
  }

  testWidgets('历史列表导出活跃段：导的是内存里的完整会话，不是落后的归档', (tester) async {
    final loop = await pumpPanel(tester, repo, [
      const AIResponse(text: '第一轮回答'),
    ]);

    // 只跑一轮。连发两轮会撞上一个与本用例无关的竞态：第一轮的落盘是
    // `unawaited` 发出的，还在飞时第二轮也看到「表里还没有这一段」，于是
    // 两次都 INSERT，凭空多一行（见 agent_session_manager_test.dart 里那条
    // waitForRows 的注释）。一轮已经能产生多个事件，够用。
    await tester.runAsync(() async {
      await loop.send('问题一');
      // 轮询等落盘，不赌固定延迟。
      for (var i = 0; i < 200; i++) {
        if ((await repo.listForServer(_server.id)).isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    final liveCount = loop.events.length;
    expect(liveCount, greaterThan(1), reason: '前置条件：内存里有多个事件');

    // 把表里那一行清空 —— 模拟「节流落盘落后于内存」。这是常态而非边界：
    // 3 秒窗口内的每一轮都处在这个状态。
    List<AgentSession> rows = const [];
    await tester.runAsync(() async {
      rows = await repo.listForServer(_server.id);
      if (rows.length == 1) {
        await repo.updateContent(
          rows.single.id!,
          title: rows.single.title,
          archive: '{"events":[]}',
          eventCount: 0,
          updatedAt: rows.single.updatedAt,
        );
      }
    });
    await tester.pumpAndSettle();
    expect(rows, hasLength(1), reason: '前置条件：活跃段占一行');

    final screen = await tapExportAt(tester, 0);

    expect(
      screen.events.length,
      liveCount,
      reason: '活跃段要走内存里的 loop.events；回表读会导出一份缺尾巴的记录',
    );
  });

  testWidgets('历史列表导出非活跃段：仍走归档，不受活跃段影响', (tester) async {
    // 先插一条与当前活跃段无关的旧会话。
    int oldId = 0;
    await tester.runAsync(() async {
      oldId = await repo.insert(
        AgentSession(
          serverId: _server.id,
          title: '旧会话',
          archive: '{"events":[{"kind":"userTurn","text":"旧问题"}]}',
          eventCount: 1,
          starred: false,
          createdAt: DateTime(2026, 9, 1),
          updatedAt: DateTime(2026, 9, 1),
        ),
      );
    });

    await pumpPanel(tester, repo, [const AIResponse(text: '回答')]);

    final screen = await tapExportAt(tester, 0);

    expect(
      screen.filenameHint,
      'session_$oldId',
      reason: '非活跃段没有内存副本，只能也只该走归档',
    );
  });
}
