import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/plan_proposal_card.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

final _calls = [
  const ToolCall(id: 'c1', name: 'edit_file', args: {
    'path': '/etc/nginx/nginx.conf',
    'description': '把 listen 80 改成 8080',
  }),
  const ToolCall(id: 'c2', name: 'bash', args: {
    'command': 'systemctl reload nginx',
    'description': '重载配置让改动生效',
  }),
];

void main() {
  testWidgets('列出每一项的 description 与真实动作', (t) async {
    await t.pumpWidget(_wrap(PlanProposalCard(
      calls: _calls,
      onApprove: () {},
      onDiscard: () {},
    )));

    // 主标题：模型写给用户的那句话
    expect(find.text('把 listen 80 改成 8080'), findsOneWidget);
    expect(find.text('重载配置让改动生效'), findsOneWidget);
    // 副标题：真实要跑的东西
    expect(find.textContaining('/etc/nginx/nginx.conf'), findsWidgets);
    expect(find.textContaining('systemctl reload nginx'), findsWidgets);
  });

  testWidgets('显示待执行项数', (t) async {
    await t.pumpWidget(_wrap(PlanProposalCard(
      calls: _calls,
      onApprove: () {},
      onDiscard: () {},
    )));

    final l = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l.agentProposalCount(2)), findsOneWidget);
  });

  testWidgets('点「全部执行」触发 onApprove', (t) async {
    var approved = 0;
    await t.pumpWidget(_wrap(PlanProposalCard(
      calls: _calls,
      onApprove: () => approved++,
      onDiscard: () {},
    )));

    await t.tap(find.text('全部执行'));
    expect(approved, equals(1));
  });

  testWidgets('点「丢弃」触发 onDiscard', (t) async {
    var discarded = 0;
    await t.pumpWidget(_wrap(PlanProposalCard(
      calls: _calls,
      onApprove: () {},
      onDiscard: () => discarded++,
    )));

    await t.tap(find.text('丢弃'));
    expect(discarded, equals(1));
  });

  testWidgets('空队列什么都不渲染', (t) async {
    await t.pumpWidget(_wrap(PlanProposalCard(
      calls: const [],
      onApprove: () {},
      onDiscard: () {},
    )));

    expect(find.text('全部执行'), findsNothing);
    expect(find.text('丢弃'), findsNothing);
  });

  testWidgets('没有逐项勾选——项间有依赖，只能整批', (t) async {
    await t.pumpWidget(_wrap(PlanProposalCard(
      calls: _calls,
      onApprove: () {},
      onDiscard: () {},
    )));

    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('description 缺失时退回到真实动作，不留空白', (t) async {
    await t.pumpWidget(_wrap(PlanProposalCard(
      calls: const [
        ToolCall(id: 'c1', name: 'write_file', args: {'path': '/etc/x.conf'}),
      ],
      onApprove: () {},
      onDiscard: () {},
    )));

    expect(find.textContaining('/etc/x.conf'), findsWidgets);
  });
}
