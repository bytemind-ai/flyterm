import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v22 → v23 migration drops shpool_configure_scrollback column', () async {
    // Use temp file (not :memory:) so close/reopen state survives migration.
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v23');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // ── Stage 1: open at v22 with a servers table including shpool col ──
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 22),
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
        use_mosh INTEGER NOT NULL DEFAULT 0,
        mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
        mosh_pid INTEGER,
        group_name TEXT,
        agent_forwarding INTEGER NOT NULL DEFAULT 0,
        server_type TEXT NOT NULL DEFAULT 'ssh',
        address_family TEXT NOT NULL DEFAULT 'auto',
        multiplexer_type TEXT NOT NULL DEFAULT 'none',
        shpool_configure_scrollback INTEGER NOT NULL DEFAULT 1,
        connection_strategy TEXT NOT NULL DEFAULT 'sshOnly',
        aqt_install_declined INTEGER NOT NULL DEFAULT 0,
        aqt_install_version TEXT
      )
    ''');
    await db.insert('servers', {
      'id': 'srv1',
      'name': 'KeepMe',
      'host': 'h',
      'port': 22,
      'username': 'u',
      'auth_type': 'password',
      'use_mosh': 1,
      'multiplexer_type': 'tmux',
      'shpool_configure_scrollback': 1,
      'connection_strategy': 'quicFallbackSsh',
      'aqt_install_declined': 0,
    });
    await db.close();

    // ── Stage 2: reopen at v23 with the production migration logic inline ──
    final db2 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 23,
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 23) {
            await db.execute('''
              CREATE TABLE servers_new (
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
                use_mosh INTEGER NOT NULL DEFAULT 0,
                mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
                mosh_pid INTEGER,
                group_name TEXT,
                agent_forwarding INTEGER NOT NULL DEFAULT 0,
                server_type TEXT NOT NULL DEFAULT 'ssh',
                address_family TEXT NOT NULL DEFAULT 'auto',
                multiplexer_type TEXT NOT NULL DEFAULT 'none',
                connection_strategy TEXT NOT NULL DEFAULT 'sshOnly',
                aqt_install_declined INTEGER NOT NULL DEFAULT 0,
                aqt_install_version TEXT
              )
            ''');
            await db.execute('''
              INSERT INTO servers_new (
                id, name, host, port, username, auth_type, key_id,
                last_connected_at, startup_command, use_tmux, jump_host_id,
                use_mosh, mosh_port_range, mosh_pid, group_name,
                agent_forwarding, server_type, address_family, multiplexer_type,
                connection_strategy, aqt_install_declined, aqt_install_version
              )
              SELECT
                id, name, host, port, username, auth_type, key_id,
                last_connected_at, startup_command, use_tmux, jump_host_id,
                use_mosh, mosh_port_range, mosh_pid, group_name,
                agent_forwarding, server_type, address_family, multiplexer_type,
                connection_strategy, aqt_install_declined, aqt_install_version
              FROM servers
            ''');
            await db.execute('DROP TABLE servers');
            await db.execute('ALTER TABLE servers_new RENAME TO servers');
          }
        },
      ),
    );

    // ── Stage 3: column should be gone ──
    final cols = await db2.rawQuery('PRAGMA table_info(servers)');
    final colNames = cols.map((c) => c['name']).toList();
    expect(colNames, isNot(contains('shpool_configure_scrollback')));
    expect(colNames, contains('connection_strategy'));
    expect(colNames, contains('aqt_install_declined'));
    expect(colNames, contains('aqt_install_version'));

    // ── Stage 4: existing row preserved (data not lost during rebuild) ──
    final row = (await db2.query('servers', where: 'id = ?', whereArgs: ['srv1']))
        .single;
    expect(row['name'], 'KeepMe');
    expect(row['use_mosh'], 1);
    expect(row['multiplexer_type'], 'tmux');
    expect(row['connection_strategy'], 'quicFallbackSsh');
    expect(row['aqt_install_declined'], 0);

    await db2.close();
  });
}
