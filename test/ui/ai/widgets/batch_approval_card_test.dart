import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/batch_approval_card.dart';

Widget wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

final calls = [
  ToolCall(id: 'a', name: 'bash', args: {
    'command': 'systemctl restart nginx',
    'description': '重启 nginx',
    'server': 'web-1',
  }),
  ToolCall(id: 'b', name: 'bash', args: {
    'command': 'systemctl restart nginx',
    'description': '重启 nginx',
    'server': 'web-2',
  }),
];

void main() {
  testWidgets('列出每条调用的目标机器', (tester) async {
    await tester.pumpWidget(wrap(BatchApprovalCard(
      calls: calls,
      targets: const ['web-1', 'web-2'],
      onApproveAll: () {},
      onDiscard: () {},
    )));
    await tester.pump();

    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('web-2'), findsOneWidget);
    expect(find.textContaining('systemctl restart nginx'), findsWidgets);
    expect(find.text('全部同意'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('目标为 null 时显示「当前会话」，不显示空白', (tester) async {
    await tester.pumpWidget(wrap(BatchApprovalCard(
      calls: [calls.first],
      targets: const [null],
      onApproveAll: () {},
      onDiscard: () {},
    )));
    await tester.pump();

    expect(find.text('当前会话'), findsOneWidget);
  });

  testWidgets('两个按钮各自触发回调', (tester) async {
    var approved = false;
    var discarded = false;
    await tester.pumpWidget(wrap(BatchApprovalCard(
      calls: calls,
      targets: const ['web-1', 'web-2'],
      onApproveAll: () => approved = true,
      onDiscard: () => discarded = true,
    )));
    await tester.pump();

    await tester.tap(find.text('全部同意'));
    await tester.tap(find.text('取消'));
    expect(approved, isTrue);
    expect(discarded, isTrue);
  });
}
