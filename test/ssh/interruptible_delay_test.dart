// test/ssh/interruptible_delay_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('InterruptibleSleeper', () {
    test('natural expiry returns after the delay', () async {
      final s = InterruptibleSleeper();
      final sw = Stopwatch()..start();
      await s.delay('t1', const Duration(milliseconds: 80));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(70));
      expect(sw.elapsedMilliseconds, lessThan(200));
    });

    test('wake interrupts an in-flight delay', () async {
      final s = InterruptibleSleeper();
      final sw = Stopwatch()..start();
      final future = s.delay('t1', const Duration(seconds: 5));
      Future.delayed(const Duration(milliseconds: 30), () => s.wake('t1'));
      await future;
      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: 'wake should short-circuit the 5 s delay');
    });

    test('wakeAll interrupts every active sleeper', () async {
      final s = InterruptibleSleeper();
      final sw = Stopwatch()..start();
      final f1 = s.delay('t1', const Duration(seconds: 5));
      final f2 = s.delay('t2', const Duration(seconds: 5));
      Future.delayed(const Duration(milliseconds: 30), s.wakeAll);
      await Future.wait([f1, f2]);
      expect(sw.elapsedMilliseconds, lessThan(200));
    });

    test('wake on unknown tabId is a no-op (no throw)', () {
      final s = InterruptibleSleeper();
      expect(() => s.wake('does-not-exist'), returnsNormally);
    });

    test('repeated wake on the same tab is safe', () async {
      final s = InterruptibleSleeper();
      final future = s.delay('t1', const Duration(seconds: 5));
      s.wake('t1');
      s.wake('t1');
      s.wake('t1');
      await future;
    });

    test('after natural expiry the tabId is removed from the registry', () async {
      final s = InterruptibleSleeper();
      await s.delay('t1', const Duration(milliseconds: 30));
      expect(s.debugActiveCount, 0);
    });
  });
}
