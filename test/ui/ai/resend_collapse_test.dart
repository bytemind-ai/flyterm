import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/widgets/superseded_group.dart';
import 'package:flyterm/ui/ai/widgets/tool_call_card.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('默认收起，点一下展开', (tester) async {
    await tester.pumpWidget(wrap(const SupersededGroup(
      children: [Text('里面的内容')],
    )));
    await tester.pumpAndSettle();

    expect(find.text('里面的内容'), findsNothing);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('里面的内容'), findsOneWidget);
  });

  testWidgets('标题显示收起的条数', (tester) async {
    await tester.pumpWidget(wrap(const SupersededGroup(
      children: [Text('a'), Text('b'), Text('c')],
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('3'), findsOneWidget);
  });

  // 这一条是选折叠式而不是截断式的**全部理由**所在：截断式会把这个按钮
  // 连同事件一起删掉，而用户想重发的场景很可能恰恰是「agent 改错了文件」。
  testWidgets('展开后，里面工具卡的撤销按钮仍然可点', (tester) async {
    var undone = false;
    final ev = ToolCallEvent(
      seq: 1, callId: 'c', toolName: 'write_file',
      displayCommand: 'write /etc/nginx.conf', description: '',
      check: const CheckResult(decision: ToolDecision.allow),
      status: ToolCallStatus.done,
    )..backupPath = '/tmp/backup.bak';

    await tester.pumpWidget(wrap(SupersededGroup(
      children: [ToolCallCard(event: ev, onUndo: () => undone = true)],
    )));
    await tester.pumpAndSettle();

    // 第一层：展开被取代的区块。
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    // 第二层：工具卡在终态走流水行，撤销按钮收在它自己的展开区里
    // （2026-09-09 信息密度改造）。这条用例的意图不变 —— 折叠不该拿走
    // 撤销能力，只是现在要多展一层才够得着。
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(undone, isTrue,
        reason: '折叠不该拿走撤销能力 —— 这是折叠式相对截断式的核心收益');
  });

  testWidgets('连续两次重发折叠成两个独立区块', (tester) async {
    // 合并成一个会让「到底重发了几次」看不出来。
    await tester.pumpWidget(wrap(const Column(children: [
      SupersededGroup(children: [Text('第一次被取代')]),
      SupersededGroup(children: [Text('第二次被取代')]),
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(SupersededGroup), findsNWidgets(2));
  });

  group('groupSupersededEvents', () {
    test('带标记的 UserTurnEvent 之后的事件归进同一组，直到下一个 UserTurnEvent', () {
      final marked = UserTurnEvent('已重发的那句')..supersededByEdit = true;
      final tool = ToolCallEvent(
        seq: 1,
        callId: 'c1',
        toolName: 'write_file',
        displayCommand: 'write foo',
        description: '',
        check: const CheckResult(decision: ToolDecision.allow),
        status: ToolCallStatus.done,
      );
      final assistant = AssistantTextEvent('取代前的回答');
      final next = UserTurnEvent('新的一轮');

      final groups = groupSupersededEvents([marked, tool, assistant, next]);

      expect(groups.length, 2);
      expect(groups[0], [marked, tool, assistant]);
      expect(groups[1], [next]);
    });

    test('BackgroundJobEvent 留在组里，不打断折叠区块', () {
      final marked = UserTurnEvent('已重发的那句')..supersededByEdit = true;
      final job = BackgroundJobEvent(
        seq: 1,
        jobId: 'job-1',
        command: 'docker build .',
        description: '',
        startedAtMs: 0,
      );
      final tool = ToolCallEvent(
        seq: 2,
        callId: 'c2',
        toolName: 'bash',
        displayCommand: 'ls',
        description: '',
        check: const CheckResult(decision: ToolDecision.allow),
        status: ToolCallStatus.done,
      );

      final groups = groupSupersededEvents([marked, job, tool]);

      // job 之后的 tool **必须仍然属于这一组**。
      //
      // 曾经把 job 排除在组外，想让它不被收起（保住 check_job 入口），结果是
      // 它把 current 复位、job 之后的工具卡全部脱离折叠 —— 不淡化、不收起，
      // 看上去像是当前这一轮跑出来的，而它们其实属于被取代的那一轮。那是
      // 误导，比「多点一次展开」严重得多。
      //
      // 入口不丢的诉求改由渲染层满足：含 job 的组不折叠、整段淡化平铺
      // （agent_view 的 hasBackgroundJob 分支）。分组只负责归属与顺序。
      expect(groups.length, 1);
      expect(groups.single, [marked, job, tool]);
    });

    test('普通事件（没有标记）各自独立成组', () {
      final a = UserTurnEvent('问题一');
      final b = AssistantTextEvent('回答一');

      final groups = groupSupersededEvents([a, b]);

      expect(groups, [
        [a],
        [b],
      ]);
    });
  });
}
