import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/terminal/selection_geometry.dart' show HandleHit;
import 'package:flyterm/ui/terminal/selection_overlay.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(width: 400, height: 800, child: child),
      ),
    );

void main() {
  const start = Offset(50, 200);
  const end = Offset(200, 300);

  TerminalSelectionOverlay _overlayAt({
    required Offset start,
    required Offset end,
    VoidCallback? onCopy,
    void Function(HandleHit which, Offset globalPosition)? onHandleGrab,
  }) =>
      TerminalSelectionOverlay(
        handles: ValueNotifier(HandlePositions(start, end)),
        onCopy: onCopy ?? () {},
        onHandleGrab: onHandleGrab ?? (_, __) {},
        onHandleMove: (_) {},
        onHandleRelease: () {},
      );

  TerminalSelectionOverlay _overlay({VoidCallback? onCopy}) =>
      _overlayAt(start: start, end: end, onCopy: onCopy);

  testWidgets('renders copy button', (tester) async {
    await tester.pumpWidget(_wrap(_overlay()));
    await tester.pump(); // allow localizations to settle
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });

  testWidgets('onCopy fires when copy button tapped', (tester) async {
    var called = false;
    await tester.pumpWidget(_wrap(_overlay(onCopy: () => called = true)));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.copy));
    expect(called, isTrue);
  });

  testWidgets('handles repaint when the notifier changes', (tester) async {
    final handles = ValueNotifier(
      const HandlePositions(Offset(50, 200), Offset(200, 300)),
    );
    await tester.pumpWidget(_wrap(
      TerminalSelectionOverlay(
        handles: handles,
        onCopy: () {},
        onHandleGrab: (_, __) {},
        onHandleMove: (_) {},
        onHandleRelease: () {},
      ),
    ));
    await tester.pump();
    expect(
      tester.getRect(find.byKey(const ValueKey('start_handle'))).center.dx,
      closeTo(50, 0.5),
    );

    handles.value = const HandlePositions(Offset(120, 200), Offset(200, 300));
    await tester.pump();
    expect(
      tester.getRect(find.byKey(const ValueKey('start_handle'))).center.dx,
      closeTo(120, 0.5),
    );
  });

  group('HandlePositions', () {
    test('equal values compare equal so ValueNotifier can skip notifying', () {
      expect(
        const HandlePositions(Offset(1, 2), Offset(3, 4)),
        const HandlePositions(Offset(1, 2), Offset(3, 4)),
      );
      expect(
        const HandlePositions(Offset(1, 2), Offset(3, 4)).hashCode,
        const HandlePositions(Offset(1, 2), Offset(3, 4)).hashCode,
      );
      expect(
        const HandlePositions(Offset(1, 2), Offset(3, 4)),
        isNot(const HandlePositions(Offset(1, 2), Offset(3, 5))),
      );
    });

    test('a ValueNotifier does not notify on an equal reassignment', () {
      final n = ValueNotifier(
        const HandlePositions(Offset(1, 2), Offset(3, 4)),
      );
      var notified = 0;
      n.addListener(() => notified++);
      n.value = const HandlePositions(Offset(1, 2), Offset(3, 4));
      expect(notified, 0);
      n.value = const HandlePositions(Offset(1, 2), Offset(3, 5));
      expect(notified, 1);
    });
  });

  group('_SelectionHandle placement', () {
    testWidgets('handle painted outside the viewport is NOT clamped back in',
        (tester) async {
      // The old implementation squeezed the 44x44 hit box inside the overlay
      // bounds, which moved the handle up to ~38px away from its real anchor.
      // Hit testing is now distance-based in the outer Listener, so this layer
      // must paint exactly where it is told.
      await tester.pumpWidget(_wrap(_overlayAt(
        start: const Offset(-20, -20),
        end: const Offset(50, 50),
      )));
      await tester.pump();
      final rect = tester.getRect(find.byKey(const ValueKey('start_handle')));
      expect(rect.center.dx, lessThan(0));
      expect(rect.top, lessThan(0));
    });

    testWidgets('handle past the right/bottom edge is NOT clamped back in',
        (tester) async {
      await tester.pumpWidget(_wrap(_overlayAt(
        start: const Offset(50, 200),
        end: const Offset(400, 800),
      )));
      await tester.pump();
      final rect = tester.getRect(find.byKey(const ValueKey('end_handle')));
      expect(rect.center.dx, closeTo(400, 0.5));
      expect(rect.right, greaterThan(400));
      expect(rect.bottom, greaterThan(800));
    });

    testWidgets('interior start handle sits exactly on its anchor',
        (tester) async {
      await tester.pumpWidget(_wrap(_overlayAt(
        start: const Offset(200, 400),
        end: const Offset(300, 500),
      )));
      await tester.pump();
      final rect = tester.getRect(find.byKey(const ValueKey('start_handle')));
      expect(rect.center.dx, closeTo(200, 0.5));
      // top = position.dy - visualHeight - (hitSize - visualHeight) / 2
      //     = 400 - 32 - 6 = 362
      expect(rect.top, closeTo(362, 0.5));
    });

    testWidgets('handle 自己吃指针事件 —— 按在它上面，下层收不到', (tester) async {
      // 这是"手柄一碰就没"的结构性防线。
      //
      // handle 以 opaque 收下 pointerDown 之后，外层 Listener 拿不到这个事件，
      // 那一按就**不可能**被判成普通 tap —— 而 tap 会退出选区。之前 handle 是
      // IgnorePointer，命中全靠外层按距离算，圆心取错就脱靶、脱靶就退出选区。
      // master 上从来没这个毛病，正因为它的 handle 一直是自己收事件的。
      var tappedBelow = false;
      HandleHit? grabbed;
      await tester.pumpWidget(_wrap(Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tappedBelow = true,
            ),
          ),
          Positioned.fill(
            child: _overlayAt(
              start: const Offset(50, 300),
              end: const Offset(60, 310),
              onHandleGrab: (which, _) => grabbed = which,
            ),
          ),
        ],
      )));
      await tester.pump();
      // 取 end handle 的中心：它画在锚点下方，而复制菜单在上方，不会是菜单
      // 吸收了这一按。
      final endHandle =
          tester.getRect(find.byKey(const ValueKey('end_handle')));
      await tester.tapAt(endHandle.center);

      expect(grabbed, HandleHit.end, reason: 'handle 自己收到了按下');
      expect(tappedBelow, isFalse,
          reason: '事件被 handle 吃掉，不该穿透到下层 —— 穿透就会被判成 tap');
    });
  });

  group('TerminalFloatingMenu', () {
    Widget _menu({
      required Rect anchor,
      required List<TerminalMenuAction> actions,
    }) =>
        _wrap(Stack(
          children: [
            TerminalFloatingMenu(
              anchor: anchor,
              actions: actions,
            ),
          ],
        ));

    TerminalMenuAction _action(String label, {VoidCallback? onTap}) =>
        TerminalMenuAction(
          icon: Icons.content_paste,
          label: label,
          onTap: onTap ?? () {},
        );

    Rect _at(Offset p) => Rect.fromCenter(center: p, width: 0, height: 0);

    testWidgets('renders one button per action', (tester) async {
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(200, 400)),
        actions: [_action('A'), _action('B')],
      ));
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('tapping an action fires its callback', (tester) async {
      var tapped = '';
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(200, 400)),
        actions: [
          _action('A', onTap: () => tapped = 'A'),
          _action('B', onTap: () => tapped = 'B'),
        ],
      ));
      await tester.pump();
      await tester.tap(find.text('B'));
      expect(tapped, 'B');
    });

    testWidgets('sits above the anchor when there is room', (tester) async {
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(200, 400)),
        actions: [_action('A')],
      ));
      await tester.pump();
      final box =
          tester.getRect(find.byKey(const ValueKey('floating_menu_body')));
      expect(box.bottom, lessThanOrEqualTo(400));
    });

    testWidgets('flips below the anchor when there is no room above',
        (tester) async {
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(200, 10)),
        actions: [_action('A')],
      ));
      await tester.pump();
      final box =
          tester.getRect(find.byKey(const ValueKey('floating_menu_body')));
      expect(box.top, greaterThanOrEqualTo(10));
    });

    testWidgets('clamps inside the left edge', (tester) async {
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(2, 400)),
        actions: [_action('A')],
      ));
      await tester.pump();
      final box =
          tester.getRect(find.byKey(const ValueKey('floating_menu_body')));
      expect(box.left, greaterThanOrEqualTo(0));
    });

    testWidgets('clamps inside the right edge', (tester) async {
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(398, 400)),
        actions: [_action('A'), _action('B')],
      ));
      await tester.pump();
      final box =
          tester.getRect(find.byKey(const ValueKey('floating_menu_body')));
      expect(box.right, lessThanOrEqualTo(400));
    });

    testWidgets('clamps inside the right edge with realistic long labels',
        (tester) async {
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(398, 400)),
        actions: [_action('选择全部文本'), _action('粘贴到终端')],
      ));
      await tester.pump();
      final box =
          tester.getRect(find.byKey(const ValueKey('floating_menu_body')));
      expect(box.right, lessThanOrEqualTo(400));
      expect(box.left, greaterThanOrEqualTo(0));
    });

    testWidgets('is wider with two actions than with one', (tester) async {
      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(200, 400)),
        actions: [_action('A')],
      ));
      await tester.pump();
      final one =
          tester.getRect(find.byKey(const ValueKey('floating_menu_body'))).width;

      await tester.pumpWidget(_menu(
        anchor: _at(const Offset(200, 400)),
        actions: [_action('A'), _action('B')],
      ));
      await tester.pump();
      final two =
          tester.getRect(find.byKey(const ValueKey('floating_menu_body'))).width;

      expect(two, greaterThan(one));
    });
  });

  group('菜单与 handle 不打架', () {
    Widget overlay(HandlePositions pos) => _wrap(
          TerminalSelectionOverlay(
            handles: ValueNotifier(pos),
            onCopy: () {},
            onHandleGrab: (_, __) {},
            onHandleMove: (_) {},
            onHandleRelease: () {},
          ),
        );

    testWidgets('菜单整体让开 start handle，不压在它上面', (tester) async {
      const startAnchor = Offset(150, 400);
      await tester.pumpWidget(
        overlay(const HandlePositions(startAnchor, Offset(250, 430))),
      );
      await tester.pumpAndSettle();

      final menu = tester.getRect(find.byKey(const ValueKey('floating_menu_body')));
      // start handle 画在锚点上方 kSelectionHandleVisualHeight 处 ——
      // 菜单底边必须在那之上，否则指尖点 handle 会先被菜单吃掉。
      const handleVisualTop = 400 - kSelectionHandleVisualHeight;
      expect(menu.bottom, lessThanOrEqualTo(handleVisualTop),
          reason: '菜单底边压到了 handle 的绘制区域');
    });

    testWidgets('菜单翻到下方时让开 end handle', (tester) async {
      // 选区贴着顶部，菜单没地方放只能翻下去
      await tester.pumpWidget(
        overlay(const HandlePositions(Offset(150, 4), Offset(250, 20))),
      );
      await tester.pumpAndSettle();

      final menu = tester.getRect(find.byKey(const ValueKey('floating_menu_body')));
      // end handle 画在锚点下方 kSelectionHandleVisualHeight 处
      const handleVisualBottom = 20 + kSelectionHandleVisualHeight;
      expect(menu.top, greaterThanOrEqualTo(handleVisualBottom),
          reason: '菜单顶边压到了 end handle 的绘制区域');
    });

    testWidgets('拖拽中菜单隐藏', (tester) async {
      await tester.pumpWidget(
        overlay(const HandlePositions(
          Offset(150, 400),
          Offset(250, 430),
          dragging: true,
        )),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('floating_menu_body')), findsNothing);
      // handle 本身照常画
      expect(find.byKey(const ValueKey('start_handle')), findsOneWidget);
    });

    testWidgets('拖拽结束菜单回来', (tester) async {
      final notifier = ValueNotifier(const HandlePositions(
        Offset(150, 400),
        Offset(250, 430),
        dragging: true,
      ));
      await tester.pumpWidget(_wrap(
        TerminalSelectionOverlay(
          handles: notifier,
          onCopy: () {},
          onHandleGrab: (_, __) {},
          onHandleMove: (_) {},
          onHandleRelease: () {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('floating_menu_body')), findsNothing);

      notifier.value =
          const HandlePositions(Offset(150, 400), Offset(250, 430));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('floating_menu_body')), findsOneWidget);
    });
  });
}
