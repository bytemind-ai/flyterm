import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/known_host_repository.dart';
import 'package:flyterm/data/models/known_host.dart';

/// `insertTxn` 重载必须真的写进外层事务 —— 这是导入原子性的基础。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('insertTxn 在外层事务内可见，提交后仍在', () async {
    final db = await AppDatabase.open(inMemory: true);
    addTearDown(db.close);
    final repo = ServerRepository(db);

    await db.transaction((txn) async {
      await repo.insertTxn(
        txn,
        const Server(
          id: 's1',
          name: 'n',
          host: 'h',
          port: 22,
          username: 'u',
          authType: 'password',
        ),
      );
      final rows = await txn.query('servers');
      expect(rows, hasLength(1), reason: '事务内应可见');
    });

    expect(await repo.findAll(), hasLength(1), reason: '提交后应仍在');
  });

  test('事务抛出时回滚，行不落库', () async {
    final db = await AppDatabase.open(inMemory: true);
    addTearDown(db.close);
    final repo = ServerRepository(db);

    await expectLater(
      db.transaction((txn) async {
        await repo.insertTxn(
          txn,
          const Server(
            id: 's2',
            name: 'n',
            host: 'h',
            port: 22,
            username: 'u',
            authType: 'password',
          ),
        );
        throw Exception('boom');
      }),
      throwsException,
    );

    expect(await repo.findAll(), isEmpty, reason: '回滚后不应留下任何行');
  });

  test('known_hosts 的 insertTxn 也能在事务里回滚', () async {
    final db = await AppDatabase.open(inMemory: true);
    addTearDown(db.close);
    final repo = KnownHostRepository(db);

    await expectLater(
      db.transaction((txn) async {
        final now = DateTime.now();
        await repo.insertTxn(
          txn,
          KnownHost(
            host: 'h1',
            port: 22,
            keyType: 'ssh-ed25519',
            fingerprintMd5: 'fp',
            firstSeen: now,
            lastSeen: now,
          ),
        );
        throw Exception('boom');
      }),
      throwsException,
    );

    expect(await repo.findAll(), isEmpty);
  });
}
