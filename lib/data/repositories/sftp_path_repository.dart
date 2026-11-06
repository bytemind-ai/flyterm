// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';

import '../models/sftp_path.dart';

/// 目录历史 / 书签的 CRUD。
///
/// **历史是自动记录的**（每次 listDirectory 成功 upsert 一条），这是选「历史
/// + 置顶」而非「纯书签」的核心理由：用户不会主动收藏，但一定会重新访问
/// `/var/log`。零操作成本换来大部分价值。
class SftpPathRepository {
  final Database _db;

  SftpPathRepository(this._db);

  /// 未置顶项的保留上限。
  static const maxUnpinned = 30;

  /// 记录一次访问（upsert + 淘汰）。
  Future<void> recordVisit({
    required String serverId,
    required String path,
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    await _db.insert(
      'sftp_paths',
      {
        'server_id': serverId,
        'path': path,
        'last_used_at': now.millisecondsSinceEpoch,
        'pinned': 0,
      },
      // 重复访问只更新时间，**不动 pinned** —— 否则一次浏览就把用户的置顶
      // 取消了。
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await _db.update(
      'sftp_paths',
      {'last_used_at': now.millisecondsSinceEpoch},
      where: 'server_id = ? AND path = ?',
      whereArgs: [serverId, path],
    );
    await _evict(serverId);
  }

  /// 自动淘汰未置顶项：只保留最近 [maxUnpinned] 条。
  ///
  /// `NOT IN` 子查询里**必须**带 `pinned = 0` —— 否则置顶项会被算进 30 条
  /// 的配额，把普通历史挤掉；外层同样要 `pinned = 0`，置顶项永不删除。
  Future<void> _evict(String serverId) async {
    await _db.rawDelete(
      '''
      DELETE FROM sftp_paths
      WHERE server_id = ? AND pinned = 0 AND path NOT IN (
        SELECT path FROM sftp_paths
        WHERE server_id = ? AND pinned = 0
        ORDER BY last_used_at DESC
        LIMIT ?
      )
      ''',
      [serverId, serverId, maxUnpinned],
    );
  }

  /// 当前服务器的目录历史，最近访问在前。
  ///
  /// [limit] 缺省为 null（不限）—— 淘汰已经把未置顶项钉在 [maxUnpinned]，
  /// 再叠一层 limit 只会让「置顶项排在很后面」时从结果里消失（置顶项不计入
  /// 配额，总行数可以是 maxUnpinned + 置顶数）。
  Future<List<SftpPath>> recent({
    required String serverId,
    int? limit,
  }) async {
    final rows = await _db.query(
      'sftp_paths',
      where: 'server_id = ?',
      whereArgs: [serverId],
      orderBy: 'last_used_at DESC',
      limit: limit,
    );
    return rows.map(SftpPath.fromMap).toList();
  }

  Future<List<SftpPath>> pinned({required String serverId}) async {
    final rows = await _db.query(
      'sftp_paths',
      where: 'server_id = ? AND pinned = 1',
      whereArgs: [serverId],
      orderBy: 'path ASC',
    );
    return rows.map(SftpPath.fromMap).toList();
  }

  Future<void> setPinned({
    required String serverId,
    required String path,
    required bool pinned,
  }) async {
    await _db.update(
      'sftp_paths',
      {'pinned': pinned ? 1 : 0},
      where: 'server_id = ? AND path = ?',
      whereArgs: [serverId, path],
    );
  }

  Future<void> remove({required String serverId, required String path}) async {
    await _db.delete(
      'sftp_paths',
      where: 'server_id = ? AND path = ?',
      whereArgs: [serverId, path],
    );
  }
}
