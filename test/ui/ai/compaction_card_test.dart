import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/ai/widgets/compaction_card.dart';
import 'package:flyterm/ui/ai/widgets/dense_event_row.dart';

Widget wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('默认折叠，只显示条数', (tester) async {
    await tester.pumpWidget(wrap(CompactionCard(
      event: CompactedEvent(
          droppedMessages: 42, summary: 'CONFIRMED: nginx 在跑'),
    )));

    expect(find.textContaining('42'), findsOneWidget);
    expect(find.textContaining('nginx 在跑'), findsNothing);
  });

  testWidgets('点开显示摘要全文——摘错了要看得见', (tester) async {
    await tester.pumpWidget(wrap(CompactionCard(
      event: CompactedEvent(
          droppedMessages: 42, summary: 'CONFIRMED: nginx 在跑'),
    )));

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    expect(find.textContaining('nginx 在跑'), findsOneWidget);
  });

  testWidgets('摘要为空时不给展开手势——点开一片空白像是坏了', (tester) async {
    await tester.pumpWidget(wrap(CompactionCard(
      event: CompactedEvent(droppedMessages: 3, summary: ''),
    )));

    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('压缩卡走流水行', (tester) async {
    await tester.pumpWidget(wrap(CompactionCard(
      event: CompactedEvent(droppedMessages: 42, summary: '摘要'),
    )));
    expect(find.byType(DenseEventRow), findsOneWidget);
  });

  testWidgets('摘要逐字可读，不走 markdown', (tester) async {
    // 摘要里的 job_id=abc_1 带下划线，markdown 会把它吃成斜体。
    await tester.pumpWidget(wrap(CompactionCard(
      event: CompactedEvent(droppedMessages: 1, summary: 'job_id=abc_1'),
    )));
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('job_id=abc_1'), findsOneWidget);
  });
}
