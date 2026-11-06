import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/network_stability.dart';

void main() {
  group('NetworkStability', () {
    test('initial score is 50', () {
      final s = NetworkStability();
      expect(s.score, 50);
      expect(s.isStable, isTrue);
    });

    test('recordOkPacket increments score by 1, caps at 100', () {
      final s = NetworkStability();
      for (var i = 0; i < 60; i++) {
        s.recordOkPacket(const Duration(milliseconds: 50));
      }
      expect(s.score, 100);
    });

    test('recordMissedDeadline drops score by 30, floors at 0', () {
      final s = NetworkStability();
      s.recordMissedDeadline();
      expect(s.score, 20);
      s.recordMissedDeadline();
      expect(s.score, 0);
      s.recordMissedDeadline();
      expect(s.score, 0);
    });

    test('isStable boundary: 50 stable, 49 not', () {
      final s = NetworkStability();
      expect(s.isStable, isTrue);
      s.recordMissedDeadline();
      expect(s.score, 20);
      expect(s.isStable, isFalse);
    });

    test('recordReconnect resets to 30 (below stable threshold)', () {
      final s = NetworkStability();
      for (var i = 0; i < 50; i++) {
        s.recordOkPacket(const Duration(milliseconds: 50));
      }
      expect(s.score, 100);
      s.recordReconnect();
      expect(s.score, 30);
      expect(s.isStable, isFalse);
    });

    test('smoothedRtt EWMA converges', () {
      final s = NetworkStability();
      s.recordOkPacket(const Duration(milliseconds: 100));
      expect(s.smoothedRtt!.inMilliseconds, 100);
      // EWMA α=0.2: new = 0.2 * 200 + 0.8 * 100 = 120
      s.recordOkPacket(const Duration(milliseconds: 200));
      expect(s.smoothedRtt!.inMilliseconds, 120);
    });
  });
}
