// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';

import '../models/server_note.dart';

/// `server_notes` 表的 CRUD。**纯 SQL，不含任何策略。**
///
/// 字节上限、内存缓存失效都在 `ServerNotesManager` 那一层 —— 绕过 Manager
/// 直接调这里就会同时跳过两者，所以 app 代码里除 Manager 外不该有第二个
/// 调用方。
///
/// 与 `AgentSkillRepository` 的区别：那边正文可能 8 KiB × N，必须把索引与
/// 正文分开读；这边一台机器只有一份、上限 4 KiB，[all] 直接把正文带回来，
/// Manager 全量缓存在内存里。
class ServerNotesRepository {
  final Database _db;

  ServerNotesRepository(this._db);

  /// 读全量，按 `updated_at` 倒序。总览列表和 Manager 的内存缓存都用它。
  ///
  /// 排序带 `server_id` 作 tie-break：同一毫秒内多条 `updated_at` 相同时，
  /// 不加这个会退化成 rowid 序 —— 其中一行再被 upsert 一次（哪怕内容不变）
  /// 就会插队到最前面，总览列表无理由跳动。
  Future<List<ServerNote>> all() => allTxn(_db);

  /// 事务版全量读取。[txn] 来自 `Database.transaction()` 回调。
  ///
  /// 排序与 [all] 完全一致 —— 两个入口必须给调用方同样的顺序，否则在事务
  /// 里导入备份与在事务外读总览会得到不同的列表。
  Future<List<ServerNote>> allTxn(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'server_notes',
      orderBy: 'updated_at DESC, server_id',
    );
    // 注意：`ServerNote` **没有** `fromMap` —— 反序列化是本文件的私有 static
    // `_fromRow`。直接复用即可（同文件可见）。
    return rows.map(_fromRow).toList();
  }

  /// 按 serverId 读正文。
  ///
  /// **null 与空串不是一回事**：null = 这台机器根本没有笔记行；空串 = 有行
  /// 但正文是空的（`upsert(body: '')` 会真的落一行）。这一层不做归一化 ——
  /// 把空正文折成「删除」是 `ServerNotesManager.replaceNote` 的职责，放在
  /// 这里会让「纯 SQL」这个定位名存实亡。
  ///
  /// 调用方若写 `if (body != null) prompt += body`，空串会往每轮 prompt 里
  /// 塞一个空段。走 Manager 就不会遇到这个问题。
  Future<String?> bodyOf(String serverId) async {
    final rows = await _db.query(
      'server_notes',
      columns: ['body'],
      where: 'server_id = ?',
      whereArgs: [serverId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['body'] as String;
  }

  /// 插入或更新。`server_id` 是主键，一台机器只有一份。
  ///
  /// [updatedAt] 只给迁移用 —— 搬旧缓存时要保住它原来的同步时间，而不是
  /// 让所有机器的笔记都显示「刚刚更新」。正常写入不传。
  ///
  /// ## 为什么不用 `ConflictAlgorithm.replace`
  ///
  /// replace 的语义是「删旧行再插新行」：将来给这张表加一列（置顶、来源、
  /// 同步状态都是候选），这个方法没传那一列，replace 就会把它**静默重置成
  /// DEFAULT**，顺带让 rowid 跳变。而那时的改动在别的文件里，没人会回头
  /// 看这一行。`ON CONFLICT DO UPDATE` 只动传进来的列，加列时不需要记得
  /// 回来改这里。
  Future<void> upsert({
    required String serverId,
    required String body,
    DateTime? updatedAt,
  }) =>
      upsertTxn(_db, serverId: serverId, body: body, updatedAt: updatedAt);

  /// 事务版 upsert。语义与 [upsert] 完全一致（ON CONFLICT 更新）。
  Future<void> upsertTxn(
    DatabaseExecutor txn, {
    required String serverId,
    required String body,
    DateTime? updatedAt,
  }) =>
      txn.rawInsert(
        'INSERT INTO server_notes(server_id, body, updated_at) '
        'VALUES(?, ?, ?) '
        'ON CONFLICT(server_id) DO UPDATE SET '
        'body = excluded.body, updated_at = excluded.updated_at',
        [
          serverId,
          body,
          (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
        ],
      );

  Future<void> delete(String serverId) =>
      _db.delete('server_notes', where: 'server_id = ?', whereArgs: [serverId]);

  static ServerNote _fromRow(Map<String, Object?> r) => ServerNote(
        serverId: r['server_id'] as String,
        body: r['body'] as String,
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );
}
