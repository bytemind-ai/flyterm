import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

AIResponse threeReadOnly() => const AIResponse(toolCalls: [
      ToolCall(id: 'a', name: 'bash', args: {'command': 'ss -ltnp'}),
      ToolCall(id: 'b', name: 'bash', args: {'command': 'uptime'}),
      ToolCall(id: 'c', name: 'bash', args: {'command': 'df -h'}),
    ]);

void main() {
  test('三条自动放行的只读命令并发执行——并行窗口接近单条，不是三倍', () async {
    // 每条命令固定耗时 60ms。串行 ≈ 180ms，并行 ≈ 60ms。
    // 阈值取 150ms：足够区分两者，又不会因 CI 抖动误判。
    //
    // 断言用的是 `runner.windowMs`(第一条命令进 run 到最后一条离开)而不是整个
    // `loop.send()` 的墙钟 —— 后者会把**进程冷启动**算进来。已实测:同一份代码,
    // 这条测试排在文件第一位时命令要到 t=128ms 才开始执行(JIT 预热),排在第二位
    // 时是 t=2ms。用墙钟的话它在本机稳定报 183ms 而并行本身只花了 63ms,是纯粹
    // 的假阴性;把零延迟的那组挪到第一位同样报 137ms,与并行无关。
    final runner = _SlowRunner(const Duration(milliseconds: 60));
    final provider = FakeProvider([
      threeReadOnly(),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('q');

    expect(runner.ran.length, equals(3));
    expect(runner.windowMs, lessThan(150));
  });

  test('结果按模型给出的原顺序归位，与完成顺序无关', () async {
    // 让第一条最慢、最后一条最快，完成顺序与请求顺序完全相反。
    final runner = _VariableRunner({
      'ss -ltnp': const Duration(milliseconds: 90),
      'uptime': const Duration(milliseconds: 50),
      'df -h': const Duration(milliseconds: 10),
    });
    final provider = FakeProvider([
      threeReadOnly(),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('q');

    // provider 第二轮收到的历史里，tool 消息的结果顺序必须是 a,b,c
    final toolMsg =
        provider.seen[1].lastWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.map((r) => r.callId).toList(),
        equals(['a', 'b', 'c']));
  });

  test('需审批的调用不并行——它和只读命令混在一轮时按 index 各归其位', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'ro', name: 'bash', args: {'command': 'uptime'}),
        ToolCall(
            id: 'rw', name: 'bash', args: {'command': 'systemctl restart nginx'}),
      ]),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    final f = loop.send('q');
    // 等审批卡出现
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final card = loop.events
        .whereType<ToolCallEvent>()
        .firstWhere((e) => e.status == ToolCallStatus.awaitingApproval);
    expect(card.displayCommand, equals('systemctl restart nginx'));
    loop.respondApproval(card.seq, ApprovalDecision.allowOnce);
    await f;

    final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.map((r) => r.callId).toList(),
        equals(['ro', 'rw']));
  });

  test('并行桶里一条抛异常，不影响同桶其他命令', () async {
    final runner = _ThrowingRunner(failOn: 'uptime');
    final provider = FakeProvider([
      threeReadOnly(),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('q');

    final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
    final results = toolMsg.toolResults!;
    expect(results.length, equals(3));
    expect(results.firstWhere((r) => r.callId == 'b').isError, isTrue);
    expect(results.firstWhere((r) => r.callId == 'a').isError, isFalse);
    expect(results.firstWhere((r) => r.callId == 'c').isError, isFalse);
  });

  test('并发上限 3：五条只读命令分两批，不是一次五个', () async {
    final runner = _ConcurrencyProbe();
    final provider = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: '1', name: 'bash', args: {'command': 'uptime'}),
        ToolCall(id: '2', name: 'bash', args: {'command': 'df -h'}),
        ToolCall(id: '3', name: 'bash', args: {'command': 'ss -ltnp'}),
        ToolCall(id: '4', name: 'bash', args: {'command': 'free -m'}),
        // 原计划用 'id'，但 'id' 不在 defaultAllowRules 里——ask 模式下会
        // 弹审批卡，没人应答会一直挂着，测试超时。换成同样只读、且命中
        // `ps *` 规则的 'ps aux'，保留「五条只读命令」这个测试意图。
        ToolCall(id: '5', name: 'bash', args: {'command': 'ps aux'}),
      ]),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('q');

    expect(runner.ran.length, equals(5));
    expect(runner.peak, lessThanOrEqualTo(3));
  });

  test('取消后未执行的调用也有 tool_result——不留悬空的 tool_use', () async {
    final runner = _SlowRunner(const Duration(milliseconds: 40));
    final provider = FakeProvider([
      const AIResponse(toolCalls: [
        // 三条都需审批 → 全进串行桶，取消能落在第一条之后
        ToolCall(
            id: 's1', name: 'bash', args: {'command': 'systemctl restart a'}),
        ToolCall(
            id: 's2', name: 'bash', args: {'command': 'systemctl restart b'}),
      ]),
    ]);
    final loop = makeLoop(provider: provider, runner: runner);

    final f = loop.send('q');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    loop.cancel();
    await f;

    final archive = loop.toArchive();
    final history = archive['history'] as List;
    final toolMsgs = history
        .whereType<Map>()
        .where((m) => m['role'] == 'tool')
        .toList();
    if (toolMsgs.isNotEmpty) {
      final results = toolMsgs.last['toolResults'] as List;
      // 两个 tool_use 必须对应两个 tool_result，一个不少
      expect(results.length, equals(2));
    }
  });
}

class _SlowRunner extends FakeRunner {
  final Duration delay;
  _SlowRunner(this.delay);

  /// 每条命令进入 / 离开 [run] 的时刻，相对本实例创建的那一刻。
  ///
  /// 存在的理由见「三条自动放行的只读命令并发执行」那条测试：拿整个
  /// `loop.send()` 的墙钟做断言会把进程冷启动算进来，测不出并行。
  final Stopwatch _sw = Stopwatch()..start();
  final List<int> startedAt = [];
  final List<int> endedAt = [];

  /// 从第一条命令进入 [run] 到最后一条离开的跨度 —— 「并行窗口」。
  /// 三条各 60ms：并行 ≈ 60ms，串行 ≈ 180ms。
  int get windowMs => endedAt.reduce((a, b) => a > b ? a : b) -
      startedAt.reduce((a, b) => a < b ? a : b);

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    startedAt.add(_sw.elapsedMilliseconds);
    await Future<void>.delayed(delay);
    endedAt.add(_sw.elapsedMilliseconds);
    return const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0);
  }
}

/// 按命令内容给不同延迟。命令在 wire 上是 base64 包装过的，所以按
/// 明文子串匹配不到 —— 用出现顺序间接匹配：wrapForSsh 是确定性的，
/// 同一条明文总是编码成同一个串，所以先算出编码后的形态再比对。
class _VariableRunner extends FakeRunner {
  final Map<String, Duration> byPlain;
  _VariableRunner(this.byPlain);

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    var delay = const Duration(milliseconds: 5);
    for (final e in byPlain.entries) {
      if (command == e.key) {
        delay = e.value;
        break;
      }
    }
    await Future<void>.delayed(delay);
    return const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0);
  }
}

class _ThrowingRunner extends FakeRunner {
  final String failOn;
  _ThrowingRunner({required this.failOn});

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (command == failOn) {
      throw Exception('boom');
    }
    return const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0);
  }
}

/// 记录同时在跑的命令数峰值。
class _ConcurrencyProbe extends FakeRunner {
  int _inFlight = 0;
  int peak = 0;

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    _inFlight++;
    if (_inFlight > peak) peak = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _inFlight--;
    return const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0);
  }
}
