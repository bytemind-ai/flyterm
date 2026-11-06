// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import '../models/mosh_process.dart';

class MoshProcessRepository {
  final Database _db;
  static const _table = 'mosh_processes';

  MoshProcessRepository(this._db);

  Future<void> upsert(MoshProcess process) => _db.insert(
    _table,
    process.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> upsertActive({
    required String id,
    required String serverId,
    required String tabId,
    required String tmuxKey,
    required int pid,
    required int udpPort,
    required String host,
    required int sshPort,
    required String username,
    required String portRange,
  }) {
    final now = DateTime.now();
    return upsert(
      MoshProcess(
        id: id,
        serverId: serverId,
        tabId: tabId,
        tmuxKey: tmuxKey,
        pid: pid,
        udpPort: udpPort,
        host: host,
        sshPort: sshPort,
        username: username,
        portRange: portRange,
        state: 'active',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<List<MoshProcess>> findAllActiveOrPending() async {
    final rows = await _db.query(
      _table,
      where: "state != 'killed'",
      orderBy: 'created_at ASC',
    );
    return rows.map(MoshProcess.fromMap).toList();
  }

  Future<List<MoshProcess>> findByTabId(String tabId) async {
    final rows = await _db.query(
      _table,
      where: "tab_id = ? AND state != 'killed'",
      whereArgs: [tabId],
      orderBy: 'created_at ASC',
    );
    return rows.map(MoshProcess.fromMap).toList();
  }

  Future<void> markPendingKillByTabId(String tabId) => _db.update(
    _table,
    {
      'state': 'pending_kill',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    },
    where: "tab_id = ? AND state != 'killed'",
    whereArgs: [tabId],
  );

  Future<void> markKilled(String id) => _db.update(
    _table,
    {'state': 'killed', 'updated_at': DateTime.now().millisecondsSinceEpoch},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> markKilledByTabId(String tabId) => _db.update(
    _table,
    {'state': 'killed', 'updated_at': DateTime.now().millisecondsSinceEpoch},
    where: "tab_id = ? AND state != 'killed'",
    whereArgs: [tabId],
  );

  Future<void> deleteKilled({Duration olderThan = const Duration(days: 7)}) {
    final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    return _db.delete(
      _table,
      where: "state = 'killed' AND updated_at < ?",
      whereArgs: [cutoff],
    );
  }
}
