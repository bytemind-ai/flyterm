/// 长按退格自重复的端到端回归测试。
///
/// 单元测试（hold_repeat_test.dart）直接喂 [HoldRepeat]；这一条走真实
/// [TerminalView] → xterm `Focus.onKeyEvent` → HoldRepeat → `terminal.onOutput`
/// 的完整链路，钉住三件事：
///   1. 输入法只发一个退格 KeyDown、迟迟不发 KeyUp 时，会自己补出一串退格。
///   2. 松手（KeyUp）后立刻停，不再多删。
///   3. 两次按键（单击）不许多删一个字符。
///
/// 背景：Android 输入法按住退格走 `sendKeyEvent(KEYCODE_DEL)`，连发用
/// `ACTION_MULTIPLE`，被 Flutter 引擎在进 Dart 之前丢掉 —— 应用侧只能自己补。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/hold_repeat.dart';
import 'package:xterm/xterm.dart';

void main() {
  /// 装配真实 TerminalView + HoldRepeat 接线，返回收到的字节数。
  Future<({HoldRepeat hold, List<String> sent, FocusNode focus})> pumpTerminal(
    WidgetTester tester,
  ) async {
    final terminal = Terminal(maxLines: 100);
    final sent = <String>[];
    terminal.onOutput = sent.add;

    late final HoldRepeat hold;
    hold = HoldRepeat(
      onFire: () {
        final seq = terminal.encodeKey(TerminalKey.backspace) ?? '\x7f';
        terminal.onOutput?.call(seq);
      },
    );
    final focus = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            focusNode: focus,
            autofocus: true,
            deleteDetection: true,
            onKeyEvent: (node, event) {
              if (event.logicalKey != LogicalKeyboardKey.backspace) {
                hold.stop();
                return KeyEventResult.ignored;
              }
              final consumed = hold.handleKeyEvent(event);
              return consumed
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    focus.requestFocus();
    await tester.pump();
    return (hold: hold, sent: sent, focus: focus);
  }

  testWidgets('holding past the initial delay keeps deleting', (tester) async {
    final t = await pumpTerminal(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(t.hold.firedCount, greaterThan(1));
    // 第一次 down 由 xterm 自己发，其余是自补重复。
    expect(t.sent.where((s) => s == '\x7f').length, greaterThan(1));
    t.hold.dispose();
  });

  testWidgets('releasing stops immediately', (tester) async {
    final t = await pumpTerminal(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    final firedAtRelease = t.hold.firedCount;

    await tester.pump(const Duration(milliseconds: 500));
    expect(t.hold.firedCount, firedAtRelease, reason: '松手后一拍都不许多发');
    t.hold.dispose();
  });

  testWidgets('a quick tap never repeats', (tester) async {
    final t = await pumpTerminal(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 500));

    expect(t.hold.firedCount, 0);
    t.hold.dispose();
  });
}
