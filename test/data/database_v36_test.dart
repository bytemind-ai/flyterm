import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v35 → v36 migration: add last_used_at (nullable) and hit_count columns',
      () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v36');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // ── Stage 1: open at v35 schema ──
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 35),
    );
    await db.execute('''
      CREATE TABLE agent_skills (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        description TEXT NOT NULL,
        body        TEXT NOT NULL,
        enabled     INTEGER NOT NULL DEFAULT 1,
        source      TEXT NOT NULL,
        updated_at  INTEGER NOT NULL
      )
    ''');
    await db.insert('agent_skills', {
      'name': 'nginx',
      'description': '排查 502',
      'body': 'existing body',
      'enabled': 1,
      'source': 'ai',
      'updated_at': 1700000000000,
    });
    await db.close();

    // ── Stage 2: reopen at v36 with inline migration ──
    final db2 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 36,
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 36) {
            await db.execute(
              'ALTER TABLE agent_skills ADD COLUMN last_used_at INTEGER',
            );
            await db.execute(
              'ALTER TABLE agent_skills ADD COLUMN hit_count INTEGER NOT NULL DEFAULT 0',
            );
          }
        },
      ),
    );

    // ── Stage 3: assertions ──
    final cols = await db2.rawQuery('PRAGMA table_info(agent_skills)');
    final colNames = cols.map((c) => c['name']).toList();
    expect(colNames, containsAll(['last_used_at', 'hit_count']));

    final row = (await db2.query('agent_skills', where: 'name = ?', whereArgs: ['nginx']))
        .single;
    expect(row['last_used_at'], isNull,
        reason: '存量行必须是 null，不能被 DEFAULT 顶成 0 —— 那会被读成'
            '"1970 年用过一次"');
    expect(row['hit_count'], equals(0));
    expect(row['body'], equals('existing body'));
    expect(row['updated_at'], equals(1700000000000));

    await db2.close();
  });
}
