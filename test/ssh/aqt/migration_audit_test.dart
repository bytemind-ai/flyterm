import 'dart:typed_data';

import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AqtTransport.markPathDied', () {
    test('sets quicPathDied and fires callback', () {
      final t = _stub();
      var fired = 0;
      t.onDisconnected = () => fired++;
      expect(t.quicPathDied, isFalse);
      t.markPathDied('test-reason');
      expect(t.quicPathDied, isTrue);
      expect(t.lastDisconnectReason, 'test-reason');
      expect(fired, 1);
    });

    test('is idempotent', () {
      final t = _stub();
      var fired = 0;
      t.onDisconnected = () => fired++;
      t.markPathDied('first');
      t.markPathDied('second');
      expect(t.lastDisconnectReason, 'first',
          reason: 'idempotent — second call must not overwrite first');
      expect(fired, 1, reason: 'callback fires only once');
    });
  });

  group('migration audit comparison', () {
    bool migrated({required int baseline, required int current}) {
      return current > baseline;
    }

    test('count incremented → success', () {
      expect(migrated(baseline: 0, current: 1), isTrue);
      expect(migrated(baseline: 5, current: 6), isTrue);
    });

    test('count unchanged → failure', () {
      expect(migrated(baseline: 0, current: 0), isFalse);
      expect(migrated(baseline: 7, current: 7), isFalse);
    });
  });

  group('migration audit identity guard', () {
    test('Map<AqtTransport, int> distinguishes swapped instances', () {
      // Two transports with the same tab.id semantics — the map keyed by
      // object identity must treat them as different keys.
      final t1 = AqtTransport.testStub(
          port: 1, spki: Uint8List(32), token: Uint8List(32), tabId: 7);
      final t2 = AqtTransport.testStub(
          port: 1, spki: Uint8List(32), token: Uint8List(32), tabId: 7);
      expect(identical(t1, t2), isFalse);

      final baseline = <AqtTransport, int>{};
      baseline[t1] = 0;
      // Looking up by t2 returns null even though it has identical-looking metadata.
      expect(baseline[t2], isNull);
      // Looking up by t1 returns the stashed value.
      expect(baseline[t1], 0);
    });
  });
}

AqtTransport _stub() => AqtTransport.testStub(
      port: 12345,
      spki: Uint8List(32),
      token: Uint8List(32),
      tabId: 1,
    );
