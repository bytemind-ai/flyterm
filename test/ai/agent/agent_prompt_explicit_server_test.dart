import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';

import '_prompt_helpers.dart';

void main() {
  test('无归属会话:讲清楚必须带 server,并内联机器名', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.full,
      activeToolNames: const {'bash', 'list_servers'},
      requireExplicitServer: true,
      serverNames: const ['web-1', 'db-prod'],
    );

    expect(p, contains('not attached to any machine'));
    expect(p, contains('web-1'));
    expect(p, contains('db-prod'));
    // 内联了名字之后仍要留 list_servers 的指引 —— 名字能告诉它打哪台,
    // 但 creds_ok 只有 list_servers 知道。
    expect(p, contains('list_servers'));
  });

  test('无归属会话:不再出现「当前会话」的措辞', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.full,
      activeToolNames: const {'bash', 'list_servers'},
      requireExplicitServer: true,
      serverNames: const ['web-1'],
    );

    // 这句是绑定式会话的措辞,在无归属会话里是错的指引。
    expect(p, isNot(contains('Omit it entirely to use the current session')));
    expect(p, isNot(contains('instead of the current session')));
  });

  test('无归属会话:一台机器都没有时明确说出来', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.full,
      activeToolNames: const {'bash', 'list_servers'},
      requireExplicitServer: true,
      serverNames: const [],
    );

    expect(p, contains('no saved servers'));
  });

  test('绑定式会话(默认):多机引导保持原样', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.full,
      activeToolNames: const {'bash', 'list_servers'},
      hasOtherServers: true,
    );

    expect(p, contains('instead of the current session'));
    expect(p, isNot(contains('not attached to any machine')));
  });

  test('无归属会话:带 copy_between_servers 时仍要有它的使用指引', () {
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.full,
      activeToolNames: const {
        'bash',
        'list_servers',
        'copy_between_servers',
      },
      requireExplicitServer: true,
      serverNames: const ['web-1', 'db-prod'],
    );

    expect(p, contains('`copy_between_servers` copies one file'));
  });

  test('schema 里必填 server 的工具，全部出现在「MUST pass server」那句里', () {
    // 这条守的是「prompt 与 schema 说同一套话」。`_withRequiredServer` 会给
    // 每个带 `server` 属性的 spec 加上必填 `server`，模型在「不挂任何机器」的
    // 会话里没有任何默认值可猜，因此 prompt 必须逐个点名。
    //
    // **为什么不能像 `agent_prompt_test.dart` 那条守卫一样对全文 `contains`**：
    // `bash` / `glob` 这些名字在用法引导、并发引导里到处出现，全文断言近乎
    // 恒真 —— 正是这一点让四个工具（`install_skill_assets` / `save_note` /
    // `tunnel_create` / `session_open`）长期漏列举却无人发现。这里改成先切出
    // 那一句，再对句子做成员检查。
    //
    // **开关必须全部打开。** 这些工具依赖 `hasSkills` / `hasAppControl` 等
    // 开关才出现在产出里（`install_skill_assets` 要 `hasSkills`；`save_note` /
    // `tunnel_create` / `session_open` 要 `hasAppControl`）。少开一个，工具
    // 就从产出里消失，守卫「看不见」它，等于静默放行 —— 拿默认档取产出正是
    // 那种会退化成恒绿的写法。
    final specs = agentToolSpecsFor(
      AgentToolTier.full,
      hasSkills: true,
      hasAppControl: true,
      hasSavedCommands: true,
      hasSkillOverflow: true,
      hasOtherServers: true,
      requireExplicitServer: true,
    );
    final p = buildAgentSystemPrompt(
      cwd: null,
      terminalContext: null,
      tier: AgentToolTier.full,
      requireExplicitServer: true,
      hasOtherServers: true,
      activeToolNames: specs.map((s) => s.name).toSet(),
      serverNames: const ['web-1', 'db-prod'],
    );

    final mustPass = mustPassServerSentence(p);
    // 先钉住句子必须存在：抽不到时返回空串，而空串对「不含某工具名」恒真，
    // 下面的逐名检查会退化成「只要句子消失就永远通过」。
    expect(mustPass, isNotEmpty,
        reason: 'prompt 里找不到「MUST pass `server`」那一句，'
            '下面的名单检查会退化成空串恒真');

    final required = <String>[
      for (final s in specs)
        if (((s.parameters['required'] as List?)?.cast<String>() ?? const [])
            .contains('server'))
          s.name,
    ];
    // 产出本身不能是空的 —— 否则循环不跑，测试照样绿。
    expect(required, isNotEmpty, reason: '没有抽到任何必填 server 的 spec');

    for (final name in required) {
      expect(mustPass, contains('`$name`'),
          reason: '`$name` 的 schema 里 `server` 是必填，'
              '但没被列进「MUST pass `server`」那句：$mustPass');
    }
  });
}
