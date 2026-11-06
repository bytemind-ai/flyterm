import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/ai_provider_form_screen.dart';

/// 表单页只在 `_save()` 里 `context.read`，构建阶段一个 provider 都不碰 ——
/// 所以可以裸 pump。测试全程不点保存，也就不会走到 sqflite（在 testWidgets
/// 里 await 它会挂死而不是报错）。
Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const AIProviderFormScreen(),
    ),
  );
  await tester.pumpAndSettle();
}

/// 在类型下拉里选中 [type]。
///
/// 选中后菜单项和按钮上会同时存在同一段文本，取 `.last` 拿菜单里那个。
Future<void> _selectType(WidgetTester tester, String type) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(type).last);
  await tester.pumpAndSettle();
}

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

  testWidgets('类型下拉里有 gemini', (tester) async {
    await _pump(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('gemini'), findsWidgets);
  });

  testWidgets('选 gemini 时出现 baseUrl 字段（反代场景）', (tester) async {
    await _pump(tester);
    await _selectType(tester, 'gemini');
    expect(find.text(l.baseUrl), findsOneWidget);
  });

  testWidgets('选 anthropic 时也出现 baseUrl 字段', (tester) async {
    // 这一条是新行为：anthropic 原先不给填 baseUrl。
    await _pump(tester);
    await _selectType(tester, 'anthropic');
    expect(find.text(l.baseUrl), findsOneWidget);
  });

  testWidgets('baseUrl 提示按类型给对，不会给 anthropic 显示 openai 的端点',
      (tester) async {
    await _pump(tester);
    await _selectType(tester, 'anthropic');
    expect(find.text('https://api.anthropic.com/v1'), findsOneWidget);
    expect(find.text('https://api.openai.com/v1'), findsNothing);
  });

  testWidgets('gemini 能填 extraParams（factory 会转发它）', (tester) async {
    // ADVANCED 区块在默认 800×600 测试视口的折叠线以下（该字段前面还有
    // presets/identity/endpoint/auth 几个 section），需要放大视口才能让它
    // 进入 ListView 的 cacheExtent 被真正 build 出来。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester);
    await _selectType(tester, 'gemini');
    expect(find.text(l.extrasJson), findsOneWidget);
  });
}
