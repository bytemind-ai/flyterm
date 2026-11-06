import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/builtin_skill_index.dart';
import 'package:flyterm/ai/agent/skill.dart';

void main() {
  group('composeBuiltinSkillIndex', () {
    test('空列表返回 null —— 调用方据此整段跳过', () {
      expect(composeBuiltinSkillIndex(const []), isNull);
    });

    test('把 name 与 description 逐行拼出来', () {
      final s = composeBuiltinSkillIndex(const [
        SkillIndexEntry(name: 'alpha', description: 'A 的说明'),
      ]);
      expect(s, contains('alpha: A 的说明'));
    });

    test('带铁律：小概率也要先 load，且不准自我说服"太简单"', () {
      final s = composeBuiltinSkillIndex(const [
        SkillIndexEntry(name: 'alpha', description: 'd'),
      ])!;
      expect(s, contains('load_skill'));
      expect(s.toLowerCase(), contains('too simple'));
    });

    test('带冲突边界：可覆盖提问节奏，不可覆盖审批', () {
      final s = composeBuiltinSkillIndex(const [
        SkillIndexEntry(name: 'alpha', description: 'd'),
      ])!;
      expect(s, contains('overrides'));
      expect(s, contains('approval'));
    });
  });

  group('buildAgentSystemPrompt 里的位置', () {
    test('内置段在 instructions 之前 —— 它更稳定', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        builtinSkillIndex: 'BUILTIN_MARK',
        instructions: 'INSTRUCTIONS_MARK',
      );
      expect(p.indexOf('BUILTIN_MARK'), lessThan(p.indexOf('INSTRUCTIONS_MARK')));
    });

    test('内置段在用户技能索引之前', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        builtinSkillIndex: 'BUILTIN_MARK',
        skillIndex: 'SKILLINDEX_MARK',
      );
      expect(p.indexOf('BUILTIN_MARK'), lessThan(p.indexOf('SKILLINDEX_MARK')));
    });

    test('lean 档也带 —— 与 load_skill 的声明一致', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        tier: AgentToolTier.lean,
        builtinSkillIndex: 'BUILTIN_MARK',
      );
      expect(p, contains('BUILTIN_MARK'));
    });

    test('全部禁用时整段消失，不留空标题', () {
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        builtinSkillIndex: composeBuiltinSkillIndex(const []),
      );
      expect(p, isNot(contains('built-in skills')));
    });

    test('只有内置、没有用户技能时，load_skill 的引导仍然在场', () {
      // 现有 load_skill 用法引导挂在 `skillIndex` 非空的条件块里。内置技能
      // 同样需要那条"一轮只 load 一次"的约束，所以条件必须是两者之一非空。
      final p = buildAgentSystemPrompt(
        cwd: null,
        terminalContext: null,
        builtinSkillIndex: 'BUILTIN_MARK',
      );
      expect(p, contains('load_skill'));
      expect(p, contains('once'));
    });
  });
}
