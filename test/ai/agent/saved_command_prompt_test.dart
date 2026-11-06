import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';

void main() {
  test('没有命令索引时 prompt 完全不提 run_saved_command', () {
    final p = buildAgentSystemPrompt(
        cwd: null, terminalContext: null, tier: AgentToolTier.full);
    expect(p, isNot(contains('run_saved_command')));
    expect(p, isNot(contains('saved commands')));
  });

  test('有索引时索引原样出现', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      savedCommandIndex: '--- saved commands ---\n部署 [s]: deploy {{s}}',
    );
    expect(p, contains('部署 [s]: deploy {{s}}'));
  });

  test('有索引时给出用法引导，lean 档也给', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.lean,
      savedCommandIndex: 'x',
    );
    expect(p, contains('run_saved_command'));
  });

  test('命令索引在 instructions 之后', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      instructions: 'INSTRUCTIONS_MARK',
      savedCommandIndex: 'CMDINDEX_MARK',
    );
    expect(p.indexOf('INSTRUCTIONS_MARK'), lessThan(p.indexOf('CMDINDEX_MARK')));
  });

  test('命令索引在 skillIndex 之前 —— skillIndex 会被 save_skill 当场改', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      savedCommandIndex: 'CMDINDEX_MARK',
      skillIndex: 'SKILLINDEX_MARK',
    );
    expect(p.indexOf('CMDINDEX_MARK'), lessThan(p.indexOf('SKILLINDEX_MARK')));
  });

  test('命令索引在 cwd 之前', () {
    final p = buildAgentSystemPrompt(
      cwd: '/var/CWD_MARK',
      terminalContext: null,
      savedCommandIndex: 'CMDINDEX_MARK',
    );
    expect(p.indexOf('CMDINDEX_MARK'), lessThan(p.indexOf('CWD_MARK')));
  });

  test('三段共存时顺序是 instructions → 命令 → 技能', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      instructions: 'AAA_MARK',
      savedCommandIndex: 'BBB_MARK',
      skillIndex: 'CCC_MARK',
    );
    expect(p.indexOf('AAA_MARK'), lessThan(p.indexOf('BBB_MARK')));
    expect(p.indexOf('BBB_MARK'), lessThan(p.indexOf('CCC_MARK')));
  });
}
