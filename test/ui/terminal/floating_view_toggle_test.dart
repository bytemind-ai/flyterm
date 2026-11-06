import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/floating_view_toggle.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(colorScheme: ColorScheme.dark()),
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            child,
          ],
        ),
      ),
    );

void main() {
  testWidgets('shows terminal icon when not in sftp mode', (tester) async {
    await tester.pumpWidget(_wrap(
      FloatingViewToggle(isSftpMode: false, onToggle: () {}),
    ));
    // When not in sftp mode, the button shows the sftp-target icon (folder_open)
    // so the user can tap to switch to sftp view.
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.byIcon(Icons.terminal), findsNothing);
  });

  testWidgets('shows folder icon when in sftp mode', (tester) async {
    await tester.pumpWidget(_wrap(
      FloatingViewToggle(isSftpMode: true, onToggle: () {}),
    ));
    // When in sftp mode, the button shows the terminal-target icon (terminal)
    // so the user can tap to switch back to terminal view.
    expect(find.byIcon(Icons.terminal), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsNothing);
  });

  testWidgets('tapping calls onToggle', (tester) async {
    int taps = 0;
    await tester.pumpWidget(_wrap(
      FloatingViewToggle(isSftpMode: false, onToggle: () => taps++),
    ));
    await tester.tap(find.byType(FloatingViewToggle));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('collapsed mode renders narrow bar not circle', (tester) async {
    await tester.pumpWidget(_wrap(
      FloatingViewToggle(
        isSftpMode: false,
        onToggle: () {},
        isCollapsed: true,
        onCollapseTap: () {},
      ),
    ));
    // When collapsed, the icons are gone
    expect(find.byIcon(Icons.terminal), findsNothing);
    expect(find.byIcon(Icons.folder_open), findsNothing);
  });

  testWidgets('tapping collapsed bar calls onCollapseTap', (tester) async {
    int taps = 0;
    await tester.pumpWidget(_wrap(
      FloatingViewToggle(
        isSftpMode: false,
        onToggle: () {},
        isCollapsed: true,
        onCollapseTap: () => taps++,
      ),
    ));
    await tester.tap(find.byType(FloatingViewToggle));
    await tester.pump();
    expect(taps, 1);
  });
}
