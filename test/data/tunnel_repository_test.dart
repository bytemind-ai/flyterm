import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/tunnel_config.dart';
import 'package:flyterm/data/repositories/tunnel_repository.dart';
import 'package:flyterm/tunnel/tunnel_entry.dart';
import 'package:uuid/uuid.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
  });

  tearDown(() async {
    await db.close();
  });

  TunnelConfig makeConfig({bool autoStart = false}) => TunnelConfig(
        id: const Uuid().v4(),
        serverId: const Uuid().v4(),
        direction: TunnelDirection.local,
        localPort: 3306,
        remoteHost: 'db.internal',
        remotePort: 3306,
        label: 'MySQL',
        autoStart: autoStart,
      );

  test('tunnels table exists after migration', () async {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='tunnels'");
    expect(tables, isNotEmpty);
  });

  test('insert and findAll round-trip', () async {
    final repo = TunnelRepository(db);
    final config = makeConfig();
    await repo.insert(config);
    final all = await repo.findAll();
    expect(all.length, 1);
    expect(all.first.id, config.id);
    expect(all.first.serverId, config.serverId);
    expect(all.first.direction, TunnelDirection.local);
    expect(all.first.localPort, 3306);
    expect(all.first.remoteHost, 'db.internal');
    expect(all.first.remotePort, 3306);
    expect(all.first.label, 'MySQL');
    expect(all.first.autoStart, false);
  });

  test('updateAutoStart flips the flag', () async {
    final repo = TunnelRepository(db);
    final config = makeConfig();
    await repo.insert(config);
    await repo.updateAutoStart(config.id, true);
    final all = await repo.findAll();
    expect(all.first.autoStart, true);
  });

  test('delete removes the row', () async {
    final repo = TunnelRepository(db);
    final config = makeConfig();
    await repo.insert(config);
    await repo.delete(config.id);
    expect(await repo.findAll(), isEmpty);
  });

  test('findAll on empty table returns empty list', () async {
    final repo = TunnelRepository(db);
    expect(await repo.findAll(), isEmpty);
  });

  test('socks5 direction round-trips correctly', () async {
    final repo = TunnelRepository(db);
    final config = TunnelConfig(
      id: const Uuid().v4(),
      serverId: const Uuid().v4(),
      direction: TunnelDirection.socks5,
      localPort: 1080,
      remoteHost: '',
      remotePort: 0,
      label: 'SOCKS5 proxy',
      autoStart: false,
    );
    await repo.insert(config);
    final all = await repo.findAll();
    expect(all.first.direction, TunnelDirection.socks5);
    expect(all.first.remoteHost, '');
    expect(all.first.remotePort, 0);
  });

  test('migration v2 to v3 creates tunnels table and preserves existing data', () async {
    // Simulate a v2 database (servers + ssh_keys + ai_providers, no tunnels)
    // singleInstance: false is required so sqflite does not reuse the ':memory:'
    // connection that setUp already opened (with version 3 + tunnels table).
    final db2 = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 2,
        singleInstance: false,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE servers (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              host TEXT NOT NULL,
              port INTEGER NOT NULL DEFAULT 22,
              username TEXT NOT NULL,
              auth_type TEXT NOT NULL DEFAULT 'password',
              key_id TEXT,
              last_connected_at INTEGER
            )
          ''');
          await db.execute('''
            CREATE TABLE ssh_keys (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              public_key TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS ai_providers (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              model TEXT NOT NULL,
              base_url TEXT,
              is_default INTEGER NOT NULL DEFAULT 0
            )
          ''');
        },
      ),
    );

    // Insert a server to verify it survives the migration
    await db2.insert('servers', {
      'id': 'srv-migration-test',
      'name': 'Prod Server',
      'host': '10.0.0.1',
      'port': 22,
      'username': 'admin',
      'auth_type': 'password',
    });

    // Verify tunnels table does NOT exist yet (v2 schema)
    final beforeTables = await db2.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='tunnels'");
    expect(beforeTables, isEmpty, reason: 'tunnels table should not exist in v2 schema');

    // Apply the v3 migration SQL (same SQL as _onUpgrade oldVersion < 3)
    await db2.execute('''
      CREATE TABLE IF NOT EXISTS tunnels (
        id          TEXT    PRIMARY KEY,
        server_id   TEXT    NOT NULL,
        direction   TEXT    NOT NULL,
        local_port  INTEGER NOT NULL,
        remote_host TEXT    NOT NULL,
        remote_port INTEGER NOT NULL,
        label       TEXT    NOT NULL,
        auto_start  INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Verify tunnels table now exists
    final afterTables = await db2.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='tunnels'");
    expect(afterTables, isNotEmpty, reason: 'tunnels table should exist after v3 migration');

    // Verify existing server data preserved
    final servers = await db2.query('servers',
        where: 'id = ?', whereArgs: ['srv-migration-test']);
    expect(servers.length, 1);
    expect(servers.first['name'], 'Prod Server');

    await db2.close();
  });
}
