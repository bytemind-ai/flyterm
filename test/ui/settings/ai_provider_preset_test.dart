import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/data/models/ai_provider_config.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/ai_provider_form_screen.dart';

/// 表单页只在 `_save()` 里 `context.read` 那三个 provider，构建阶段一个都不碰
/// —— 所以这里可以裸 pump。测试全程不点保存，也就不会走到 sqflite（在
/// testWidgets 里 await 它会挂死而不是报错）。
Future<void> _pump(WidgetTester tester, {AIProviderConfig? existing}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AIProviderFormScreen(existing: existing),
    ),
  );
  await tester.pumpAndSettle();
}

/// 按 label 取输入框当前文本。表单里的 TextFormField 没有 key，靠 decoration
/// 的 labelText 定位是唯一稳定的抓手。
String _fieldText(WidgetTester tester, String label) {
  final field = tester.widgetList<TextField>(find.byType(TextField)).firstWhere(
        (t) => t.decoration?.labelText == label,
      );
  return field.controller?.text ?? '';
}

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

  testWidgets('点预设填好 baseUrl 与 model', (tester) async {
    await _pump(tester);

    await tester.tap(find.widgetWithText(ActionChip, 'DeepSeek'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, l.baseUrl), 'https://api.deepseek.com/v1');
    expect(_fieldText(tester, l.model), 'deepseek-v4-pro');
  });

  testWidgets('显示名为空时用预设名填上', (tester) async {
    await _pump(tester);

    await tester.tap(find.widgetWithText(ActionChip, 'Kimi'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, l.displayName), 'Kimi');
  });

  testWidgets('已经起过名字的，预设不许冲掉', (tester) async {
    // 用户特意写了「生产环境」再点预设想省掉抄 URL —— 结果名字没了，
    // 这是纯粹的破坏，且不会有任何提示。
    await _pump(tester);

    await tester.enterText(
        find.widgetWithText(TextFormField, l.displayName), '生产环境');
    await tester.tap(find.widgetWithText(ActionChip, 'DeepSeek'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, l.displayName), '生产环境');
    // 该填的照样填了 —— 保护名字不等于什么都不做。
    expect(_fieldText(tester, l.baseUrl), 'https://api.deepseek.com/v1');
  });

  testWidgets('智谱的 base URL 不带 /v1', (tester) async {
    // OpenAIProvider 拼的是 `$baseUrl/chat/completions`，不硬塞版本段。
    // 预设里要是习惯性写成 /v1，请求会变成 .../api/paas/v4/v1/... 然后 404。
    await _pump(tester);

    await tester.tap(find.widgetWithText(ActionChip, 'GLM'));
    await tester.pumpAndSettle();

    expect(_fieldText(tester, l.baseUrl),
        'https://open.bigmodel.cn/api/paas/v4');
  });

  testWidgets('编辑已有配置时不出现预设', (tester) async {
    // 编辑页存在的意义就是保住这份配置，而预设点一下就覆盖 baseUrl/model。
    await _pump(
      tester,
      existing: const AIProviderConfig(
        id: 'p1',
        name: '我的 DeepSeek',
        type: 'openai',
        model: 'deepseek-v4-flash',
        baseUrl: 'https://api.deepseek.com/v1',
      ),
    );

    expect(find.byType(ActionChip), findsNothing);
    expect(find.text(l.providerSectionPresets), findsNothing);
  });
}
