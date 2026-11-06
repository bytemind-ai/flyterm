import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ServerNotesRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = ServerNotesRepository(db);
  });

  tearDown(() async => db.close());

  test('bodyOf 未命中返回 null', () async {
    expect(await repo.bodyOf('nope'), isNull);
  });

  test('upsert 新建后能读回', () async {
    await repo.upsert(serverId: 's1', body: '这台用 podman');
    expect(await repo.bodyOf('s1'), '这台用 podman');
  });

  test('同一 serverId 再次 upsert 是覆盖，不新增行', () async {
    await repo.upsert(serverId: 's1', body: '第一版');
    await repo.upsert(serverId: 's1', body: '第二版');

    expect(await repo.bodyOf('s1'), '第二版');
    expect((await repo.all()).length, 1);
  });

  test('all 按 updatedAt 倒序', () async {
    // 用显式时间戳而不是 sleep 拉开间隔：排序断言不该依赖时钟。
    await repo.upsert(
        serverId: 'old', body: 'a',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1000));
    await repo.upsert(
        serverId: 'new', body: 'b',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000));

    final rows = await repo.all();
    expect(rows.map((n) => n.serverId).toList(), ['new', 'old']);
  });

  test('delete 删掉对应行', () async {
    await repo.upsert(serverId: 's1', body: 'a');
    await repo.delete('s1');
    expect(await repo.bodyOf('s1'), isNull);
  });

  test('upsert 可以指定 updatedAt —— 迁移要保住旧时间戳', () async {
    final past = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    await repo.upsert(serverId: 's1', body: 'a', updatedAt: past);

    expect((await repo.all()).single.updatedAt, past);
  });

  test('ServerNote 带回 serverId / body / updatedAt', () async {
    // 双边窗口。单边的 isBefore(now + 1s) 是恒真断言 —— 1970 年的时间戳
    // 也能通过，等于没测。
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await repo.upsert(serverId: 's1', body: 'a');
    final after = DateTime.now().add(const Duration(seconds: 1));

    final note = (await repo.all()).single;
    expect(note.serverId, 's1');
    expect(note.body, 'a');
    expect(note.updatedAt.isAfter(before), isTrue);
    expect(note.updatedAt.isBefore(after), isTrue);
  });

  test('删服务器会连带删掉它的笔记', () async {
    final servers = ServerRepository(db);
    await servers.insert(const Server(
      id: 's1',
      name: 'test-server',
      host: 'example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    ));
    await repo.upsert(serverId: 's1', body: '这台用 podman');

    await servers.delete('s1');

    expect(await repo.bodyOf('s1'), isNull);
  });
}
