import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/transport/app_lifecycle_hook.dart';

void main() {
  test('quick resume (<60s) calls onResumedQuick', () {
    var quick = 0;
    var hard = 0;
    var clock = DateTime(2026, 5, 10);
    final h = MoshLifecycleHook(
      onResumedQuick: () => quick++,
      onResumedHardReconnect: () => hard++,
      now: () => clock,
    );
    h.didChangeAppLifecycleState(AppLifecycleState.paused);
    clock = clock.add(const Duration(seconds: 30));
    h.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(quick, 1);
    expect(hard, 0);
  });

  test('long resume (>=60s) calls onResumedHardReconnect', () {
    var quick = 0;
    var hard = 0;
    var clock = DateTime(2026, 5, 10);
    final h = MoshLifecycleHook(
      onResumedQuick: () => quick++,
      onResumedHardReconnect: () => hard++,
      now: () => clock,
    );
    h.didChangeAppLifecycleState(AppLifecycleState.paused);
    clock = clock.add(const Duration(seconds: 90));
    h.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(quick, 0);
    expect(hard, 1);
  });

  test('resume without prior pause is a no-op', () {
    var quick = 0;
    var hard = 0;
    final h = MoshLifecycleHook(
      onResumedQuick: () => quick++,
      onResumedHardReconnect: () => hard++,
    );
    h.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(quick, 0);
    expect(hard, 0);
  });
}
