import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v24 → v25 migration: add use_daemon column with default 0', () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v25');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // ── Stage 1: open at v24 schema ──
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 24),
    );
    await db.execute('''
      CREATE TABLE servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL DEFAULT 'password',
        key_id TEXT,
        last_connected_at INTEGER,
        startup_command TEXT,
        use_tmux INTEGER NOT NULL DEFAULT 0,
        jump_host_id TEXT,
        mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
        mosh_pid INTEGER,
        group_name TEXT,
        agent_forwarding INTEGER NOT NULL DEFAULT 0,
        server_type TEXT NOT NULL DEFAULT 'ssh',
        address_family TEXT NOT NULL DEFAULT 'auto',
        connection_strategy TEXT NOT NULL DEFAULT 'quic'
      )
    ''');
    await db.insert('servers', {
      'id': 'srv1',
      'name': 'Existing',
      'host': 'h',
      'port': 22,
      'username': 'u',
      'auth_type': 'password',
      'connection_strategy': 'quic',
    });
    await db.close();

    // ── Stage 2: reopen at v25 with inline migration ──
    final db2 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 25,
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 25) {
            await db.execute(
              "ALTER TABLE servers ADD COLUMN use_daemon INTEGER NOT NULL DEFAULT 0",
            );
          }
        },
      ),
    );

    // ── Stage 3: assertions ──
    final cols = await db2.rawQuery('PRAGMA table_info(servers)');
    final colNames = cols.map((c) => c['name']).toList();
    expect(colNames, contains('use_daemon'));

    final row = (await db2.query('servers', where: 'id = ?', whereArgs: ['srv1']))
        .single;
    expect(row['use_daemon'], 0); // default applied to existing row

    // New rows can set use_daemon explicitly
    await db2.insert('servers', {
      'id': 'srv2',
      'name': 'NewDaemon',
      'host': 'h',
      'port': 22,
      'username': 'u',
      'auth_type': 'password',
      'connection_strategy': 'quic',
      'use_daemon': 1,
    });
    final daemonRow =
        (await db2.query('servers', where: 'id = ?', whereArgs: ['srv2'])).single;
    expect(daemonRow['use_daemon'], 1);

    await db2.close();
  });
}
