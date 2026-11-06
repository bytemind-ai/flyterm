import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSkillRepository repo;

  // 每个测试自己开一份内存库、tearDown 关掉 —— 共享实例会让状态在测试
  // 之间泄漏（见 CLAUDE.md 的测试约定）。
  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = AgentSkillRepository(db);
  });

  tearDown(() async => db.close());

  test('插入后能按 name 读回正文', () async {
    await repo.upsert(
      name: 'nginx',
      description: '排查 502',
      body: '正文内容',
      source: SkillSource.ai,
    );
    expect(await repo.bodyOf('nginx'), equals('正文内容'));
  });

  test('同名 upsert 是更新不是新增', () async {
    await repo.upsert(
        name: 'x', description: 'v1', body: 'b1', source: SkillSource.ai);
    await repo.upsert(
        name: 'x', description: 'v2', body: 'b2', source: SkillSource.file);
    final all = await repo.all();
    expect(all, hasLength(1));
    expect(all.single.description, equals('v2'));
    expect(all.single.body, equals('b2'));
  });

  test('all() 按 updatedAt 倒序 —— 索引取前 N 条靠这个顺序', () async {
    await repo.upsert(
        name: 'old', description: 'd', body: 'b', source: SkillSource.ai);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.upsert(
        name: 'new', description: 'd', body: 'b', source: SkillSource.ai);
    final all = await repo.all();
    expect(all.first.name, equals('new'));
  });

  test('禁用之后 bodyOf 返回 null —— 关掉就是彻底拿不到', () async {
    await repo.upsert(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    final row = (await repo.all()).single;
    await repo.setEnabled(row.id, false);
    expect(await repo.bodyOf('x'), isNull);
  });

  test('删除后读不到', () async {
    await repo.upsert(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    await repo.delete((await repo.all()).single.id);
    expect(await repo.all(), isEmpty);
  });

  test('bodyOf 大小写不敏感 —— 模型复述 name 时会改大小写', () async {
    await repo.upsert(
        name: 'Nginx-Check', description: 'd', body: 'B', source: SkillSource.ai);
    expect(await repo.bodyOf('nginx-check'), equals('B'));
  });
}
