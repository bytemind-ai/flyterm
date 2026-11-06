import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/approval_card.dart';

// 钉住中文 locale —— 断言的是 l10n 出来的中文文案。
Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

ToolCallEvent _event(CheckResult check) => ToolCallEvent(
      seq: 0,
      callId: 'c1',
      toolName: 'bash',
      displayCommand: 'systemctl restart nginx',
      description: '重启 nginx 让新配置生效',
      check: check,
      status: ToolCallStatus.awaitingApproval,
    );

const _normal = CheckResult(
  decision: ToolDecision.needApproval,
  reason: ApprovalReason.noMatchingRule,
  suggestedRule: 'systemctl restart *',
);
const _deny = CheckResult(
  decision: ToolDecision.needApproval,
  reason: ApprovalReason.credentialDeny,
);
const _fileWrite = CheckResult(
  decision: ToolDecision.needApproval,
  reason: ApprovalReason.fileWrite,
);

/// 卡内按钮 = FilledButton（含 tonal） + TextButton。
int _buttonCount(WidgetTester t) =>
    t.widgetList(find.byType(FilledButton)).length +
    t.widgetList(find.byType(TextButton)).length;

void main() {
  testWidgets('normal 卡恰好 3 个按钮', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_normal),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    await t.pumpAndSettle();

    expect(_buttonCount(t), equals(3), reason: '拒绝 / 就这一次 / 总是允许');
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('就这一次'), findsOneWidget);
    expect(find.text('总是允许'), findsOneWidget);
  });

  testWidgets('fileWrite 卡恰好 2 个按钮（canRemember=false）', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_fileWrite),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    await t.pumpAndSettle();

    expect(_buttonCount(t), equals(2));
    expect(find.text('总是允许'), findsNothing);
  });

  testWidgets('bypass + deny → 换成「本轮不再问」', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_deny),
      providerName: 'OpenAI',
      bypassMode: true,
      onDecision: (_, __, ___) {},
    )));
    await t.pumpAndSettle();

    expect(_buttonCount(t), equals(3),
        reason: '拒绝 / 就这一次 / 本轮不再问（没有「总是允许」）');
    expect(find.text('本轮不再问'), findsOneWidget);
  });

  testWidgets('「加入方案」按钮已删 —— 防止有人加回来', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_normal),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    await t.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(find.text(l.agentAddToPlan), findsNothing);
  });

  testWidgets('规则文本默认折叠，点开才出输入框', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_normal),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    await t.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('systemctl restart *'), findsOneWidget);

    await t.tap(find.textContaining('systemctl restart *'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });
}
