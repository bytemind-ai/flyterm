import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ssh/aqt/file_transfer/aqt_file_repo.dart';
import 'package:flyterm/ssh/aqt/file_transfer/aqt_file_state.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AqtFileRepo repo;

  setUp(() async {
    db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE aqt_file_transfer_state (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server_id INTEGER, request_id INTEGER, mode INTEGER,
            local_path TEXT, remote_path TEXT,
            total_size INTEGER, bytes_done INTEGER,
            sha256_full BLOB, status INTEGER, updated_at INTEGER
          )
        ''');
      },
    );
    repo = AqtFileRepo(db);
  });

  tearDown(() => db.close());

  test('insert + findUnfinished', () async {
    final s = AqtFileTransferState(
      serverId: 1,
      requestId: 42,
      mode: AqtFileMode.upload,
      localPath: '/tmp/foo',
      remotePath: '~/foo',
      totalSize: 1024,
      bytesDone: 256,
      sha256Full: Uint8List(32),
      status: AqtFileStatus.running,
      updatedAt: DateTime.now(),
    );
    await repo.insert(s);
    final found = await repo.findUnfinished(1);
    expect(found, hasLength(1));
    expect(found.first.bytesDone, 256);
  });

  test('completed not returned by findUnfinished', () async {
    final s = AqtFileTransferState(
      serverId: 1,
      requestId: 1,
      mode: AqtFileMode.upload,
      localPath: '/tmp',
      remotePath: '/tmp',
      totalSize: 100,
      bytesDone: 100,
      sha256Full: Uint8List(32),
      status: AqtFileStatus.completed,
      updatedAt: DateTime.now(),
    );
    await repo.insert(s);
    expect(await repo.findUnfinished(1), isEmpty);
  });

  test('markBytesDone updates bytes', () async {
    final s = AqtFileTransferState(
      serverId: 1,
      requestId: 99,
      mode: AqtFileMode.download,
      localPath: '/tmp/dl',
      remotePath: '~/dl',
      totalSize: 4096,
      bytesDone: 0,
      sha256Full: Uint8List(32),
      status: AqtFileStatus.running,
      updatedAt: DateTime.now(),
    );
    final id = await repo.insert(s);
    await repo.markBytesDone(id, 2048);
    final found = await repo.findUnfinished(1);
    expect(found.first.bytesDone, 2048);
  });
}
