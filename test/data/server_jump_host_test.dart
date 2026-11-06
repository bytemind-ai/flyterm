import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ServerRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = ServerRepository(db);
  });

  tearDown(() async => db.close());

  test('Server.toMap/fromMap roundtrips jumpHostId', () {
    const id = 'server-1';
    const jumpId = 'jump-1';
    final s = Server(
      id: id, name: 'Target', host: '10.0.0.1', port: 22,
      username: 'user', authType: 'password', jumpHostId: jumpId,
    );
    final map = s.toMap();
    expect(map['jump_host_id'], jumpId);
    final restored = Server.fromMap(map);
    expect(restored.jumpHostId, jumpId);
  });

  test('Server.fromMap accepts null jumpHostId', () {
    final map = {
      'id': 'x', 'name': 'N', 'host': 'h', 'port': 22,
      'username': 'u', 'auth_type': 'password',
      'key_id': null, 'last_connected_at': null,
      'startup_command': null, 'use_tmux': 0,
      // jump_host_id absent (old row) — must not throw
    };
    final s = Server.fromMap(map);
    expect(s.jumpHostId, isNull);
  });

  test('Server.copyWith clears jumpHostId when passed null', () {
    final s = Server(
      id: '1', name: 'T', host: 'h', port: 22,
      username: 'u', authType: 'password', jumpHostId: 'j',
    );
    final cleared = s.copyWith(jumpHostId: null);
    expect(cleared.jumpHostId, isNull);
  });

  test('DB v9: jump_host_id column exists and is persisted', () async {
    final jump = Server(
      id: const Uuid().v4(), name: 'Bastion', host: '1.2.3.4',
      port: 22, username: 'ops', authType: 'password',
    );
    final target = Server(
      id: const Uuid().v4(), name: 'Target', host: '10.0.0.5',
      port: 22, username: 'dev', authType: 'password',
      jumpHostId: jump.id,
    );
    await repo.insert(jump);
    await repo.insert(target);

    final fetched = await repo.findById(target.id);
    expect(fetched?.jumpHostId, jump.id);
  });
}
