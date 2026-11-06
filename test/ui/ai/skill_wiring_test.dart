import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/skill_index.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AgentSkillManager mgr;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    mgr = AgentSkillManager(AgentSkillRepository(db));
    await mgr.reload();
  });

  tearDown(() async => db.close());

  // 这里断言的是 terminal_screen 里那两个闭包该有的行为，用真的 manager
  // 跑一遍，把「装配错了」在单元层就抓住。
  test('新存的技能下一轮就进 prompt —— 不需要重开面板', () async {
    String promptNow() => buildAgentSystemPrompt(
          cwd: null,
          terminalContext: null,
          skillIndex: composeSkillIndex(mgr.indexEntries),
        );

    // 断言的是**完整索引行**，不是裸 'nginx'。
    //
    // 这条原来写的是 `isNot(contains('nginx'))`，而 prompt 的无条件区里有一句
    // `@` 引用的示例用了 `@/etc/nginx/nginx.conf` —— 于是这个断言恒假，测试
    // 从「守住索引段未注入」退化成「prompt 里任何地方都不许出现 nginx 这五个
    // 字母」。后者管得太宽：示例用哪个文件名是任意的，而 nginx.conf 恰好是最
    // 典型的运维文件，被当示例的概率很高。
    //
    // 与下面那条用同一个字符串，前后对称，也正好锁住这条测试真正关心的东西：
    // `composeSkillIndex` 在没有技能时不该产出任何索引行。
    expect(promptNow(), isNot(contains('nginx: 排查 502')));
    await mgr.save(
        name: 'nginx', description: '排查 502', body: 'B', source: SkillSource.ai);
    expect(promptNow(), contains('nginx: 排查 502'));
  });

  test('第一个技能存进去之后，下一轮工具清单才出现 load_skill', () async {
    List<String> toolsNow() =>
        agentToolSpecsFor(AgentToolTier.full, hasSkills: mgr.names.isNotEmpty)
            .map((s) => s.name)
            .toList();

    expect(toolsNow(), isNot(contains('load_skill')));
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    expect(toolsNow(), contains('load_skill'));
  });

  test('禁用最后一个技能之后，load_skill 又消失', () async {
    await mgr.save(
        name: 'x', description: 'd', body: 'b', source: SkillSource.ai);
    expect(mgr.names, isNotEmpty);
    await mgr.setEnabled(mgr.skills.single.id, false);
    expect(mgr.names, isEmpty,
        reason: '禁用后不进索引，工具也该跟着消失，否则模型会调一个必然失败的工具');
  });
}
