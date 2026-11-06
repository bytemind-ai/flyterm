import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/skill.dart';

void main() {
  var nextId = 1;

  AgentSkill mk(
    String name, {
    int? updatedAtMs,
    int? usedAtMs,
    int hits = 0,
    bool enabled = true,
  }) {
    return AgentSkill(
      id: nextId++,
      name: name,
      description: 'd',
      body: 'b',
      enabled: enabled,
      source: SkillSource.ai,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs ?? 0),
      lastUsedAt:
          usedAtMs == null ? null : DateTime.fromMillisecondsSinceEpoch(usedAtMs),
      hitCount: hits,
    );
  }

  test('总数不超过名额时全部进索引', () {
    final skills = List.generate(5, (i) => mk('s$i', updatedAtMs: i));
    expect(selectIndexed(skills), hasLength(5));
  });

  // 下面三条都要**超过** kMaxIndexedSkills 才有意义：`selectIndexed` 对
  // 不超额的列表直接原样返回（那时候根本没有「谁挤掉谁」的问题）。
  //
  // 同时 padding 的取值要保证被测的两条都留在输出里 —— 输出恒为 30 条，
  // 垫底被挤掉的那个必须是某条 pad。否则 `indexOf` 返回 -1，断言就从
  // 「A 排在 B 前面」悄悄变成了「A 的下标小于 -1」，永远失败。

  test('用过的排在没用过的前面 —— 哪怕没用过的那条内容更新', () {
    // unused 给一个最大的 updatedAt：这样它在「没用过」的组里排第一，
    // 不会被挤出输出，断言才验证得到「用过压过没用过」这件事本身。
    final used = mk('used', updatedAtMs: 1, usedAtMs: 100);
    final unused = mk('unused', updatedAtMs: 999999);
    final all = [
      unused,
      used,
      ...List.generate(
          kMaxIndexedSkills - 1, (i) => mk('pad$i', updatedAtMs: 3 + i)),
    ];
    final out = selectIndexed(all).map((s) => s.name).toList();
    expect(out, contains('used'));
    expect(out, contains('unused'));
    expect(out.indexOf('used'), lessThan(out.indexOf('unused')));
  });

  test('都用过时最近用的在前', () {
    // pad 的 usedAt 全部低于被测两条，于是垫底被挤掉的是 pad0。
    final older = mk('older', updatedAtMs: 1, usedAtMs: 100);
    final newer = mk('newer', updatedAtMs: 2, usedAtMs: 200);
    final all = [
      older,
      newer,
      ...List.generate(kMaxIndexedSkills - 1,
          (i) => mk('pad$i', updatedAtMs: 3 + i, usedAtMs: 10 + i)),
    ];
    final out = selectIndexed(all).map((s) => s.name).toList();
    expect(out, contains('older'));
    expect(out.indexOf('newer'), lessThan(out.indexOf('older')));
  });

  test('用过时刻相同时命中多的在前', () {
    // 同上：pad 的 usedAt 压在被测两条之下，保证挤掉的是 pad。
    final fewHits = mk('few', updatedAtMs: 1, usedAtMs: 100, hits: 1);
    final manyHits = mk('many', updatedAtMs: 2, usedAtMs: 100, hits: 10);
    final all = [
      fewHits,
      manyHits,
      ...List.generate(kMaxIndexedSkills - 1,
          (i) => mk('pad$i', updatedAtMs: 3 + i, usedAtMs: 50 + i, hits: 5)),
    ];
    final out = selectIndexed(all).map((s) => s.name).toList();
    expect(out, contains('few'));
    expect(out.indexOf('many'), lessThan(out.indexOf('few')));
  });

  test('都没用过时退化为 updatedAt 倒序（与改造前行为一致）', () {
    final all = List.generate(
        kMaxIndexedSkills + 5, (i) => mk('s$i', updatedAtMs: i));
    final out = selectIndexed(all).map((s) => s.name).toSet();
    // 最新的 kMaxIndexedSkills 条（即 id 更大、updatedAt 更大的那些）应该在。
    for (var i = 5; i < kMaxIndexedSkills + 5; i++) {
      expect(out, contains('s$i'));
    }
    for (var i = 0; i < 5; i++) {
      expect(out, isNot(contains('s$i')));
    }
  });

  test('冷启动饥饿：全用过的老 skill 挤满 merit 名额，刚存的新 skill 仍必须在索引里', () {
    final oldUsed = List.generate(
        kIndexMeritSlots,
        (i) => mk('old$i',
            updatedAtMs: 1, usedAtMs: 1000 + i, hits: 100));
    final freshNew = mk('brand-new', updatedAtMs: 999999999, enabled: true);
    final out = selectIndexed([...oldUsed, freshNew]);
    expect(out.map((s) => s.name), contains('brand-new'),
        reason: '没有保留位的话新存的进不了索引 → 模型看不见 → 永远不会被 load → 永远进不去');
  });

  test('超过总额时正好取 kMaxIndexedSkills 条', () {
    final all = List.generate(
        kMaxIndexedSkills + 7, (i) => mk('s$i', updatedAtMs: i));
    expect(selectIndexed(all), hasLength(kMaxIndexedSkills));
  });

  test('新人格里放的是最新存入的，不是随便剩下的', () {
    final used = List.generate(
        kMaxIndexedSkills,
        (i) => mk('used$i', updatedAtMs: 100 + i, usedAtMs: 1000 + i));
    final veryNew = mk('very-new', updatedAtMs: 999999999);
    final veryOld = mk('very-old', updatedAtMs: -999999999);
    final out = selectIndexed([...used, veryNew, veryOld]);
    expect(out.map((s) => s.name), contains('very-new'));
    expect(out.map((s) => s.name), isNot(contains('very-old')));
  });

  test('同一条不会因为同时够格两段而被算两次', () {
    final all = List.generate(
        kMaxIndexedSkills + 3, (i) => mk('s$i', updatedAtMs: i));
    final out = selectIndexed(all);
    final names = out.map((s) => s.name).toList();
    expect(names.toSet(), hasLength(names.length));
  });

  test('kIndexMeritSlots + kIndexFreshSlots == kMaxIndexedSkills', () {
    expect(kIndexMeritSlots + kIndexFreshSlots, equals(kMaxIndexedSkills));
  });
}
