import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/tool_call_card.dart';

void main() {
  ToolCallEvent ev(String tool, {String? output, FileEditPreview? preview}) {
    final e = ToolCallEvent(
      seq: 1,
      callId: 'c1',
      toolName: tool,
      displayCommand: tool == 'load_skill'
          ? 'load skill: nginx'
          : 'save skill: nginx',
      description: '排查 502',
      check: const CheckResult(decision: ToolDecision.allow),
      preview: preview,
    );
    e.status = ToolCallStatus.done;
    e.output = output;
    return e;
  }

  Future<void> pump(WidgetTester tester, ToolCallEvent e) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ToolCallCard(event: e)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('load_skill 显示成一行，不展示正文', (tester) async {
    await pump(
        tester,
        ev('load_skill',
            output: '[skill: nginx]\n' + ('这是很长的正文\n' * 200)));
    expect(find.textContaining('nginx'), findsWidgets);
    expect(find.textContaining('这是很长的正文'), findsNothing,
        reason: '8 KiB markdown 铺在手机屏幕上是灾难');
  });

  testWidgets('load_skill 卡片不可展开', (tester) async {
    await pump(tester, ev('load_skill', output: '[skill: nginx]\nBODY'));
    expect(find.byType(ExpansionTile), findsNothing);
  });

  testWidgets('save_skill 展示正文预览 —— 用户在批准永久 prompt', (tester) async {
    await pump(
      tester,
      ev('save_skill',
          preview: const FileEditPreview(
              path: 'nginx', newText: 'SKILL_BODY_MARK')),
    );
    expect(find.textContaining('SKILL_BODY_MARK'), findsOneWidget);
  });

  testWidgets('save_skill 显示 description', (tester) async {
    await pump(
      tester,
      ev('save_skill',
          preview: const FileEditPreview(path: 'nginx', newText: 'B')),
    );
    expect(find.textContaining('排查 502'), findsWidgets);
  });
}
