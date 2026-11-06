import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';

void main() {
  List<String> namesOf(AgentToolTier t,
          {required bool hasSkills, bool hasOtherServers = false}) =>
      agentToolSpecsFor(t,
              hasSkills: hasSkills, hasOtherServers: hasOtherServers)
          .map((s) => s.name)
          .toList();

  test('没有技能时两档都不声明 load_skill —— 给模型一个必然失败的工具是错的',
      () {
    expect(namesOf(AgentToolTier.lean, hasSkills: false),
        isNot(contains('load_skill')));
    expect(namesOf(AgentToolTier.full, hasSkills: false),
        isNot(contains('load_skill')));
  });

  test('有技能时 lean 档也有 load_skill —— 单参数只读，小模型写不坏', () {
    expect(namesOf(AgentToolTier.lean, hasSkills: true),
        contains('load_skill'));
  });

  test('save_skill 只进 full 档 —— 三个字段是小模型容易写坏的形状', () {
    expect(namesOf(AgentToolTier.lean, hasSkills: true),
        isNot(contains('save_skill')));
    expect(namesOf(AgentToolTier.full, hasSkills: true),
        contains('save_skill'));
  });

  test('full 档没有技能时仍然有 save_skill —— 否则第一个技能永远建不出来',
      () {
    expect(namesOf(AgentToolTier.full, hasSkills: false),
        contains('save_skill'));
  });

  test('hasSkills 默认 false —— 漏传的后果是少一个工具，不是多一个假工具', () {
    expect(agentToolSpecsFor(AgentToolTier.full).map((s) => s.name),
        isNot(contains('load_skill')));
  });

  test('原有工具一个都没少', () {
    final lean = namesOf(AgentToolTier.lean, hasSkills: false);
    expect(lean, containsAll(['bash', 'read_file', 'read_terminal']));
    // 多机档：这条量的是「full 档原有工具一个都没少」，而 `list_servers` /
    // `copy_between_servers` 只在用户真有第二台机器时才声明。
    final full =
        namesOf(AgentToolTier.full, hasSkills: false, hasOtherServers: true);
    expect(
        full,
        containsAll([
          'bash', 'read_file', 'read_terminal', 'write_file', 'edit_file',
          'set_plan', 'run_background', 'check_job', 'download_file',
          'upload_file', 'list_servers', 'copy_between_servers',
        ]));
  });
}
