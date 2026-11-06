// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import '../models/tunnel_config.dart';

class TunnelRepository {
  final Database _db;
  static const _table = 'tunnels';

  TunnelRepository(this._db);

  Future<void> insert(TunnelConfig config) => insertTxn(_db, config);

  /// 事务版插入。[txn] 通常是 `Database.transaction()` 回调里拿到的 `Transaction`。
  /// 2026-10-07 加：配置备份导入需要在单个事务里写多张表，逐表失败会留下半导入状态。
  Future<void> insertTxn(DatabaseExecutor txn, TunnelConfig config) =>
      txn.insert(
        _table,
        config.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<TunnelConfig>> findAll() async {
    final rows = await _db.query(_table, orderBy: 'rowid ASC');
    return rows.map(TunnelConfig.fromMap).toList();
  }

  Future<void> updateAutoStart(String id, bool autoStart) => _db.update(
        _table,
        {'auto_start': autoStart ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> delete(String id) =>
      _db.delete(_table, where: 'id = ?', whereArgs: [id]);
}
