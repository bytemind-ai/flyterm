import 'dart:typed_data';

import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/prewarm_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrewarmPool', () {
    test('store + take returns same instance and removes from pool', () {
      final pool = PrewarmPool();
      final t = _stub();
      pool.store('tab-a', t);
      expect(pool.has('tab-a'), isTrue);
      final taken = pool.take('tab-a');
      expect(identical(taken, t), isTrue);
      expect(pool.has('tab-a'), isFalse);
    });

    test('take on unknown returns null', () {
      final pool = PrewarmPool();
      expect(pool.take('nope'), isNull);
    });

    test('store overwrites previous', () {
      final pool = PrewarmPool();
      final t1 = _stub();
      final t2 = _stub();
      pool.store('tab-a', t1);
      pool.store('tab-a', t2);
      final taken = pool.take('tab-a');
      expect(identical(taken, t2), isTrue);
    });

    test('evictAndClose removes entry', () async {
      final pool = PrewarmPool();
      pool.store('tab-a', _stub());
      await pool.evictAndClose('tab-a');
      expect(pool.has('tab-a'), isFalse);
    });

    test('evictAndClose on unknown is no-op (does not throw)', () async {
      final pool = PrewarmPool();
      await pool.evictAndClose('nope');
      // No exception.
    });

    test('evictAll clears every entry', () async {
      final pool = PrewarmPool();
      pool.store('a', _stub());
      pool.store('b', _stub());
      await pool.evictAll();
      expect(pool.has('a'), isFalse);
      expect(pool.has('b'), isFalse);
    });
  });
}

AqtTransport _stub() => AqtTransport.testStub(
      port: 12345,
      spki: Uint8List(32),
      token: Uint8List(32),
      tabId: 1,
    );
