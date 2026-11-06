import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ui/ai/mention.dart';

void main() {
  test('内置技能排在用户技能之前', () {
    final out = matchLocal(
      kind: TriggerKind.slash,
      query: '',
      servers: const [],
      skills: const [
        SkillIndexEntry(name: 'plan-change', description: '规划改动'),
        SkillIndexEntry(name: 'nginx', description: '排查 502'),
      ],
      commands: const [],
    );
    expect(out.first.label, 'plan-change');
  });

  test('按名字前缀能匹配到内置技能', () {
    final out = matchLocal(
      kind: TriggerKind.slash,
      query: 'plan',
      servers: const [],
      skills: const [
        SkillIndexEntry(name: 'plan-change', description: '规划改动'),
        SkillIndexEntry(name: 'nginx', description: '排查 502'),
      ],
      commands: const [],
    );
    expect(out, hasLength(1));
    expect(out.single.insertText, 'plan-change');
    expect(out.single.subtitle, '规划改动');
  });
}
