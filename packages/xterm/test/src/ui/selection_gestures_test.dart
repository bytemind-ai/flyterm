import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 第一行第一个词上的点。(20, 8) 这个偏移在 FlyTerm 侧的
/// selection_enter_test.dart 里已验证可用：x=20 落在 'hello' 中间，
/// y=8 落在第一行内。
Offset _firstWord(WidgetTester tester) =>
    tester.getTopLeft(find.byType(TerminalView)) + const Offset(20, 8);

Widget _wrap(Terminal terminal, TerminalController controller,
        {required bool builtin}) =>
    MaterialApp(
      home: Scaffold(
        body: TerminalView(
          terminal,
          controller: controller,
          builtinSelectionGestures: builtin,
        ),
      ),
    );

/// 走构造函数默认值 —— 刻意不传 builtinSelectionGestures。
///
/// 这是守住 pub 包原语义的唯一一道网：如果有人把默认值改成 false，只有不传
/// 参的调用点会红。显式传 true 的测试是测不出默认值回归的。
Widget _wrapDefault(Terminal terminal, TerminalController controller) =>
    MaterialApp(
      home: Scaffold(
        body: TerminalView(terminal, controller: controller),
      ),
    );

/// 长按后拖动 —— **触摸设备上真正的"拖拽选字"路径**。
///
/// 不能用 `tester.dragFrom()` 测这条：`gesture_detector.dart` 里的
/// `PanGestureRecognizer` 声明了 `supportedDevices: {PointerDeviceKind.mouse}`，
/// 而 `dragFrom` 默认发的是 touch 指针 —— 手指拖拽根本进不了那个识别器，
/// `onDragStart`/`onDragUpdate` 在手机上永远不触发。用 touch 版 dragFrom 测
/// 出来的"没有选区"跟开关无关，是手势压根没被识别，属于假阳性。
///
/// 触摸设备上摸得到的是 `LongPressGestureRecognizer`
/// （`supportedDevices: {PointerDeviceKind.touch}`），走
/// `onLongPressStart` → `onLongPressMoveUpdate`。
Future<void> _longPressDrag(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await gesture.moveBy(const Offset(60, 0));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}

void main() {
  late Terminal terminal;
  late TerminalController controller;

  setUp(() {
    terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('hello world\r\nfoo bar baz');
    controller = TerminalController();
  });

  group('builtinSelectionGestures: false —— 嵌入方独占选区', () {
    testWidgets('长按不建立选区', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: false));
      await tester.pumpAndSettle();

      await tester.longPressAt(_firstWord(tester));
      await tester.pumpAndSettle();

      expect(controller.selection, isNull);
    });

    testWidgets('长按后拖动不扩展选区', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: false));
      await tester.pumpAndSettle();

      await _longPressDrag(tester, _firstWord(tester));

      expect(controller.selection, isNull);
    });

    testWidgets('鼠标拖拽不建立选区', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: false));
      await tester.pumpAndSettle();

      await tester.dragFrom(_firstWord(tester), const Offset(60, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(controller.selection, isNull);
    });

    testWidgets('双击不建立选区', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: false));
      await tester.pumpAndSettle();

      await _doubleTap(tester, _firstWord(tester));

      expect(controller.selection, isNull);
    });
  });

  /// 每条"关掉后不建立选区"都必须有一条对照。
  ///
  /// 否则测试会因为**手势压根没被识别**而绿，与守卫是否生效无关 —— 守卫被
  /// 误删也照样绿。这一组的作用就是证明：同样的手势在开关打开时确实能建立
  /// 选区，所以上一组测到的 null 是守卫的功劳。
  group('对照组：同样的手势在开关打开时确实建立选区', () {
    testWidgets('长按会选词', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: true));
      await tester.pumpAndSettle();

      await tester.longPressAt(_firstWord(tester));
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
    });

    testWidgets('长按后拖动会扩展选区', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: true));
      await tester.pumpAndSettle();

      await _longPressDrag(tester, _firstWord(tester));

      expect(controller.selection, isNotNull);
    });

    testWidgets('鼠标拖拽会建立选区', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: true));
      await tester.pumpAndSettle();

      await tester.dragFrom(_firstWord(tester), const Offset(60, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
    });

    testWidgets('双击会选词', (tester) async {
      await tester.pumpWidget(_wrap(terminal, controller, builtin: true));
      await tester.pumpAndSettle();

      await _doubleTap(tester, _firstWord(tester));

      expect(controller.selection, isNotNull);
    });
  });

  // 默认值必须保持 pub 包的原语义，否则 fork 的其他消费者会被静默改行为。
  group('默认 true —— 包的原行为不变', () {
    testWidgets('不传该参数时长按仍然选词 —— 默认值守卫', (tester) async {
      await tester.pumpWidget(_wrapDefault(terminal, controller));
      await tester.pumpAndSettle();

      await tester.longPressAt(_firstWord(tester));
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
    });
  });
}
