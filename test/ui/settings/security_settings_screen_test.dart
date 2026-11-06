import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/security_settings_screen.dart';

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
        home: const SecuritySettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染危险命令保护', (tester) async {
    await pump(tester);
    expect(find.text('危险命令保护'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
  });

  testWidgets('不再包含生物识别锁（该功能已于 2026-10-07 整体移除）',
      (tester) async {
    await pump(tester);
    expect(find.text('生物识别锁'), findsNothing);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
  });

  testWidgets('切换危险命令保护写回 TerminalSettings', (tester) async {
    await pump(tester);
    final before = settings.dangerousCommandGuard;
    await tester.tap(find.widgetWithText(SwitchListTile, '危险命令保护'));
    await tester.pumpAndSettle();
    expect(settings.dangerousCommandGuard, !before);
  });
}
