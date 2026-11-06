import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

void main() {
  test('没有技能索引时 prompt 里完全不提 load_skill', () {
    final p = buildAgentSystemPrompt(
        cwd: null, terminalContext: null, tier: AgentToolTier.full);
    expect(p, isNot(contains('load_skill')));
    expect(p, isNot(contains('your skills')));
  });

  test('有索引时索引原样出现', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      skillIndex: '--- your skills ---\nnginx: 排查 502',
    );
    expect(p, contains('nginx: 排查 502'));
  });

  test('有索引时给出 load_skill 的用法引导，且 lean 档也给', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.lean,
      skillIndex: '--- your skills ---\nx: y',
    );
    expect(p, contains('load_skill'));
    expect(p, contains('once'),
        reason: '「一次会话只 load 一次」这条约束必须在 prompt 里');
  });

  test('索引位置在 instructions 之后 —— 更易变的放后面', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      instructions: 'INSTRUCTIONS_MARK',
      skillIndex: 'SKILLINDEX_MARK',
    );
    expect(p.indexOf('INSTRUCTIONS_MARK'),
        lessThan(p.indexOf('SKILLINDEX_MARK')));
  });

  test('索引位置在 cwd 之前', () {
    final p = buildAgentSystemPrompt(
      cwd: '/var/CWD_MARK',
      terminalContext: null,
      skillIndex: 'SKILLINDEX_MARK',
    );
    expect(p.indexOf('SKILLINDEX_MARK'), lessThan(p.indexOf('CWD_MARK')));
  });

  test('save_skill 引导只在 full 档出现', () {
    final lean = buildAgentSystemPrompt(
        cwd: null, terminalContext: null, tier: AgentToolTier.lean);
    expect(lean, isNot(contains('save_skill')));
    final full = buildAgentSystemPrompt(
        cwd: null, terminalContext: null, tier: AgentToolTier.full);
    expect(full, contains('save_skill'));
  });

  test('plan 模式的引导段没有被 skill 改动挤掉', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      mode: PermissionMode.ask,
      skillIndex: 'x',
    );
    expect(p, contains('INVESTIGATION MODE'));
  });

  test('有长尾时提示模型索引不全、可以检索', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      skillIndex: '--- your skills ---\nnginx: 排查 502',
      hasSkillOverflow: true,
    );
    expect(p, contains('search_skills'));
  });

  test('没有长尾时不提检索', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      skillIndex: '--- your skills ---\nnginx: 排查 502',
      hasSkillOverflow: false,
    );
    expect(p, isNot(contains('search_skills')));
  });

  test('一个技能都没有时，即使 hasSkillOverflow 为 true 也不提检索', () {
    // 防御一种不该发生但代价很低的组合：没有 skillIndex 却传了 overflow。
    // 引导语必须嵌在 `if (skillIndex != null && ...)` 块内。
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      hasSkillOverflow: true,
    );
    expect(p, isNot(contains('search_skills')));
  });
}
