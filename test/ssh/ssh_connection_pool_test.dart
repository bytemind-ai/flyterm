// Unit tests for [SshConnectionPool]. We don't drive a real SSH stack
// here — the pool's job is acquire/release/refcount/race semantics, so
// we substitute a fake "client" via a minimal harness.
//
// We can't easily fake [SSHClient] because dartssh2 doesn't expose a
// constructor we can drive without a socket. Instead these tests cover
// the pure-Dart parts of the pool through visible-for-testing helpers;
// the acquire-with-real-build path is exercised in the integration test
// path by running the SSH suite end-to-end.
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/ssh_connection_pool.dart';

void main() {
  group('SshConnectionPool.keyFor', () {
    test('direct + key auth produces a stable composite key', () {
      final k = SshConnectionPool.keyFor(
        host: 'example.com',
        port: 22,
        username: 'alice',
        authType: 'key',
        keyId: 'k1',
      );
      expect(k, 'd:example.com:22:alice:k1');
    });

    test('different (host, port, user, keyId) produce different keys', () {
      final base = SshConnectionPool.keyFor(
        host: 'a',
        port: 22,
        username: 'u',
        authType: 'key',
        keyId: 'k',
      );
      final diffHost = SshConnectionPool.keyFor(
        host: 'b',
        port: 22,
        username: 'u',
        authType: 'key',
        keyId: 'k',
      );
      final diffPort = SshConnectionPool.keyFor(
        host: 'a',
        port: 23,
        username: 'u',
        authType: 'key',
        keyId: 'k',
      );
      final diffUser = SshConnectionPool.keyFor(
        host: 'a',
        port: 22,
        username: 'v',
        authType: 'key',
        keyId: 'k',
      );
      final diffKey = SshConnectionPool.keyFor(
        host: 'a',
        port: 22,
        username: 'u',
        authType: 'key',
        keyId: 'k2',
      );
      expect({base, diffHost, diffPort, diffUser, diffKey}.length, 5);
    });

    test('jump host paths bypass pooling (key is null)', () {
      final k = SshConnectionPool.keyFor(
        host: 'a',
        port: 22,
        username: 'u',
        authType: 'key',
        keyId: 'k',
        jumpHostId: 'jump1',
      );
      expect(k, isNull);
    });

    test('password auth bypasses pooling (key is null)', () {
      final k = SshConnectionPool.keyFor(
        host: 'a',
        port: 22,
        username: 'u',
        authType: 'password',
      );
      expect(k, isNull);
    });

    test('key auth without keyId bypasses pooling', () {
      final k = SshConnectionPool.keyFor(
        host: 'a',
        port: 22,
        username: 'u',
        authType: 'key',
      );
      expect(k, isNull);
    });
  });

  group('SshConnectionPool initial state', () {
    test('empty pool reports 0 alive and refcount 0 for any key', () {
      final p = SshConnectionPool();
      expect(p.aliveCount, 0);
      expect(p.refCountOf('d:any:22:user:key'), 0);
      expect(p.isHealthy('d:any:22:user:key'), isFalse);
    });
  });

  group('SshConnectionPool invalidation retirement', () {
    const key = 'd:example.com:22:alice:k1';

    test(
      'invalidate with refCount > 1 retires without closing until final release',
      () {
        final pool = SshConnectionPool();
        final client = Object();
        var closeCount = 0;

        pool.addClientForTesting(
          key,
          client,
          refCount: 2,
          onClose: () => closeCount++,
        );

        pool.invalidateForTesting(key, client);

        expect(pool.aliveCount, 0);
        expect(pool.refCountOf(key), 0);
        expect(pool.retiredCountOf(key), 1);
        expect(closeCount, 0);

        pool.releaseForTesting(key, client);

        expect(pool.aliveCount, 0);
        expect(pool.retiredCountOf(key), 1);
        expect(closeCount, 0);

        pool.releaseForTesting(key, client);

        expect(pool.aliveCount, 0);
        expect(pool.retiredCountOf(key), 0);
        expect(closeCount, 1);
      },
    );

    test('invalidate with refCount <= 1 closes and clears immediately', () {
      final pool = SshConnectionPool();
      final client = Object();
      var closeCount = 0;

      pool.addClientForTesting(
        key,
        client,
        refCount: 1,
        onClose: () => closeCount++,
      );

      pool.invalidateForTesting(key, client);

      expect(pool.aliveCount, 0);
      expect(pool.refCountOf(key), 0);
      expect(pool.retiredCountOf(key), 0);
      expect(closeCount, 1);
    });
  });
}
