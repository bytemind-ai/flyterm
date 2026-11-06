import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ui/settings/agent_skills_screen.dart';

AgentSkill mk({DateTime? used, int hits = 0}) => AgentSkill(
      id: 1,
      name: 'n',
      description: 'd',
      body: 'b',
      enabled: true,
      source: SkillSource.ai,
      updatedAt: DateTime(2026, 1, 1),
      lastUsedAt: used,
      hitCount: hits,
    );

void main() {
  final now = DateTime(2026, 9, 4, 12);

  test('从未用过', () {
    expect(skillUsageDays(mk(), now: now), isNull);
  });

  test('今天用过算 0 天', () {
    expect(skillUsageDays(mk(used: DateTime(2026, 9, 4, 1)), now: now),
        equals(0));
  });

  test('7 天前用过算 7 天', () {
    expect(
        skillUsageDays(mk(used: DateTime(2026, 8, 28, 12)), now: now), equals(7));
  });

  test('未来时间戳不返回负数', () {
    expect(skillUsageDays(mk(used: DateTime(2027, 1, 1)), now: now), equals(0));
  });
}
