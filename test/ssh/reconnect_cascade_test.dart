import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';
import 'package:flyterm/ssh/session_manager.dart';

void main() {
  group('Cascade guard pure logic', () {
    test('zero recent reconnects: no cooldown', () {
      expect(ReconnectService.shouldCooldown([]), isFalse);
    });

    test('4 failures within 90s: no cooldown', () {
      final now = DateTime.now();
      final events = List.generate(4, (i) => ReconnectEvent(
          now.subtract(Duration(seconds: i * 10)),
          ReconnectCause.watchdogTimeout, ReconnectKind.soft, false));
      expect(ReconnectService.shouldCooldown(events), isFalse);
    });

    test('5 failures within 90s: cooldown', () {
      final now = DateTime.now();
      final events = List.generate(5, (i) => ReconnectEvent(
          now.subtract(Duration(seconds: i * 10)),
          ReconnectCause.watchdogTimeout, ReconnectKind.soft, false));
      expect(ReconnectService.shouldCooldown(events), isTrue);
    });

    test('5 events but 1 outside 90s window: no cooldown', () {
      final now = DateTime.now();
      final events = [
        ReconnectEvent(now.subtract(const Duration(seconds: 100)),
            ReconnectCause.watchdogTimeout, ReconnectKind.soft, false),
        ...List.generate(4, (i) => ReconnectEvent(
            now.subtract(Duration(seconds: i * 10)),
            ReconnectCause.watchdogTimeout, ReconnectKind.soft, false)),
      ];
      expect(ReconnectService.shouldCooldown(events), isFalse);
    });

    test('5 success events within 90s: no cooldown (successes excluded)', () {
      final now = DateTime.now();
      final events = List.generate(5, (i) => ReconnectEvent(
          now.subtract(Duration(seconds: i * 10)),
          ReconnectCause.watchdogTimeout, ReconnectKind.soft, true)); // succeeded=true
      expect(ReconnectService.shouldCooldown(events), isFalse);
    });

    test('4 successes + 1 failure: no cooldown', () {
      final now = DateTime.now();
      final events = [
        ReconnectEvent(now.subtract(const Duration(seconds: 5)),
            ReconnectCause.watchdogTimeout, ReconnectKind.soft, false),
        ...List.generate(4, (i) => ReconnectEvent(
            now.subtract(Duration(seconds: i * 10 + 15)),
            ReconnectCause.watchdogTimeout, ReconnectKind.soft, true)),
      ];
      expect(ReconnectService.shouldCooldown(events), isFalse);
    });

    test('30s-spaced failures never trigger cooldown (cooldown spacing breaks cycle)', () {
      // With 90s window and 30s cooldown spacing: max 3 events in window
      // (0s, 30s, 60s). 90s event is NOT strictly after cutoff → excluded.
      // So threshold=5 is never reached — perpetual cycle is broken.
      final now = DateTime.now();
      final events = List.generate(5, (i) => ReconnectEvent(
          now.subtract(Duration(seconds: i * 30)),
          ReconnectCause.watchdogTimeout, ReconnectKind.soft, false));
      // events at 0s, 30s, 60s, 90s, 120s → only 0s, 30s, 60s in window (3 < 5)
      expect(ReconnectService.shouldCooldown(events), isFalse);
    });

    test('since: filter excludes events before network comeback', () {
      final now = DateTime.now();
      final comeback = now.subtract(const Duration(seconds: 30));
      final events = [
        // 4 events BEFORE comeback (old network) — should not count
        ...List.generate(4, (i) => ReconnectEvent(
            comeback.subtract(Duration(seconds: (i + 1) * 5)),
            ReconnectCause.watchdogTimeout, ReconnectKind.soft, false)),
        // 1 event AFTER comeback (new network)
        ReconnectEvent(now.subtract(const Duration(seconds: 5)),
            ReconnectCause.watchdogTimeout, ReconnectKind.soft, false),
      ];
      expect(ReconnectService.shouldCooldown(events, since: comeback), isFalse);
    });

    test('since: filter: 5 failures after comeback → cooldown', () {
      final now = DateTime.now();
      final comeback = now.subtract(const Duration(seconds: 60));
      final events = List.generate(5, (i) => ReconnectEvent(
          comeback.add(Duration(seconds: i * 5 + 1)),
          ReconnectCause.watchdogTimeout, ReconnectKind.soft, false));
      expect(ReconnectService.shouldCooldown(events, since: comeback), isTrue);
    });
  });
}
