// AgentView 的渲染与交互测试。
//
// 语音输入部分（原本占据本文件开头的大段）已于 2026-10 整体移除：终端页 AI
// 面板不再渲染麦克风，见 `PanelInputRow` 的类文档。随之删掉的是五个语音相关
// 用例与两个 fake service——`AgentView` 现在不再读 `VoiceInputService`，测试
// 装配里也不再需要它。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/widgets/plan_proposal_card.dart';
import 'package:flyterm/ui/ai/widgets/transfer_card.dart';
import 'package:flyterm/ui/ui_flags.dart';

import '../../ai/agent/_fakes.dart';

/// 与 `agent_plan_mode_test.dart` 里那份同名 helper 一致——那边是纯逻辑测
/// （不装配 provider），这边是 widget 测，各自独立一份省得再拉一层依赖。
AIResponse writeCall(String id, String path, String content) =>
    AIResponse(toolCalls: [
      ToolCall(id: id, name: 'write_file', args: {
        'path': path,
        'content': content,
        'description': 'write it',
      })
    ]);

Widget _wrap(Widget child, {Locale? locale}) {
  return MaterialApp(
    // null 时行为与改动前完全一致（不设置 `locale:` 等价于传 null）——
    // 只有新增的提案卡/plan 模式测试需要钉住中文断言文案时才传
    // `Locale('zh')`。
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 本文件下面有测试断言常驻任务条（`Key('jobsBar')`）的出现/消失——那条现在
  // 挂在 `kShowJobBoard` 上，编译期默认 false。覆盖成 true 让这批测试验的
  // 「任务条该不该显示」的逻辑不受「看板本身下没下线」影响；
  // 看板下线本身由 `home_screen_jobs_visibility_test.dart` 等测试单独覆盖。
  setUp(() => debugShowJobBoardOverride = true);
  tearDown(() => debugShowJobBoardOverride = null);

  testWidgets('输入行不渲染麦克风——语音输入已从面板移除', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));

    await tester.pumpWidget(_wrap(AgentView(loop: loop, providerName: 'fake')));
    await tester.pump();

    // 三种麦克风图标都不该出现（可用 / 灰化 / 录音中）。
    expect(find.byIcon(Icons.mic_none), findsNothing);
    expect(find.byIcon(Icons.mic_off), findsNothing);
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(find.byKey(const Key('panelInputRow.micHitArea')), findsNothing);
  });

  testWidgets('提案事件渲染成提案卡，不再是占位文字', (tester) async {
    final loop = makeLoop(
      provider: FakeProvider([
        writeCall('c1', '/etc/app.conf', 'x=1'),
        const AIResponse(text: 'proposal ready'),
      ]),
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
    );
    // 提案在 send() 返回前就已经攒好——先跑完整轮，再把 loop 交给
    // AgentView，断言只关心事件流的渲染，不关心时序。
    await loop.send('fix the config');

    await tester.pumpWidget(
      _wrap(
        AgentView(loop: loop, providerName: 'fake'),
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    expect(find.byType(PlanProposalCard), findsOneWidget);
  });

  testWidgets('点「全部执行」调用 approvePlan', (tester) async {
    final r = FakeRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        writeCall('c1', '/etc/app.conf', 'x=1'),
        const AIResponse(text: 'proposal ready'),
        const AIResponse(text: 'applied'),
      ]),
      runner: r,
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('fix the config');

    await tester.pumpWidget(
      _wrap(
        AgentView(loop: loop, providerName: 'fake'),
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('全部执行'));
    // FakeRunner.run 内部有一个真实的 1ms Duration delay（模拟命令执行要
    // 跨一次网络往返）——pumpAndSettle 会推进这个 fake Timer 直到收尾。
    await tester.pumpAndSettle();

    expect(r.ran, hasLength(1),
        reason: '批准之后队列里的 write_file 应当真的执行了一次');
    expect(loop.planQueue, isEmpty);
  });

  testWidgets('点「丢弃」调用 discardPlan', (tester) async {
    final r = FakeRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        writeCall('c1', '/etc/app.conf', 'x=1'),
        const AIResponse(text: 'proposal ready'),
      ]),
      runner: r,
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('fix the config');

    await tester.pumpWidget(
      _wrap(
        AgentView(loop: loop, providerName: 'fake'),
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('丢弃'));
    await tester.pump();

    expect(loop.planQueue, isEmpty);
    expect(find.byType(PlanProposalCard), findsNothing);
    expect(r.ran, isEmpty, reason: '丢弃不应该执行任何命令');
  });

  testWidgets('审批卡经 AgentView 渲染时不再有「加入方案」按钮', (tester) async {
    // 「加入方案」按钮已随按钮瘦身（2026-10-13）删除 —— 它的语义被 ask 档
    // 的提案队列吸收。这条用例钉在**集成层**（AgentView -> ApprovalCard），
    // 与 approval_card_buttons_test.dart 的组件层断言互补。
    //
    // echo 不在 defaultAllowRules 里，默认档下会卡在 awaitingApproval——
    // 卡在一个从不 complete 的 Completer 上，不依赖任何真实 Timer。
    final provider = FakeProvider([bashCall('c1', 'echo hi')]);
    final loop = makeLoop(provider: provider);

    await tester.pumpWidget(
      _wrap(
        AgentView(loop: loop, providerName: 'fake'),
        locale: const Locale('zh'),
      ),
    );

    // ignore: unawaited_futures
    final f = loop.send('查一下这个问题');
    await tester.pump();

    expect(find.text('加入方案'), findsNothing);
    expect(find.text('就这一次'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);

    loop.cancel();
    await f;
  });

  testWidgets('TransferEvent 渲染成 TransferCard', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));
    loop.debugAddEvent(TransferEvent(
      seq: 1,
      direction: TransferDirection.download,
      remotePath: '/var/log/app.log',
      filename: 'app.log',
      totalBytes: 100,
      bytesDone: 100,
      status: TransferStatus.done,
      localPath: '/storage/Download/app.log',
    ));

    await tester.pumpWidget(
      _wrap(AgentView(loop: loop, providerName: 'fake')),
    );
    await tester.pump();

    expect(find.byType(TransferCard), findsOneWidget);
  });

  testWidgets('TruncatedEvent 渲染成「更早的 N 条已省略」', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));
    loop.debugAddEvent(TruncatedEvent(37));

    await tester.pumpWidget(
      _wrap(
        AgentView(loop: loop, providerName: 'fake'),
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    expect(find.textContaining('37'), findsOneWidget);
    expect(find.textContaining('已省略'), findsOneWidget);
  });

  testWidgets('agent 停止后，只要还有未收尾的后台任务，常驻条仍然显示',
      (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));
    loop.debugAddEvent(BackgroundJobEvent(
      seq: 1,
      jobId: 'j1',
      command: 'sleep 300',
      description: '等锁',
      startedAtMs: DateTime.now().millisecondsSinceEpoch - 600 * 1000,
      lineCursor: 0,
      tail: '',
    ));

    var opened = false;
    // `_wrap` 的签名是 `_wrap(Widget child, {Locale? locale})` —— 它包的是
    // 任意 child，不是 loop。自己构造 AgentView 传进去。**必须传
    // `locale: const Locale('zh')`**：该文件的 _wrap 默认不设 locale，而下面
    // 按中文串断言。
    await tester.pumpWidget(_wrap(
      AgentView(
        loop: loop,
        providerName: 'fake',
        onOpenJobs: () => opened = true,
      ),
      locale: const Locale('zh'),
    ));
    await tester.pump();

    // 前提：agent 确实没在跑。没有这一条，下面的断言会被 _RunningBar
    // 的存在掩盖成恒真。
    expect(loop.isRunning, isFalse);
    expect(loop.hasRunningJobs, isTrue);

    // 未收尾的 BackgroundJobEvent 同时会在事件流里渲染一张 JobCard，措辞与
    // 常驻条相同（同一个 `jobCheckedLabel`）——用 `Key('jobsBar')` 把断言
    // 精确限定在常驻条内部，避免被事件流里那张卡片凑成假阳性的「找到一个」。
    final jobsBar = find.byKey(const Key('jobsBar'));
    expect(jobsBar, findsOneWidget);
    expect(
      find.descendant(of: jobsBar, matching: find.textContaining('等锁')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: jobsBar, matching: find.textContaining('分钟前确认')),
      findsOneWidget,
    );

    await tester.tap(jobsBar);
    await tester.pump();
    expect(opened, isTrue);

    loop.dispose();
  });

  testWidgets('任务写入 exitCode 之后常驻条消失', (tester) async {
    final loop = makeLoop(provider: FakeProvider([]));
    final job = BackgroundJobEvent(
      seq: 1,
      jobId: 'j1',
      command: 'sleep 300',
      description: '等锁',
      startedAtMs: DateTime.now().millisecondsSinceEpoch - 600 * 1000,
      lineCursor: 0,
      tail: '',
    );
    loop.debugAddEvent(job);
    await tester.pumpWidget(_wrap(
      AgentView(loop: loop, providerName: 'fake'),
      locale: const Locale('zh'),
    ));
    await tester.pump();
    expect(find.byKey(const Key('jobsBar')), findsOneWidget);

    job.exitCode = 0;
    loop.debugNotify();
    await tester.pump();

    expect(loop.hasRunningJobs, isFalse);
    expect(find.byKey(const Key('jobsBar')), findsNothing);
    loop.dispose();
  });
}
