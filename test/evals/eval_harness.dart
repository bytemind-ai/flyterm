// eval 的基础设施。**这个文件不是测试**，是被 eval 文件 import 的库。

import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/builtin_skill_index.dart';
import 'package:flyterm/ai/agent/builtin_skill_manager.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按命令返回预设输出的 runner。
///
/// ## 为什么不复用 `FakeRunner`
///
/// 那个是**按序**返回（`results` 是 List，用尽后重复最后一条），而 eval
/// 需要「这条命令返回这个、那条返回那个」—— 场景的全部意义就在于精确控制
/// 模型看到什么。改 `FakeRunner` 的行为会波及同目录几十个测试。
class MapRunner implements CommandRunner {
  /// 命令子串 → stdout。
  final Map<String, String> outputs;

  /// 执行过的命令，按顺序。
  final List<String> ran = [];

  /// 没有命中任何预设的命令。报告里会列出来 —— 「模型跑了预期外的命令」
  /// 是诊断时想知道的信息。
  final List<String> unmatched = [];

  MapRunner(this.outputs);

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    for (final entry in outputs.entries) {
      // 子串匹配而不是精确相等：模型总会加 `--no-pager`、`2>&1`、`| head`
      // 之类，精确匹配会让所有预设全部落空，场景失去意义。
      if (command.contains(entry.key)) {
        return CommandOutput(
            stdout: entry.value, stderr: '', exitCode: 0, timedOut: false);
      }
    }
    unmatched.add(command);
    // 空输出 + exit 0，不是 `command not found` —— 后者会把模型带进一条
    // 与被测行为无关的错误恢复路径。
    return const CommandOutput(
        stdout: '', stderr: '', exitCode: 0, timedOut: false);
  }

  @override
  Future<void> dispose() async {}
}

/// 从对话历史里按顺序抽出全部工具调用。
///
/// 数据源是 `AgentLoop.debugHistory` 而不是 `loop.events`：`ToolCallEvent`
/// 没有 args 字段，只有拼好的 `displayCommand` 文本。
List<ToolCall> extractToolCalls(List<AIMessage> history) => [
      for (final m in history)
        if (m.role == 'assistant')
          ...?m.toolCalls,
    ];

/// 一个场景跑 N 次的结果。
class ScenarioResult {
  final String name;

  /// 每次运行是否命中判据。
  final List<bool> runs;

  /// 用的哪个模型。**必须记** —— 不同模型的分数不可比，跨时间看趋势时
  /// 没有这个字段就是在比苹果和橘子。
  final String model;

  /// 每次运行的工具名序列，失败时打印用。
  final List<List<String>> transcripts;

  /// 第一次运行时**实际发给模型**的 system prompt。
  ///
  /// 记它有两个用处：诊断时能知道模型到底看到了什么；以及给
  /// 「prompt 是真实组装的」这件事一个护栏 —— 这里曾经是一个硬编码的
  /// `'eval prompt'` 占位串，导致四个场景测的都是「空 prompt 下模型会不会
  /// 碰巧调 load_skill」。`FakeProvider` 不读 prompt，单测照不出这件事。
  final String systemPrompt;

  const ScenarioResult({
    required this.name,
    required this.runs,
    required this.model,
    required this.transcripts,
    // 有默认值：打分与报告的单测不关心 prompt，不该被迫每处都填一个。
    this.systemPrompt = '',
  });

  int get hits => runs.where((r) => r).length;
  int get total => runs.length;
  String get score => '$hits/$total';

  bool passed({required int threshold}) => hits >= threshold;

  /// 一行结果；未达阈值时附上每次失败的实际调用序列。
  ///
  /// 通过时**不打印序列**：报告要能一眼扫完，全绿时的细节没人看。
  String format({required int threshold}) {
    final mark = passed(threshold: threshold) ? '✓' : '✗';
    final buf = StringBuffer('$mark $name  $score  [$model]');
    if (!passed(threshold: threshold)) {
      for (var i = 0; i < runs.length; i++) {
        if (runs[i]) continue;
        final t = i < transcripts.length ? transcripts[i] : const <String>[];
        buf.write('\n    run ${i + 1}: [${t.join(', ')}]');
      }
    }
    return buf.toString();
  }
}

/// 跑一个场景 [times] 次，返回打分结果。
///
/// [provider] 是个工厂而不是实例：每次运行都要全新的 loop 与全新的对话，
/// 复用会让第二次运行带着第一次的历史，测的就不是同一件事了。
///
/// `AgentLoop` 的必填参数照 `test/ai/agent/builtin_skill_wiring_test.dart`
/// 里的 `_buildLoop` 配平——不用 `_fakes.dart` 的 `makeLoop`，那个助手的
/// provider 参数类型写死了 `FakeProvider`，接不进真实 provider。
Future<ScenarioResult> runScenario({
  required String name,
  required String userMessage,
  required Map<String, String> commandOutputs,
  required bool Function(List<ToolCall>) verdict,
  required AIProvider Function() provider,
  required String model,
  int times = 3,
  int maxTurns = 6,

  /// 这个场景里**被禁用**的内置技能名。默认全部启用。
  ///
  /// 用来测「禁用之后模型不再 load 它」。注意这里测的是**模型行为**——
  /// 「技能不在索引里时它不会去 load」；禁用机制本身（prefs 的存储方向、
  /// `allNames` 含不含被禁用的）由 `builtin_skill_manager_test.dart` 覆盖，
  /// 两层不重复。
  Set<String> disabledBuiltinSkills = const {},
}) async {
  // 真实加载内置技能 —— system prompt 里的索引、`load_skill` 能取到的正文
  // 都来自这里。
  //
  // ## 这一段是整个 eval 成立的前提
  //
  // 早先这里是 `systemPromptProvider: (_) => 'eval prompt'` 一个硬编码字符
  // 串：模型看不到技能索引、看不到铁律、看不到任何行为约束，于是四个场景
  // 测的都是「模型在空 prompt 下会不会碰巧调 load_skill」，与生产行为毫无
  // 关系。而 `FakeProvider` 按脚本返回、根本不读 prompt，所以单测全绿也照
  // 不出这件事 —— 只有真跑一次才会发现。
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final builtin = BuiltinSkillManager(prefs);
  await builtin.load();

  // 一条都没加载到就**立刻炸**，不要静默往下走。
  //
  // `BuiltinSkillManager.load` 对加载失败的处理是「跳过并 debugPrint」——
  // 那对 App 是对的（一个坏文件不该让应用起不来），但对 eval 是致命的：
  // 技能没加载 → prompt 里没有索引 → 场景测的又是「空 prompt 下的行为」，
  // 而且照样绿。同一类「静默失效」这个文件里已经踩过一次（硬编码的
  // 'eval prompt'），不能再靠人眼去发现第二次。
  //
  // 最常见的原因是调用方忘了 `TestWidgetsFlutterBinding.ensureInitialized()`
  // —— 没有它 `rootBundle` 读不到 assets。
  if (builtin.all.isEmpty) {
    throw StateError(
      'eval 依赖内置技能，但一条都没加载到。'
      '多半是缺 TestWidgetsFlutterBinding.ensureInitialized()：'
      '没有它 rootBundle 读不到 assets/builtin_skills/，而 '
      'BuiltinSkillManager.load 对读取失败是静默跳过的。',
    );
  }

  for (final name in disabledBuiltinSkills) {
    await builtin.setEnabled(name, false);
  }

  final runs = <bool>[];
  final transcripts = <List<String>>[];
  var firstPrompt = '';

  for (var i = 0; i < times; i++) {
    final runner = MapRunner(commandOutputs);
    // `providerProvider` 被 `AgentLoop` **每一轮**都重新调用一次（不是只在
    // 构造时调一次） —— 生产实现靠这个拿到用户中途切换的模型。这里必须只
    // 调 [provider] 工厂一次、拿到单个实例后原样闭包返回，否则每一轮都会
    // 造出一个全新的 `FakeProvider`，脚本下标被打回 0，模型永远只说第一句。
    final providerInstance = provider();
    final loop = AgentLoop(
      providerProvider: () => providerInstance,
      runnerProvider: (_) => runner,
      rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
      modeProvider: () => PermissionMode.bypass,
      toolSpecsProvider: () =>
          agentToolSpecsFor(AgentToolTier.full, hasSkills: true),
      onRuleAdded: (_) {},
      // 用**真实的** prompt 组装，不是占位字符串：内置技能索引与那条铁律
      // （「有一点可能适用就先 load」）正是被测对象本身。
      systemPromptProvider: (inputs) => firstPrompt = buildAgentSystemPrompt(
        cwd: '/var/www',
        terminalContext: null,
        tier: AgentToolTier.full,
        mode: PermissionMode.bypass,
        builtinSkillIndex: composeBuiltinSkillIndex(builtin.entries),
        activeToolNames: inputs.activeToolNames,
        hasAtReference: inputs.hasAtReference,
      ),
      // 技能的三条接线。没有它们，`load_skill('troubleshoot')` 会回
      // 「没有这个技能」，模型试一次就放弃 —— 判据于是永远不命中。
      skillNamesProvider: () => builtin.names,
      skillBodyProvider: (name, {Set<String> alsoAllow = const {}}) async =>
          builtin.bodyOf(name),
      builtinSkillNamesProvider: () => builtin.allNames,
      maxTurns: maxTurns,
    );

    await loop.send(userMessage);
    final calls = extractToolCalls(loop.debugHistory);
    runs.add(verdict(calls));
    transcripts.add(calls.map((c) => c.name).toList());
  }

  return ScenarioResult(
    name: name,
    runs: runs,
    model: model,
    transcripts: transcripts,
    systemPrompt: firstPrompt,
  );
}
