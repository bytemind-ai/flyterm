// Agent 行为评测。**打真实 LLM，花钱，默认 skip。**
//
//     FLYTERM_EVAL_KEY=sk-... flutter test test/evals/agent_behavior_eval.dart
//
// 可选：FLYTERM_EVAL_MODEL 指定模型（默认取便宜的那档）。
//
// ## 这套东西保证不了什么
//
// 1. **eval 绿不等于真机对。** MapRunner 的输出是人写的 —— 干净、简短、
//    格式规整。真实的 `systemctl status` 带颜色、更长、各发行版格式不同。
//    模型在理想输出上先 load 技能，不保证在真实输出上也会。**它替代不了
//    真机验证**，只能把「明显坏了」尽早照出来。
// 2. **它测 prompt 与技能的依从性，不测代码正确性。** 代码 bug 归普通单测；
//    两类覆盖不互相替代。
// 3. **它绑定模型。** 换模型后阈值可能要重调，所以报告里记了模型名。
// 4. **它只测前几跳**，不测整个排查流程的质量 —— 那需要人判断。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';

import 'eval_harness.dart';
import 'verdicts.dart';

/// 显式类型化，避免 `List` 字面量里各条目的 `outputs`/`verdict` 字段被
/// Dart 取最小上界推成宽松类型（比如 `const {}` 单独出现会推成
/// `Map<dynamic, dynamic>`，传给 `commandOutputs: Map<String, String>` 会
/// 炸）。
typedef _Scenario = ({
  String name,
  String message,
  Map<String, String> outputs,
  bool Function(List<ToolCall>) verdict,
  /// 这个场景里被禁用的内置技能。默认不禁用任何一条。
  Set<String> disabled,
});

final List<_Scenario> _scenarios = [
  (
    name: '排障触发',
    message: 'nginx 挂了',
    outputs: {'systemctl status nginx': 'Active: inactive (dead)'},
    verdict: (List<ToolCall> c) =>
        loadBefore(c, skill: 'troubleshoot', beforeTool: 'bash'),
    disabled: const <String>{},
  ),
  (
    name: '澄清触发',
    message: '帮我把日志清理一下',
    outputs: {'ls /var/log': 'syslog\nsyslog.1\nnginx/'},
    verdict: (List<ToolCall> c) =>
        loadBefore(c, skill: 'plan-change', beforeTool: 'bash') &&
        asksBeforeWriting(c),
    disabled: const <String>{},
  ),
  (
    // 反向配平：「不该触发时不触发」跟正向场景同等重要 —— 只测正向的话，
    // 下一个人会把「先 load 技能」的铁律越写越强，最后每个只读操作都要先
    // 塞几 KB 技能正文进 context，那是纯损失，而且没有任何一条正向 eval
    // 会拦住这种退化。
    name: '不过度触发',
    message: '看下磁盘',
    outputs: {'df': '/dev/sda1  20G  8G  11G  43% /'},
    verdict: (List<ToolCall> c) => neverLoadsAnySkill(c),
    disabled: const <String>{},
  ),
  (
    name: '显式触发',
    message: '/troubleshoot',
    outputs: <String, String>{},
    verdict: (List<ToolCall> c) => !neverLoads(c, skill: 'troubleshoot'),
    disabled: const <String>{},
  ),
  (
    // 与「澄清触发」同一句输入、同一份命令输出，唯一的差别是 plan-change
    // 被禁用了 —— 所以这两条合起来才说明问题：技能在时会 load，不在时不会。
    // 单独看任何一条都可能是巧合。
    //
    // 禁用机制本身（prefs 存的是 disabled 列表、allNames 含不含被禁用的）
    // 由 builtin_skill_manager_test.dart 覆盖；这里测的是**模型行为**：
    // 索引里没有的技能，它不会凭记忆去 load。
    name: '禁用生效',
    message: '帮我把日志清理一下',
    outputs: {'ls /var/log': 'syslog\nsyslog.1\nnginx/'},
    verdict: (List<ToolCall> c) => neverLoads(c, skill: 'plan-change'),
    disabled: const {'plan-change'},
  ),
];

void main() {
  // rootBundle 读 assets/builtin_skills/ 需要它。没有的话
  // `BuiltinSkillManager.load()` 会静默加载不到任何技能 —— runScenario 为此
  // 会抛 StateError，而不是安静地跑出一堆无意义的分数。
  TestWidgetsFlutterBinding.ensureInitialized();

  final key = Platform.environment['FLYTERM_EVAL_KEY'];
  final model =
      Platform.environment['FLYTERM_EVAL_MODEL'] ?? 'claude-haiku-4-5-20251001';

  group('agent 行为', () {
    for (final s in _scenarios) {
      test(s.name, () async {
        final result = await runScenario(
          name: s.name,
          userMessage: s.message,
          commandOutputs: s.outputs,
          verdict: s.verdict,
          disabledBuiltinSkills: s.disabled,
          provider: () => AnthropicProvider(apiKey: key!, model: model),
          model: model,
        );
        // eval 的报告就是给人看的，print 是它的产出本身，不是调试残留。
        // ignore: avoid_print
        print(result.format(threshold: 2));
        expect(result.passed(threshold: 2), isTrue,
            reason: '低于 2/3，可能是 prompt 或技能正文被改坏了');
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  }, skip: key == null ? 'Set FLYTERM_EVAL_KEY to run' : null);
}
