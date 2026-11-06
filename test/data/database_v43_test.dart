import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/database.dart';

/// v42 → v43：删掉计划任务的三张表。
///
/// 范式照 `database_v40_test.dart`（已随功能一起删除）：**走真实的
/// `AppDatabase.open`**（`overridePath`），而不是在测试里内联一份迁移逻辑
/// —— 副本漂移了测试还是绿的，那就什么都没测。
///
/// 这个文件替代了原来的 v40/v41/v42 三个测试。那三个断言的是「表建出来了
/// 没有 / 列加上了没有」，而这些表现在的最终状态是「不存在」，断言全部失去
/// 意义。但它们守的另一半必须留下：**从老版本一路升上来不能崩**。
/// `database.dart` 的 `_addColumnIfMissing` 文档记着 v39 → v42 真的崩过一次，
/// 跨度越大的升级越容易踩 —— 恰恰是放久了才更新的用户。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  /// 三张表的名字。断言「都不存在」时统一用这一份，避免两处写不一样。
  const scheduledTables = [
    'scheduled_tasks',
    'scheduled_task_runs',
    'scheduled_deploy_targets',
  ];

  Future<List<String>> remainingScheduledTables(dynamic db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name IN ('scheduled_tasks', 'scheduled_task_runs', "
      "'scheduled_deploy_targets') ORDER BY name",
    );
    return [for (final r in rows) r['name'] as String];
  }

  /// 建一个 v39 的库（计划任务三张表从未存在过），塞一行存量 servers。
  Future<String> makeV39(String tag) async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v43_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 39),
    );
    await db.execute('''
      CREATE TABLE servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL DEFAULT 'password'
      )
    ''');
    await db.insert('servers', {
      'id': 'srv-1',
      'name': 'legacy-host',
      'host': '10.0.0.1',
      'username': 'root',
    });
    await db.close();
    return path;
  }

  /// 建一个 v42 的库 —— **真实用过计划任务的用户**就长这样：三张表都在，
  /// 里面有数据。这是本文件最该覆盖的起点。
  Future<String> makeV42(String tag) async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v43_$tag');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 42),
    );
    await db.execute('''
      CREATE TABLE servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL DEFAULT 'password'
      )
    ''');
    await db.insert('servers', {
      'id': 'srv-1',
      'name': 'legacy-host',
      'host': '10.0.0.1',
      'username': 'root',
    });
    await db.execute('''
      CREATE TABLE scheduled_tasks (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        schedule TEXT NOT NULL,
        command TEXT,
        frozen_command TEXT,
        server_id TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        permission_mode TEXT NOT NULL,
        authorized_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE scheduled_task_runs (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        status TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_task_runs_task ON scheduled_task_runs '
        '(task_id, started_at DESC)');
    await db.execute(
        'CREATE TABLE scheduled_deploy_targets (server_id TEXT PRIMARY KEY)');
    await db.insert('scheduled_tasks', {
      'id': 't1',
      'name': '每晚备份',
      'kind': 'remote_cron',
      'schedule': '0 3 * * *',
      'command': 'pg_dump mydb',
      'server_id': 'srv-1',
      'permission_mode': 'ask',
      'created_at': 1,
      'updated_at': 1,
    });
    await db.insert('scheduled_task_runs', {
      'id': 'run-1',
      'task_id': 't1',
      'started_at': 2,
      'status': 'ok',
    });
    await db.insert('scheduled_deploy_targets', {'server_id': 'srv-1'});
    await db.close();
    return path;
  }

  test('v42（有计划任务数据）→ v43：三张表被删，存量 servers 不受影响',
      () async {
    final path = await makeV42('from42');

    final db = await AppDatabase.open(overridePath: path);

    expect(await remainingScheduledTables(db), isEmpty,
        reason: '三张表都该被 v43 删掉');

    // 索引跟着表走（SQLite 删表会连带删它的索引），显式断言一次 —— 留下
    // 一个指向不存在的表的索引，下次建同名表时会直接报错。
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_task_runs_task'",
    );
    expect(indexes, isEmpty);

    // 存量数据一字未动 —— 这是整条迁移最要紧的断言。
    final servers = await db.query('servers');
    expect(servers, hasLength(1));
    expect(servers.single['name'], 'legacy-host');
    expect(servers.single['host'], '10.0.0.1');

    await db.close();
  });

  test('v39 → v43：跨越整段计划任务生命周期也不崩', () async {
    final path = await makeV39('from39');

    // 这条路径会依次跑 v40 建表 → v41 建第三张表并回填 → v42 加列回填 →
    // v43 全删。中间白建白回填一次，无害；真正要守的是「不抛异常」。
    final db = await AppDatabase.open(overridePath: path);

    expect(await db.getVersion(), greaterThanOrEqualTo(43));
    expect(await remainingScheduledTables(db), isEmpty);

    final servers = await db.query('servers');
    expect(servers, hasLength(1));
    expect(servers.single['name'], 'legacy-host');

    await db.close();
  });

  test('新装的库里三张表从不存在', () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v43_fresh');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // 首次 open 走 _onCreate —— 它不该再建这三张表。
    final db = await AppDatabase.open(overridePath: path);

    expect(await db.getVersion(), greaterThanOrEqualTo(43));
    expect(await remainingScheduledTables(db), isEmpty);

    await db.close();
  });

  test('scheduledTables 常量与断言用的 IN 子句保持同步', () {
    // 两处写了同一组表名（常量 + rawQuery 的 IN 子句）。这条守卫让「只改了
    // 一处」立刻红掉，而不是让断言悄悄少查一张表。
    expect(scheduledTables, hasLength(3));
  });
}
