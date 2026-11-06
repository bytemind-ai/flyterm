import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/ai/agent/skill.dart';

/// `agent_skill_assets` 表的 CRUD 与级联删除。
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

  Future<int> saveSkill(String name, {List<AgentSkillAsset> assets = const []}) async {
    await repo.upsert(
      name: name,
      description: 'd',
      body: 'b',
      source: SkillSource.ai,
      assets: assets,
    );
    final skill = (await repo.all()).firstWhere((s) => s.name == name);
    return skill.id;
  }

  test('新库上 agent_skill_assets 表存在', () async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='agent_skill_assets'",
    );
    expect(rows, hasLength(1));
  });

  test('upsert 带 assets 时一同落库，读回顺序与 position 一致', () async {
    await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'scripts/a.sh', content: 'A', executable: true),
      AgentSkillAsset(path: 'templates/b.conf', content: 'B'),
      AgentSkillAsset(path: 'c.txt', content: 'C'),
    ]);
    final assets = await repo.assetsOf('nginx');
    expect(assets.map((a) => a.path).toList(),
        equals(['scripts/a.sh', 'templates/b.conf', 'c.txt']));
    expect(assets[0].executable, isTrue);
    expect(assets[0].content, equals('A'));
    expect(assets[1].executable, isFalse);
  });

  test('upsert 不带 assets（null）时不动已有附件', () async {
    await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'scripts/a.sh', content: 'A'),
    ]);
    // 不传 assets 的调用点（还没有，但 API 允许）不该把附件清掉。
    await repo.upsert(
        name: 'nginx',
        description: 'd2',
        body: 'b2',
        source: SkillSource.ai);
    expect((await repo.assetsOf('nginx')).single.path, equals('scripts/a.sh'));
  });

  test('upsert 传空 assets 时清空该技能已有附件', () async {
    await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'scripts/a.sh', content: 'A'),
    ]);
    // 语义是「这条技能现在没有附件了」。
    await repo.upsert(
        name: 'nginx',
        description: 'd2',
        body: 'b2',
        source: SkillSource.ai,
        assets: const []);
    expect(await repo.assetsOf('nginx'), isEmpty);
  });

  test('assetsOf 对不存在的技能返回空列表而非抛异常', () async {
    expect(await repo.assetsOf('does-not-exist'), isEmpty);
  });

  test('assetsOf 大小写不敏感', () async {
    await saveSkill('Nginx', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'X'),
    ]);
    expect((await repo.assetsOf('nginx')).single.path, equals('x.sh'));
  });

  test('删除技能时附件同事务删除', () async {
    final id = await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'scripts/a.sh', content: 'A'),
      AgentSkillAsset(path: 'b.conf', content: 'B'),
    ]);
    await repo.delete(id);
    final orphan = await db.query('agent_skill_assets', where: 'skill_id = ?',
        whereArgs: [id]);
    expect(orphan, isEmpty, reason: '孤儿行会永久占空间且永不被读');
  });

  test('同一技能内 path 唯一（撞名时后者替换前者）', () async {
    await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'first'),
      AgentSkillAsset(path: 'x.sh', content: 'second'),
    ]);
    final assets = await repo.assetsOf('nginx');
    expect(assets, hasLength(1));
    expect(assets.single.content, equals('second'));
  });

  test('两个技能可以有同名 path', () async {
    await saveSkill('a', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'A'),
    ]);
    await saveSkill('b', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'B'),
    ]);
    expect((await repo.assetsOf('a')).single.content, equals('A'));
    expect((await repo.assetsOf('b')).single.content, equals('B'));
  });

  test('bodyOf 与 all 不因附件表存在而改变行为', () async {
    await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'X'),
    ]);
    expect(await repo.bodyOf('nginx'), equals('b'));
    expect((await repo.all()).single.body, equals('b'));
  });

  test('updateFields 不动附件', () async {
    final id = await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'X'),
    ]);
    await repo.updateFields(id, body: 'changed');
    expect((await repo.assetsOf('nginx')).single.path, equals('x.sh'));
  });

  test('all() 填好 assetCount，且不读附件正文', () async {
    await saveSkill('a', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'X'),
      AgentSkillAsset(path: 'y.sh', content: 'Y'),
    ]);
    await saveSkill('b');
    final byName = {for (final s in await repo.all()) s.name: s};
    expect(byName['a']!.assetCount, equals(2));
    expect(byName['b']!.assetCount, equals(0));
    expect(byName['a']!.assets, isEmpty,
        reason: '列表层不填正文 —— assetsOf 才是读正文的入口');
  });

  test('assetCount 在删除附件后跟着变', () async {
    await saveSkill('a', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'X'),
    ]);
    expect((await repo.all()).single.assetCount, equals(1));
    await repo.upsert(
        name: 'a', description: 'd', body: 'b',
        source: SkillSource.ai, assets: const []);
    expect((await repo.all()).single.assetCount, equals(0));
  });

  test('updateFields 带 assets 时整组替换', () async {
    final id = await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'old.sh', content: 'OLD'),
    ]);
    await repo.updateFields(id, assets: const [
      AgentSkillAsset(path: 'new.sh', content: 'NEW', executable: true),
      AgentSkillAsset(path: 't.conf', content: 'T'),
    ]);
    final assets = await repo.assetsOf('nginx');
    expect(assets.map((a) => a.path).toList(), equals(['new.sh', 't.conf']));
    expect(assets.first.executable, isTrue);
  });

  test('updateFields 不带 assets（null）时不动附件', () async {
    final id = await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'keep.sh', content: 'K'),
    ]);
    await repo.updateFields(id, body: 'changed');
    expect((await repo.assetsOf('nginx')).single.path, equals('keep.sh'));
  });

  test('updateFields 传空 assets 时清空', () async {
    final id = await saveSkill('nginx', assets: const [
      AgentSkillAsset(path: 'x.sh', content: 'X'),
    ]);
    await repo.updateFields(id, assets: const []);
    expect(await repo.assetsOf('nginx'), isEmpty);
  });

  test('updateFields 改附件时 body 与 description 也一起落', () async {
    final id = await saveSkill('nginx');
    await repo.updateFields(id,
        description: 'd2',
        body: 'b2',
        assets: const [AgentSkillAsset(path: 'a.sh', content: 'A')]);
    final s = (await repo.all()).single;
    expect(s.description, equals('d2'));
    expect(s.body, equals('b2'));
    expect(s.assetCount, equals(1));
  });
}
