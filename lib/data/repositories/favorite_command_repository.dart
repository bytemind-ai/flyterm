// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import '../models/favorite_command.dart';

class FavoriteCommandRepository {
  final Database _db;
  FavoriteCommandRepository(this._db);

  Future<List<FavoriteCommand>> findAll() async {
    final rows = await _db.query('favorite_commands', orderBy: 'sort_order ASC, rowid ASC');
    return rows.map(FavoriteCommand.fromMap).toList();
  }

  Future<void> insert(FavoriteCommand cmd) => insertTxn(_db, cmd);

  /// 事务版插入。[txn] 通常是 `Database.transaction()` 回调里拿到的 `Transaction`。
  /// 2026-10-07 加：配置备份导入需要在单个事务里写多张表，逐表失败会留下半导入状态。
  Future<void> insertTxn(DatabaseExecutor txn, FavoriteCommand cmd) =>
      txn.insert('favorite_commands', cmd.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> delete(String id) =>
      _db.delete('favorite_commands', where: 'id = ?', whereArgs: [id]);

  Future<void> update(FavoriteCommand cmd) =>
      _db.update('favorite_commands', cmd.toMap(),
          where: 'id = ?', whereArgs: [cmd.id]);

  /// Batch-update sort_order to match the given list order.
  Future<void> updateOrders(List<FavoriteCommand> commands) async {
    final batch = _db.batch();
    for (var i = 0; i < commands.length; i++) {
      batch.update(
        'favorite_commands',
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [commands[i].id],
      );
    }
    await batch.commit(noResult: true);
  }
}
