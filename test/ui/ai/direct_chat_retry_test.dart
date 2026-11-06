// 重试 / 编辑重发的**位置规则**：这两个动作只出现在最后一轮上。
//
// 回退语义本身由 test/ai/ai_engine_test.dart 的 popLastTurn 组覆盖；这里只管
// 「按钮挂在哪几条消息上」——那段判断全在 direct_chat_view.dart 的 itemBuilder
// 里，engine 层的测试碰不到它。
//
// 为什么这条规则值得单独测：允许回退中间某条会静默丢掉它之后的全部对话，而
// 手机上没有撤销路径，engine 也不保留分支。判断写错不会报错，只会让用户点一下
// 就丢掉半段排查记录。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/direct_chat_view.dart';

/// 直连模式走的是 complete / completeStream，不是 agent 那套
/// completeWithTools —— 所以不能复用 _fakes.dart 里的 FakeProvider。
class _StubProvider extends AIProvider {
  final List<String> replies;
  int _i = 0;

  _StubProvider(this.replies);

  @override
  String get displayName => 'stub';
  @override
  String get providerType => 'stub';
  @override
  Future<String> complete(List<AIMessage> messages) async =>
      replies[_i++ % replies.length];
}

Future<AIEngine> _engineWith(
  SharedPreferences prefs,
  List<(String, String)> turns,
) async {
  final engine = AIEngine(prefs, serverId: 'srv-retry');
  for (final (q, a) in turns) {
    await engine.query(q, provider: _StubProvider([a]));
  }
  return engine;
}

Future<void> _pump(
  WidgetTester tester,
  AIEngine engine,
  SharedPreferences prefs, {
  AIProvider? provider,
}) async {
  final aiSvc = AIProviderService(prefs);
  aiSvc.setProvider(provider ?? _StubProvider(['新回答']));

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AIProviderService>.value(value: aiSvc),
        ChangeNotifierProvider<VoiceInputService>.value(
          value: VoiceInputService(),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: DirectChatView(engine: engine)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('两轮对话里，重试只挂在最后那条回答上', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final engine =
        await _engineWith(prefs, [('第一问', '第一答'), ('第二问', '第二答')]);
    await _pump(tester, engine, prefs);

    // 屏幕上有两条 assistant 消息，但只有一个重试按钮。
    expect(find.text('第一答'), findsOneWidget);
    expect(find.text('第二答'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('两轮对话里，编辑只挂在最后那条提问上', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final engine =
        await _engineWith(prefs, [('第一问', '第一答'), ('第二问', '第二答')]);
    await _pump(tester, engine, prefs);

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('编辑把原话载回输入框，并把那一轮从历史里摘掉', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final engine = await _engineWith(prefs, [('原来的问题', '原来的回答')]);
    await _pump(tester, engine, prefs);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // 原话进了输入框
    expect(find.widgetWithText(TextField, '原来的问题'), findsOneWidget);
    // 那一轮从屏幕上消失了 —— 它现在在输入框里，不在记录里
    expect(find.text('原来的回答'), findsNothing);
  });

  testWidgets('点重试换掉旧回答，提问不重复', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final engine = await _engineWith(prefs, [('这是什么错', '不满意的回答')]);
    await _pump(tester, engine, prefs,
        provider: _StubProvider(['重试后的回答']));

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('重试后的回答'), findsOneWidget);
    expect(find.text('不满意的回答'), findsNothing);
    // 提问只剩一条。popLastTurn 不删 user 消息的话，query 会再追加一条，
    // 屏幕上就是两个一模一样的气泡。
    expect(find.text('这是什么错'), findsOneWidget);
  });

  testWidgets('空会话里两个按钮都不出现', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final engine = AIEngine(prefs, serverId: 'srv-retry');
    await _pump(tester, engine, prefs);

    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });
}
