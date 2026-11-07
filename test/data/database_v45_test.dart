import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/database.dart';

/// v44 → v45：经由 SSH 通道（SSH relay）的两列 ——
/// `servers.aqt_via_ssh`（「始终走 SSH 通道」）与
/// `aqt_session_state.via_ssh`（会话首次连接时探测出的路由）。
/// 范式同 `database_v44_test.dart`：走真实的 `AppDatabase.open`。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Future<List<String>> columns(Database db, String table) async => [
        for (final c in await db.rawQuery('PRAGMA table_info($table)'))
          c['name'] as String,
      ];

  test('v44 → v45：两列加上，存量行取默认 0', () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v45');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 44),
    );
    await old.execute('''
      CREATE TABLE servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL DEFAULT 'password',
        aqt_ports TEXT
      )
    ''');
    await old.execute('''
      CREATE TABLE aqt_session_state (
        tab_id TEXT PRIMARY KEY,
        aqt_tab_id INTEGER NOT NULL DEFAULT 0,
        port INTEGER NOT NULL,
        spki BLOB NOT NULL,
        scrollback_cursor INTEGER NOT NULL DEFAULT 0,
        server_ttl_secs INTEGER,
        saved_at INTEGER NOT NULL
      )
    ''');
    await old.insert('servers', {
      'id': 'srv-1',
      'name': 'legacy-host',
      'host': '10.0.0.1',
      'username': 'root',
    });
    await old.insert('aqt_session_state', {
      'tab_id': 't1',
      'port': 61005,
      'spki': [1, 2, 3],
      'saved_at': 1,
    });
    await old.close();

    final db = await AppDatabase.open(overridePath: path);
    addTearDown(db.close);
    expect(await db.getVersion(), greaterThanOrEqualTo(45));
    expect(await columns(db, 'servers'), contains('aqt_via_ssh'));
    expect(await columns(db, 'aqt_session_state'), contains('via_ssh'));
    expect((await db.query('servers')).single['aqt_via_ssh'], 0);
    expect((await db.query('aqt_session_state')).single['via_ssh'], 0);
  });

  test('全新安装的库直接带两列', () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v45_new');
    addTearDown(() => dir.delete(recursive: true));
    final db =
        await AppDatabase.open(overridePath: p.join(dir.path, 'fresh.db'));
    addTearDown(db.close);
    expect(await columns(db, 'servers'), contains('aqt_via_ssh'));
    expect(await columns(db, 'aqt_session_state'), contains('via_ssh'));
  });
}
