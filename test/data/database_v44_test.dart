import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/database.dart';

/// v43 → v44：servers 加 aqt_ports 列（AQT daemon 的 UDP 端口段）。
///
/// 走真实的 `AppDatabase.open`（`overridePath`），不在测试里内联迁移逻辑 ——
/// 范式同 `database_v43_test.dart`。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Future<List<String>> serverColumns(Database db) async => [
        for (final c in await db.rawQuery('PRAGMA table_info(servers)'))
          c['name'] as String,
      ];

  test('v43 → v44：加 aqt_ports 列，存量服务器为 null（使用默认范围）', () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v44');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 43),
    );
    await old.execute('''
      CREATE TABLE servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL DEFAULT 'password'
      )
    ''');
    await old.insert('servers', {
      'id': 'srv-1',
      'name': 'legacy-host',
      'host': '10.0.0.1',
      'username': 'root',
    });
    await old.close();

    final db = await AppDatabase.open(overridePath: path);
    addTearDown(db.close);
    expect(await db.getVersion(), greaterThanOrEqualTo(44));
    expect(await serverColumns(db), contains('aqt_ports'));
    final rows = await db.query('servers');
    expect(rows.single['name'], 'legacy-host');
    expect(rows.single['aqt_ports'], isNull);
  });

  test('全新安装的库直接带 aqt_ports 列', () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v44_new');
    addTearDown(() => dir.delete(recursive: true));
    final db =
        await AppDatabase.open(overridePath: p.join(dir.path, 'fresh.db'));
    addTearDown(db.close);
    expect(await serverColumns(db), contains('aqt_ports'));
  });
}
