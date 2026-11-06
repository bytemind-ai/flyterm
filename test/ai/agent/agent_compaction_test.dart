import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// 能分别脚本化「带工具的一轮」与「纯文本的摘要调用」的 provider。
class _CompactProvider extends FakeProvider {
  /// 摘要调用（`complete`）的返回值。抛出去的话模拟摘要失败。
  final Object summaryResult;

  /// `complete` 被调用了几次。摘要走的就是它。
  int summaryCalls = 0;

  _CompactProvider(super.script, {required this.summaryResult});

  @override
  Future<String> complete(List<AIMessage> messages) async {
    summaryCalls++;
    if (summaryResult is String) return summaryResult as String;
    throw summaryResult;
  }
}

/// 计划原文这里只灌大 `ToolResult`（孤儿消息，没有配对的 `ToolCall`）。
///
/// **为什么这里改成配对的 `ToolCall` + `ToolResult`，且 `ToolCall.args` 故意
/// 很大**：`_dropOldestOutput` 只替换 `ToolResult.content`，从不touch
/// `ToolCall.args`。如果历史里只有大 `ToolResult`（原计划的写法），把
/// `debugDropOldestOutput()` 调用到底之后，全部输出都变成几十字符的
/// marker，历史总量瞬间归零——既不会再超过 `_dropOldOutputsIfNeeded` 的
/// 0.8 阈值（`_compact` 根本不会被触发），`findCompactionCut` 也凑不够
/// `keepTokens` 走到一个非平凡的切点。摘要测试要验证的恰恰是「免费的丢弃
/// 手段用尽后」那个状态，所以历史里必须留一块丢不掉的东西——对应真实场景
/// 就是「一条很长的 shell 命令 / heredoc」：命令原文很长，即使输出被丢，
/// 参数本身依然占预算。
///
/// 另外，原计划的孤儿 `ToolResult` 本身也过不了「tool_use 都有
/// 配对 tool_result」这条自查（历史里根本没有对应的 `ToolCall`），配对写法
/// 顺带把这个问题也解决了。
const int _kBigArgsChars = 2100;
const int _kSmallResultChars = 300;

/// 造一条历史很长的 loop：塞满「长命令 + 小输出」配对的完整轮次。
///
/// **`tokenBudget=28000` 是 2026-09-15 token 估算器重新标定之后实测重新
/// 校准出来的**（原来是 20000，与旧的 `chars / 3.5` 估算器配套）。估算器
/// 改成内容感知的三段速率之后，`leanToolSpecs` 这条 28 轮历史 drop 到底的
/// 估算值实测 24929 token（不再是按 `chars/3.5` 手算的那个数），而旧的
/// `tokenBudget=20000` 会让 24929 > tokenBudget（100%）在轮次开头就直接
/// 硬停，压根走不到摘要——这正是本文件 4 条测试全红的原因。28000 让
/// 24929 落在 `[0.8×28000, 28000] = [22400, 28000]` 区间中段，两侧都留了
/// 约 10% 余量。
AgentLoop loadedLoop(FakeProvider provider,
    {int tokenBudget = 28000, int rounds = 28}) {
  final loop = AgentLoop(
    providerProvider: () => provider,
    runnerProvider: (_) => FakeRunner(),
    rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
    modeProvider: () => PermissionMode.bypass,
    onRuleAdded: (_) {},
    systemPromptProvider: (_) => 'test prompt',
    cwdProvider: () => '/tmp',
    toolSpecsProvider: () => leanToolSpecs,
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
  test('drop 还丢得动时不调摘要——便宜的手段优先', () async {
    // 这一轮模型直接给出最终文本、不调用工具——`_dropOldOutputsIfNeeded`
    // 的调用点在「执行完一轮工具调用之后」，没有工具调用的这一轮根本不会
    // 走到那个检查点，摘要自然不会被触发。
    final provider = _CompactProvider(
      [const AIResponse(text: 'done')],
      summaryResult: 'SUMMARY',
    );
    final loop = loadedLoop(provider);

    await loop.send('q');

    expect(provider.summaryCalls, equals(0));
  });

  test('drop 丢不动了且仍超阈值时，触发一次摘要', () async {
    final provider = _CompactProvider(
      [bashCall('r0', 'ps aux'), const AIResponse(text: 'done')],
      summaryResult: '已确认：nginx 在跑；已排除：端口冲突',
    );
    final loop = loadedLoop(provider);
    // 把所有工具输出都先丢掉，制造「丢不动了」的状态
    while (loop.debugDropOldestOutput()) {}

    await loop.send('q');

    expect(provider.summaryCalls, equals(1));
    final cards = loop.events.whereType<CompactedEvent>().toList();
    expect(cards.length, equals(1));
    expect(cards.single.summary, contains('已确认'));
  });

  test('摘要失败时 history 不变，会话继续跑到硬停', () async {
    final provider = _CompactProvider(
      [bashCall('r0', 'ps aux'), const AIResponse(text: 'done')],
      summaryResult: Exception('429 rate limited'),
    );
    final loop = loadedLoop(provider);
    while (loop.debugDropOldestOutput()) {}
    final before = loop.debugHistoryLength;

    await loop.send('q');

    // 恰好等于 1：压缩自本任务起改为与工具执行并发起飞
    // （`_maybeCompactConcurrently`，见 `agent_loop.dart`），但 `_compactedThisTurn`
    // 这面本轮旗子保证失败之后轮末 `_dropOldOutputsIfNeeded` 这道兜底不会
    // 再补发第二次——429 限流时再发一次只会火上浇油。一轮最多一次真实的
    // 摘要调用，失败就等下一轮再说。
    expect(provider.summaryCalls, equals(1));
    // 摘要失败不该改动历史，也不该产出摘要卡
    expect(loop.events.whereType<CompactedEvent>(), isEmpty);
    // 用户那句话与模型的回答会加进去，但压缩本身没有删掉任何东西
    expect(loop.debugHistoryLength, greaterThanOrEqualTo(before));
    expect(loop.stopReason, isNot(equals(AgentStopReason.error)));
  });

  test('压缩后 history 里每个 tool_use 都还有配对的 tool_result', () async {
    final provider = _CompactProvider(
      [bashCall('r0', 'ps aux'), const AIResponse(text: 'done')],
      summaryResult: 'SUMMARY',
    );
    final loop = loadedLoop(provider);
    while (loop.debugDropOldestOutput()) {}
    await loop.send('q');

    final useIds = <String>[];
    final resIds = <String>[];
    for (final m in loop.debugHistory) {
      for (final t in m.toolCalls ?? const <ToolCall>[]) {
        useIds.add(t.id);
      }
      for (final r in m.toolResults ?? const <ToolResult>[]) {
        resIds.add(r.callId);
      }
    }
    for (final id in resIds) {
      expect(useIds, contains(id), reason: '悬空的 tool_result: $id');
    }
  });

  test('system 消息永远是 history 的第一条', () async {
    final provider = _CompactProvider(
      [bashCall('r0', 'ps aux'), const AIResponse(text: 'done')],
      summaryResult: 'SUMMARY',
    );
    final loop = loadedLoop(provider);
    while (loop.debugDropOldestOutput()) {}
    await loop.send('q');

    expect(loop.debugHistory.first.role, equals('system'));
  });

  test('第二次触发是重摘，不是并排堆两份摘要', () async {
    final provider = _CompactProvider(
      [
        bashCall('r0', 'ps aux'),
        const AIResponse(text: 'r1'),
        bashCall('r1x', 'ps aux'),
        const AIResponse(text: 'r2'),
      ],
      summaryResult: 'SUMMARY',
    );
    final loop = loadedLoop(provider);
    while (loop.debugDropOldestOutput()) {}
    await loop.send('q1');

    // 再灌一批「长命令 + 小输出」，制造第二次压缩的条件。数量比 [loadedLoop]
    // 默认的 28 轮小：第一次压缩已经把历史收得很小，第二批不必再造出同等
    // 体量才能重新越过 0.8 阈值——量太大反而会在还没等到模型应答前就先
    // 撞上 `tokenBudget`（100%）硬停，那样这条测试验的就不是「重摘」而是
    // 「压根没触发」的假阳性。
    for (var i = 0; i < 20; i++) {
      loop.debugSeedToolCall(ToolCall(
        id: 'd$i',
        name: 'bash',
        args: {'command': 'y' * _kBigArgsChars},
      ));
      loop.debugSeedToolResult(
          ToolResult(callId: 'd$i', content: 'y' * _kSmallResultChars, exitCode: 0));
    }
    while (loop.debugDropOldestOutput()) {}
    await loop.send('q2');

    final summaries = loop.debugHistory
        .where((m) => m.content.contains('summary of the earlier part'))
        .length;
    expect(summaries, equals(1));
  });

  test('摘要卡进归档并能恢复', () async {
    final provider = _CompactProvider(
      [bashCall('r0', 'ps aux'), const AIResponse(text: 'done')],
      summaryResult: 'S',
    );
    final loop = loadedLoop(provider);
    while (loop.debugDropOldestOutput()) {}
    await loop.send('q');

    final restored = makeLoop(
      provider: FakeProvider([]),
      restoreFrom: loop.toArchive(),
    );
    expect(restored.events.whereType<CompactedEvent>().length, equals(1));
  });

  test('压缩之后，改过的文件出现在历史里的摘要消息中', () async {
    final provider = _CompactProvider(
      [bashCall('r0', 'ps aux'), const AIResponse(text: 'done')],
      summaryResult: 'SUMMARY',
    );
    final loop = AgentLoop(
      providerProvider: () => provider,
      runnerProvider: (_) => FakeRunner(),
      rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
      modeProvider: () => PermissionMode.bypass,
      onRuleAdded: (_) {},
      systemPromptProvider: (_) => 'test prompt',
      cwdProvider: () => '/tmp',
      toolSpecsProvider: () => leanToolSpecs,
      // 与 loadedLoop 同步重标定，理由见那边的 dartdoc。
      tokenBudget: 28000,
    );

    // 最早的一轮：edit_file 改了 /etc/nginx.conf —— 必须落在被压缩掉的
    // （更旧的）那段范围里，所以要在下面那批「长命令」之前先塞进去。
    loop.debugSeedToolCall(const ToolCall(
      id: 'edit0',
      name: 'edit_file',
      args: {'path': '/etc/nginx.conf', 'old_string': 'a', 'new_string': 'b'},
    ));
    loop.debugSeedToolResult(const ToolResult(
      callId: 'edit0',
      content: 'Edited /etc/nginx.conf at line 1.',
      exitCode: 0,
    ));

    // 同 loadedLoop：塞满「长命令 + 小输出」的完整轮次，制造「丢不动了仍
    // 超阈值」的状态，才能真正触发一次摘要压缩。
    for (var i = 0; i < 28; i++) {
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
    while (loop.debugDropOldestOutput()) {}

    await loop.send('q');

    final summaryMsg = loop.debugHistory
        .firstWhere((m) => m.content.contains('end of summary'));
    expect(summaryMsg.content, contains('<modified-files>'));
    expect(summaryMsg.content, contains('/etc/nginx.conf'));
  });
}
