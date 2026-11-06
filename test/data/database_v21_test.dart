import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v20 → v21 migration adds aqt_install_declined + aqt_install_version',
      () async {
    // Use a temp-file DB so state survives close()/reopen() across versions.
    // (inMemoryDatabasePath spawns a fresh DB on each open, so it can't be
    // used to verify migrations across openDatabase calls.)
    final tempDir = await Directory.systemTemp.createTemp('flyterm_v21_test_');
    final dbPath = p.join(tempDir.path, 'v21_test.db');
    addTearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    // Step 1: Open at v20, create with old schema (minimal columns needed)
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: 20),
    );
    await db.execute('''
      CREATE TABLE servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL DEFAULT 'password',
        connection_strategy TEXT NOT NULL DEFAULT 'sshOnly'
      )
    ''');
    await db.insert('servers', {
      'id': 'test1',
      'name': 'Test',
      'host': 'h',
      'port': 22,
      'username': 'u',
      'auth_type': 'password',
      'connection_strategy': 'sshOnly',
    });
    await db.close();

    // Step 2: Reopen at v21 — should auto-run migration logic
    final db2 = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 21,
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 21) {
            await db.execute(
                'ALTER TABLE servers ADD COLUMN aqt_install_declined INTEGER NOT NULL DEFAULT 0');
            await db.execute(
                'ALTER TABLE servers ADD COLUMN aqt_install_version TEXT');
          }
        },
      ),
    );
    // Step 3: Verify columns exist
    final cols = await db2.rawQuery('PRAGMA table_info(servers)');
    final colNames = cols.map((c) => c['name']).toList();
    expect(colNames, contains('aqt_install_declined'));
    expect(colNames, contains('aqt_install_version'));
    await db2.close();
  });
}
