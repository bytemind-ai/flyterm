// ExportPreviewScreen：两个关键行为。
//
// 1. 脱敏计数 > 0 时顶部显示横幅（`aiExportRedacted`），= 0 时不显示。
// 2. 事件流渲染出的正文为空时，展示空态文案而不是空白页 —— 且不出现分享按钮
//    （没内容可分享）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/export_preview_screen.dart';

Future<void> _pump(WidgetTester tester, List<AgentEvent> events) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExportPreviewScreen(events: events, filenameHint: 'test'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

  testWidgets('有内容且含密钥时显示脱敏横幅与分享按钮', (tester) async {
    await _pump(tester, [
      UserTurnEvent('帮我看下 api_key=sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      AssistantTextEvent('好的，已经看过了'),
    ]);
    expect(find.text(l.aiExportRedacted(1)), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
  });

  testWidgets('无密钥时不显示脱敏横幅', (tester) async {
    await _pump(tester, [
      UserTurnEvent('普通的一轮对话'),
      AssistantTextEvent('普通的回答'),
    ]);
    expect(find.byIcon(Icons.shield_outlined), findsNothing);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
  });

  testWidgets('空事件流显示空态，不出现分享按钮', (tester) async {
    await _pump(tester, []);
    expect(find.text(l.aiExportEmpty), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsNothing);
  });
}
