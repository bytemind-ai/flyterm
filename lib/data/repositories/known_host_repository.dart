// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';

import '../models/known_host.dart';

/// CRUD over the `known_hosts` table. Lookup keys are
/// (host, port, key_type) — same composite the table uses as PRIMARY KEY.
class KnownHostRepository {
  final Database db;
  KnownHostRepository(this.db);

  /// Returns the row for this triple, or null if no record exists yet
  /// (TOFU situation — caller should prompt the user).
  Future<KnownHost?> find({
    required String host,
    required int port,
    required String keyType,
  }) async {
    final rows = await db.query(
      'known_hosts',
      where: 'host = ? AND port = ? AND key_type = ?',
      whereArgs: [host, port, keyType],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return KnownHost.fromMap(rows.first);
  }

  /// Insert a new (host, port, key_type) record. Use [save] (upsert)
  /// when overwriting after a user-confirmed key change.
  Future<void> insert(KnownHost h) => insertTxn(db, h);

  /// 事务版插入。[txn] 通常是 `Database.transaction()` 回调里拿到的 `Transaction`。
  /// 2026-10-07 加：配置备份导入需要在单个事务里写多张表，逐表失败会留下半导入状态。
  /// 保留 [insert] 原有的 `ConflictAlgorithm.abort` 语义 —— 不静默覆盖已有记录。
  Future<void> insertTxn(DatabaseExecutor txn, KnownHost h) => txn.insert(
        'known_hosts',
        h.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

  /// Upsert — replaces the existing row if one exists for the same
  /// (host, port, key_type). Use after the user explicitly accepts a
  /// host-key change.
  Future<void> save(KnownHost h) => saveTxn(db, h);

  /// 事务版 upsert，语义同 [save]（`ConflictAlgorithm.replace`）。
  Future<void> saveTxn(DatabaseExecutor txn, KnownHost h) => txn.insert(
        'known_hosts',
        h.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Bump `last_seen` to now without touching the fingerprint or
  /// `first_seen`. Called on every successful verification so the
  /// management screen can sort by recency.
  Future<void> touch({
    required String host,
    required int port,
    required String keyType,
  }) async {
    await db.update(
      'known_hosts',
      {'last_seen': DateTime.now().millisecondsSinceEpoch},
      where: 'host = ? AND port = ? AND key_type = ?',
      whereArgs: [host, port, keyType],
    );
  }

  Future<void> delete({
    required String host,
    required int port,
    required String keyType,
  }) async {
    await db.delete(
      'known_hosts',
      where: 'host = ? AND port = ? AND key_type = ?',
      whereArgs: [host, port, keyType],
    );
  }

  Future<List<KnownHost>> findAll() async {
    final rows = await db.query('known_hosts', orderBy: 'last_seen DESC');
    return rows.map(KnownHost.fromMap).toList();
  }
}
