// 触发判断与保留窗口判断必须用同一套速率。
//
// `estimateMessageChars` 的 dartdoc 从前用注释约定这件事；抽成共享实现之后
// 它是结构保证，但仍要钉一条 —— 结构保证也会被下一个人绕过去。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/token_estimate.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

void main() {
  test('工具 schema 计入估算 —— 它不在 _history 里，旧实现整段漏算', () async {
    final loop = makeLoop(
      provider: FakeProvider([const AIResponse(text: 'done')]),
      runner: FakeRunner(),
      mode: PermissionMode.bypass,
    );
    await loop.send('hi');

    // 工具 schema 实测 full 档 3739 token。这里只断言「非零且量级对得上」，
    // 不钉死具体值：工具清单会变，钉死会让加一个工具就红。
    final schema = estimateToolSchemaTokens(loop.debugToolSpecs());
    expect(schema, greaterThan(300),
        reason: '哪怕 lean 档 5 个工具，实测也有 1037 token');
    expect(loop.debugEstimateTokens(), greaterThan(schema),
        reason: '总估算必须包含 schema 那一项');
  });

  test('两个估算器口径一致 —— 触发判断与保留窗口判断用同一套速率', () async {
    // `estimateMessageChars` 的 dartdoc 从前用注释约定这件事，而本次改动
    // 差点就漏掉 compaction 那一半。抽成共享实现之后它是结构保证，这一条
    // 钉的是「结构保证没被下一个人绕过去」。
    final loop = makeLoop(
      provider: FakeProvider([const AIResponse(text: 'done')]),
      runner: FakeRunner(),
      mode: PermissionMode.bypass,
    );
    await loop.send('hi');

    final byMessage = loop
        .debugHistory
        .fold<int>(0, (a, m) => a + estimateMessageTokens(m));
    expect(loop.debugEstimateTokens(),
        equals(byMessage + estimateToolSchemaTokens(loop.debugToolSpecs())),
        reason: '_estimateTokens 必须恰好等于「逐条 estimateMessageTokens 之和'
            ' + 工具 schema」。不等就说明有一边偷偷用了别的速率');
  });

  test('真实 usage 当下界 —— 计算值低于真值时取真值', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        const AIResponse(
          text: 'done',
          usage: TokenUsage(inputTokens: 90000, cachedTokens: 10000),
        ),
      ]),
      runner: FakeRunner(),
      mode: PermissionMode.bypass,
    );
    await loop.send('hi');

    // 历史很短，计算值远小于 10 万；下界必须把它顶上去。
    expect(loop.debugEstimateTokens(), equals(100000),
        reason: 'totalInput = inputTokens + cachedTokens = 100000');
  });

  test('历史缩短时下界作废 —— 否则 _dropOldOutputsIfNeeded 的 while 卡死',
      () async {
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', 'journalctl -u nginx'),
        const AIResponse(
          text: 'done',
          usage: TokenUsage(inputTokens: 90000, cachedTokens: 10000),
        ),
      ]),
      runner: FakeRunner(),
      mode: PermissionMode.bypass,
    );
    await loop.send('go');
    expect(loop.debugEstimateTokens(), equals(100000), reason: '先确认地板在');

    // 丢掉一条工具输出 —— 历史变短了，那次真实测量不再对应当前历史。
    expect(loop.debugDropOldestOutput(), isTrue);
    expect(loop.debugEstimateTokens(), lessThan(100000),
        reason: '地板不作废的话，丢弃循环永远跨不过阈值：它会把能丢的全丢完，'
            '再白发一次 _compact 的真实调用，最后靠 guard 兜住');
  });

  test('服务端不给 usage 时完全走计算值 —— 地板保持 0', () async {
    // Ollama 与部分兼容端点确实不给 usage。这条是 `_estimateTokens` 不改成
    // 「只用真值」的全部理由，必须钉住。
    final loop = makeLoop(
      // 不带 usage 的 AIResponse —— TokenUsage 默认全 0
      provider: FakeProvider([const AIResponse(text: 'done')]),
      runner: FakeRunner(),
      mode: PermissionMode.bypass,
    );
    await loop.send('hi');

    final byMessage = loop
        .debugHistory
        .fold<int>(0, (a, m) => a + estimateMessageTokens(m));
    expect(loop.debugEstimateTokens(),
        equals(byMessage + estimateToolSchemaTokens(loop.debugToolSpecs())),
        reason: '地板为 0 时结果必须与纯计算值逐位相同，不能有任何兜底加成');
  });

  test('丢弃循环能收敛 —— guard 熔断器不该被用到', () async {
    // 这条与「地板作废」是同一个失败的两面：那条测的是地板降没降，
    // 这条测的是降了之后循环真的能出来。
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', 'journalctl -u nginx'),
        bashCall('c2', 'journalctl -u sshd'),
        const AIResponse(
          text: 'done',
          usage: TokenUsage(inputTokens: 90000, cachedTokens: 10000),
        ),
      ]),
      // 显式给一段够长的输出：`FakeRunner()` 默认的两字节 `'ok'` 会让
      // `[output dropped: N lines, exit 0]` 这条 marker 本身（约 34 字符）
      // 比原内容还长，第二次丢弃时估算值反而会涨 —— 那是 marker 开销在
      // 极短输出上的真实副作用，与本测试要盯的「地板作废」无关，用真实
      // 量级的日志输出把它排除掉。
      runner: FakeRunner(
        result: CommandOutput(
          stdout: 'Sep 14 11:20:01 host nginx[1234]: 127.0.0.1 - - '
                  '"GET /api/v1/items?page=3 HTTP/1.1" 200 4213\n' *
              10,
          stderr: '',
          exitCode: 0,
        ),
      ),
      mode: PermissionMode.bypass,
    );
    await loop.send('go');

    // 反复丢到没得丢，断言每一次都真的让估算值下降 —— 只要有一次没降，
    // while 循环在生产里就会空转到 guard 熔断。
    var prev = loop.debugEstimateTokens();
    while (loop.debugDropOldestOutput()) {
      final now = loop.debugEstimateTokens();
      expect(now, lessThan(prev),
          reason: '丢掉了东西但估算值没降 —— 这正是 while 卡死的形状');
      prev = now;
    }
  });
}
