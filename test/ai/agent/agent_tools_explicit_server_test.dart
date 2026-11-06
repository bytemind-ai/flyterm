import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

ToolSpec? _find(List<ToolSpec> specs, String name) {
  for (final s in specs) {
    if (s.name == name) return s;
  }
  return null;
}

List<String> _required(ToolSpec s) =>
    ((s.parameters['required'] as List).cast<String>());

void main() {
  group('requireExplicitServer = true', () {
    final specs = agentToolSpecsFor(
      AgentToolTier.full,
      hasOtherServers: true,
      // hasSavedCommands: true 让 run_saved_command 真的进了 base 列表 ——
      // 否则下面「绑当前会话的工具整组不声明」里对它的断言会因为它压根没被
      // 声明而白过,测不出 kSessionBoundToolNames 有没有把它挡住。
      hasSavedCommands: true,
      requireExplicitServer: true,
    );

    test('六个主力工具的 server 变成必填', () {
      for (final name in [
        'bash',
        'read_file',
        'write_file',
        'edit_file',
        'glob',
        'grep',
      ]) {
        final spec = _find(specs, name);
        expect(spec, isNotNull, reason: '$name 应当仍被声明');
        expect(_required(spec!), contains('server'),
            reason: '$name 的 server 应当是必填');
      }
    });

    test('server 的描述不再说「省略则用当前会话」', () {
      final bash = _find(specs, 'bash')!;
      final desc = ((bash.parameters['properties']
          as Map)['server'] as Map)['description'] as String;
      expect(desc.toLowerCase(), isNot(contains('omit')));
      expect(desc.toLowerCase(), contains('required'));
    });

    test('绑当前会话的工具整组不声明', () {
      // 直接遍历生产代码里的真值集合,而不是在测试里再维护一份影子拷贝 ——
      // 后者会让「以后往 kSessionBoundToolNames 加了新工具却忘了同步测试」
      // 这种错法测不出来。
      for (final name in kSessionBoundToolNames) {
        expect(_find(specs, name), isNull, reason: '$name 不该出现在全局会话');
      }
    });

    test('list_servers 无条件声明(即使只有一台机器)', () {
      final only1 = agentToolSpecsFor(
        AgentToolTier.full,
        hasOtherServers: false,
        requireExplicitServer: true,
      );
      expect(_find(only1, 'list_servers'), isNotNull);
    });
  });

  group('requireExplicitServer = false(现有行为不变)', () {
    final specs = agentToolSpecsFor(
      AgentToolTier.full,
      hasOtherServers: true,
    );

    test('server 仍是可选', () {
      expect(_required(_find(specs, 'bash')!), isNot(contains('server')));
    });

    test('绑当前会话的工具照常声明', () {
      expect(_find(specs, 'read_terminal'), isNotNull);
      expect(_find(specs, 'run_background'), isNotNull);
    });

    test('单机时不声明 list_servers —— 这条老行为不受影响', () {
      final only1 = agentToolSpecsFor(
        AgentToolTier.full,
        hasOtherServers: false,
      );
      expect(_find(only1, 'list_servers'), isNull);
    });
  });
}
