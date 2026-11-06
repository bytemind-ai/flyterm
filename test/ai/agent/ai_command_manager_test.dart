import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/ai_command_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late FavoriteCommandRepository repo;
  late AiCommandManager mgr;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = FavoriteCommandRepository(db);
    mgr = AiCommandManager(repo);
    await mgr.reload();
  });

  tearDown(() async => db.close());

  Future<void> add(String name, String command,
      {bool ai = true, int order = 0}) async {
    await repo.insert(FavoriteCommand(
      id: name,
      name: name,
      command: command,
      sortOrder: order,
      aiEnabled: ai,
    ));
    await mgr.reload();
  }

  test('初始为空', () {
    expect(mgr.indexEntries, isEmpty);
    expect(mgr.names, isEmpty);
    expect(mgr.byName('x'), isNull);
  });

  test('只有 aiEnabled 的进索引', () async {
    await add('开放', 'ls', ai: true, order: 0);
    await add('不开放', 'ps', ai: false, order: 1);
    expect(mgr.names, equals(['开放']));
  });

  test('byName 是同步的 —— _resolve 就是这样用它的', () async {
    await add('部署', 'deploy {{s}}');
    expect(mgr.byName('部署')!.command, equals('deploy {{s}}'));
  });

  test('byName 大小写不敏感', () async {
    await add('Deploy-API', 'ls');
    expect(mgr.byName('deploy-api'), isNotNull);
  });

  test('未勾选的 byName 返回 null —— 不能绕过开关', () async {
    await add('私密', 'rm -rf /tmp/x', ai: false);
    expect(mgr.byName('私密'), isNull);
  });

  test('按 sortOrder 排序，取前 kMaxIndexedCommands 条', () async {
    for (var i = 0; i <= kMaxIndexedCommands; i++) {
      await add('c$i', 'ls', order: i);
    }
    expect(mgr.indexEntries, hasLength(kMaxIndexedCommands));
    expect(mgr.overflowCount, equals(1));
    expect(mgr.names, isNot(contains('c$kMaxIndexedCommands')));
  });

  test('被挤出索引的不能调用 —— 否则上限形同虚设', () async {
    for (var i = 0; i <= kMaxIndexedCommands; i++) {
      await add('c$i', 'ls', order: i);
    }
    expect(mgr.byName('c$kMaxIndexedCommands'), isNull);
  });

  test('reload 会通知监听者', () async {
    var n = 0;
    mgr.addListener(() => n++);
    await add('x', 'ls');
    expect(n, greaterThan(0));
  });

  test('indexTokenEstimate 随条数增长', () async {
    final before = mgr.indexTokenEstimate;
    await add('部署服务', 'deploy-cli deploy --service {{s}}');
    expect(mgr.indexTokenEstimate, greaterThan(before));
  });

  test('取消勾选之后索引同步变空', () async {
    const cmd =
        FavoriteCommand(id: 'x', name: 'x', command: 'ls', aiEnabled: true);
    await repo.insert(cmd);
    await mgr.reload();
    expect(mgr.indexEntries, isNotEmpty);

    await repo.update(cmd.copyWith(aiEnabled: false));
    await mgr.reload();
    expect(mgr.indexEntries, isEmpty);
  });
}
