import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/host_key_verifier.dart';
import 'package:flyterm/ssh/ssh_connection.dart';
import 'package:flyterm/ssh/ssh_connection_pool.dart';

void main() {
  final env = Platform.environment;
  final runLocalSshTest = env['RUN_LOCAL_SSH_TEST'] == '1';

  test(
    'direct key auth reuses pooled localhost client and opens shells',
    () async {
      final host = env['SSH_TEST_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['SSH_TEST_PORT'] ?? '') ?? 22;
      final user =
          _envOrNull(env, 'SSH_TEST_USER') ?? _envOrNull(env, 'USER') ?? 'root';
      final keyPath = env['SSH_TEST_KEY'] ?? '/root/.ssh/id_rsa';
      final privateKeyPem = await File(keyPath).readAsString();

      final pool = SshConnectionPool();
      final verifier = _AcceptAllHostKeyVerifier();
      final keyId = 'local-test:$keyPath';
      final poolKey =
          SshConnectionPool.keyFor(
            host: host,
            port: port,
            username: user,
            authType: 'key',
            keyId: keyId,
          )!;
      final first = SSHConnection();
      final second = SSHConnection();

      try {
        final firstShell = await first.connect(
          host: host,
          port: port,
          username: user,
          privateKeyPem: privateKeyPem,
          openShell: true,
          hostKeyVerifier: verifier,
          pool: pool,
          keyId: keyId,
          addressFamily: host == '127.0.0.1' ? 'ipv4' : 'auto',
        );

        final secondShell = await second.connect(
          host: host,
          port: port,
          username: user,
          privateKeyPem: privateKeyPem,
          openShell: true,
          hostKeyVerifier: verifier,
          pool: pool,
          keyId: keyId,
          addressFamily: host == '127.0.0.1' ? 'ipv4' : 'auto',
        );

        expect(firstShell, isNotNull);
        expect(secondShell, isNotNull);
        expect(first.shell, same(firstShell));
        expect(second.shell, same(secondShell));
        expect(first.client, same(second.client));
        expect(pool.aliveCount, 1);
      } finally {
        final pooledClient = first.client ?? second.client;
        if (pooledClient != null) {
          pool.invalidate(poolKey, pooledClient);
        }
        await second.close();
        await first.close();
      }
    },
    skip:
        runLocalSshTest
            ? false
            : 'Set RUN_LOCAL_SSH_TEST=1 to run localhost sshd integration test.',
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'MaxSessions=1 channel-open failure retires pool and retries fresh client',
    () async {
      final host = env['SSH_TEST_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['SSH_TEST_MAXSESSIONS_PORT'] ?? '')!;
      final user =
          _envOrNull(env, 'SSH_TEST_USER') ?? _envOrNull(env, 'USER') ?? 'root';
      final keyPath = env['SSH_TEST_KEY'] ?? '/root/.ssh/id_rsa';
      final privateKeyPem = await File(keyPath).readAsString();

      final pool = SshConnectionPool();
      final verifier = _AcceptAllHostKeyVerifier();
      final keyId = 'local-maxsessions-test:$keyPath';
      final first = SSHConnection();
      final second = SSHConnection();

      try {
        final firstShell = await first.connect(
          host: host,
          port: port,
          username: user,
          privateKeyPem: privateKeyPem,
          openShell: true,
          hostKeyVerifier: verifier,
          pool: pool,
          keyId: keyId,
          addressFamily: host == '127.0.0.1' ? 'ipv4' : 'auto',
        );
        final firstClient = first.client;

        final secondShell = await second.connect(
          host: host,
          port: port,
          username: user,
          privateKeyPem: privateKeyPem,
          openShell: true,
          hostKeyVerifier: verifier,
          pool: pool,
          keyId: keyId,
          addressFamily: host == '127.0.0.1' ? 'ipv4' : 'auto',
        );

        expect(firstShell, isNotNull);
        expect(secondShell, isNotNull);
        expect(firstClient, isNotNull);
        expect(first.client, same(firstClient));
        expect(firstClient!.isClosed, isFalse);
        expect(second.client, isNot(same(firstClient)));
        expect(pool.aliveCount, 0);
      } finally {
        await second.close();
        await first.close();
      }
    },
    skip:
        !runLocalSshTest
            ? 'Set RUN_LOCAL_SSH_TEST=1 to run localhost sshd integration test.'
            : env['SSH_TEST_MAXSESSIONS_PORT'] == null
            ? 'Set SSH_TEST_MAXSESSIONS_PORT to a localhost sshd with MaxSessions=1.'
            : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

String? _envOrNull(Map<String, String> env, String key) {
  final value = env[key];
  return value == null || value.isEmpty ? null : value;
}

class _AcceptAllHostKeyVerifier implements HostKeyVerifier {
  @override
  Future<bool> verify({
    required String host,
    required int port,
    required String keyType,
    required String fingerprintMd5,
  }) async => true;
}
