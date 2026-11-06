// test/ssh/aqt/connect_timings_test.dart
//
// Unit tests for ConnectTimings model (debug overlay `conn` row).

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';

void main() {
  group('ConnectTimings', () {
    test('default constructor produces all zeros', () {
      const t = ConnectTimings();
      expect(t.tcpMs, 0);
      expect(t.authMs, 0);
      expect(t.bootMs, 0);
      expect(t.handshakeMs, 0);
      expect(t.totalMs, 0);
    });

    test('totalMs is the sum of all phases', () {
      const t = ConnectTimings(tcpMs: 120, authMs: 340, bootMs: 80, handshakeMs: 65);
      expect(t.totalMs, 605);
    });

    test('totalMs ignores unspecified phases (default 0)', () {
      const t = ConnectTimings(authMs: 1000);
      expect(t.totalMs, 1000);
    });

    test('copyWith replaces only specified fields', () {
      const t = ConnectTimings(tcpMs: 10, authMs: 20, bootMs: 30, handshakeMs: 40);
      final u = t.copyWith(bootMs: 999);
      expect(u.tcpMs, 10);
      expect(u.authMs, 20);
      expect(u.bootMs, 999);
      expect(u.handshakeMs, 40);
      expect(u.totalMs, 1069);
    });

    test('copyWith with no args returns equivalent copy', () {
      const t = ConnectTimings(tcpMs: 7, authMs: 8, bootMs: 9, handshakeMs: 10);
      final u = t.copyWith();
      expect(u.tcpMs, t.tcpMs);
      expect(u.authMs, t.authMs);
      expect(u.bootMs, t.bootMs);
      expect(u.handshakeMs, t.handshakeMs);
      expect(u.totalMs, t.totalMs);
    });

    test('large values do not overflow within int', () {
      const t = ConnectTimings(tcpMs: 30000, authMs: 60000, bootMs: 5000, handshakeMs: 12000);
      expect(t.totalMs, 107000);
    });
  });
}
