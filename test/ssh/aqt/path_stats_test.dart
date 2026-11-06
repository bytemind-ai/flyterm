// test/ssh/aqt/path_stats_test.dart
//
// Unit tests for the Dart-side PathStats model (debug overlay).

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';

void main() {
  group('PathStats', () {
    test('empty constant has all zeros', () {
      const e = PathStats.empty;
      expect(e.rttUs, 0);
      expect(e.lostPackets, 0);
      expect(e.sentPackets, 0);
      expect(e.migrationCount, 0);
      expect(e.rebindingCount, 0);
      expect(e.cwndBytes, 0);
    });

    test('rttMs converts micro→milli with rounding', () {
      expect(const PathStats(rttUs: 33000).rttMs, 33);
      expect(const PathStats(rttUs: 33500).rttMs, 34); // round-half-up
      expect(const PathStats(rttUs: 32499).rttMs, 32);
    });

    test('lossRate is 0 when no packets sent (no divide-by-zero)', () {
      const s = PathStats(lostPackets: 10, sentPackets: 0);
      expect(s.lossRate, 0.0);
    });

    test('lossRate is lost / sent', () {
      const s = PathStats(lostPackets: 5, sentPackets: 1000);
      expect(s.lossRate, 0.005);
    });

    test('cwndKB rounds bytes/1024', () {
      expect(const PathStats(cwndBytes: 14336).cwndKB, 14);
      expect(const PathStats(cwndBytes: 14400).cwndKB, 14); // 14.0625 → 14
      expect(const PathStats(cwndBytes: 14848).cwndKB, 15); // 14.5 → 15 (round-half-away)
    });

    test('migration / rebinding counts preserved verbatim', () {
      const s = PathStats(migrationCount: 7, rebindingCount: 3);
      expect(s.migrationCount, 7);
      expect(s.rebindingCount, 3);
    });

    test('typical mobile path values render cleanly', () {
      // RTT 65 ms, 0.2% loss, no migrations, ~22 KB cwnd
      const s = PathStats(
        rttUs: 65000,
        lostPackets: 4,
        sentPackets: 2000,
        cwndBytes: 22 * 1024,
      );
      expect(s.rttMs, 65);
      expect(s.lossRate, 0.002);
      expect(s.cwndKB, 22);
    });
  });
}
