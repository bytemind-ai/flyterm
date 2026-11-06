// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import '../models/server.dart';

class ServerRepository {
  final Database _db;
  static const _table = 'servers';

  ServerRepository(this._db);

  Future<void> insert(Server server) => insertTxn(_db, server);

  /// 事务版插入。[txn] 通常是 `Database.transaction()` 回调里拿到的 `Transaction`。
  /// 2026-10-07 加：配置备份导入需要在单个事务里写多张表，逐表失败会留下半导入状态。
  Future<void> insertTxn(DatabaseExecutor txn, Server server) => txn.insert(
        _table,
        server.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<Server>> findAll() async {
    final rows = await _db.query(_table, orderBy: 'name ASC');
    return rows.map(Server.fromMap).toList();
  }

  Future<Server?> findById(String id) async {
    final rows =
        await _db.query(_table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Server.fromMap(rows.first);
  }

  Future<void> update(Server server) => _db.update(
        _table,
        server.toMap(),
        where: 'id = ?',
        whereArgs: [server.id],
      );

  /// 删掉一台服务器，连带它的 agent 笔记。
  ///
  /// **不靠 `ON DELETE CASCADE`** —— sqflite 默认不开 `foreign_keys` pragma，
  /// 声明了外键也不会真的级联，留下的是一份永远查不到归属的孤儿笔记。
  ///
  /// 事务包起来：两条删除之间崩溃会留下同样的孤儿。
  Future<void> delete(String id) => _db.transaction((txn) async {
        await txn.delete(_table, where: 'id = ?', whereArgs: [id]);
        await txn.delete('server_notes',
            where: 'server_id = ?', whereArgs: [id]);
      });

  Future<void> updateMoshPid(String serverId, int? pid) =>
      _db.update(_table, {'mosh_pid': pid},
          where: 'id = ?', whereArgs: [serverId]);

  Future<List<Server>> findWithMoshPid() async {
    final rows =
        await _db.query(_table, where: 'mosh_pid IS NOT NULL');
    return rows.map(Server.fromMap).toList();
  }
}
