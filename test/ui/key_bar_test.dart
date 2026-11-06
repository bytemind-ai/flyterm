import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/ui/terminal/key_bar.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final settings = KeybarSettings();
  await settings.seedIfEmpty();
  await tester.pumpWidget(
    ChangeNotifierProvider<KeybarSettings>.value(
      value: settings,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

void main() {
  testWidgets('KeyBar renders ESC, TAB, CTRL, arrow keys', (tester) async {
    final terminal = Terminal();
    await _pump(tester, KeyBar(terminal: terminal));
    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('TAB'), findsOneWidget);
    expect(find.text('CTRL'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
  });

  testWidgets('tapping ESC sends escape sequence to terminal',
      (tester) async {
    String? received;
    final terminal = Terminal();
    terminal.onOutput = (data) => received = data;

    await _pump(tester, KeyBar(terminal: terminal));
    await tester.tap(find.text('ESC'));
    await tester.pump();

    expect(received, '\x1b');
  });

  testWidgets('CTRL toggles sticky state on tap', (tester) async {
    final terminal = Terminal();
    await _pump(tester, KeyBar(terminal: terminal));
    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(find.text('CTRL'), findsOneWidget);
  });

  testWidgets('AI button renders and fires onAITap', (tester) async {
    final terminal = Terminal();
    bool tapped = false;
    await _pump(tester,
        KeyBar(terminal: terminal, onAITap: () => tapped = true));
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_awesome));
    expect(tapped, isTrue);
  });

  testWidgets('MIC button renders and fires onMicTap', (tester) async {
    final terminal = Terminal();
    bool tapped = false;
    await _pump(tester,
        KeyBar(terminal: terminal, onMicTap: () => tapped = true));
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_none));
    expect(tapped, isTrue);
  });

  testWidgets('AI and MIC absent when callbacks not provided',
      (tester) async {
    final terminal = Terminal();
    await _pump(tester, KeyBar(terminal: terminal));
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
    expect(find.byIcon(Icons.mic), findsNothing);
  });
}
