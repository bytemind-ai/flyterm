import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/sftp_path_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SftpPathRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = SftpPathRepository(db);
  });

  tearDown(() async => db.close());

  test('记录访问后能读回来', () async {
    await repo.recordVisit(serverId: 's1', path: '/var/log');
    final recent = await repo.recent(serverId: 's1');
    expect(recent.map((e) => e.path), contains('/var/log'));
  });

  test('同一路径重复访问只留一条，且时间更新', () async {
    await repo.recordVisit(serverId: 's1', path: '/var/log');
    await repo.recordVisit(serverId: 's1', path: '/var/log');
    final recent = await repo.recent(serverId: 's1');
    expect(recent.where((e) => e.path == '/var/log').length, 1);
  });

  test('不同服务器互不可见', () async {
    await repo.recordVisit(serverId: 's1', path: '/a');
    await repo.recordVisit(serverId: 's2', path: '/b');
    expect((await repo.recent(serverId: 's1')).map((e) => e.path), ['/a']);
  });

  test('置顶后出现在 pinned 列表', () async {
    await repo.recordVisit(serverId: 's1', path: '/var/log');
    await repo.setPinned(serverId: 's1', path: '/var/log', pinned: true);
    expect((await repo.pinned(serverId: 's1')).map((e) => e.path),
        ['/var/log']);
  });

  test('自动淘汰：未置顶超过 30 条时删最旧', () async {
    for (var i = 0; i < 35; i++) {
      await repo.recordVisit(serverId: 's1', path: '/p$i');
    }
    final recent = await repo.recent(serverId: 's1');
    expect(recent.length, lessThanOrEqualTo(30));
  });

  test('置顶项不被自动淘汰', () async {
    await repo.recordVisit(serverId: 's1', path: '/keep');
    await repo.setPinned(serverId: 's1', path: '/keep', pinned: true);
    for (var i = 0; i < 35; i++) {
      await repo.recordVisit(serverId: 's1', path: '/p$i');
    }
    expect((await repo.recent(serverId: 's1')).map((e) => e.path),
        contains('/keep'));
  });

  test('删除单条', () async {
    await repo.recordVisit(serverId: 's1', path: '/gone');
    await repo.remove(serverId: 's1', path: '/gone');
    expect((await repo.recent(serverId: 's1')), isEmpty);
  });
}
