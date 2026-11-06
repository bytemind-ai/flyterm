import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

/// 一组共享的并发计数器 + 闸门。
///
/// ## 为什么不用 `Future.delayed` 把命令「拖住」一小会儿
///
/// 初版用的是 `await Future.delayed(5ms)`，靠这 5 毫秒让同批调用有机会
/// 重叠，然后量峰值。那是一场赛跑，而且**输了不报错、只是报出一个偏小的
/// 峰值** —— 实测本机负载下 `Future.delayed(1ms)` 的真实触发延迟在
/// 2–15ms 之间抖动，于是「5 条同时在飞」经常只量到 2 条，测试红得莫名其妙，
/// 而生产代码完全正确。
///
/// 换成闸门之后一个时间常量都不剩：每条命令进来就挂在自己的 `Completer`
/// 上，直到测试显式放行。「有几条同时在飞」不再是一个需要抢时间窗口去
/// 观测的瞬时量，而是一个稳定状态 —— 测试等到它稳定了再断言。
class _Gate {
  int inFlight = 0;
  int peak = 0;
  int started = 0;
  final List<Completer<void>> _pending = [];

  Future<void> enter() {
    started++;
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    final c = Completer<void>();
    _pending.add(c);
    return c.future.whenComplete(() => inFlight--);
  }

  /// 放行当前挂着的全部命令。
  void releaseAll() {
    final batch = List.of(_pending);
    _pending.clear();
    for (final c in batch) {
      if (!c.isCompleted) c.complete();
    }
  }

  /// 等到 [count] 条命令**同时**挂在闸门上，或超时。
  ///
  /// 超时不抛 —— 让随后的 `expect(peak, ...)` 去报错，那条消息比一个
  /// TimeoutException 有用得多（它会直接告诉你实际只起飞了几条）。
  Future<void> waitForInFlight(int count,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (inFlight < count && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

/// 所有目标机共用一个 [_Gate] —— 峰值本来就要跨机统计。
class _GatedRunner implements CommandRunner {
  final _Gate gate;
  final List<String> ran = [];

  _GatedRunner(this.gate);

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    await gate.enter();
    return const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0);
  }

  @override
  Future<void> dispose() async {}
}

AIResponse _bashCalls(List<(String id, String cmd, String? server)> specs) =>
    AIResponse(toolCalls: [
      for (final (id, cmd, server) in specs)
        ToolCall(id: id, name: 'bash', args: {
          'command': cmd,
          'description': 'why',
          if (server != null) 'server': server,
        }),
    ]);

List<ServerListEntry> _servers(int n) => [
      for (var i = 1; i <= n; i++)
        ServerListEntry(id: 'id$i', name: 'host$i', host: 'h$i', credsOk: true),
    ];

void main() {
  test('同一台机上仍然是 3 并发（零回归）', () async {
    final gate = _Gate();
    final runner = _GatedRunner(gate);
    final loop = makeLoop(
      provider: FakeProvider([
        _bashCalls([
          ('a', 'ps', null),
          ('b', 'ss -tln', null),
          ('c', 'uptime', null),
          ('d', 'df -h', null),
        ]),
        const AIResponse(text: 'done'),
      ]),
      runner: runner,
    );

    final done = loop.send('查一下');

    // 4 条全同机、per-target 上限 3 —— 应当恰好 3 条挂在闸门上，第 4 条
    // 等着补位。多等一会儿确认它**不会**变成 4。
    await gate.waitForInFlight(3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gate.inFlight, 3,
        reason: '全同机时 per-target 3 生效，第 4 条必须等着');
    expect(gate.peak, 3);

    gate.releaseAll();
    // 第 4 条补位后同样挂在闸门上，放行它才能收工。
    await gate.waitForInFlight(1);
    gate.releaseAll();
    await done;

    expect(runner.ran.length, 4);
    expect(gate.peak, 3, reason: '全程峰值不该超过 3');
  });

  test('5 台机各一条 → 5 条同时起飞（旧行为是 3+2 两批）', () async {
    final gate = _Gate();
    final loop = makeLoop(
      provider: FakeProvider([
        _bashCalls([
          for (var i = 1; i <= 5; i++) ('c$i', 'uptime', 'host$i'),
        ]),
        const AIResponse(text: 'done'),
      ]),
      runnersByServerId: {
        for (var i = 1; i <= 5; i++) 'id$i': _GatedRunner(gate),
      },
      servers: _servers(5),
      toolSpecs: () => fullToolSpecs,
    );

    final done = loop.send('五台都看看');

    await gate.waitForInFlight(5);
    expect(gate.peak, 5,
        reason: '5 台不同机器不该互相排队 —— 旧的批次屏障只会到 3');

    gate.releaseAll();
    await done;
  });

  test('抢跑配额也按目标机分离：跨机 5 条只读全部抢跑', () async {
    final gate = _Gate();

    // ## 为什么断言 `ToolMetrics.speculative` 而不是并发峰值
    //
    // 峰值量不出这件事。抢跑只放行 3 条时，剩下 2 条会在 StreamDone 之后
    // 由 `_executeRound` 的并行桶补上 —— 而并行桶已经是两层配额了，闸门把
    // 5 条全拦住，峰值照样是 5。**两种实现的峰值完全一样**，用峰值断言的
    // 测试对「抢跑配额有没有改成两层」这件事根本不敏感（实测：把
    // `_maybeSpeculate` 的配额退回单层全局，峰值断言依然全绿）。
    //
    // `speculative` 标记是唯一能分开这两条路径的信号：它只在
    // `_maybeSpeculate` 真的让这条调用在流式期间起飞时才置 true。
    final calls = [
      for (var i = 1; i <= 5; i++)
        ToolCall(id: 'c$i', name: 'bash', args: {
          'command': 'uptime',
          'description': 'why',
          'server': 'host$i',
        }),
    ];

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [
            for (final c in calls) ToolCallReady(c),
            StreamDone(AIResponse(toolCalls: calls)),
          ],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      runnersByServerId: {
        for (var i = 1; i <= 5; i++) 'id$i': _GatedRunner(gate),
      },
      servers: _servers(5),
      toolSpecs: () => fullToolSpecs,
    );

    final done = loop.send('五台都看看');

    await gate.waitForInFlight(5);
    gate.releaseAll();
    await done;

    final speculated = loop.metrics.turns
        .expand((t) => t.tools)
        .where((m) => m.speculative)
        .length;
    expect(speculated, 5,
        reason: '抢跑配额若仍是全局 3，只有 3 条会带 speculative 标记，'
            '另外 2 条要等到 StreamDone 之后才由并行桶发出');
  });
}
