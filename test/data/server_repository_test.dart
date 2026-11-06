import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/ssh/multiplexer/multiplexer_backend.dart';

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

  tearDown(() async {
    await db.close();
  });

  test('database opens and creates tables', () async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    expect(names, containsAll({'servers', 'ssh_keys'}));
  });

  test('insert and fetch server', () async {
    final server = Server(
      id: const Uuid().v4(),
      name: 'My Server',
      host: 'example.com',
      port: 22,
      username: 'admin',
      authType: 'password',
    );
    await repo.insert(server);
    final all = await repo.findAll();
    expect(all.length, 1);
    expect(all.first.host, 'example.com');
  });

  test('update server', () async {
    final server = Server(
      id: const Uuid().v4(),
      name: 'Old',
      host: 'host.com',
      port: 22,
      username: 'user',
      authType: 'password',
    );
    await repo.insert(server);
    await repo.update(server.copyWith(name: 'New'));
    final updated = await repo.findById(server.id);
    expect(updated?.name, 'New');
  });

  test('delete server', () async {
    final server = Server(
      id: const Uuid().v4(),
      name: 'ToDelete',
      host: 'host.com',
      port: 22,
      username: 'user',
      authType: 'password',
    );
    await repo.insert(server);
    await repo.delete(server.id);
    expect(await repo.findAll(), isEmpty);
  });

  test('useTmux persists and multiplexerType derives from it', () async {
    final server = Server(
      id: const Uuid().v4(),
      name: 'TmuxServer',
      host: 'tmux.example.com',
      port: 22,
      username: 'user',
      authType: 'password',
      useTmux: true,
    );
    await repo.insert(server);
    final fetched = await repo.findById(server.id);
    expect(fetched?.useTmux, isTrue);
    expect(fetched?.multiplexerType, MultiplexerType.tmux);

    await repo.update(server.copyWith(useTmux: false));
    final updated = await repo.findById(server.id);
    expect(updated?.useTmux, isFalse);
    expect(updated?.multiplexerType, MultiplexerType.none);
  });

  test('Server without useTmux in DB defaults to false', () async {
    // Simulate a row written before the migration (no use_tmux column value)
    await db.rawInsert(
      "INSERT INTO servers (id, name, host, port, username, auth_type) "
      "VALUES ('legacy-id', 'Legacy', 'legacy.host', 22, 'user', 'password')",
    );
    final fetched = await repo.findById('legacy-id');
    expect(fetched?.useTmux, isFalse);
    expect(fetched?.multiplexerType, MultiplexerType.none);
  });

  test('DB v13 has server_type column in servers table', () async {
    final db = await AppDatabase.open(inMemory: true);
    final cols = await db.rawQuery("PRAGMA table_info(servers)");
    final colNames = cols.map((c) => c['name'] as String).toSet();
    expect(colNames, contains('server_type'));
    await db.close();
  });
}
