// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ui/terminal/resize_freeze.dart';

/// [ResizeFreeze] 纯状态机：键盘弹收时冻结 alt-buffer 画面，等远端重绘落屏
/// （或超时）再解冻。这里不涉及任何 widget / 图像，只测时序。
void main() {
  late List<bool> changes;
  ResizeFreeze make() => ResizeFreeze(onChanged: changes.add);

  setUp(() => changes = []);

  test('ineligible begin → 不冻结、不回调', () {
    fakeAsync((async) {
      final f = make();
      expect(f.begin(eligible: false), isFalse);
      expect(f.frozen, isFalse);
      expect(changes, isEmpty);
      f.dispose();
    });
  });

  test('begin → frozen + onChanged(true)', () {
    fakeAsync((async) {
      final f = make();
      expect(f.begin(eligible: true), isTrue);
      expect(f.frozen, isTrue);
      expect(changes, [true]);
      f.dispose();
    });
  });

  test('remoteResizeSent 之前的 outputRendered 不解冻', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      f.outputRendered();
      expect(f.frozen, isTrue);
      expect(changes, [true]);
      f.dispose();
    });
  });

  test('remoteResizeSent 再 outputRendered → 只解冻一次', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      f.remoteResizeSent();
      expect(f.frozen, isTrue);
      f.outputRendered();
      expect(f.frozen, isFalse);
      f.outputRendered();
      async.elapse(const Duration(seconds: 3));
      expect(changes, [true, false]);
      f.dispose();
    });
  });

  test('remoteResizeSent 后 500 ms 无输出 → 解冻', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      async.elapse(const Duration(milliseconds: 200));
      f.remoteResizeSent();
      async.elapse(const Duration(milliseconds: 499));
      expect(f.frozen, isTrue);
      async.elapse(const Duration(milliseconds: 1));
      expect(f.frozen, isFalse);
      expect(changes, [true, false]);
      f.dispose();
    });
  });

  test('begin 后 1500 ms 硬上限，即使没发 remote resize', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      async.elapse(const Duration(milliseconds: 1499));
      expect(f.frozen, isTrue);
      async.elapse(const Duration(milliseconds: 1));
      expect(f.frozen, isFalse);
      expect(changes, [true, false]);
      f.dispose();
    });
  });

  test('硬上限不被 remoteResizeSent 推迟', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      async.elapse(const Duration(milliseconds: 1400));
      f.remoteResizeSent();
      async.elapse(const Duration(milliseconds: 100));
      expect(f.frozen, isFalse);
      f.dispose();
    });
  });

  test('cancel → 解冻；未冻结时 cancel 无回调', () {
    fakeAsync((async) {
      final f = make();
      f.cancel();
      expect(changes, isEmpty);
      f.begin(eligible: true);
      f.cancel();
      expect(f.frozen, isFalse);
      expect(changes, [true, false]);
      async.elapse(const Duration(seconds: 3));
      expect(changes, [true, false]);
      f.dispose();
    });
  });

  test('冻结中重复 begin 是 no-op（不再 onChanged(true)、不重置上限）', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      async.elapse(const Duration(milliseconds: 1000));
      expect(f.begin(eligible: true), isFalse);
      expect(changes, [true]);
      async.elapse(const Duration(milliseconds: 500));
      expect(f.frozen, isFalse);
      f.dispose();
    });
  });

  test('未冻结时 remoteResizeSent / outputRendered 都是 no-op', () {
    fakeAsync((async) {
      final f = make();
      f.remoteResizeSent();
      f.outputRendered();
      async.elapse(const Duration(seconds: 3));
      expect(changes, isEmpty);
      // 上一轮残留的 remoteResizeSent 不能让下一次 begin 被输出立刻解冻。
      f.begin(eligible: true);
      f.outputRendered();
      expect(f.frozen, isTrue);
      f.dispose();
    });
  });

  test('解冻后可以再次冻结', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      f.cancel();
      expect(f.begin(eligible: true), isTrue);
      expect(changes, [true, false, true]);
      f.dispose();
    });
  });

  test('dispose 取消计时器，之后不再回调', () {
    fakeAsync((async) {
      final f = make();
      f.begin(eligible: true);
      f.remoteResizeSent();
      f.dispose();
      async.elapse(const Duration(seconds: 3));
      expect(changes, [true]);
      expect(async.pendingTimers, isEmpty);
      expect(f.begin(eligible: true), isFalse);
    });
  });
}
