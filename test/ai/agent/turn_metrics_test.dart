import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/turn_metrics.dart';

import '_fakes.dart';

void main() {
  test('startTurn 递增 turn 序号', () {
    final r = MetricsRecorder();
    expect(r.startTurn().turn, 0);
    expect(r.startTurn().turn, 1);
    expect(r.turns.length, 2);
  });

  test('current 返回最后开启的那一轮', () {
    final r = MetricsRecorder();
    r.startTurn();
    final t = r.startTurn();
    expect(identical(r.current, t), isTrue);
  });

  test('空记录器的 current 是 null', () {
    expect(MetricsRecorder().current, isNull);
  });

  test('超过 kMaxTurnMetrics 时丢最早的，序号不回退', () {
    final r = MetricsRecorder();
    for (var i = 0; i < kMaxTurnMetrics + 5; i++) {
      r.startTurn();
    }
    expect(r.turns.length, kMaxTurnMetrics);
    expect(r.turns.first.turn, 5);
    expect(r.turns.last.turn, kMaxTurnMetrics + 4);
  });

  // 真机回归（2026-09-15）：一次提问跑了 4 个工具（activate_tools / mkdir /
  // upload / mv），收工总结却显示「本轮 2s · 0 次调用 · 135 token」。
  //
  // 数字本身没算错：`current` 是 `_turns.last`，而 turn 的粒度是**一次 LLM
  // 请求**。最后那次请求正是模型给最终文本的那一次，没有工具调用 —— 于是
  // 「最后一步」被当成了「本轮」显示出来。用户眼里的一轮是「发一条消息到
  // 收到回答」，跨越中间所有 LLM 请求。
  group('一次提问的聚合', () {
    test('只统计 beginRun 之后的轮次', () {
      final r = MetricsRecorder();
      // 上一次提问：不该被算进来。
      r.startTurn()
        ..turnTotalMs = 9000
        ..toolCallCount = 7
        ..inputTok = 500
        ..outputTok = 500;

      r.beginRun();
      r.startTurn()
        ..turnTotalMs = 3000
        ..toolCallCount = 3
        ..inputTok = 100
        ..outputTok = 20;
      // 末轮给最终文本，没有工具调用 —— 单看它就是那个「0 次调用」。
      r.startTurn()
        ..turnTotalMs = 2000
        ..toolCallCount = 0
        ..inputTok = 15
        ..outputTok = 120;

      final t = r.currentRunTotals;
      expect(t.toolCalls, 3);
      expect(t.totalMs, 5000);
      expect(t.tokens, 255);
    });

    test('没调过 beginRun 时统计全部 —— 恢复存档后不至于显示 0', () {
      final r = MetricsRecorder();
      r.startTurn()
        ..turnTotalMs = 1000
        ..toolCallCount = 2;

      expect(r.currentRunTotals.toolCalls, 2);
    });

    test('空记录器返回全 0，不抛', () {
      final t = MetricsRecorder().currentRunTotals;
      expect(t.toolCalls, 0);
      expect(t.totalMs, 0);
      expect(t.tokens, 0);
    });

    // 环形缓冲会把早期轮次丢掉，下标随之失效 —— 所以边界必须用 turn 编号
    // 记，不能记 `_turns.length`。
    test('裁剪掉起始轮之后仍然只算本次提问', () {
      final r = MetricsRecorder();
      r.beginRun();
      for (var i = 0; i < kMaxTurnMetrics + 5; i++) {
        r.startTurn().toolCallCount = 1;
      }
      expect(r.currentRunTotals.toolCalls, kMaxTurnMetrics,
          reason: '被裁掉的那 5 轮统计不到，但不能因此把边界算错');
    });
  });

  test('toJsonl 每轮一行合法 JSON', () {
    final r = MetricsRecorder();
    final t = r.startTurn()
      ..ttftMs = 120
      ..streamTotalMs = 900
      ..inputTok = 1000
      ..cachedTok = 800
      ..outputTok = 42
      ..turnTotalMs = 2000
      ..historyTok = 5000
      ..toolCallCount = 1
      ..compactMs = 0
      ..dropCount = 1;
    t.tools.add(ToolMetrics(tool: 'bash', bucket: 'parallel')
      ..execMs = 300
      ..outBytes = 1024);
    r.startTurn();

    final lines = r.toJsonl().trim().split('\n');
    expect(lines.length, 2);
    final first = jsonDecode(lines.first) as Map<String, dynamic>;
    expect(first['turn'], 0);
    expect(first['ttftMs'], 120);
    expect(first['cachedTok'], 800);
    expect(first['toolCallCount'], 1);
    expect((first['tools'] as List).first['tool'], 'bash');
    expect((first['tools'] as List).first['execMs'], 300);
  });

  test('ToolMetrics 默认值：没抢跑过就是 false/0', () {
    final m = ToolMetrics(tool: 'read_file', bucket: 'serial');
    expect(m.speculative, isFalse);
    expect(m.speculativeHit, isFalse);
    expect(m.waitApprovalMs, 0);
    expect(m.execMs, 0);
  });

  group('从归档恢复（会话结束后仍能显示统计）', () {
    test('toJson 能原样读回 —— 字段一个不少', () {
      final t = TurnMetrics(3)
        ..ttftMs = 420
        ..streamTotalMs = 3100
        ..inputTok = 8200
        ..cachedTok = 6000
        ..outputTok = 450
        ..turnTotalMs = 3500
        ..historyTok = 9000
        ..compactMs = 120
        ..dropCount = 2
        ..toolCallCount = 3
        ..newConnCount = 1;
      t.tools.add(ToolMetrics(tool: 'bash', bucket: 'serial')
        ..execMs = 120
        ..waitApprovalMs = 3000
        ..outBytes = 2048
        ..speculative = true
        ..speculativeHit = false);

      final back = TurnMetrics.fromJson(t.toJson())!;
      expect(back.turn, 3);
      expect(back.ttftMs, 420);
      expect(back.streamTotalMs, 3100);
      expect(back.inputTok, 8200);
      expect(back.cachedTok, 6000);
      expect(back.outputTok, 450);
      expect(back.turnTotalMs, 3500);
      expect(back.historyTok, 9000);
      expect(back.compactMs, 120);
      expect(back.dropCount, 2);
      expect(back.toolCallCount, 3);
      expect(back.newConnCount, 1);
      expect(back.tools, hasLength(1));
      expect(back.tools.single.tool, 'bash');
      expect(back.tools.single.execMs, 120);
      expect(back.tools.single.waitApprovalMs, 3000);
      expect(back.tools.single.speculative, isTrue);
    });

    test('MetricsRecorder 往返：轮次、序号、本次提问合计都对得上', () {
      final r = MetricsRecorder();
      // 第一次提问：2 轮
      r.beginRun();
      r.startTurn()
        ..inputTok = 100
        ..outputTok = 10
        ..toolCallCount = 1
        ..turnTotalMs = 50;
      r.startTurn()
        ..inputTok = 200
        ..outputTok = 20
        ..toolCallCount = 0
        ..turnTotalMs = 70;

      final before = r.currentRunTotals;
      final back = MetricsRecorder.fromJson(r.toJson());

      expect(back.turns, hasLength(2));
      expect(back.currentRunTotals, before,
          reason: '恢复后当前提问的合计必须一致 —— 否则收工总结会显示错的数');
      expect(back.currentRunTotals.toolCalls, 1);
      expect(back.currentRunTotals.tokens, 330);
      expect(back.turns.last.turn, 1,
          reason: '轮次编号要接上，否则后续 beginRun 的边界算错');
    });

    test('恢复后 startTurn 继续递增，不重用旧编号', () {
      final r = MetricsRecorder();
      r.startTurn();
      r.startTurn();

      final back = MetricsRecorder.fromJson(r.toJson());
      expect(back.startTurn().turn, 2,
          reason: '恢复后新轮必须拿新编号；重用会让 currentRunTotals 的边界错位');
    });

    test('空记录器往返仍是空', () {
      final back = MetricsRecorder.fromJson(MetricsRecorder().toJson());
      expect(back.turns, isEmpty);
      expect(back.currentRunTotals.toolCalls, 0);
    });

    test('坏数据不抛，降级成空记录器', () {
      // 归档可能来自更早的版本、或落盘时被截断。
      // 与 `_restore` 里逐项 try/catch 的风格一致：单块坏数据不该
      // 毁掉整段恢复。
      expect(MetricsRecorder.fromJson(null).turns, isEmpty);
      expect(MetricsRecorder.fromJson('not a map').turns, isEmpty);
      expect(MetricsRecorder.fromJson(const {'turns': 'nope'}).turns, isEmpty);
      // 单条坏轮次被跳过，好的那条保留
      final mixed = {
        'turns': [
          {'turn': 5, 'inputTok': 7},
          'garbage',
          {'nope': 1},
        ],
      };
      final back = MetricsRecorder.fromJson(mixed);
      expect(back.turns, hasLength(1));
      expect(back.turns.single.turn, 5);
      expect(back.turns.single.inputTok, 7);
    });

    test('缺字段的旧轮次按 0 补，不抛', () {
      final back = MetricsRecorder.fromJson(const {
        'turns': [
          {'turn': 1},
        ],
      });
      expect(back.turns.single.ttftMs, 0);
      expect(back.turns.single.tools, isEmpty);
    });
  });

  group('端到端：会话结束后统计不丢（用户报的那个问题）', () {
    // 用户报的现象：token 统计在会话期间显示，会话结束后就不显示了。
    //
    // 根因：收工总结那行的**容器**（StoppedEvent）进了归档，但总结里的
    // **数字**来自 AgentLoop 的 MetricsRecorder —— 那是内存状态，不落盘时
    // closeLoop/dispose 一发生就没了，新 loop 的 recorder 是空的，UI 那行
    // `metrics: null` 于是整行不渲染。
    //
    // 这两条用真实的 loop（不是裸 MetricsRecorder）走 toArchive/restore，
    // 是唯一能抓住「忘了在 toArchive 里加这一项」这个错误的层次。
    test('归档里现在带 metrics 这一项', () async {
      final loop = makeLoop(
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'bash', args: {
              'command': 'uptime', 'description': '看负载', 'server': 'web-1',
            }),
          ]),
          // 带上用量 —— 真实 provider 都会给，而 token 统计正是本用例要
          // 保护的那个数（`FakeProvider` 的默认 usage 是全 0）。
          const AIResponse(
              text: 'done',
              usage: TokenUsage(inputTokens: 8200, outputTokens: 450)),
        ]),
        runner: FakeRunner(),
        servers: const [
          ServerListEntry(id: 'id-1', name: 'web-1', host: 'h', credsOk: true),
        ],
        toolSpecs: () => fullToolSpecs,
      );
      await loop.send('查负载');

      final archive = loop.toArchive();
      expect(archive.containsKey('metrics'), isTrue,
          reason: '不带这一项，会话结束后收工总结就会消失');

      // 恢复出来的 loop 必须能看到本次提问的合计
      final restored = makeLoop(
          provider: FakeProvider([]), restoreFrom: archive);
      expect(restored.metrics.turns, isNotEmpty,
          reason: '恢复后 recorder 不该是空的');
      expect(restored.metrics.currentRunTotals.toolCalls, 1,
          reason: '这一轮跑了 1 个工具，恢复后仍要数得出来');
      expect(restored.metrics.currentRunTotals.tokens, 8650,
          reason: 'token 数要活下来 —— 那正是用户要看的那个数');

      loop.dispose();
      restored.dispose();
    });

    test('旧归档（没有 metrics 字段）恢复后不崩，只是没统计', () async {
      final loop = makeLoop(provider: FakeProvider([]));
      final archive = Map<String, dynamic>.of(loop.toArchive())
        ..remove('metrics');
      loop.dispose();

      final restored = makeLoop(
          provider: FakeProvider([]), restoreFrom: archive);
      expect(restored.metrics.turns, isEmpty);
      expect(restored.metrics.currentRunTotals.toolCalls, 0);
      restored.dispose();
    });
  });
}
