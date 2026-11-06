import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';

import '_fakes.dart';

/// 摘要调用（`complete`）睡 150ms 并记录起止时间——用来跟工具执行的耗时窗口
/// 求交集。150ms 远大于测试运行环境下两次时间戳读取之间的开销，避免抖动把
/// 两段本该重叠的区间判成不重叠。
///
/// 摘要失败场景复用同一个类：[summaryResult] 是字符串就正常返回，是别的
/// 对象就抛出去——与 `agent_compaction_test.dart` 的 `_CompactProvider` 同构。
class _TimingProvider extends FakeProvider {
  final Object summaryResult;
  int summaryCalls = 0;
  DateTime? compactStart;
  DateTime? compactEnd;

  _TimingProvider(super.script, {required this.summaryResult});

  @override
  Future<String> complete(List<AIMessage> messages) async {
    summaryCalls++;
    compactStart = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    compactEnd = DateTime.now();
    if (summaryResult is String) return summaryResult as String;
    throw summaryResult;
  }
}

/// 睡 150ms 并记录起止时间的 runner——与 [_TimingProvider] 配对，让测试能
/// 断言「压缩」和「工具执行」这两段耗时在时间上确有重叠。
///
/// 用 `write_file` 而不是 `bash` 驱动它：`bash` 命中 allowlist 会被
/// `tool_partition.dart` 分进 parallel 桶，在 `StreamDone` 之前就被
/// `_maybeSpeculate` 抢跑执行——那样这个 runner 的起止时间就不再可靠地对应
/// `_executeRound` 的窗口了。`write_file` 按工具名被无条件排除出并行桶
/// （`partitionToolCals` 的文档注释：写文件有先后语义，不抢跑），因此永远
/// 走 `_executeRound` 里的正常串行路径，计时干净。
class _TimingRunner implements CommandRunner {
  DateTime? runStart;
  DateTime? runEnd;

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    runStart = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    runEnd = DateTime.now();
    return const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0);
  }

  @override
  Future<void> dispose() async {}
}

/// `write_file` 走的是「先写本地文件，再（在有 runner 的场景下）用命令落地」
/// 的哪条具体路径取决于 `_executeWriteFile`/`_runFileWrite` 的实现；这里只
/// 关心它最终会调用 `runnerProvider(...).run(...)`，所以直接用
/// `debugSeedToolCall`/`debugSeedToolResult` 把「已经跑完的历史」灌好，再用
/// 一条新的 `write_file` 调用去触发这一轮真正要执行、要计时的那次 run()。
AIResponse _writeFileCall(String id) => AIResponse(toolCalls: [
      ToolCall(id: id, name: 'write_file', args: {
        'path': '/tmp/concurrent_compaction_probe.txt',
        'content': 'x',
      }),
    ]);

const int _kBigArgsChars = 2100;
const int _kSmallResultChars = 300;

/// 造一条历史很长的 loop，参数与建法照抄 `agent_compaction_test.dart` 的
/// `loadedLoop`——同样的「长命令 + 短输出」配对手法，理由见那边的注释：
/// `_dropOldestOutput` 只替换 `ToolResult.content`，从不 touch
/// `ToolCall.args`，所以历史里必须留一块丢不掉的东西，才能在「免费手段用
/// 尽」之后仍然超阈值，走到 `_compact()`。
///
/// `tokenBudget=10400`、`rounds=8` 不是抄来的，是量出来的——2026-09-15
/// token 估算器重新标定之后，旧的 `chars / 3.5` 手算（原注释：8 轮 drop 到底
/// ≈ 16800 字符 ≈ 4800 token）不再对应实际估算值：估算器改成内容感知的
/// 三段速率之后，这里用的是 `fullToolSpecs`（比 `agent_compaction_test.dart`
/// 的 `leanToolSpecs` 多算一截工具 schema token），8 轮 drop 到底实测
/// history 部分 6915 token + 工具 schema 2717 token = **9632 token**。
///
/// 光让总量落在阈值区间还不够——`findCompactionCut` 还有一条独立的下限：
/// 从尾部往前按 `keepTokens = tokenBudget × 0.25` 回溯保留的那一段，剩下要
/// 丢的那一段（`gain`）必须 ≥ `kMinCompactionGain`(4000)。这条历史里每一
/// 「轮」约 865 token（大 `command` 参数 ~840 + drop 后的输出 marker ~25），
/// 之前试过 `tokenBudget=11000`（`keepTokens=2750`）会往回保留 4.5 轮，只剩
/// 3.5 轮（≈3460 token）可丢，正好卡在 4000 门槛之下，`findCompactionCut`
/// 判定收益不够直接返回 0——4 条测试全红但 `_maybeCompactConcurrently` 其实
/// 已经正确判断过阈值，只是 `_compact()` 内部又被这道独立下限挡住了。
/// `tokenBudget=10400`（`keepTokens=2600`）把回溯保留点往前推半轮，变成留 4
/// 轮、丢 5 轮（实测收益 4325 token），越过了下限；同时 9632 仍落在
/// `[0.8×10400, 10400] = [8320, 10400]` 区间中段，两头各留约 8%–13% 余量，
/// 且早于 `send()` 之前（drop 耗尽后）的预热估算 9609 也小于 10400，不会在
/// 轮次开头就被 `tokenBudget` 硬停。
AgentLoop _loadedLoop(
  FakeProvider provider, {
  required CommandRunner runner,
  int tokenBudget = 10400,
  int rounds = 8,
}) {
  final loop = AgentLoop(
    providerProvider: () => provider,
    runnerProvider: (_) => runner,
    rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
    modeProvider: () => PermissionMode.bypass,
    onRuleAdded: (_) {},
    systemPromptProvider: (_) => 'test prompt',
    cwdProvider: () => '/tmp',
    // 必须用 full 档而不是 lean（既有压缩测试用的默认档）——`write_file`
    // 只在 `fullToolSpecs`(`_extraFullToolSpecs`) 里注册。lean 档不认识这个
    // 工具名，`_executeOneInner` 会直接回一条 "Unknown tool" 错误，压根不
    // 创建 `ToolCallEvent`，更不会走到 runner——这里选 `write_file` 正是
    // 为了绕开抢跑，选错档会让这条调用在到达 runner 之前就被拒收。
    toolSpecsProvider: () => fullToolSpecs,
    tokenBudget: tokenBudget,
  );
  for (var i = 0; i < rounds; i++) {
    loop.debugSeedToolCall(ToolCall(
      id: 'c$i',
      name: 'bash',
      args: {'command': 'x' * _kBigArgsChars},
    ));
    loop.debugSeedToolResult(ToolResult(
      callId: 'c$i',
      content: 'x' * _kSmallResultChars,
      exitCode: 0,
    ));
  }
  return loop;
}

void main() {
  test('压缩与工具执行在时间上重叠', () async {
    final runner = _TimingRunner();
    final provider = _TimingProvider(
      [_writeFileCall('w0'), const AIResponse(text: 'done')],
      summaryResult: '已确认：探测完成',
    );
    final loop = _loadedLoop(provider, runner: runner);
    // 免费手段先用尽——与既有压缩测试同样的前置动作，制造「drop 已经丢不
    // 动了」的状态，这样 `send()` 一旦触发轮内检查就必然落到 `_compact()`。
    while (loop.debugDropOldestOutput()) {}
    // 记录一下实测的 token 估算值，方便调参数时确认没有跑偏（不是断言，只
    // 是给调试留的锚点——真正的断言在下面）。
    // ignore: avoid_print
    print('debugEstimateTokens after drop-exhaustion: '
        '${loop.debugEstimateTokens()} (tokenBudget=10400, threshold=8320)');

    final runnerStart = DateTime.now();
    await loop.send('q');
    final runnerEnd = DateTime.now();

    // 前置断言：确实发生过一次压缩，否则下面的区间相交断言就是空对空。
    final cards = loop.events.whereType<CompactedEvent>().toList();
    expect(cards.length, equals(1),
        reason: '压缩没有被触发，重叠断言无从谈起——多半是种子参数没能越过阈值');

    // 核心断言：两个时间区间相交，**不是**总耗时缩短了多少。
    //
    // 为什么不断言总耗时：见项目记忆 `project_test_false_positives.md`——
    // 墙钟总时长断言在冷启动抖动下会假阳性（这台机器偶尔慢那么一下，两段
    // 150ms 顺序执行也可能凑巧比另一台机器上并发执行还快）。区间相交只依赖
    // 相对顺序（谁先开始、谁先结束），不依赖绝对耗时，冷启动抖动不会让它
    // 时对时错。
    //
    // 串行实现下这条必然失败：`_compact()` 在 `await _dropOldOutputsIfNeeded()`
    // 里，严格晚于 `await _executeRound` 完成之后才会开始，两个区间不可能
    // 相交。
    expect(provider.compactStart, isNotNull);
    expect(provider.compactEnd, isNotNull);
    expect(runner.runStart, isNotNull);
    expect(runner.runEnd, isNotNull);
    final overlap = runner.runStart!.isBefore(provider.compactEnd!) &&
        provider.compactStart!.isBefore(runner.runEnd!);
    expect(overlap, isTrue,
        reason: '压缩窗口 [${provider.compactStart}, ${provider.compactEnd}] '
            '与工具执行窗口 [${runner.runStart}, ${runner.runEnd}] 未重叠——'
            '说明压缩仍在串行等待工具执行完成之后才开始');

    // 边界检查：两个动作确实都在 send() 的墙钟窗口内发生，不是巧合。
    expect(runnerStart.isAfter(runnerEnd), isFalse);
  });

  test('压缩失败时不写 errorMessage，会话照常收工', () async {
    final runner = _TimingRunner();
    final provider = _TimingProvider(
      [_writeFileCall('w0'), const AIResponse(text: 'done')],
      summaryResult: Exception('429 rate limited'),
    );
    final loop = _loadedLoop(provider, runner: runner);
    while (loop.debugDropOldestOutput()) {}

    await loop.send('q');

    // 摘要确实被尝试过（否则下面「没写 errorMessage」是无意义的真）。
    //
    // 恰好等于 1：`_compactedThisTurn` 这面本轮旗子保证并发压缩失败之后，
    // 轮末 `_dropOldOutputsIfNeeded` 这道兜底不会再补发第二次——429 限流
    // 时再发一次只会加剧限流，是本末倒置，不是「设计里明说的行为」（那是
    // 修复前的说法，本任务把它改掉了）。
    expect(provider.summaryCalls, equals(1));
    // 摘要失败是降级，不是会话终止性错误——`_compact()` 内部的 catch 有意
    // 不记 _errorMessage/_errorStack，这里断言那条约定没有被并发化破坏。
    expect(loop.errorMessage, isNull);
    expect(loop.events.whereType<CompactedEvent>(), isEmpty);
    expect(loop.stopReason, equals(AgentStopReason.completed));
  });

  test('压缩失败时一轮只调一次模型，不重复兜底', () async {
    // 专门针对本任务修复 2 的回归测试：并发压缩（`_maybeCompactConcurrently`）
    // 失败之后，轮末兜底（`_dropOldOutputsIfNeeded`）不应该再发起第二次真实
    // 的摘要调用。上面那条「压缩失败时不写 errorMessage」测试已经顺带验了
    // 这一点，这里单独写一条，把断言焦点直接放在调用次数上，不与
    // errorMessage/stopReason 等其他不变量混在一起。
    final runner = _TimingRunner();
    final provider = _TimingProvider(
      [_writeFileCall('w0'), const AIResponse(text: 'done')],
      summaryResult: Exception('429 rate limited'),
    );
    final loop = _loadedLoop(provider, runner: runner);
    while (loop.debugDropOldestOutput()) {}

    await loop.send('q');

    expect(provider.summaryCalls, equals(1),
        reason: '并发压缩失败（多半是 429 限流）之后，轮末兜底又发了一次'
            '真实的模型调用——这正是本任务要修的成本回归：为一次限流失败'
            '连发两次请求，只会让限流更严重。');
  });

  test('并发压缩后 tool_use 与 tool_result 仍然一一配对', () async {
    final runner = _TimingRunner();
    final provider = _TimingProvider(
      [_writeFileCall('w0'), const AIResponse(text: 'done')],
      summaryResult: '已确认：探测完成',
    );
    final loop = _loadedLoop(provider, runner: runner);
    while (loop.debugDropOldestOutput()) {}

    await loop.send('q');

    // 前置：确认这次真的压缩过——否则这条测试只是在重复既有压缩测试已经
    // 验过的「串行路径下配对不坏」，测不出并发化引入的风险。
    expect(loop.events.whereType<CompactedEvent>(), isNotEmpty);

    // 这是发线协议的硬约束：一条带 toolCalls 的消息之后必须紧跟一条
    // role == 'tool' 的消息，且 toolResults 数量与前一条的 toolCalls 数量
    // 相等——破坏它会在下一次真实请求上炸出 400。并发化把「append 助手
    // 消息」「跑 _compact（只碰 [1, cut) 那一段）」「append 工具结果」三件
    // 事的时序拆开了，这条测试确认拆开之后配对依然完整。
    final history = loop.debugHistory;
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final calls = m.toolCalls ?? const <ToolCall>[];
      if (calls.isEmpty) continue;
      expect(i + 1, lessThan(history.length),
          reason: '第 $i 条带 toolCalls 的消息之后没有下一条消息了——悬空的 tool_use');
      final next = history[i + 1];
      expect(next.role, equals('tool'),
          reason: '第 $i 条带 toolCalls 的消息之后紧跟的不是 tool 消息');
      expect(next.toolResults?.length, equals(calls.length),
          reason: '第 $i 条消息有 ${calls.length} 个 toolCalls，'
              '但紧跟的 tool 消息只有 ${next.toolResults?.length} 个 toolResults');
    }
  });
}
