/// 长按退格「自重复」的回归测试。
///
/// 背景：输入法连发走 `ACTION_MULTIPLE`，而 Flutter 引擎的 KeyChannelResponder
/// 只处理 ACTION_DOWN/ACTION_UP —— 连发事件在进 Dart 之前就没了。所以按住不放
/// 的重复只能由 [HoldRepeat] 在 down/up 之间补。这组测试钉住四条不变式：
///
///   1. 一次点按（down 立刻 up）**不许**多删字符。
///   2. 按住超过 initialDelay 开始按间隔重复。
///   3. up 之后立刻停，不许漏出一拍。
///   4. 真键盘的 KeyRepeatEvent 到达时让位给系统，不许双倍删除。
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/hold_repeat.dart';

void main() {
  KeyDownEvent down() => const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.backspace,
        logicalKey: LogicalKeyboardKey.backspace,
        timeStamp: Duration.zero,
      );
  KeyUpEvent up() => const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.backspace,
        logicalKey: LogicalKeyboardKey.backspace,
        timeStamp: Duration.zero,
      );
  KeyRepeatEvent repeat() => const KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.backspace,
        logicalKey: LogicalKeyboardKey.backspace,
        timeStamp: Duration.zero,
      );

  test('a tap (down+up) never repeats', () {
    fakeAsync((async) {
      var fired = 0;
      final hr = HoldRepeat(onFire: () => fired++);

      hr.handleKeyEvent(down());
      async.elapse(const Duration(milliseconds: 80)); // 普通点按的按压时长
      hr.handleKeyEvent(up());
      async.elapse(const Duration(seconds: 2));

      expect(fired, 0);
    });
  });

  test('holding past the initial delay starts repeating', () {
    fakeAsync((async) {
      var fired = 0;
      final hr = HoldRepeat(onFire: () => fired++);

      hr.handleKeyEvent(down());
      async.elapse(const Duration(milliseconds: 300));
      expect(fired, 0, reason: '起始延迟内不许触发，否则单击会多删');
      async.elapse(const Duration(milliseconds: 200)); // 越过 320ms
      expect(hr.isRepeating, isTrue);
      async.elapse(const Duration(milliseconds: 500)); // ~12 拍
      expect(fired, greaterThan(5));
    });
  });

  test('half-second hold still produces repeats', () {
    // 真机上的签名就是 span≈523ms（见 2026-10-24 的 IME 诊断截图）：
    // 用户按住约半秒就松手，起始延迟必须明显短于这个值，否则“长按”要等
    // 到手指快抬起来才开始重复，体感就是“没反应”。
    fakeAsync((async) {
      var fired = 0;
      final hr = HoldRepeat(onFire: () => fired++);

      hr.handleKeyEvent(down());
      async.elapse(const Duration(milliseconds: 523));
      hr.handleKeyEvent(up());

      expect(fired, greaterThanOrEqualTo(3));
    });
  });

  test('up stops immediately, no trailing fire', () {
    fakeAsync((async) {
      var fired = 0;
      final hr = HoldRepeat(onFire: () => fired++);

      hr.handleKeyEvent(down());
      async.elapse(const Duration(milliseconds: 600));
      final atRelease = fired;
      hr.handleKeyEvent(up());
      async.elapse(const Duration(seconds: 1));

      expect(fired, atRelease, reason: '松手后一拍都不许多发');
      expect(hr.isRepeating, isFalse);
    });
  });

  test('a real keyboard repeat takes over instead of stacking', () {
    fakeAsync((async) {
      var fired = 0;
      final hr = HoldRepeat(onFire: () => fired++);

      hr.handleKeyEvent(down());
      async.elapse(const Duration(milliseconds: 300));
      hr.handleKeyEvent(repeat()); // 硬件键盘开始自己重复
      async.elapse(const Duration(seconds: 2));

      expect(fired, 0, reason: '系统重复已在发，不能叠加成双倍删除');
      expect(hr.isRepeating, isFalse);
    });
  });

  test('runaway is capped even if key-up is lost', () {
    fakeAsync((async) {
      var fired = 0;
      final hr = HoldRepeat(
        onFire: () => fired++,
        initialDelay: const Duration(milliseconds: 10),
        interval: const Duration(milliseconds: 10),
        maxRepeats: 5,
      );

      hr.handleKeyEvent(down());
      async.elapse(const Duration(seconds: 5));

      expect(fired, 5, reason: 'up 丢了也不许把命令行删空');
      expect(hr.isRepeating, isFalse);
    });
  });

  test('handing a down again re-arms from scratch', () {
    fakeAsync((async) {
      var fired = 0;
      final hr = HoldRepeat(onFire: () => fired++);

      hr.handleKeyEvent(down());
      async.elapse(const Duration(milliseconds: 500));
      final first = fired;
      expect(first, greaterThan(0));

      hr.handleKeyEvent(down()); // 第二次按下（第一次的 up 丢了）
      async.elapse(const Duration(milliseconds: 500));

      expect(fired, greaterThan(first));
    });
  });
}
