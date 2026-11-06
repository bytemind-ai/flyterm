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

  test('初始为空时索引为空、names 为空', () {
    expect(mgr.indexEntries, isEmpty);
    expect(mgr.names, isEmpty);
  });

  test('保存之后 indexEntries 同步立刻反映 —— 不需要再 await 一次读库', () async {
    await mgr.save(
        name: 'nginx', description: '排查 502', body: 'B', source: SkillSource.ai);
    // 关键：这里是同步 getter，systemPromptProvider 就是这样用它的
    expect(mgr.indexEntries.map((e) => e.name), contains('nginx'));
    expect(mgr.names, contains('nginx'));
  });

  test('删除之后索引同步移除', () async {
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    final id = mgr.skills.single.id;
    await mgr.delete(id);
    expect(mgr.indexEntries, isEmpty);
  });

  test('禁用之后不进索引，但仍在 skills 里（列表页要显示它）', () async {
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    await mgr.setEnabled(mgr.skills.single.id, false);
    expect(mgr.indexEntries, isEmpty);
    expect(mgr.skills, hasLength(1));
  });

  test('超过 kMaxIndexedSkills 时只有前 N 条进索引，其余留在库里', () async {
    for (var i = 0; i < kMaxIndexedSkills + 5; i++) {
      await mgr.save(
          name: 's$i', description: 'd', body: 'b', source: SkillSource.ai);
    }
    expect(mgr.indexEntries, hasLength(kMaxIndexedSkills));
    expect(mgr.skills, hasLength(kMaxIndexedSkills + 5));
    expect(mgr.overflowCount, equals(5));
  });

  test('被挤出索引的 skill 不能被 load —— 否则索引上限形同虚设', () async {
    for (var i = 0; i < kMaxIndexedSkills + 1; i++) {
      await mgr.save(
          name: 's$i', description: 'd', body: 'b', source: SkillSource.ai);
      // updated_at 用毫秒时间戳排序；同一毫秒内连续 31 次 save 会导致
      // updatedAt 相同，倒序就不稳定，s0 未必被挤到最后。这里睡 1ms
      // 让时间戳单调递增，避免测试假性通过/偶发失败。
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // s0 最早写入，按 updatedAt 倒序排在最后，被挤出索引
    expect(mgr.names, isNot(contains('s0')));
    expect(await mgr.bodyOf('s0'), isNull);
  });

  test('被挤出索引的 skill 在白名单里时可以 load', () async {
    for (var i = 0; i < kMaxIndexedSkills + 1; i++) {
      await mgr.save(
          name: 's$i', description: 'd', body: 'b', source: SkillSource.ai);
      // 同上一条测试：睡 1ms 让 updated_at 单调递增，否则同毫秒内的 31 次
      // save 会让倒序不稳定、s0 未必被挤出。
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(mgr.names, isNot(contains('s0')));
    // 白名单用小写 —— 调用方（AgentLoop）存的是 name.toLowerCase()。
    expect(await mgr.bodyOf('s0', alsoAllow: {'s0'}), equals('b'));
  });

  test('白名单不含的名字仍然被拦，且大小写折叠一致', () async {
    for (var i = 0; i < kMaxIndexedSkills + 1; i++) {
      await mgr.save(
          name: 's$i', description: 'd', body: 'b', source: SkillSource.ai);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(await mgr.bodyOf('s0', alsoAllow: {'other'}), isNull);
    // 白名单里存的是小写，查询给大写也该放行。
    expect(await mgr.bodyOf('S0', alsoAllow: {'s0'}), equals('b'));
  });

  test('save 会通知监听者', () async {
    var notified = 0;
    mgr.addListener(() => notified++);
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    expect(notified, greaterThan(0));
  });

  test('indexTokenEstimate 随条数增长', () async {
    final before = mgr.indexTokenEstimate;
    await mgr.save(
        name: 'x', description: '一句话描述', body: 'b', source: SkillSource.ai);
    expect(mgr.indexTokenEstimate, greaterThan(before));
  });
}
