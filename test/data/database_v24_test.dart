import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v23 → v24 migration: 4 strategies collapse to 3 + drop dead columns',
      () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v24');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // ── Stage 1: open at v23 schema (all to-be-dropped columns present) ──
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 23),
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
        connection_strategy TEXT NOT NULL DEFAULT 'sshOnly',
        aqt_install_declined INTEGER NOT NULL DEFAULT 0,
        aqt_install_version TEXT
      )
    ''');
    // 5 rows covering 4 historical strategies + 1 dirty-data scenario:
    await db.insert('servers', {
      'id': 'r1-sshOnly', 'name': 'A', 'host': 'h', 'port': 22,
      'username': 'u', 'auth_type': 'password',
      'connection_strategy': 'sshOnly', 'use_mosh': 0, 'multiplexer_type': 'none',
    });
    await db.insert('servers', {
      'id': 'r2-mosh', 'name': 'B', 'host': 'h', 'port': 22,
      'username': 'u', 'auth_type': 'password',
      'connection_strategy': 'mosh', 'use_mosh': 1, 'multiplexer_type': 'none',
    });
    await db.insert('servers', {
      'id': 'r3-quicFallback', 'name': 'C', 'host': 'h', 'port': 22,
      'username': 'u', 'auth_type': 'password',
      'connection_strategy': 'quicFallbackSsh', 'use_mosh': 0,
      'multiplexer_type': 'tmux',
    });
    await db.insert('servers', {
      'id': 'r4-quicOnly', 'name': 'D', 'host': 'h', 'port': 22,
      'username': 'u', 'auth_type': 'password',
      'connection_strategy': 'quicOnly', 'use_mosh': 0,
      'multiplexer_type': 'tmux',
    });
    // Dirty data: useMosh=1 was historical source-of-truth even though
    // strategy stayed at default 'sshOnly'.
    await db.insert('servers', {
      'id': 'r5-dirty', 'name': 'E', 'host': 'h', 'port': 22,
      'username': 'u', 'auth_type': 'password',
      'connection_strategy': 'sshOnly', 'use_mosh': 1,
      'multiplexer_type': 'tmux',
    });
    await db.close();

    // ── Stage 2: reopen at v24 with the production migration logic inline ──
    final db2 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 24,
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 24) {
            // 1. Dirty data fix
            await db.execute(
              "UPDATE servers SET connection_strategy = 'mosh' "
              "WHERE use_mosh = 1 AND connection_strategy = 'sshOnly'",
            );
            // 2. Collapse enum values
            await db.execute(
              "UPDATE servers SET connection_strategy = 'ssh' "
              "WHERE connection_strategy = 'sshOnly'",
            );
            await db.execute(
              "UPDATE servers SET connection_strategy = 'quic' "
              "WHERE connection_strategy IN ('quicFallbackSsh', 'quicOnly')",
            );
            // 3. multiplexer_type='tmux' → use_tmux=1
            await db.execute(
              "UPDATE servers SET use_tmux = 1 WHERE multiplexer_type = 'tmux'",
            );
            // 4. Rebuild dance (drop 4 columns)
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
                mosh_port_range TEXT NOT NULL DEFAULT '60000:61000',
                mosh_pid INTEGER,
                group_name TEXT,
                agent_forwarding INTEGER NOT NULL DEFAULT 0,
                server_type TEXT NOT NULL DEFAULT 'ssh',
                address_family TEXT NOT NULL DEFAULT 'auto',
                connection_strategy TEXT NOT NULL DEFAULT 'quic'
              )
            ''');
            await db.execute('''
              INSERT INTO servers_new (
                id, name, host, port, username, auth_type, key_id,
                last_connected_at, startup_command, use_tmux, jump_host_id,
                mosh_port_range, mosh_pid, group_name, agent_forwarding,
                server_type, address_family, connection_strategy
              )
              SELECT
                id, name, host, port, username, auth_type, key_id,
                last_connected_at, startup_command, use_tmux, jump_host_id,
                mosh_port_range, mosh_pid, group_name, agent_forwarding,
                server_type, address_family, connection_strategy
              FROM servers
            ''');
            await db.execute('DROP TABLE servers');
            await db.execute('ALTER TABLE servers_new RENAME TO servers');
          }
        },
      ),
    );

    // ── Stage 3: assertions ──
    final cols = await db2.rawQuery('PRAGMA table_info(servers)');
    final colNames = cols.map((c) => c['name']).toList();
    expect(colNames, isNot(contains('use_mosh')));
    expect(colNames, isNot(contains('multiplexer_type')));
    expect(colNames, isNot(contains('aqt_install_declined')));
    expect(colNames, isNot(contains('aqt_install_version')));
    expect(colNames, contains('use_tmux'));
    expect(colNames, contains('connection_strategy'));

    Future<Map<String, Object?>> rowById(String id) async =>
        (await db2.query('servers', where: 'id = ?', whereArgs: [id])).single;

    expect((await rowById('r1-sshOnly'))['connection_strategy'], 'ssh');
    expect((await rowById('r1-sshOnly'))['use_tmux'], 0);

    expect((await rowById('r2-mosh'))['connection_strategy'], 'mosh');
    expect((await rowById('r2-mosh'))['use_tmux'], 0);

    expect((await rowById('r3-quicFallback'))['connection_strategy'], 'quic');
    expect((await rowById('r3-quicFallback'))['use_tmux'], 1);

    expect((await rowById('r4-quicOnly'))['connection_strategy'], 'quic');
    expect((await rowById('r4-quicOnly'))['use_tmux'], 1);

    // Dirty data: use_mosh=1 + strategy='sshOnly' → final strategy=mosh
    expect((await rowById('r5-dirty'))['connection_strategy'], 'mosh');
    expect((await rowById('r5-dirty'))['use_tmux'], 1);

    await db2.close();
  });
}
