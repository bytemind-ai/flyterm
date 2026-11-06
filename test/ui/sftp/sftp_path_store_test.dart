import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/sftp_path_repository.dart';
import 'package:flyterm/ui/sftp/sftp_path_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `SftpPathStore` 是 repository 的薄 façade，唯一有独立逻辑的是 `suggest`
/// （前缀匹配 + 上限）。所以测试集中在 `suggest` 的语义上，其余方法只做
/// 转发，用一两条断言确认转发方向没写反。
void main() {
  late Database db;
  late SftpPathRepository repo;
  late SftpPathStore store;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = SftpPathRepository(db);
    store = SftpPathStore(repo: repo, serverId: 's1');
  });

  tearDown(() async => db.close());

  group('转发到 repository', () {
    test('recordVisit 后能在 recent 里读回来', () async {
      await store.recordVisit('/var/log');
      expect((await store.recent()).map((e) => e.path), contains('/var/log'));
    });

    test('serverId 是构造时绑定的，不同 server 互不可见', () async {
      await store.recordVisit('/mine');
      final other = SftpPathStore(repo: repo, serverId: 's2');
      await other.recordVisit('/theirs');
      expect((await store.recent()).map((e) => e.path), ['/mine']);
    });

    test('setPinned 后出现在 pinned 列表', () async {
      await store.recordVisit('/var/log');
      await store.setPinned('/var/log', true);
      expect((await store.pinned()).map((e) => e.path), ['/var/log']);
    });

    test('remove 后 recent 里消失', () async {
      await store.recordVisit('/gone');
      await store.remove('/gone');
      expect(await store.recent(), isEmpty);
    });
  });

  group('suggest', () {
    test('空前缀返回最近若干条', () async {
      await store.recordVisit('/a');
      await store.recordVisit('/b');
      expect(await store.suggest(''), containsAll(['/a', '/b']));
    });

    test('前缀匹配', () async {
      await store.recordVisit('/var/log');
      await store.recordVisit('/var/www');
      await store.recordVisit('/etc/nginx');
      expect(await store.suggest('/var'), ['/var/www', '/var/log']);
    });

    test('大小写不敏感', () async {
      await store.recordVisit('/Var/Log');
      expect(await store.suggest('/var'), ['/Var/Log']);
      expect(await store.suggest('/VAR'), ['/Var/Log']);
    });

    test('最多返回 8 条', () async {
      for (var i = 0; i < 12; i++) {
        await store.recordVisit('/dir/$i');
      }
      final result = await store.suggest('/dir');
      expect(result.length, 8);
    });

    test('建议里不含不匹配的路径', () async {
      await store.recordVisit('/var/log');
      await store.recordVisit('/etc/nginx');
      expect(await store.suggest('/var'), isNot(contains('/etc/nginx')));
    });
  });
}
