import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/ai/agent/skill.dart';

/// v37 → v38：新建 `agent_skill_assets` 表。
///
/// 与同目录其它 `database_vNN_test.dart` 不同，这条**走真实的
/// `AppDatabase.open`**（而不是在测试里内联一份迁移逻辑）。早先那些测试
/// 内联是因为 `AppDatabase.open` 不接受路径；现在它接受 `overridePath`
/// （见该方法的文档注释），就没有理由再测一份副本 —— 副本漂移了测试还是绿的。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v37 → v38 建出 agent_skill_assets 表，且存量技能不受影响', () async {
    final dir = await Directory.systemTemp.createTemp('flyterm_db_v38');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // ── Stage 1: 手动建出 v37 的 agent_skills 表（无附件表） ──
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 37),
    );
    await db.execute('''
      CREATE TABLE agent_skills (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        description TEXT NOT NULL,
        body        TEXT NOT NULL,
        enabled     INTEGER NOT NULL DEFAULT 1,
        source      TEXT NOT NULL,
        updated_at  INTEGER NOT NULL,
        last_used_at INTEGER,
        hit_count   INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.insert('agent_skills', {
      'name': 'legacy',
      'description': 'd',
      'body': 'b',
      'enabled': 1,
      'source': 'ai',
      'updated_at': 1,
      'hit_count': 3,
    });
    await db.close();

    // ── Stage 2: 用生产路径重开（会跑 _onUpgrade） ──
    final db2 = await AppDatabase.open(overridePath: path);

    // 表建出来了。
    final tables = await db2.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='agent_skill_assets'",
    );
    expect(tables, hasLength(1));

    // 存量技能一字未动（附件是可选的，没有迁移动作）。
    final repo = AgentSkillRepository(db2);
    final legacy = (await repo.all()).single;
    expect(legacy.name, equals('legacy'));
    expect(legacy.body, equals('b'));
    expect(legacy.hitCount, equals(3));
    expect(legacy.assetCount, equals(0));
    expect(await repo.assetsOf('legacy'), isEmpty);

    // 新表能正常写读。
    await repo.upsert(
        name: 'new',
        description: 'd',
        body: 'b',
        source: SkillSource.ai,
        assets: const [
          AgentSkillAsset(path: 's.sh', content: 'echo', executable: true),
        ]);
    expect((await repo.assetsOf('new')).single.executable, isTrue);

    await db2.close();
  });
}
