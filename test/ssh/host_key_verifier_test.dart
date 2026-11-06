import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/models/known_host.dart';
import 'package:flyterm/data/repositories/known_host_repository.dart';
import 'package:flyterm/ssh/host_key_verifier.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late KnownHostRepository repo;
  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false, // independent in-memory DB per test
        onCreate: (db, _) => db.execute('''
          CREATE TABLE known_hosts (
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            key_type TEXT NOT NULL,
            fingerprint_md5 TEXT NOT NULL,
            first_seen INTEGER NOT NULL,
            last_seen INTEGER NOT NULL,
            PRIMARY KEY (host, port, key_type)
          )
        '''),
      ),
    );
    repo = KnownHostRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  HostKeyPrompt _alwaysAccept() =>
      ({
        required String host,
        required int port,
        required String keyType,
        required String fingerprintMd5,
        required HostKeyPromptKind kind,
        String? expectedFingerprintMd5,
      }) async =>
          HostKeyDecision.accept;

  HostKeyPrompt _alwaysReject() =>
      ({
        required String host,
        required int port,
        required String keyType,
        required String fingerprintMd5,
        required HostKeyPromptKind kind,
        String? expectedFingerprintMd5,
      }) async =>
          HostKeyDecision.reject;

  test('TOFU: accept prompt inserts row and returns true', () async {
    HostKeyPromptKind? gotKind;
    final v = DefaultHostKeyVerifier(
      repo: repo,
      prompt: ({
        required String host,
        required int port,
        required String keyType,
        required String fingerprintMd5,
        required HostKeyPromptKind kind,
        String? expectedFingerprintMd5,
      }) async {
        gotKind = kind;
        return HostKeyDecision.accept;
      },
    );

    final ok = await v.verify(
      host: 'example.com',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprintMd5: 'aa:bb:cc:dd',
    );

    expect(ok, isTrue);
    expect(gotKind, HostKeyPromptKind.trustOnFirstUse);
    final row = await repo.find(
        host: 'example.com', port: 22, keyType: 'ssh-ed25519');
    expect(row, isNotNull);
    expect(row!.fingerprintMd5, 'aa:bb:cc:dd');
  });

  test('TOFU: reject prompt → no insert, returns false', () async {
    final v = DefaultHostKeyVerifier(repo: repo, prompt: _alwaysReject());
    final ok = await v.verify(
      host: 'example.com',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprintMd5: 'aa:bb:cc:dd',
    );
    expect(ok, isFalse);
    final row = await repo.find(
        host: 'example.com', port: 22, keyType: 'ssh-ed25519');
    expect(row, isNull);
  });

  test('match: silent accept, refreshes last_seen', () async {
    final old = DateTime.now().subtract(const Duration(days: 1));
    await repo.save(KnownHost(
      host: 'a.com',
      port: 22,
      keyType: 'ssh-rsa',
      fingerprintMd5: 'aa',
      firstSeen: old,
      lastSeen: old,
    ));
    final v = DefaultHostKeyVerifier(
      repo: repo,
      prompt: ({
        required String host,
        required int port,
        required String keyType,
        required String fingerprintMd5,
        required HostKeyPromptKind kind,
        String? expectedFingerprintMd5,
      }) async {
        fail('prompt must not be called on a matching fingerprint');
      },
    );
    final ok = await v.verify(
        host: 'a.com', port: 22, keyType: 'ssh-rsa', fingerprintMd5: 'aa');
    expect(ok, isTrue);
    final row = await repo.find(host: 'a.com', port: 22, keyType: 'ssh-rsa');
    expect(row!.lastSeen.isAfter(old), isTrue);
  });

  test('mismatch: prompt fires with kind=mismatch, expected fp passed through',
      () async {
    final old = DateTime.now().subtract(const Duration(days: 30));
    await repo.save(KnownHost(
      host: 'a.com',
      port: 22,
      keyType: 'ssh-rsa',
      fingerprintMd5: 'aa',
      firstSeen: old,
      lastSeen: old,
    ));
    HostKeyPromptKind? gotKind;
    String? gotExpected;
    final v = DefaultHostKeyVerifier(
      repo: repo,
      prompt: ({
        required String host,
        required int port,
        required String keyType,
        required String fingerprintMd5,
        required HostKeyPromptKind kind,
        String? expectedFingerprintMd5,
      }) async {
        gotKind = kind;
        gotExpected = expectedFingerprintMd5;
        return HostKeyDecision.accept;
      },
    );
    final ok = await v.verify(
        host: 'a.com', port: 22, keyType: 'ssh-rsa', fingerprintMd5: 'bb');
    expect(ok, isTrue);
    expect(gotKind, HostKeyPromptKind.mismatch);
    expect(gotExpected, 'aa');
    final row = await repo.find(host: 'a.com', port: 22, keyType: 'ssh-rsa');
    expect(row!.fingerprintMd5, 'bb');
    // firstSeen preserved across replace
    expect(row.firstSeen.millisecondsSinceEpoch,
        old.millisecondsSinceEpoch);
  });

  test('mismatch: reject prompt leaves row unchanged, returns false',
      () async {
    final t = DateTime.now().subtract(const Duration(days: 30));
    await repo.save(KnownHost(
      host: 'a.com',
      port: 22,
      keyType: 'ssh-rsa',
      fingerprintMd5: 'aa',
      firstSeen: t,
      lastSeen: t,
    ));
    final v = DefaultHostKeyVerifier(repo: repo, prompt: _alwaysReject());
    final ok = await v.verify(
        host: 'a.com', port: 22, keyType: 'ssh-rsa', fingerprintMd5: 'bb');
    expect(ok, isFalse);
    final row = await repo.find(host: 'a.com', port: 22, keyType: 'ssh-rsa');
    expect(row!.fingerprintMd5, 'aa');
  });

  test('no prompt registered: fails closed on TOFU and mismatch', () async {
    final v = DefaultHostKeyVerifier(repo: repo);
    final tofu = await v.verify(
        host: 'a.com', port: 22, keyType: 'ssh-rsa', fingerprintMd5: 'aa');
    expect(tofu, isFalse);
    await repo.save(KnownHost(
      host: 'b.com',
      port: 22,
      keyType: 'ssh-rsa',
      fingerprintMd5: 'aa',
      firstSeen: DateTime.now(),
      lastSeen: DateTime.now(),
    ));
    final mismatch = await v.verify(
        host: 'b.com', port: 22, keyType: 'ssh-rsa', fingerprintMd5: 'bb');
    expect(mismatch, isFalse);
  });

  test('different (host, port, keyType) tuples are tracked independently',
      () async {
    final v = DefaultHostKeyVerifier(repo: repo, prompt: _alwaysAccept());
    expect(
        await v.verify(
            host: 'a.com', port: 22, keyType: 'ssh-rsa', fingerprintMd5: 'aa'),
        isTrue);
    expect(
        await v.verify(
            host: 'a.com', port: 2222, keyType: 'ssh-rsa', fingerprintMd5: 'cc'),
        isTrue);
    expect(
        await v.verify(
            host: 'a.com',
            port: 22,
            keyType: 'ssh-ed25519',
            fingerprintMd5: 'dd'),
        isTrue);
    final all = await repo.findAll();
    expect(all.length, 3);
  });
}
