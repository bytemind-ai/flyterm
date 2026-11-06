// test/ai/agent/concurrency_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/concurrency.dart';

/// 一个可以被测试手动放行的任务工厂。记录并发峰值。
class _Tracker {
  int inFlight = 0;
  int peak = 0;
  final Map<int, Completer<String>> gates = {};

  Future<String> task(int i) {
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    final c = Completer<String>();
    gates[i] = c;
    return c.future.whenComplete(() => inFlight--);
  }

  void release(int i, [String? value]) => gates[i]!.complete(value ?? 'r$i');
}

void main() {
  group('runWithLimits', () {
    test('并发峰值不超过 globalLimit', () async {
      final t = _Tracker();
      final f = runWithLimits<String>(
        count: 5,
        keyOf: (i) => null,
        task: t.task,
        perKeyLimit: 99,
        globalLimit: 2,
      );
      await Future<void>.delayed(Duration.zero);
      expect(t.peak, 2, reason: 'globalLimit=2 时不该同时跑第三条');
      for (var i = 0; i < 5; i++) {
        t.gates[i]?.complete('r$i');
        await Future<void>.delayed(Duration.zero);
      }
      final out = await f;
      expect(out, ['r0', 'r1', 'r2', 'r3', 'r4']);
      expect(t.peak, 2);
    });

    test('perKeyLimit 按 key 分别计数，不同 key 不占彼此配额', () async {
      final t = _Tracker();
      // 5 条分属 5 个不同 key，perKeyLimit=1 —— 5 条应当全部同时起飞。
      final f = runWithLimits<String>(
        count: 5,
        keyOf: (i) => 'host$i',
        task: t.task,
        perKeyLimit: 1,
        globalLimit: 8,
      );
      await Future<void>.delayed(Duration.zero);
      expect(t.peak, 5, reason: '5 个不同 key 不该互相排队');
      for (var i = 0; i < 5; i++) {
        t.gates[i]!.complete('r$i');
      }
      await f;
    });

    test('同一个 key 顶住 perKeyLimit', () async {
      final t = _Tracker();
      final f = runWithLimits<String>(
        count: 4,
        keyOf: (i) => 'same',
        task: t.task,
        perKeyLimit: 2,
        globalLimit: 8,
      );
      await Future<void>.delayed(Duration.zero);
      expect(t.peak, 2);
      for (var i = 0; i < 4; i++) {
        t.gates[i]?.complete('r$i');
        await Future<void>.delayed(Duration.zero);
      }
      await f;
      expect(t.peak, 2);
    });

    test('滑动窗口：一条完成立刻补一条，不等整批', () async {
      final t = _Tracker();
      final f = runWithLimits<String>(
        count: 3,
        keyOf: (i) => null,
        task: t.task,
        perKeyLimit: 99,
        globalLimit: 2,
      );
      await Future<void>.delayed(Duration.zero);
      expect(t.gates.containsKey(2), isFalse, reason: '第三条此刻还没起飞');

      // 只放行第 0 条。批次屏障的实现会继续等第 1 条；滑动窗口应当立刻补上第 2 条。
      t.release(0);
      await Future<void>.delayed(Duration.zero);
      expect(t.gates.containsKey(2), isTrue,
          reason: '第 0 条一完成就该补上第 2 条，而不是等第 1 条也完成');

      t.release(1);
      t.release(2);
      await f;
    });

    test('结果按原下标归位，与完成顺序无关', () async {
      final t = _Tracker();
      final f = runWithLimits<String>(
        count: 3,
        keyOf: (i) => null,
        task: t.task,
        perKeyLimit: 99,
        globalLimit: 3,
      );
      await Future<void>.delayed(Duration.zero);
      // 逆序完成
      t.release(2, 'c');
      t.release(1, 'b');
      t.release(0, 'a');
      expect(await f, ['a', 'b', 'c']);
    });

    test('某条抛错不影响其余，该位置为 null', () async {
      final out = await runWithLimits<String>(
        count: 3,
        keyOf: (i) => null,
        task: (i) async {
          if (i == 1) throw StateError('boom');
          return 'r$i';
        },
        perKeyLimit: 99,
        globalLimit: 3,
      );
      expect(out, ['r0', null, 'r2']);
    });

    test('shouldStop 之后不再起飞新的，已起飞的仍然收回结果', () async {
      final t = _Tracker();
      var stop = false;
      final f = runWithLimits<String>(
        count: 4,
        keyOf: (i) => null,
        task: t.task,
        perKeyLimit: 99,
        globalLimit: 2,
        shouldStop: () => stop,
      );
      await Future<void>.delayed(Duration.zero);
      stop = true;
      t.release(0);
      t.release(1);
      final out = await f;
      expect(out[0], 'r0');
      expect(out[1], 'r1');
      expect(out[2], isNull, reason: '停止之后不该再起飞');
      expect(out[3], isNull);
      expect(t.gates.containsKey(2), isFalse);
    });

    test('limit == 1 退化成串行', () async {
      final t = _Tracker();
      final f = runWithLimits<String>(
        count: 3,
        keyOf: (i) => null,
        task: t.task,
        perKeyLimit: 1,
        globalLimit: 1,
      );
      await Future<void>.delayed(Duration.zero);
      expect(t.peak, 1);
      for (var i = 0; i < 3; i++) {
        t.gates[i]?.complete('r$i');
        await Future<void>.delayed(Duration.zero);
      }
      await f;
      expect(t.peak, 1);
    });

    test('count == 0 直接返回空表', () async {
      final out = await runWithLimits<String>(
        count: 0,
        keyOf: (i) => null,
        task: (i) async => 'x',
        perKeyLimit: 3,
        globalLimit: 8,
      );
      expect(out, isEmpty);
    });
  });
}
