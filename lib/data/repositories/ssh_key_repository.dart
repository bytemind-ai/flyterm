// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import '../models/ssh_key.dart';

class SSHKeyRepository {
  final Database _db;
  static const _table = 'ssh_keys';

  SSHKeyRepository(this._db);

  Future<void> insert(SSHKey key) => insertTxn(_db, key);

  /// 事务版插入。[txn] 通常是 `Database.transaction()` 回调里拿到的 `Transaction`。
  /// 2026-10-07 加：配置备份导入需要在单个事务里写多张表，逐表失败会留下半导入状态。
  Future<void> insertTxn(DatabaseExecutor txn, SSHKey key) => txn.insert(
        _table,
        key.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<SSHKey>> findAll() async {
    final rows = await _db.query(_table, orderBy: 'name ASC');
    return rows.map(SSHKey.fromMap).toList();
  }

  Future<SSHKey?> findById(String id) async {
    final rows =
        await _db.query(_table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : SSHKey.fromMap(rows.first);
  }

  Future<void> delete(String id) =>
      _db.delete(_table, where: 'id = ?', whereArgs: [id]);
}
