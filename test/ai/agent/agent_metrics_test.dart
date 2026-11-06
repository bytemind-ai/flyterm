import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';
import '../../sftp/sftp_transfer_task_test.dart' show FakeTransferOps;

void main() {
  test('等审批的时间不计入 execMs', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      bashCall('c1', 'rm -rf /tmp/x'),
      const AIResponse(text: 'done'),
    ]);
    // 默认 ask 模式：'rm -rf /tmp/x' 不在 defaultAllowRules 里，必弹审批。
    final loop = makeLoop(provider: provider, runner: runner);

    final f = loop.send('clean up');
    // 等审批卡真正出现，而不是猜一个固定延迟——`_awaitApproval` 是异步
    // 挂起的，出现时机取决于事件循环调度。
    while (loop.pendingApprovals.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    // 模拟用户「泡杯咖啡再点批准」：这段时长必须只进 waitApprovalMs，
    // 绝不能混进 execMs（FakeRunner 自己只睡 1ms）。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);
    await f;

    final tm = loop.metrics.turns.first.tools.single;
    expect(tm.waitApprovalMs, greaterThanOrEqualTo(180));
    // 与 waitApprovalMs 比，不与一个常数比。
    //
    // 这里原本是 `lessThan(100)` —— 100 只是「FakeRunner 睡的 1ms」与「模拟
    // 用户思考的 200ms」之间随手取的中点，它把「execMs 不含审批时长」这条
    // 断言绑在了机器有多快上。冷启动（VM 预热）时 execMs 实测能到 114–141ms，
    // 于是这条会在与它无关的改动里随机变红，两次被误判成回归。
    //
    // 相对比较表达的是这条测试真正要说的因果：审批那段时间如果混进了
    // execMs，execMs 必然 >= waitApprovalMs。抓 bug 的能力没降低，反而更直接。
    expect(tm.execMs, lessThan(tm.waitApprovalMs));
  });

  test('不需审批的调用 waitApprovalMs 为 0', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      bashCall('c1', 'uptime'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
        provider: provider, runner: runner, mode: PermissionMode.bypass);

    await loop.send('how long has it been up');

    final tm = loop.metrics.turns.first.tools.single;
    expect(tm.waitApprovalMs, equals(0));
    expect(tm.execMs, greaterThanOrEqualTo(0));
  });

  test('每轮产生一条 TurnMetrics，并记下 usage', () async {
    final p = FakeProvider([
      const AIResponse(
        text: 'all good',
        usage: TokenUsage(inputTokens: 1200, cachedTokens: 900, outputTokens: 30),
      ),
    ]);
    final loop = makeLoop(provider: p, runner: FakeRunner());

    await loop.send('status?');

    expect(loop.metrics.turns.length, equals(1));
    final m = loop.metrics.turns.single;
    expect(m.inputTok, equals(1200));
    expect(m.cachedTok, equals(900));
    expect(m.outputTok, equals(30));
    expect(m.turnTotalMs, greaterThanOrEqualTo(0));
    expect(m.historyTok, greaterThan(0));
  });

  test('两轮工具调用产生两条 TurnMetrics', () async {
    final p = FakeProvider([
      bashCall('c1', 'systemctl status nginx'),
      const AIResponse(text: 'nginx is down'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    await loop.send('why 502?');

    expect(loop.metrics.turns.length, equals(2));
    expect(loop.metrics.turns.first.toolCallCount, equals(1));
    expect(loop.metrics.turns.last.toolCallCount, equals(0));
  });

  test('write_file 的等审批时长不计入 execMs', () async {
    // write_file 永远需要审批（既有的安全决策，没有任何参数组合能免审批），
    // 所以这是「修复 1」里受影响最重的一个工具：修复前它的 execMs 恒被人类
    // 反应时间污染，恒为无意义值。
    //
    // toolSpecsProvider 必须换成 fullToolSpecs —— write_file 只在
    // fullToolSpecs 里声明，leanToolSpecs（`makeLoop` 的默认档）不认识它，
    // `_executeOneInner` 会直接回 "Unknown tool"，压根不会创建
    // `ToolCallEvent`，更不会走到这里要测的审批与执行路径。
    final runner = FakeRunner(
        result: const CommandOutput(stdout: '', stderr: '', exitCode: 0));
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.readOnly,
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'write_file', args: {
            'path': '/tmp/probe.txt',
            'content': 'hi',
            'description': '写探针文件',
          }),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );

    final f = loop.send('write it');
    while (loop.pendingApprovals.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // 模拟用户「泡杯咖啡再点批准」，与 bash 那条测试同一个手法。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);
    await f;

    final tm = loop.metrics.turns.first.tools.single;
    expect(tm.waitApprovalMs, greaterThanOrEqualTo(180));
    expect(tm.execMs, lessThan(tm.waitApprovalMs));
  });

  test('download_file 的等审批时长同样不计入 execMs，且 outBytes 有填', () async {
    // 挑一个传输类的工具复核：`tm` 的透传不是只对 write_file 一个工具
    // 做对了，而是所有会审批的 executor 都覆盖到了。
    final tmp = await Directory.systemTemp.createTemp('flyterm_metrics_dl');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final ops = FakeTransferOps()
      ..statSize = 5
      ..chunks = [
        [65, 66, 67, 68, 69]
      ]; // "ABCDE"
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      sftpOpsProvider: () async => ops,
      downloadDirProvider: () async => tmp,
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'd1', name: 'download_file', args: {
            'remote_path': '/var/log/app.log',
            'description': '把日志拉下来',
          }),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );

    final f = loop.send('拉日志');
    while (loop.pendingApprovals.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);
    await f;

    final tm = loop.metrics.turns.first.tools.single;
    expect(tm.waitApprovalMs, greaterThanOrEqualTo(180));
    expect(tm.execMs, lessThan(tm.waitApprovalMs));
    expect(tm.outBytes, greaterThan(0),
        reason: '回填给模型的下载结果消息应该被记进 outBytes');
  });

  test('ttft 与 streamTotal 在流式路径上被记录', () async {
    final p = FakeProvider([], streamScript: [
      <AgentChunk>[
        const TextDelta('查一下 '),
        const TextDelta('nginx'),
        const StreamDone(AIResponse(text: '查一下 nginx')),
      ],
    ]);
    final loop = makeLoop(provider: p, runner: FakeRunner());

    await loop.send('why 502');

    final m = loop.metrics.turns.single;
    expect(m.ttftMs, greaterThanOrEqualTo(0));
    expect(m.streamTotalMs, greaterThanOrEqualTo(m.ttftMs));
    // FakeProvider 不产生真实连接，debugCountConnections 也没打开——
    // 恒为 0 是正确的默认行为。
    expect(m.newConnCount, 0);
  });

  test('失败的调用同样计入 outBytes —— 失败消息也发给模型、也烧 token', () async {
    // 这条守的是一个真实的口径不一致：`outBytes` 原先由七个 executor 各自
    // 在「成功返回」那一行填，于是所有失败分支恒为 0；而 `bash` 那条路
    // 在 exit != 0 时照样计入 stderr。同一个字段对不同工具含义不同，分析
    // 「这条调用为什么让历史突然变大」时，一次输出很大但最终失败的操作
    // 会被误读成零输出。
    //
    // 现在统一在 `_executeOne` 外层从 `ToolResult.content` 取长度，这条
    // 测试就是它的守卫：用一条**必然失败**的命令，断言 outBytes 仍非零。
    final loop = makeLoop(
      runner: FakeRunner(
        result: const CommandOutput(
          stdout: '',
          stderr: 'cat: /nope: No such file or directory',
          exitCode: 1,
        ),
      ),
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'bash', args: {
            'command': 'cat /nope',
            'description': '读一个不存在的文件',
          }),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );

    await loop.send('go');

    final tm = loop.metrics.turns.first.tools.single;
    expect(tm.outBytes, greaterThan(0),
        reason: '失败的回填内容（含 stderr 与 exit code）同样占 token，'
            '不该被记成零输出');
  });
}
