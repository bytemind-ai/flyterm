import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/terminal_screen.dart';

void main() {
  group('StatusDot', () {
    Future<void> pump(WidgetTester tester, {
      DotProtocol protocol = DotProtocol.ssh,
      bool isStable = true,
      bool isInitial = false,
      bool isDisconnected = false,
      bool isReconnecting = false,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: StatusDot(
            protocol: protocol,
            isStable: isStable,
            isInitial: isInitial,
            isDisconnected: isDisconnected,
            isReconnecting: isReconnecting,
          )),
        ),
      ));
    }

    testWidgets('green fill when SSH connected and stable', (tester) async {
      await pump(tester, protocol: DotProtocol.ssh);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFF66BB6A));
    });

    testWidgets('blue fill when mosh connected and stable', (tester) async {
      await pump(tester, protocol: DotProtocol.mosh);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFF42A5F5));
    });

    testWidgets('orange fill when network unstable', (tester) async {
      await pump(tester, protocol: DotProtocol.ssh, isStable: false);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFFF8000));
    });

    testWidgets('red fill when disconnected (highest priority)', (tester) async {
      await pump(tester, protocol: DotProtocol.mosh, isDisconnected: true);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFEF5350));
    });

    testWidgets('grey fill when initial (never connected)', (tester) async {
      await pump(tester, protocol: DotProtocol.ssh, isInitial: true);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFF9E9E9E));
    });

    testWidgets('SSH reconnecting keeps green colour (no amber)', (tester) async {
      await pump(tester, protocol: DotProtocol.ssh, isReconnecting: true);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFF66BB6A));
    });

    testWidgets('mosh reconnecting keeps blue colour (no amber)', (tester) async {
      await pump(tester, protocol: DotProtocol.mosh, isReconnecting: true);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFF42A5F5));
    });

    testWidgets('reconnecting outranks unstable: protocol colour wins',
        (tester) async {
      await pump(tester,
          protocol: DotProtocol.ssh, isReconnecting: true, isStable: false);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFF66BB6A));
    });

    testWidgets('disconnected outranks reconnecting', (tester) async {
      await pump(tester,
          protocol: DotProtocol.ssh, isDisconnected: true, isReconnecting: true);
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFEF5350));
    });

    testWidgets('dot is 6×6 dp', (tester) async {
      await pump(tester, protocol: DotProtocol.ssh);
      final size = tester.getSize(find.byType(Container));
      expect(size.width, 6.0);
      expect(size.height, 6.0);
    });
  });
}
