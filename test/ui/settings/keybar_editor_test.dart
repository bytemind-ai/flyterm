import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/data/keybar_config.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/keybar_editor_screen.dart';

class _Seeded {
  final KeybarSettings keybar;
  final TerminalSettings terminal;
  _Seeded(this.keybar, this.terminal);
}

Future<_Seeded> _seeded() async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final k = KeybarSettings();
  await k.seedIfEmpty();
  final t = TerminalSettings(SecureStorageService());
  await t.load();
  return _Seeded(k, t);
}

Widget _wrap(_Seeded s, Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<KeybarSettings>.value(value: s.keybar),
        ChangeNotifierProvider<TerminalSettings>.value(value: s.terminal),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editor renders all 14 default rows', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = await _seeded();
    await tester.pumpWidget(_wrap(s, const KeybarEditorScreen()));
    await tester.pumpAndSettle();
    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('TAB'), findsOneWidget);
    expect(find.text('CTRL'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
  });

  testWidgets('delete button removes the row', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = await _seeded();
    await tester.pumpWidget(_wrap(s, const KeybarEditorScreen()));
    await tester.pumpAndSettle();
    final deleteButtons = find.byKey(const ValueKey('delete-seed-tab'));
    expect(deleteButtons, findsOneWidget);
    await tester.tap(deleteButtons);
    await tester.pumpAndSettle();
    expect(find.text('TAB'), findsNothing);
    expect(s.keybar.items.any((e) => e.id == 'seed-tab'), isFalse);
  });

  testWidgets('restore-defaults via overflow menu confirms then resets',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = await _seeded();
    await s.keybar.remove('seed-tab');
    expect(s.keybar.items.length, 13);
    await tester.pumpWidget(_wrap(s, const KeybarEditorScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore defaults'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(s.keybar.items.length, 14);
  });

  testWidgets('right-buttons section renders 3 rows with checkboxes '
      '(keyboard excluded)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = await _seeded();
    await tester.pumpWidget(_wrap(s, const KeybarEditorScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('right-microphone')), 200);
    expect(find.byKey(const ValueKey('right-favorites')), findsOneWidget);
    expect(find.byKey(const ValueKey('right-microphone')), findsOneWidget);
    expect(find.byKey(const ValueKey('right-ai')), findsOneWidget);
    expect(find.byKey(const ValueKey('right-keyboard')), findsNothing);
  });

  testWidgets('toggling a right-button checkbox flips enabled in settings',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = await _seeded();
    await tester.pumpWidget(_wrap(s, const KeybarEditorScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('right-microphone')), 200);
    final micRow = find.byKey(const ValueKey('right-microphone'));
    expect(micRow, findsOneWidget);
    await tester.tap(find.descendant(
        of: micRow, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    final mic = s.keybar.rightButtons.firstWhere(
        (e) => e.type == RightButton.microphone);
    expect(mic.enabled, isFalse);
  });

  testWidgets('keyboard-mode picker switches TerminalSettings.keyboardTrigger',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = await _seeded();
    expect(s.terminal.keyboardTrigger, KeyboardTriggerMode.singleTap);
    await tester.pumpWidget(_wrap(s, const KeybarEditorScreen()));
    await tester.pumpAndSettle();
    // Tap the "Icon Button" radio tile.
    await tester.tap(find.text('Icon Button'));
    await tester.pumpAndSettle();
    expect(s.terminal.keyboardTrigger, KeyboardTriggerMode.iconButton);
  });
}
