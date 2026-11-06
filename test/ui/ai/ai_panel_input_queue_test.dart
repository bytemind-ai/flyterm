// 回归测试：agent 模式排队输入的 UI 接线。
//
// 排队机制本身（AgentLoop._pendingInputs / send() 在 isRunning 时入队 /
// withdrawPendingInput）在更早的任务里已经写好并测过了，但一直没有 UI
// 入口——AgentView 的输入框在 loop 运行期间被整体禁用，用户压根碰不到
// 这条排队路径。这里测的是那层接线：输入框在运行期间不再禁用，发送后
// 排队内容以气泡形式出现，点击气泡能撤回并回填进输入框。
//
// 走完整的 AIPanel 装配（而不是像 agent_view_test.dart 那样只测
// AgentView 本身），是为了确认这条路径在真实的 provider/widget 树里也
// 成立——同一个 loop 实例贯穿测试全程，用 loopFactory 把它交给 AIPanel。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/ai_panel.dart';
import 'package:flyterm/ui/ai/widgets/panel_chrome.dart';

import '../../ai/agent/_fakes.dart';

/// 最小 stub —— 只有 `AgentExecChannel.isAvailable()`/`obtain()` 用到
/// `loadPassword`。其余交给 noSuchMethod。与 `ai_panel_test.dart` 同款。
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
    // 预置「规则已读过」，跳过 _maybeForceRuleReview 弹出的设置页 ——
    // 它会盖住面板，输入框就摸不到了。
    SharedPreferences.setMockInitialValues({
      'agent_rules_reviewed_global': true,
    });
  });

  /// 与 `ai_panel_test.dart` 的 `pumpPanel` 同一套装配，但额外把 loop 实例
  /// 交回调用方——`loopFactory` 返回的是外部持有的同一个 loop，而不是每次
  /// 调用都新建一个，这样测试才能在断言里直接摸到 `loop.pendingInputs` 这
  /// 类状态，同时仍然走的是真实的 AIPanel/AgentView 组件树。
  ///
  /// **不在这里（也不在任何一个测试里）调用 `loop.dispose()`**——AIPanel
  /// 才是 loop 的所有者，测试手动 dispose 会跟 AIPanel 自己的 dispose 撞车
  /// （dispose 之后的 notifyListeners 会触发 ChangeNotifier 的 assert）。
  Future<AgentLoop> pumpWithLoop(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final aiSvc = AIProviderService(prefs);
    final provider = FakeProvider([const AIResponse(text: 'ok')]);
    aiSvc.setProvider(provider);
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
    );

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
              execChannel:
                  AgentExecChannel(server: _server, storage: _FakeStorage()),
              loopFactory: () => loop,
            ),
          ),
        ),
      ),
    );
    // 等 _resolveMode 的 await channel.isAvailable() 落地。
    await tester.pumpAndSettle();
    return loop;
  }

  /// 面板里除了输入框之外目前没有别的 `TextField`（历史列表用的是
  /// ListTile，没有输入控件），但这里仍然用「输入框范围内」的 descendant
  /// finder 而不是裸的 `find.byType(TextField)`——万一将来面板头部或别的
  /// 卡片里加了搜索框之类的输入控件，`find.byType(TextField)` 会因为匹配
  /// 多个而报错，descendant 版本不受影响。
  Finder inputTextField() => find.descendant(
        of: find.byType(PanelInputRow),
        matching: find.byType(TextField),
      );

  testWidgets('运行中输入框不禁用，发送后出现待发气泡', (tester) async {
    final loop = await pumpWithLoop(tester);
    // 用测试钩子直接把 loop 摆成运行态——不需要真的驱动一整轮模型/工具调用，
    // 这里要测的只是「运行期间 UI 允许发送、发送进了排队」这条接线本身。
    loop.debugForceRunning();
    await tester.pump();

    expect(
      tester.widget<TextField>(inputTextField()).enabled,
      isTrue,
      reason: '运行中的输入框不该再被禁用——排队机制已经替代了原来的整体置灰',
    );

    await tester.enterText(inputTextField(), '顺便也查一下 nginx 日志');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(loop.pendingInputs, equals(['顺便也查一下 nginx 日志']),
        reason: '运行中发送应该落进排队队列，而不是被丢弃或立即执行');
    expect(find.text('顺便也查一下 nginx 日志'), findsOneWidget,
        reason: '排队的内容应该以气泡形式渲染出来，用户能看见它还在等');
  });

  testWidgets('点击待发气泡撤回并回填输入框', (tester) async {
    final loop = await pumpWithLoop(tester);
    loop.debugForceRunning();
    await tester.pump();

    await tester.enterText(inputTextField(), '排查磁盘占用');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(loop.pendingInputs, equals(['排查磁盘占用']));

    await tester.tap(find.text('排查磁盘占用'));
    await tester.pump();

    expect(loop.pendingInputs, isEmpty,
        reason: '点击气泡应该把这条排队输入撤回，而不是留在队列里');
    expect(
      tester.widget<TextField>(inputTextField()).controller!.text,
      equals('排查磁盘占用'),
      reason: '撤回的内容应该原样回填进输入框，而不是消失',
    );
  });
}
