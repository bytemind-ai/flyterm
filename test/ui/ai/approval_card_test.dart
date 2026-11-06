import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/approval_card.dart';

/// 本组测试断言的是 l10n 出来的中文文案（「就这一次」等），
/// 所以必须钉住 locale —— 默认 locale 下拿到的是英文，断言必然失败。
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

// NOTE: canRemember/denyHit 是从 reason 派生的 getter，不是构造参数
// （就是为了不让它们能被独立设置而漂移）——所以这里只传 reason。
const _normal = CheckResult(
  decision: ToolDecision.needApproval,
  reason: ApprovalReason.noMatchingRule,
  suggestedRule: 'systemctl restart *',
);

const _deny = CheckResult(
  decision: ToolDecision.needApproval,
  reason: ApprovalReason.credentialDeny,
);

void main() {
  testWidgets('显示三个按钮与建议规则', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_normal),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    expect(find.text('就这一次'), findsOneWidget);
    expect(find.text('总是允许'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.textContaining('systemctl restart *'), findsOneWidget);
  });

  testWidgets('deny 卡没有「总是允许」', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_deny),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    expect(find.text('总是允许'), findsNothing);
    expect(find.text('就这一次'), findsOneWidget);
  });

  testWidgets('deny 卡显示凭据警示并带 provider 名', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_deny),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    expect(find.textContaining('OpenAI'), findsOneWidget);
  });

  testWidgets('就这一次回调不带规则', (t) async {
    ApprovalDecision? got;
    String? rule;
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_normal),
      providerName: 'OpenAI',
      onDecision: (d, r, __) {
        got = d;
        rule = r;
      },
    )));
    await t.tap(find.text('就这一次'));
    expect(got, equals(ApprovalDecision.allowOnce));
    expect(rule, isNull);
  });

  testWidgets('总是允许回调带上规则', (t) async {
    String? rule;
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_normal),
      providerName: 'OpenAI',
      onDecision: (_, r, __) => rule = r,
    )));
    await t.tap(find.text('总是允许'));
    expect(rule, equals('systemctl restart *'));
  });

  testWidgets('拒绝回调传出 reject', (t) async {
    ApprovalDecision? got;
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(_normal),
      providerName: 'OpenAI',
      onDecision: (d, _, __) => got = d,
    )));
    await t.tap(find.text('拒绝'));
    expect(got, equals(ApprovalDecision.reject));
  });

  testWidgets('元字符原因被展示', (t) async {
    const meta = CheckResult(
      decision: ToolDecision.needApproval,
      reason: ApprovalReason.shellMetachar,
    );
    await t.pumpWidget(_wrap(ApprovalCard(
      event: _event(meta),
      providerName: 'OpenAI',
      onDecision: (_, __, ___) {},
    )));
    expect(find.textContaining('元字符'), findsOneWidget);
  });

  testWidgets('fileWrite 的卡片没有「总是允许」', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: ToolCallEvent(
        seq: 0,
        callId: 'c1',
        toolName: 'write_file',
        displayCommand: 'write /etc/x.conf (3 lines)',
        description: '写配置',
        check: const CheckResult(
          decision: ToolDecision.needApproval,
          reason: ApprovalReason.fileWrite,
        ),
        preview: const FileEditPreview(path: '/etc/x.conf', newText: 'a\nb\n'),
      ),
      providerName: 'Anthropic',
      onDecision: (_, __, ___) {},
    )));

    expect(find.text('就这一次'), findsOneWidget);
    expect(find.text('总是允许'), findsNothing);
  });

  testWidgets('edit_file 的卡片显示 old 与 new', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(
      event: ToolCallEvent(
        seq: 0,
        callId: 'c1',
        toolName: 'edit_file',
        displayCommand: 'edit /etc/x.conf:2',
        description: '改端口',
        check: const CheckResult(
          decision: ToolDecision.needApproval,
          reason: ApprovalReason.fileWrite,
        ),
        preview: const FileEditPreview(
          path: '/etc/x.conf',
          oldText: 'listen 80;',
          newText: 'listen 8080;',
          atLine: 2,
        ),
      ),
      providerName: 'Anthropic',
      onDecision: (_, __, ___) {},
    )));

    expect(find.textContaining('listen 80;'), findsOneWidget);
    expect(find.textContaining('listen 8080;'), findsOneWidget);
  });

  group('本轮不再问按钮', () {
    testWidgets('bypass + 凭据命中时出现，点击回调带 silence=true', (t) async {
      bool? silenced;
      await t.pumpWidget(_wrap(ApprovalCard(
        event: _event(_deny),
        providerName: 'Anthropic',
        bypassMode: true,
        onDecision: (_, __, silence) => silenced = silence,
      )));

      expect(find.text('本轮不再问'), findsOneWidget);
      await t.tap(find.text('本轮不再问'));
      expect(silenced, isTrue);
    });

    testWidgets('ask 档（bypassMode: false）不渲染 —— 出现会让人以为边界被关掉了',
        (t) async {
      await t.pumpWidget(_wrap(ApprovalCard(
        event: _event(_deny),
        providerName: 'Anthropic',
        onDecision: (_, __, ___) {},
      )));

      expect(find.text('本轮不再问'), findsNothing);
    });

    testWidgets('bypass 但非凭据命中（noMatchingRule）时不渲染', (t) async {
      await t.pumpWidget(_wrap(ApprovalCard(
        event: _event(_normal),
        providerName: 'Anthropic',
        bypassMode: true,
        onDecision: (_, __, ___) {},
      )));

      expect(find.text('本轮不再问'), findsNothing);
    });
  });
}
