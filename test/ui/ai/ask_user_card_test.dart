import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/ask_option.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/widgets/ask_user_list.dart';

import '../../ai/agent/_fakes.dart';

/// 见 `agent_streaming_view_test.dart` 里同名类的注释：真 service 会去碰
/// 平台通道并挂起，测试环境必须换成最小 fake。
class _FakeVoiceInputService extends VoiceInputService {
  @override
  bool get isAvailable => false;

  @override
  bool get isListening => false;

  @override
  Future<bool> prepare() async => false;

  @override
  Future<void> startListening({
    required void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  }) async {}

  @override
  Future<void> cancelListening() async {}
}

Widget _wrap(AgentLoop loop) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<VoiceInputService>(
        create: (_) => _FakeVoiceInputService(),
        child: Scaffold(
          body: AgentView(loop: loop, providerName: 'fake'),
        ),
      ),
    );

void main() {
  ToolCall askCall() => const ToolCall(id: 'c1', name: 'ask_user', args: {
        'question': '先处理哪个？',
        'options': [
          {'label': '3306'},
          {'label': '3307', 'description': '灰度实例'},
        ],
      });

  /// 反复 pump 直到挂起态建立。`loop.send` 里的 await 链挂在真实 microtask
  /// 上，单次 pump 推不完。
  Future<void> pumpUntilAwaiting(WidgetTester tester, AgentLoop loop) async {
    for (var i = 0; i < 100; i++) {
      if (loop.state == AgentLoopState.awaitingAnswer) {
        await tester.pump();
        return;
      }
      await tester.pump(const Duration(milliseconds: 5));
    }
    fail('挂起状态始终没有建立（state=${loop.state}）');
  }

  testWidgets('ask_user 渲染成可点的选项，而不是「允许一次 / 拒绝」审批卡',
      (tester) async {
    // 回归：`ask_user` 借用 `awaitingApproval` 当挂起态，而事件分派的
    // switch 里 ApprovalCard 那一支只看 status。漏掉 toolName 守卫就会被
    // 它抢先匹配——用户看到审批卡、看不到选项，且两个按钮都打不通
    // （`respondApproval` 查 `_pending`，提问的 completer 在 `_pendingAnswers`），
    // loop 永久停在 awaitingAnswer。
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [askCall()]),
        const AIResponse(text: '好'),
      ]),
    );
    await tester.pumpWidget(_wrap(loop));

    final done = loop.send('改端口');
    await pumpUntilAwaiting(tester, loop);

    expect(find.text('3306'), findsOneWidget);
    expect(find.text('3307'), findsOneWidget);
    expect(find.text('灰度实例'), findsOneWidget);
    expect(find.text('先处理哪个？'), findsOneWidget);

    // 清单形状：每个选项一个 ○ 标记，问题行一个 ?，「其他…」一个 ✎。
    expect(find.text('○'), findsNWidgets(2));
    expect(find.text('?'), findsOneWidget);
    expect(find.text('✎'), findsOneWidget);
    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(find.text(l.agentAskOther), findsOneWidget);

    // 旧形状的全宽按钮不该再有
    expect(find.byType(OutlinedButton), findsNothing);

    expect(find.text(l.agentAllowOnce), findsNothing,
        reason: '提问卡不该出现审批按钮');

    // 点选项要真的把答案送回 loop，否则和死按钮没区别。
    await tester.tap(find.text('3306'));
    await tester.pump();
    await done.timeout(const Duration(seconds: 5));

    final results = loop.debugHistory
        .where((m) => m.role == 'tool')
        .expand((m) => m.toolResults ?? const <ToolResult>[]);
    expect(results.any((r) => r.content == '3306'), isTrue);

    loop.dispose();
  });

  testWidgets('点「其他…」展开输入框，提交的文本作为答案回给模型',
      (tester) async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [askCall()]),
        const AIResponse(text: '好'),
      ]),
    );
    await tester.pumpWidget(_wrap(loop));

    final done = loop.send('改端口');
    await pumpUntilAwaiting(tester, loop);

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    // `find.byType(TextField)` 不能裸用：`AgentView` 自带的消息输入框
    // （hintText「描述你要排查的问题」）本身就是个 TextField，全局找会把它
    // 也算进去。必须限定在 AskUserList 子树内，才是「其他…」展开出的那个。
    final askField = find.descendant(
      of: find.byType(AskUserList),
      matching: find.byType(TextField),
    );
    expect(askField, findsNothing, reason: '默认不展开');

    await tester.tap(find.text(l.agentAskOther));
    await tester.pump();
    expect(askField, findsOneWidget);

    await tester.enterText(askField, '3308，新加的');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await done.timeout(const Duration(seconds: 5));

    final results = loop.debugHistory
        .where((m) => m.role == 'tool')
        .expand((m) => m.toolResults ?? const <ToolResult>[]);
    expect(
      results.first.content,
      '3308，新加的\n\n(free-form answer, not one of the offered options)',
    );

    loop.dispose();
  });

  testWidgets('输入框按键盘「发送」键（onSubmitted）也能提交答案',
      (tester) async {
    // 之前只测了点 IconButton 那条路径；`textInputAction: send` 配的是
    // 键盘发送键，走的是 `onSubmitted` 回调，是另一条独立代码路径，此前
    // 没有测试覆盖。
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [askCall()]),
        const AIResponse(text: '好'),
      ]),
    );
    await tester.pumpWidget(_wrap(loop));

    final done = loop.send('改端口');
    await pumpUntilAwaiting(tester, loop);

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    final askField = find.descendant(
      of: find.byType(AskUserList),
      matching: find.byType(TextField),
    );

    await tester.tap(find.text(l.agentAskOther));
    await tester.pump();
    await tester.enterText(askField, '3309');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await done.timeout(const Duration(seconds: 5));

    final results = loop.debugHistory
        .where((m) => m.role == 'tool')
        .expand((m) => m.toolResults ?? const <ToolResult>[]);
    expect(
      results.first.content,
      '3309\n\n(free-form answer, not one of the offered options)',
    );

    loop.dispose();
  });

  testWidgets('挂起态也渲染分类标签 [header]（不止折叠态那份）',
      (tester) async {
    // `[header]` 在挂起支和折叠支里是两段几乎一样但各自独立的代码
    // （问题行 vs 折叠后的单行），此前只有折叠态被断言过（归档恢复那条），
    // 挂起态这段没有任何测试覆盖。
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          const ToolCall(id: 'c1', name: 'ask_user', args: {
            'question': '先处理哪个？',
            'header': '实例',
            'options': [
              {'label': '3306'},
              {'label': '3307'},
            ],
          }),
        ]),
        const AIResponse(text: '好'),
      ]),
    );
    await tester.pumpWidget(_wrap(loop));

    final done = loop.send('改端口');
    await pumpUntilAwaiting(tester, loop);

    expect(find.textContaining('[实例]'), findsOneWidget);

    // 收尾：答一下，避免 loop 挂着泄漏。
    final ev = loop.events.whereType<ToolCallEvent>().last;
    loop.respondAnswer(ev.seq, '3306');
    await done.timeout(const Duration(seconds: 5));
    loop.dispose();
  });

  testWidgets('空白输入不提交 —— 误触一次就得让 agent 没答案地继续',
      (tester) async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [askCall()]),
        const AIResponse(text: '好'),
      ]),
    );
    await tester.pumpWidget(_wrap(loop));

    final done = loop.send('改端口');
    await pumpUntilAwaiting(tester, loop);

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    await tester.tap(find.text(l.agentAskOther));
    await tester.pump();

    // 同上：限定在 AskUserList 子树内，避开 AgentView 自带的消息输入框。
    final askField = find.descendant(
      of: find.byType(AskUserList),
      matching: find.byType(TextField),
    );
    await tester.enterText(askField, '   ');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    expect(askField, findsOneWidget, reason: '输入框不该关闭');
    expect(loop.state, AgentLoopState.awaitingAnswer, reason: '仍在等答案');

    // 收尾：真的答一下，否则 loop 挂着，测试结束时会泄漏
    final ev = loop.events.whereType<ToolCallEvent>().last;
    loop.respondAnswer(ev.seq, '3306');
    await done.timeout(const Duration(seconds: 5));
    loop.dispose();
  });

  testWidgets('答完折叠成一行，选项与标记都消失', (tester) async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [askCall()]),
        const AIResponse(text: '好'),
      ]),
    );
    await tester.pumpWidget(_wrap(loop));

    final done = loop.send('改端口');
    await pumpUntilAwaiting(tester, loop);
    await tester.tap(find.text('3306'));
    await tester.pump();
    await done.timeout(const Duration(seconds: 5));
    await tester.pump();

    expect(find.text('○'), findsNothing);
    expect(find.text('✓'), findsOneWidget);
    expect(find.textContaining('→ 3306'), findsOneWidget);

    loop.dispose();
  });

  testWidgets('归档恢复出来的提问不可点，显示「未回答」', (tester) async {
    final ev = ToolCallEvent(
      seq: 1,
      callId: 'c1',
      toolName: 'ask_user',
      displayCommand: 'ask: 先处理哪个？',
      description: '实例',
      check: const CheckResult(decision: ToolDecision.allow),
    )..status = ToolCallStatus.rejected;

    await tester.pumpWidget(MaterialApp(
      // 计划原文这里漏了 `locale`：没有它渲染走系统/测试默认 locale
      // （非 zh），下面按 zh 串断言会找不到——与 `_wrap()` 保持一致，显式
      // 钉死 zh。
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // `onAnswer` 传非 null，与 `agent_view.dart` 的真实配置一致——生产
      // 路径对任何 `toolName == 'ask_user'` 都传回调，只按 status 走只读支。
      // 这条测试要钉住的是 status 那半守卫，不是 onAnswer 是否为 null。
      home: Scaffold(body: AskUserList(event: ev, onAnswer: (_) {})),
    ));

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(find.text('✗'), findsOneWidget);
    expect(find.textContaining('[实例]'), findsOneWidget);
    expect(find.textContaining(l.agentAskUnanswered), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('刚建出来的 running 态渲染成清单，不是「✗ 未回答」',
      (tester) async {
    // `ToolCallEvent` 的默认 status 是 `running`，executor 要再走几行才把它
    // 翻成 `awaitingApproval`。眼下那几行没有 await、画不出帧，所以这一态
    // 在生产里观察不到——但只要将来谁在中间插一次异步调用，用户就会先看到
    // 一个「✗ 未回答」再看到问题，被告知他没回答一个还没显示的问题。
    //
    // 这条测试钉住 `pending` 用的是「还没到终态」而不是「正好等于
    // awaitingApproval」，让那次未来的改动撞在这里而不是撞在真机上。
    final ev = ToolCallEvent(
      seq: 1,
      callId: 'c1',
      toolName: 'ask_user',
      displayCommand: 'ask: 先处理哪个？',
      description: '',
      check: const CheckResult(decision: ToolDecision.allow),
      askOptions: const [AskOption(label: '3306'), AskOption(label: '3307')],
    );
    expect(ev.status, ToolCallStatus.running, reason: '前提：默认就是 running');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: AskUserList(event: ev, onAnswer: (_) {})),
    ));

    expect(find.text('○'), findsNWidgets(2));
    expect(find.text('✗'), findsNothing);
  });
}
