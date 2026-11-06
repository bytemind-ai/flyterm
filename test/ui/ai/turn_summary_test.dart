// 收工总结的渲染测试。
//
// 数据全部来自 loop.metrics.current(第一期造的那把秤),本任务不新增
// 任何采集点。计量是纯旁路,所以「秤上没有数据」必须退化成不渲染,而不是
// 显示一行 0 —— 那是在报告一件没发生过的事。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';

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
  testWidgets('正常收工显示时长与调用次数', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    final m = loop.metrics.startTurn();
    m.turnTotalMs = 222000;
    m.toolCallCount = 5;
    loop.debugAddEvent(StoppedEvent(AgentStopReason.completed));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.textContaining('3m42s'), findsOneWidget);
    expect(find.textContaining('5 次调用'), findsOneWidget);
  });

  // 计量是纯旁路(turn_metrics.dart 首行自述),任何一处采集失败都不该
  // 影响会话 —— 呈现层同理:读不到就整行不渲染。
  testWidgets('没有计量数据时整行不渲染', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(StoppedEvent(AgentStopReason.completed));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.textContaining('次调用'), findsNothing);
  });

  // 非 completed 的终止原来就有横幅,加总结不能把它挤掉。
  testWidgets('达到轮数上限时横幅与总结同时在', (t) async {
    final loop = makeLoop(provider: FakeProvider(const []), maxTurns: 25);
    addTearDown(loop.dispose);

    final m = loop.metrics.startTurn();
    m.turnTotalMs = 42000;
    m.toolCallCount = 2;
    loop.debugAddEvent(StoppedEvent(AgentStopReason.maxTurns));
    loop.debugNotify();

    await t.pumpWidget(_wrap(loop));

    expect(find.textContaining('已达轮数上限'), findsOneWidget);
    expect(find.textContaining('42s'), findsOneWidget);
  });
}
