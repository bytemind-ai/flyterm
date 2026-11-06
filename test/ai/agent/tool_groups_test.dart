import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_groups.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

void main() {
  group('分组常量', () {
    test('七个组，成员不重叠', () {
      expect(kToolGroups.keys.toSet(), {
        'transfer',
        'sftp',
        'web',
        'skills',
        'jobs',
        'app_config',
        'app_session',
      });
      final all = kToolGroups.values.expand((e) => e).toList();
      expect(all.toSet().length, all.length, reason: '同一个工具不能属于两个组');
    });

    test('组成员都是真实存在的工具名', () {
      // 全部 conditional 开关都打开 —— 本测试断言的是「组里写的名字是真
      // 工具」，那就得把工具都声明出来。漏开关会让它误报某个名字不存在。
      final real = agentToolSpecsFor(AgentToolTier.full,
              hasSkills: true, hasOtherServers: true, hasAppControl: true)
          .map((s) => s.name)
          .toSet();
      for (final name in kToolGroups.values.expand((e) => e)) {
        expect(real, contains(name), reason: '$name 不是真实工具');
      }
    });

    test('core 与 on-demand 不重叠，且合起来覆盖 full 档', () {
      final full = agentToolSpecsFor(AgentToolTier.full,
              hasSkills: true,
              hasSkillOverflow: true,
              hasOtherServers: true,
              hasAppControl: true)
          .map((s) => s.name)
          .toSet();
      final onDemand = kToolGroups.values.expand((e) => e).toSet();
      // full 档里除 on-demand 之外的，就是 core
      expect(onDemand.difference(full), isEmpty);
    });
  });

  group('filterByUnlockedGroups', () {
    List<ToolSpec> specs() => agentToolSpecsFor(AgentToolTier.full,
        hasSkills: true, hasOtherServers: true);

    test('没解锁任何组时，on-demand 工具全部消失', () {
      final out = filterByUnlockedGroups(specs(), const {})
          .map((s) => s.name)
          .toSet();
      expect(out, isNot(contains('upload_file')));
      expect(out, isNot(contains('web_fetch')));
      expect(out, isNot(contains('save_skill')));
      expect(out, isNot(contains('list_jobs')));
      // core 的照常在
      expect(out, contains('bash'));
      expect(out, contains('check_job'));
    });

    test('解锁 transfer 后那三个出现，别的组不受影响', () {
      final out = filterByUnlockedGroups(specs(), const {'transfer'})
          .map((s) => s.name)
          .toSet();
      expect(out, contains('upload_file'));
      expect(out, contains('download_file'));
      expect(out, contains('copy_between_servers'));
      expect(out, isNot(contains('web_fetch')));
    });

    test('单机用户解锁 transfer 也拿不到 copy_between_servers', () {
      // conditional 先筛（hasOtherServers=false 时它压根不在入参里），
      // 解锁只能从已有的里面放行，不能凭空造出来。
      final single = agentToolSpecsFor(AgentToolTier.full,
          hasSkills: true, hasOtherServers: false);
      final out = filterByUnlockedGroups(single, const {'transfer'})
          .map((s) => s.name)
          .toSet();
      expect(out, contains('upload_file'));
      expect(out, isNot(contains('copy_between_servers')));
    });

    test('未知组名被忽略，不抛', () {
      final out = filterByUnlockedGroups(specs(), const {'nope'})
          .map((s) => s.name)
          .toSet();
      expect(out, isNot(contains('upload_file')));
      expect(out, contains('bash'));
    });

    test('lean 档不受影响 —— 它本来就没有 on-demand 工具', () {
      final lean = agentToolSpecsFor(AgentToolTier.lean, hasSkills: true);
      final out = filterByUnlockedGroups(lean, const {});
      expect(out.map((s) => s.name), lean.map((s) => s.name));
    });
  });

  group('more_tools 工具定义', () {
    test('full 档声明 more_tools，lean 档不声明', () {
      final full = agentToolSpecsFor(AgentToolTier.full, hasSkills: true)
          .map((s) => s.name);
      expect(full, contains('more_tools'));

      final lean = agentToolSpecsFor(AgentToolTier.lean, hasSkills: true)
          .map((s) => s.name);
      expect(lean, isNot(contains('more_tools')),
          reason: 'lean 档没有可解锁的工具，给了它只会白占位');
    });

    test('more_tools 自己是 core —— 不能被自己锁住', () {
      expect(groupOf('more_tools'), isNull);
      final out = filterByUnlockedGroups(
          agentToolSpecsFor(AgentToolTier.full, hasSkills: true), const {});
      expect(out.map((s) => s.name), contains('more_tools'));
    });

    test('参数 schema 里列出了全部组名', () {
      final spec = agentToolSpecsFor(AgentToolTier.full,
              hasSkills: true, hasAppControl: true)
          .firstWhere((s) => s.name == 'more_tools');
      final json = spec.parameters.toString();
      for (final g in kToolGroups.keys) {
        expect(json, contains(g));
      }
    });

    // **描述里必须出现组内每个工具名。**
    //
    // 这条守的是一个真实发生过的缺陷：`jobs` 组从 `[list_jobs]` 扩到五件套
    // （加了 `list_tasks` / `create_task` / `update_task` / `delete_task`）时，
    // `kToolGroups` 改了、上面的 enum 测试也因自动生成而自动通过，但**描述是
    // 手写散文**，仍然只写着 `jobs (list_jobs)`。
    //
    // 后果很具体：模型靠这段描述判断「哪个组里有我要的工具」，看不到
    // `create_task` 就不会去解锁 `jobs`——于是「帮我每天备份一下」这个需求
    // 在对话里永远实现不了，而所有测试全绿。
    //
    // 不断言全句措辞（那样改一个词就要改测试），只断言**工具名出现过**。
    test('描述里列出的工具覆盖各组全部成员', () {
      final spec = agentToolSpecsFor(AgentToolTier.full,
              hasSkills: true, hasAppControl: true)
          .firstWhere((s) => s.name == 'more_tools');
      // 只看描述，不看 parameters —— enum 是自动生成的，那里含工具名不算数。
      final desc = spec.description;
      for (final entry in kToolGroups.entries) {
        for (final tool in entry.value) {
          expect(desc, contains(tool),
              reason: '`more_tools` 的描述里没提到 `$tool`（属于 ${entry.key} 组）'
                  '—— 模型不会知道解锁 `${entry.key}` 能拿到它');
        }
      }
    });

    // 没开 app 控制时不该把 app_config 列进 schema —— 模型解锁它会得到
    // 「已激活」却看不到任何新工具，白烧一轮。与 hasOtherServers 为 false
    // 时藏掉 copy_between_servers 是同一条原则。
    test('没开 app 控制时 schema 不列 app_config', () {
      final spec = agentToolSpecsFor(AgentToolTier.full,
              hasSkills: true, hasAppControl: false)
          .firstWhere((s) => s.name == 'more_tools');
      final enumVals =
          ((spec.parameters['properties'] as Map)['group'] as Map)['enum']
              as List;
      expect(enumVals, isNot(contains('app_config')));
      expect(enumVals, contains('transfer'));
    });
  });
}
