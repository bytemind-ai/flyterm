// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:sqflite/sqflite.dart';
import 'aqt_file_state.dart';

class AqtFileRepo {
  final Database db;
  AqtFileRepo(this.db);

  Future<int> insert(AqtFileTransferState s) =>
      db.insert('aqt_file_transfer_state', s.toMap());

  Future<int> update(AqtFileTransferState s) => db.update(
        'aqt_file_transfer_state',
        s.toMap(),
        where: 'id = ?',
        whereArgs: [s.id],
      );

  Future<int> delete(int id) => db.delete(
        'aqt_file_transfer_state',
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<List<AqtFileTransferState>> findUnfinished(int serverId) async {
    final rows = await db.query(
      'aqt_file_transfer_state',
      where: 'server_id = ? AND status IN (?, ?, ?)',
      whereArgs: [
        serverId,
        AqtFileStatus.pending.index,
        AqtFileStatus.running.index,
        AqtFileStatus.paused.index,
      ],
      orderBy: 'updated_at DESC',
    );
    return rows.map(AqtFileTransferState.fromMap).toList();
  }

  Future<void> markBytesDone(int id, int bytesDone) => db.update(
        'aqt_file_transfer_state',
        {
          'bytes_done': bytesDone,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
}
