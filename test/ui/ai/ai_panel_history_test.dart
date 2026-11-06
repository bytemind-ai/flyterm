// 历史列表的**接线**：头部图标 ↔ 面板内视图切换。
//
// SessionHistoryView 自己的渲染与交互由
// test/ui/ai/widgets/session_history_view_test.dart 覆盖；这里只管它有没有被正确
// 挂进面板 —— 那条链（onHistory 开关 → _showHistory → _buildBody 分支）全在
// ai_panel.dart 里，单元测试碰不到。
//
// 不需要 SQLite：AgentSessionManager 不带 repository 时 sessionsFor 返回空列表，
// 正好驱动空态，而视图切换与表里有没有数据无关。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/ai_panel.dart';
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

  setUp(() {
    // 跳过 _maybeForceRuleReview 弹出的设置页，否则它会盖住面板。
    SharedPreferences.setMockInitialValues({
      'agent_rules_reviewed_global': true,
    });
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final aiSvc = AIProviderService(prefs);
    final provider = FakeProvider([const AIResponse(text: 'ok')]);
    aiSvc.setProvider(provider);
    final agentMgr = AgentSessionManager(prefs);
    final channel = AgentExecChannel(server: _server, storage: _FakeStorage());

    AgentLoop? captured;
    AgentLoop loopFactory() => captured ??= makeLoop(provider: provider);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AIProviderService>.value(value: aiSvc),
          ChangeNotifierProvider<AgentSessionManager>.value(value: agentMgr),
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
  }

  testWidgets('点历史图标进列表，再点返回键回到对话', (tester) async {
    await pumpPanel(tester);
    final l = await AppLocalizations.delegate.load(const Locale('zh'));

    expect(find.byType(AgentView), findsOneWidget);
    expect(find.byType(SessionHistoryView), findsNothing);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();

    expect(find.byType(SessionHistoryView), findsOneWidget);
    expect(
      find.byType(AgentView),
      findsNothing,
      reason: '列表与对话是互斥的两个视图，不该同时挂着',
    );
    expect(
      find.text(l.aiHistoryEmpty),
      findsOneWidget,
      reason: '没有 repository → 空列表 → 应显示空态',
    );

    // 退回走头部左侧的 arrow_back —— 列表打开后 history 开关不再渲染，
    // 那两个入口干同一件事只会让人猜它们有什么区别。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(AgentView), findsOneWidget);
    expect(find.byType(SessionHistoryView), findsNothing);
  });

  testWidgets('历史列表打开时，新建会话按钮仍在（不该被视图切换弄丢）', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();

    // 这条测试的**真实意图**是「切到历史视图后新建按钮不能被弄丢」。
    // 入口从溢出菜单挪回头部裸图标之后，「回得去」由第一条测试覆盖。
    expect(
      find.byIcon(Icons.add_comment_outlined),
      findsOneWidget,
      reason: '切到历史视图后新建会话按钮消失了 —— 用户没法开新会话',
    );
  });

  testWidgets('历史列表打开时点新建会话，应回到对话视图', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.byType(SessionHistoryView), findsOneWidget);

    // 用户报的「新会话按钮在历史列表里不可用」就是这里：按钮点得动、归档也
    // 真的发生了，但视图仍停在列表上，界面零反馈 —— 从用户角度就是没反应。
    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();

    expect(
      find.byType(AgentView),
      findsOneWidget,
      reason: '新建会话必须把面板切回对话，否则用户看不到那段新会话',
    );
    expect(find.byType(SessionHistoryView), findsNothing);
  });
}
