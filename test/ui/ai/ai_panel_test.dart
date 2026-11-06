// 面板头部给哪些按钮 —— 按模式分。
//
// agent 模式撤掉了「分析错误」「会话总结」。它们真正提供的能力从来不是「省一次
// 打字」（那个用户自己能做），而是把**当前**屏幕附进问题里：输入框直接打字走的
// 是 `loop.send(text)`，裸文本，模型只能看到 system prompt 里那份 **loop 创建
// 时**的终端快照，而 loop 按 serverId 复用、寿命跨多次面板开关，那份可能已经是
// 几十条命令之前的。也就是说正确性依赖「用户记得点按钮而不是打字」。
//
// 那件事现在由 `read_terminal` 工具承担（见
// test/ai/agent/agent_read_terminal_test.dart）：模型需要看屏幕时自己要。
//
// 直连模式没有工具可用，撤掉就是纯损失，所以保留。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel_menu_helper.dart';

import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/ai_panel.dart';

import '../../ai/agent/_fakes.dart';

/// 最小 stub —— 只有 `AgentExecChannel.isAvailable()`/`obtain()` 用到
/// `loadPassword`。其余交给 noSuchMethod。
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
    // 预置「规则已读过」，跳过 _maybeForceRuleReview 弹出的设置页 —— 它会盖住
    // 面板，头部按钮就找不到了。
    SharedPreferences.setMockInitialValues({
      'agent_rules_reviewed_global': true,
    });
  });

  /// [withChannel] false = 没有 execChannel/loopFactory，`_resolveMode` 会退回
  /// 直连模式。
  Future<void> pumpPanel(
    WidgetTester tester, {
    required bool withChannel,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final aiSvc = AIProviderService(prefs);
    final provider = FakeProvider([const AIResponse(text: 'ok')]);
    aiSvc.setProvider(provider);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AIProviderService>.value(value: aiSvc),
          ChangeNotifierProvider<AgentSessionManager>.value(
            value: AgentSessionManager(prefs),
          ),
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
              contextProvider: () => 'MARKER',
              execChannel: withChannel
                  ? AgentExecChannel(server: _server, storage: _FakeStorage())
                  : null,
              loopFactory: withChannel
                  ? () => makeLoop(provider: provider)
                  : null,
            ),
          ),
        ),
      ),
    );
    // 等 _resolveMode 的 await channel.isAvailable() 落地。
    await tester.pumpAndSettle();
  }

  testWidgets('agent 模式：撤掉分析错误与会话总结，头部常驻历史与新建会话', (tester) async {
    await pumpPanel(tester, withChannel: true);

    // 直接可见的是「历史会话」+「新建会话」。agent 模式没有溢出菜单 ——
    // 分析错误/总结已交给 read_terminal 工具，菜单里再没有别的项。
    expect(find.byIcon(Icons.add_comment_outlined), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(
      find.byIcon(Icons.more_vert),
      findsNothing,
      reason: 'agent 模式菜单里只剩历史一项，已挪到头部裸图标，空菜单不该渲染',
    );
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
    expect(find.byIcon(Icons.summarize_outlined), findsNothing);
  });

  testWidgets('直连模式：保留分析错误与会话总结 —— 那里没有工具可以替代', (tester) async {
    await pumpPanel(tester, withChannel: false);

    expect(await panelMenuContains(tester, Icons.bug_report_outlined), isTrue);
    expect(await panelMenuContains(tester, Icons.summarize_outlined), isTrue);

    // 直连模式的历史在 engine 里，没有分段的概念。
    expect(find.byIcon(Icons.history), findsNothing);
  });
}
