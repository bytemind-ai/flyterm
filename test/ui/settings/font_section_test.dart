import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/appearance_settings_screen.dart';

/// 字体段行为测试。
///
/// 2026-10-07 设置页重排把字体/字号/行高从 `SettingsScreen` 的「终端」段迁进
/// `AppearanceSettingsScreen`。本文件的断言全部保持不变（同一批 l10n key、
/// 同一批控件），只把挂载点从 `SettingsScreen` 换成外观子页 —— 因为原挂载点
/// 已不再渲染这些控件。顺带把 provider 树从"整个设置页所需"缩减为"外观页所需"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> pump(WidgetTester tester, TerminalSettings settings) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<TerminalSettings>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const AppearanceSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('font section renders 代码字体 + 行间距 rows', (tester) async {
    final s = TerminalSettings(SecureStorageService());
    await pump(tester, s);
    expect(find.text('代码字体'), findsOneWidget);
    expect(find.text('行间距'), findsOneWidget);
    // CJK section removed
    expect(find.text('中文字体'), findsNothing);
  });

  testWidgets('selecting Courier Prime via dropdown updates settings.fontFamily',
      (tester) async {
    final s = TerminalSettings(SecureStorageService());
    await pump(tester, s);
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Courier Prime').last);
    await tester.pumpAndSettle();
    expect(s.fontFamily, 'CourierPrime');
  });

  testWidgets('Courier Prime is selectable', (tester) async {
    final s = TerminalSettings(SecureStorageService());
    await pump(tester, s);
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Courier Prime').last);
    await tester.pumpAndSettle();
    expect(s.fontFamily, 'CourierPrime');
  });

  testWidgets('line height slider drag updates value', (tester) async {
    final s = TerminalSettings(SecureStorageService());
    await pump(tester, s);
    // index 0 = font size, index 1 = line height。外观页只有这两个 Slider
    // （已核实：主题/光标是下拉，预览是纯展示），所以索引语义与旧设置页一致。
    final slider = find.byType(Slider).at(1);
    await tester.drag(slider, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(s.lineHeight, greaterThan(1.2));
  });
}
