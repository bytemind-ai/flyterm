import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSkillManager mgr;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    mgr = AgentSkillManager(AgentSkillRepository(db));
    await mgr.reload();
  });

  tearDown(() async => db.close());

  test('bodyOf 成功取到正文时 hitCount 变 1', () async {
    await mgr.save(
        name: 'nginx', description: '排查 502', body: 'B', source: SkillSource.ai);

    final body = await mgr.bodyOf('nginx');
    expect(body, equals('B'));

    await mgr.reload();
    final skill = mgr.skills.singleWhere((s) => s.name == 'nginx');
    expect(skill.hitCount, equals(1));
  });

  test('拿不到正文时不记账 —— 被禁用的情形', () async {
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    final id = mgr.skills.single.id;
    await mgr.setEnabled(id, false);

    final body = await mgr.bodyOf('x');
    expect(body, isNull);

    await mgr.reload();
    final skill = mgr.skills.singleWhere((s) => s.id == id);
    expect(skill.hitCount, equals(0));
  });

  test('拿不到正文时不记账 —— 名字不存在的情形', () async {
    // 建一条无关的 skill，确认它的 hitCount 不会被 does-not-exist 的
    // load_skill 误伤（markUsed 用 WHERE name = ?，没有匹配行本就是空操作，
    // 这里断言的是「没有副作用」而不是某一行被改）。
    await mgr.save(
        name: 'unrelated', description: 'd', body: 'b', source: SkillSource.ai);

    final body = await mgr.bodyOf('does-not-exist');
    expect(body, isNull);

    await mgr.reload();
    final skill = mgr.skills.singleWhere((s) => s.name == 'unrelated');
    expect(skill.hitCount, equals(0));
  });

  test('记账不刷新内存索引 —— 会话内索引必须恒定，否则每次 load_skill 都击穿 prompt cache',
      () async {
    await mgr.save(
        name: 'a', description: 'd', body: 'b', source: SkillSource.ai);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await mgr.save(
        name: 'b', description: 'd', body: 'b', source: SkillSource.ai);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await mgr.save(
        name: 'c', description: 'd', body: 'b', source: SkillSource.ai);

    final before = mgr.indexEntries.map((e) => e.name).toList();

    await mgr.bodyOf('b');

    final after = mgr.indexEntries.map((e) => e.name).toList();
    expect(after, equals(before),
        reason: '会话内索引必须恒定，否则每次 load_skill 都击穿 prompt cache');
  });

  test('记账不触发 notifyListeners', () async {
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);

    var notified = 0;
    mgr.addListener(() => notified++);

    await mgr.bodyOf('x');

    expect(notified, equals(0));
  });

  test('下次 reload 之后信号可见 —— 断言库里的 hitCount / lastUsedAt', () async {
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    final id = mgr.skills.single.id;

    await mgr.bodyOf('x');
    await mgr.reload();

    final skill = mgr.skills.singleWhere((s) => s.id == id);
    expect(skill.hitCount, equals(1));
    expect(skill.lastUsedAt, isNotNull);
  });
}
