import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/transport/clock_drift_detector.dart';

void main() {
  test('reports suspend when actual gap > 5x expected', () {
    Duration? reported;
    final t0 = DateTime(2026, 5, 10, 12, 0, 0);
    var clock = t0;
    final d = ClockDriftDetector(
      expectedInterval: const Duration(milliseconds: 100),
      onSuspectedSuspend: (gap) => reported = gap,
      now: () => clock,
    );
    d.onTick();
    clock = t0.add(const Duration(seconds: 2));
    d.onTick();
    expect(reported, isNotNull);
    expect(reported!.inMilliseconds, 2000);
  });

  test('does not fire when gap is within 5x expected', () {
    var fired = false;
    final t0 = DateTime(2026, 5, 10);
    var clock = t0;
    final d = ClockDriftDetector(
      expectedInterval: const Duration(milliseconds: 100),
      onSuspectedSuspend: (_) => fired = true,
      now: () => clock,
    );
    d.onTick();
    clock = t0.add(const Duration(milliseconds: 400));
    d.onTick();
    expect(fired, false);
  });

  test('first tick never fires (no baseline)', () {
    var fired = false;
    final d = ClockDriftDetector(
      expectedInterval: const Duration(milliseconds: 100),
      onSuspectedSuspend: (_) => fired = true,
    );
    d.onTick();
    expect(fired, false);
  });
}
