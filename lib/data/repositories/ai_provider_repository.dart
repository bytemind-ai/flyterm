// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import '../models/ai_provider_config.dart';

class AIProviderRepository {
  final Database _db;

  AIProviderRepository(this._db);

  Future<void> insert(AIProviderConfig config) => insertTxn(_db, config);

  /// 事务版插入。[txn] 通常是 `Database.transaction()` 回调里拿到的 `Transaction`。
  /// 2026-10-07 加：配置备份导入需要在单个事务里写多张表，逐表失败会留下半导入状态。
  Future<void> insertTxn(DatabaseExecutor txn, AIProviderConfig config) async {
    if (config.isDefault) await _clearDefault(txn);
    await txn.insert('ai_providers', config.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<AIProviderConfig>> findAll() async {
    final rows = await _db.query('ai_providers');
    return rows.map(AIProviderConfig.fromMap).toList();
  }

  Future<AIProviderConfig?> findDefault() async {
    final rows = await _db.query(
        'ai_providers', where: 'is_default = 1', limit: 1);
    return rows.isEmpty ? null : AIProviderConfig.fromMap(rows.first);
  }

  Future<void> update(AIProviderConfig config) async {
    if (config.isDefault) await _clearDefault();
    await _db.update('ai_providers', config.toMap(),
        where: 'id = ?', whereArgs: [config.id]);
  }

  Future<void> delete(String id) =>
      _db.delete('ai_providers', where: 'id = ?', whereArgs: [id]);

  Future<void> _clearDefault([DatabaseExecutor? executor]) =>
      (executor ?? _db).update('ai_providers', {'is_default': 0});
}
