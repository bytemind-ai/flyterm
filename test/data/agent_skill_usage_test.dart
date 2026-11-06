import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/ai/agent/skill.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSkillRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = AgentSkillRepository(db);
  });

  tearDown(() async => db.close());

  test('新存入的 skill lastUsedAt 为 null、hitCount 为 0', () async {
    await repo.upsert(
        name: 'nginx', description: 'd', body: 'b', source: SkillSource.ai);
    final skill = (await repo.all()).single;
    expect(skill.lastUsedAt, isNull);
    expect(skill.hitCount, equals(0));
  });

  test('markUsed 累加 hitCount 并写 lastUsedAt', () async {
    await repo.upsert(
        name: 'nginx', description: 'd', body: 'b', source: SkillSource.ai);
    await repo.markUsed('nginx');
    await repo.markUsed('nginx');
    final skill = (await repo.all()).single;
    expect(skill.hitCount, equals(2));
    expect(skill.lastUsedAt, isNotNull);
  });

  test('markUsed 绝不改 updatedAt', () async {
    await repo.upsert(
        name: 'nginx', description: 'd', body: 'b', source: SkillSource.ai);
    final before = (await repo.all()).single.updatedAt;
    // 让墙钟往前走一点，确保如果 markUsed 意外碰了 updatedAt 能被测出来。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.markUsed('nginx');
    final after = (await repo.all()).single.updatedAt;
    expect(after, equals(before),
        reason: 'updated_at 被使用时间污染的话，一条老 skill 被 load 一次就变'
            '「新」，真正的新条目永远轮不到那 5 格保留位');
  });

  test('markUsed 大小写不敏感', () async {
    await repo.upsert(
        name: 'nginx', description: 'd', body: 'b', source: SkillSource.ai);
    await repo.markUsed('NGINX');
    final skill = (await repo.all()).single;
    expect(skill.hitCount, equals(1));
  });

  test('markUsed 打在不存在的名字上不抛异常', () async {
    await expectLater(repo.markUsed('does-not-exist'), completes);
  });

  test('upsert 覆盖同名时保留 hitCount', () async {
    await repo.upsert(
        name: 'nginx', description: 'd', body: 'b', source: SkillSource.ai);
    await repo.markUsed('nginx');
    await repo.markUsed('nginx');
    await repo.upsert(
        name: 'nginx',
        description: 'd2',
        body: 'b2',
        source: SkillSource.ai);
    final skill = (await repo.all()).single;
    expect(skill.hitCount, equals(2));
    expect(skill.description, equals('d2'));
  });
}
