import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/appearance_settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  late TerminalSettings settings;

  setUp(() async {
    settings = TerminalSettings(SecureStorageService());
  });

  Future<void> pump(WidgetTester tester) async {
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

  testWidgets('渲染 6 个外观控件', (tester) async {
    await pump(tester);
    expect(find.text('终端主题'), findsOneWidget);
    expect(find.text('光标样式'), findsOneWidget);
    expect(find.text('代码字体'), findsOneWidget);
    expect(find.text('终端字体大小'), findsOneWidget);
    expect(find.text('行间距'), findsOneWidget);
    expect(find.textContaining('const x = 42;'), findsOneWidget);
  });

  testWidgets('有 AppBar 标题', (tester) async {
    await pump(tester);
    expect(find.widgetWithText(AppBar, '外观设置'), findsOneWidget);
  });

  testWidgets('改字号写回 TerminalSettings', (tester) async {
    await pump(tester);
    final before = settings.fontSize;
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(settings.fontSize, before + 1);
  });
}
