// 活性原则的渲染测试：同类事件只有最新那条保持完整形态。
//
// 用 makeLoop + debugAddEvent 直接搭真实的 AgentView（模式取自
// turn_summary_test.dart），因为分派发生在 _buildEvent 这个私有方法里，
// 只测 LatestEventIndex 覆盖不到「switch 分支顺序写反」这类错误 ——
// Dart 里 when 分支排在无条件分支之后会永远匹配不到，而那正是本任务
// 最容易犯的错。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/widgets/dense_event_row.dart';
import 'package:flyterm/ui/ai/widgets/plan_checklist.dart';

import '../../ai/agent/_fakes.dart';

Widget _wrap(AgentLoop loop) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider(
        create: (_) => VoiceInputService(),
        child: Scaffold(body: AgentView(loop: loop, providerName: 'fake')),
      ),
    );

void main() {
  testWidgets('被取代的旧计划退成流水行，最新的仍是清单', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(PlanUpdatedEvent(['检查配置'], 0));
    loop.debugAddEvent(PlanUpdatedEvent(['检查配置', '重启服务'], 1));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.byType(PlanChecklist), findsOneWidget);
    expect(find.byType(DenseEventRow), findsOneWidget);
  });

  testWidgets('步骤完全相同的两条也能区分新旧', (t) async {
    // 用 == 比较会把两条都判成最新，清单就会渲染两张。
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(PlanUpdatedEvent(['检查配置'], 0));
    loop.debugAddEvent(PlanUpdatedEvent(['检查配置'], 0));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.byType(PlanChecklist), findsOneWidget);
  });

  testWidgets('只有最新的停止横幅带「继续」按钮', (t) async {
    // 两轮都因轮数上限停下。改造前两张横幅上各有一个可点的「继续」，
    // 点历史那个会在当前轮末尾追一句 continue —— 用户以为自己在续上
    // 半小时前那一轮。
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(StoppedEvent(AgentStopReason.maxTurns));
    loop.debugAddEvent(StoppedEvent(AgentStopReason.maxTurns));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.text('继续'), findsOneWidget);
  });

  testWidgets('收工总结只出现在最新那条横幅上', (t) async {
    // metrics.current 是 _turns.last，给每条 StoppedEvent 都传它的话，
    // 五轮会话里五条总结显示的全是第五轮的数字。历史位置上宁可不显示，
    // 也好过显示错的。
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    final m = loop.metrics.startTurn();
    m.turnTotalMs = 222000;
    m.toolCallCount = 5;

    loop.debugAddEvent(StoppedEvent(AgentStopReason.maxTurns));
    loop.debugAddEvent(StoppedEvent(AgentStopReason.maxTurns));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.textContaining('5 次调用'), findsOneWidget);
  });

  testWidgets('唯一一条停止横幅仍然带「继续」按钮', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(StoppedEvent(AgentStopReason.maxTurns));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.text('继续'), findsOneWidget);
  });

  testWidgets('只有最新的中断横幅带恢复入口', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(SessionInterruptedEvent(['bash']));
    loop.debugAddEvent(SessionInterruptedEvent(['read_file']));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    // 两条横幅的标题都在（记录不抹掉），但恢复按钮只有一个。
    expect(find.text('上次会话被中断'), findsNWidgets(2));
    expect(find.text('继续'), findsOneWidget);
  });
}
