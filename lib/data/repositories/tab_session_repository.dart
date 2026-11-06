// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';

/// A single row from [tab_sessions], representing one open tab as it was
/// when the app last ran.
class TabSessionRecord {
  final String id;
  final String serverId;
  final String tmuxKey;
  final int position;
  final bool isActive;
  /// Last SFTP directory for this specific tab (null = use HOME on next open).
  final String? sftpLastPath;

  const TabSessionRecord({
    required this.id,
    required this.serverId,
    required this.tmuxKey,
    required this.position,
    required this.isActive,
    this.sftpLastPath,
  });

  factory TabSessionRecord.fromMap(Map<String, dynamic> m) => TabSessionRecord(
        id: m['id'] as String,
        serverId: m['server_id'] as String,
        tmuxKey: m['tmux_key'] as String,
        position: m['position'] as int,
        isActive: (m['is_active'] as int) == 1,
        sftpLastPath: m['sftp_last_path'] as String?,
      );
}

/// Persists the list of open tabs so they can be restored on the next app
/// launch — analogous to Chrome's "continue where you left off" feature.
///
/// [save] replaces all rows atomically. [SessionManager] calls it after every
/// tab open, close, or active-tab change.
class TabSessionRepository {
  final Database _db;
  TabSessionRepository(this._db);

  /// Replaces all persisted rows in one transaction.
  /// [rows] must contain maps with keys: id, server_id, tmux_key, position,
  /// is_active (0 or 1).
  Future<void> save(List<Map<String, dynamic>> rows) async {
    await _db.transaction((txn) async {
      await txn.delete('tab_sessions');
      for (final row in rows) {
        await txn.insert('tab_sessions', row);
      }
    });
  }

  /// Returns saved tabs ordered by [position] ascending.
  Future<List<TabSessionRecord>> load() async {
    final rows = await _db.query('tab_sessions', orderBy: 'position ASC');
    return rows.map(TabSessionRecord.fromMap).toList();
  }

  /// Removes all saved tab records (called when the last tab is closed).
  Future<void> clear() => _db.delete('tab_sessions');
}
