import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';

void main() {
  List<String> namesOf(AgentToolTier t,
          {bool hasSkills = false,
          bool hasSavedCommands = false,
          bool hasOtherServers = false}) =>
      agentToolSpecsFor(t,
              hasSkills: hasSkills,
              hasSavedCommands: hasSavedCommands,
              hasOtherServers: hasOtherServers)
          .map((s) => s.name)
          .toList();

  test('没有可用命令时不声明 —— 给模型一个必然失败的工具是错的', () {
    expect(namesOf(AgentToolTier.full), isNot(contains('run_saved_command')));
    expect(namesOf(AgentToolTier.lean), isNot(contains('run_saved_command')));
  });

  test('有命令时两档都声明 —— 两个参数，小模型写得来', () {
    expect(namesOf(AgentToolTier.lean, hasSavedCommands: true),
        contains('run_saved_command'));
    expect(namesOf(AgentToolTier.full, hasSavedCommands: true),
        contains('run_saved_command'));
  });

  test('hasSavedCommands 默认 false', () {
    expect(agentToolSpecsFor(AgentToolTier.full).map((s) => s.name),
        isNot(contains('run_saved_command')));
  });

  test('与 hasSkills 互不干扰', () {
    final both = namesOf(AgentToolTier.full,
        hasSkills: true, hasSavedCommands: true);
    expect(both, containsAll(['load_skill', 'save_skill', 'run_saved_command']));
    final onlySkills = namesOf(AgentToolTier.full, hasSkills: true);
    expect(onlySkills, contains('load_skill'));
    expect(onlySkills, isNot(contains('run_saved_command')));
  });

  test('原有工具一个都没少', () {
    // 多机档：`list_servers` / `copy_between_servers` 只在用户真有第二台
    // 机器时才声明（单机下它们必然失败）。
    expect(
        namesOf(AgentToolTier.full, hasOtherServers: true),
        containsAll([
          'bash', 'read_file', 'read_terminal', 'write_file', 'edit_file',
          'set_plan', 'run_background', 'check_job', 'download_file',
          'upload_file', 'list_servers', 'copy_between_servers', 'save_skill',
        ]));
  });
}
