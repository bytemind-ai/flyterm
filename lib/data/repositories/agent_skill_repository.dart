// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';

import '../../ai/agent/skill.dart';

/// `agent_skills` 表的 CRUD。
///
/// 正文（`body`）只在 [bodyOf] 里按 name 精确查 —— 它可能有 8 KiB × N，而
/// 索引每轮都要生成一次。把两者分开是整个存储设计的前提，见 [all] 的说明。
class AgentSkillRepository {
  final Database _db;

  AgentSkillRepository(this._db);

  /// 读全量，**按 `updatedAt` 倒序**。
  ///
  /// 顺序不是装饰：索引超过 `kMaxIndexedSkills` 时取前 N 条，靠的就是这个
  /// 排序 —— 最近建的 / 最近改的是用户当下在用的那些。
  ///
  /// 这里确实把 `body` 一起读了出来，因为 `AgentSkillManager` 只在初始化和
  /// 每次增删改后调它；每轮生成索引读的是它缓存下来的 `SkillIndexEntry`，
  /// 不碰数据库。
  Future<List<AgentSkill>> all() => allTxn(_db);

  /// 事务版全量读取。
  ///
  /// 排序与 [all] 完全一致：索引截断取前 N 条依赖它，事务内外必须同序。
  ///
  /// ## 为什么带一个附件数量子查询
  ///
  /// 列表页要显示「N assets」徒标，而**不能**对每一行再查一次附件
  /// （N+1）。子查询返回的只是一个计数，不会把正文拉进来 —— 这里读的是
  /// 列表数据，附件正文不是列表的一部分。
  ///
  /// 子查询而不是 `LEFT JOIN + GROUP BY`：后者要列出 `agent_skills.*` 的
  /// 每一列，加列时容易漏，而漏掉的列会静默变成 null。
  Future<List<AgentSkill>> allTxn(DatabaseExecutor txn) async {
    final rows = await txn.rawQuery(
      'SELECT s.*, '
      '(SELECT COUNT(*) FROM agent_skill_assets a WHERE a.skill_id = s.id) '
      'AS asset_count '
      'FROM agent_skills s ORDER BY s.updated_at DESC',
    );
    // `AgentSkill` 没有 `fromMap` —— 用本文件的私有 static `_fromRow`。
    return rows.map(_fromRow).toList();
  }

  /// 按 name 读正文。返回 null 表示不存在**或已被禁用** —— 对调用方是同一
  /// 件事：拿不到。禁用了却还能 load，那个开关就没有意义。
  Future<String?> bodyOf(String name) async {
    final rows = await _db.query(
      'agent_skills',
      columns: ['body'],
      where: 'name = ? COLLATE NOCASE AND enabled = 1',
      whereArgs: [name.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['body'] as String;
  }

  /// 按 name 读附件，按 `position` 升序。
  ///
  /// **不查 enabled**：调用方（`load_skill` / 详情页）已经先通过了正文那关，
  /// 拿得到的技能就是启用的。多查一次会让 `install_skill_assets` 与
  /// `load_skill` 对“同一技能能不能用”出现两套答案。
  ///
  /// 技能不存在或无附件都返回空列表 —— 对调用方是同一件事。
  Future<List<AgentSkillAsset>> assetsOf(String name) =>
      assetsOfTxn(_db, name);

  /// 按 name 读附件（事务版）。语义与 [assetsOf] 一致。
  Future<List<AgentSkillAsset>> assetsOfTxn(
      DatabaseExecutor txn, String name) async {
    final rows = await txn.rawQuery(
      'SELECT a.path, a.content, a.executable FROM agent_skill_assets a '
      'JOIN agent_skills s ON s.id = a.skill_id '
      'WHERE s.name = ? COLLATE NOCASE '
      'ORDER BY a.position ASC, a.id ASC',
      [name.trim()],
    );
    return rows
        .map((r) => AgentSkillAsset(
              path: r['path'] as String,
              content: r['content'] as String,
              executable: (r['executable'] as int) == 1,
            ))
        .toList();
  }

  /// 按 name 插入或更新。撞名时更新，不新增第二行。
  Future<void> upsert({
    required String name,
    required String description,
    required String body,
    required SkillSource source,
    List<AgentSkillAsset>? assets,
  }) =>
      upsertTxn(_db,
          name: name,
          description: description,
          body: body,
          source: source,
          assets: assets);

  /// 事务版 upsert。语义与 [upsert] 一致：同名（COLLATE NOCASE）则更新，否则插入。
  /// **不写 enabled** —— 沿用现有语义（新行默认 1，已有行不碰 enabled）。
  ///
  /// [assets] 为 null 时**不动**附件；非 null（含空列表）时**整组替换**。
  /// 这个区分是刻意的：老调用点（不带附件）不该把附件清掉，而“这条技能
  /// 现在没有附件了”必须表达得出来。
  Future<void> upsertTxn(
    DatabaseExecutor txn, {
    required String name,
    required String description,
    required String body,
    required SkillSource source,
    List<AgentSkillAsset>? assets,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await txn.query(
      'agent_skills',
      columns: ['id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: [name.trim()],
      limit: 1,
    );
    final values = {
      'name': name.trim(),
      'description': description.trim(),
      'body': body,
      'source': source.name,
      'updated_at': now,
    };
    final int skillId;
    if (existing.isEmpty) {
      skillId = await txn.insert('agent_skills', {...values, 'enabled': 1});
    } else {
      skillId = existing.first['id'] as int;
      await txn.update('agent_skills', values,
          where: 'id = ?', whereArgs: [skillId]);
    }
    if (assets != null) {
      await _replaceAssetsTxn(txn, skillId, assets);
    }
  }

  /// 整组替换某技能的附件。
  ///
  /// 先删后插而不是逐条 upsert：附件的语义是“这条技能现在带哪几个文件”，
  /// 一组就是全部。逐条合并的话，删掉一个附件需要另一条 API，而两条 API
  /// 终究要同时正确。
  ///
  /// **重名 path 后者胜**（而不是抛 `UNIQUE` 约束错）：上游是模型给的数组，
  /// 重复一个 path 是它会犯的错，而一次约束异常会把整次 `save_skill` 变成
  /// 一个看不懂的数据库错误。去重后 position 重新紧凑编号，与入库后的
  /// 读回顺序一致。
  Future<void> _replaceAssetsTxn(
    DatabaseExecutor txn,
    int skillId,
    List<AgentSkillAsset> assets,
  ) async {
    await txn.delete('agent_skill_assets',
        where: 'skill_id = ?', whereArgs: [skillId]);
    final deduped = <String, AgentSkillAsset>{};
    for (final a in assets) {
      deduped[a.path] = a;
    }
    var position = 0;
    for (final a in deduped.values) {
      await txn.insert('agent_skill_assets', {
        'skill_id': skillId,
        'path': a.path,
        'content': a.content,
        'executable': a.executable ? 1 : 0,
        'position': position++,
      });
    }
  }

  /// 改描述 / 正文 / 附件。
  ///
  /// [assets] 为 null 时**不动**附件；非 null（含空列表）时整组替换——与
  /// [upsert] 同一套语义，理由也一样：旧调用点不该把附件清掉，而“现在
  /// 没有附件了”要表达得出来。
  Future<void> updateFields(int id,
      {String? description, String? body, List<AgentSkillAsset>? assets}) async {
    await _db.transaction((txn) async {
      await txn.update(
        'agent_skills',
        {
          if (description != null) 'description': description.trim(),
          if (body != null) 'body': body,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (assets != null) {
        await _replaceAssetsTxn(txn, id, assets);
      }
    });
  }

  /// 记一次成功的 `load_skill`。
  ///
  /// **只写使用信号，不碰 `updated_at`** —— 理由见 `AgentSkill.lastUsedAt`。
  ///
  /// 匹配用 `COLLATE NOCASE`，与 [bodyOf] 和唯一索引同一套折叠规则；不一致
  /// 的话 `load_skill` 取到了正文而这里记不上账。
  Future<void> markUsed(String name) async {
    await _db.rawUpdate(
      'UPDATE agent_skills SET hit_count = hit_count + 1, last_used_at = ? '
      'WHERE name = ? COLLATE NOCASE',
      [DateTime.now().millisecondsSinceEpoch, name.trim()],
    );
  }

  Future<void> setEnabled(int id, bool enabled) => _db.update(
        'agent_skills',
        {'enabled': enabled ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> delete(int id) async {
    await _db.transaction((txn) async {
      await txn.delete('agent_skill_assets',
          where: 'skill_id = ?', whereArgs: [id]);
      await txn.delete('agent_skills', where: 'id = ?', whereArgs: [id]);
    });
  }

  static AgentSkill _fromRow(Map<String, Object?> r) => AgentSkill(
        id: r['id'] as int,
        name: r['name'] as String,
        description: r['description'] as String,
        body: r['body'] as String,
        enabled: (r['enabled'] as int) == 1,
        // 未知值折回 file：这个字段只驱动一个 UI 徽标，为它抛异常会让
        // 整个技能列表打不开。
        source: SkillSource.values.firstWhere(
          (s) => s.name == r['source'],
          orElse: () => SkillSource.file,
        ),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        lastUsedAt: r['last_used_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_used_at'] as int),
        hitCount: (r['hit_count'] as int?) ?? 0,
        // `all()` 的 rawQuery 会带上这一列；`assetsOf` 等其它路径不经
        // `_fromRow`，所以缺列时只能是 0。
        assetCount: (r['asset_count'] as int?) ?? 0,
      );
}
