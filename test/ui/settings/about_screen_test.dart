import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/about_screen.dart';

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
        home: const AboutScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染版本行与开源许可入口', (tester) async {
    await pump(tester);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
  });

  testWidgets('连击 7 次版本行切换 debugOverlay', (tester) async {
    await pump(tester);
    expect(settings.debugOverlay, isFalse);
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('版本'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(settings.debugOverlay, isTrue);
  });

  testWidgets('未连击 7 次不切换（4 次应仍为 false）', (tester) async {
    await pump(tester);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('版本'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(settings.debugOverlay, isFalse);
  });
}
