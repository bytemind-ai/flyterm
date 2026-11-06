// test/ssh/foreground_fast_path_test.dart
// Unit tests for B1+B2 foreground fast-path flag semantics.
//
// We test only the flag set/take behavior on an isolated FastPathRegistry
// instance — the full integration (lifecycle → mark → take → use in RWR) is
// covered by the existing reconnect integration tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('FastPathRegistry', () {
    test('mark sets the flag', () {
      final r = FastPathRegistry();
      r.mark('t1');
      expect(r.contains('t1'), isTrue);
    });

    test('take returns true on first call, false after', () {
      final r = FastPathRegistry();
      r.mark('t1');
      expect(r.take('t1'), isTrue,
          reason: 'first take returns true');
      expect(r.contains('t1'), isFalse,
          reason: 'flag must be cleared after first use');
      expect(r.take('t1'), isFalse,
          reason: 'second take returns false');
    });

    test('contains returns false for unknown tabId', () {
      final r = FastPathRegistry();
      expect(r.contains('unknown'), isFalse);
    });
  });
}
