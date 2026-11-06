// SPDX-License-Identifier: GPL-3.0-or-later
/// per-turn 耗时计量。**纯旁路** —— 任何一处采集失败都不该影响会话，
/// 调用方负责用 try/catch 包住（见 `AgentLoop._metric`）。
///
/// ## 为什么字段是可变的
///
/// 这个仓库大多数数据类是不可变的，这里刻意不是：一轮的指标分散在五个
/// 时刻到达（请求发出、首个 chunk、StreamDone、每个工具进出、轮末），
/// 做成不可变意味着每次都要整体重建再回写。`ToolCallEvent` 已经是同样的
/// 可变事件类（`output` / `exitCode` / `undone` 都是后填的），保持一致。
library;

import 'dart:convert';

/// 保留多少轮。超出丢最早的。
///
/// 与 `_kMaxEvents`（500）同思路：长会话里这是唯一不断长大的结构。
/// 200 轮远超 `maxTurns`（25）的单次上限，够覆盖一整段多次提问的会话。
const int kMaxTurnMetrics = 200;

/// 一次工具调用的耗时切片。
class ToolMetrics {
  final String tool;

  /// `'local'` | `'parallel'` | `'serial'`。
  final String bucket;

  /// 这条调用是否在流式期间抢跑过。
  bool speculative = false;

  /// 抢跑的结果是否被最终采用（false = 判据变了、丢弃重跑）。
  bool speculativeHit = false;

  /// 等用户点审批的时长。
  ///
  /// **绝不能并进 [execMs]。** 人类反应时间是几秒到几分钟，混进去之后
  /// 所有工具耗时数据全部作废 —— 一次「泡杯咖啡再点批准」会让 execMs
  /// 的中位数彻底失去意义。
  int waitApprovalMs = 0;

  /// 取连接（`AgentExecChannel.obtain`）的时长。
  int connMs = 0;

  /// 建 channel + 收流的时长。**不含** [waitApprovalMs]。
  int execMs = 0;

  /// 回填给模型的输出字节数。
  int outBytes = 0;

  ToolMetrics({required this.tool, required this.bucket});

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'bucket': bucket,
        if (speculative) 'speculative': true,
        if (speculative) 'speculativeHit': speculativeHit,
        if (waitApprovalMs > 0) 'waitApprovalMs': waitApprovalMs,
        if (connMs > 0) 'connMs': connMs,
        'execMs': execMs,
        'outBytes': outBytes,
      };

  /// 从 [toJson] 读回。坏数据返回 null（调用方跳过这一条）。
  ///
  /// 缺字段按 0 补：归档可能来自更早的版本。
  static ToolMetrics? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final tool = raw['tool'];
    final bucket = raw['bucket'];
    if (tool is! String || bucket is! String) return null;
    final m = ToolMetrics(tool: tool, bucket: bucket)
      ..speculative = raw['speculative'] == true
      ..speculativeHit = raw['speculativeHit'] == true
      ..waitApprovalMs = _intOf(raw['waitApprovalMs'])
      ..connMs = _intOf(raw['connMs'])
      ..execMs = _intOf(raw['execMs'])
      ..outBytes = _intOf(raw['outBytes']);
    return m;
  }
}

/// 宽容地取一个 int。缺字段 / 类型不对 / 负数都归 0。
///
/// 用在从归档恢复的路径上：那段数据可能来自更早的版本、或写盘时被截断，
/// 而一个畸形的数字不该让整段恢复失败。
int _intOf(Object? v) => v is int && v >= 0 ? v : 0;

/// 一轮的耗时与用量。
class TurnMetrics {
  final int turn;

  /// 请求发出 → 第一个 chunk 到达。
  int ttftMs = 0;

  /// 请求发出 → StreamDone。
  int streamTotalMs = 0;

  int inputTok = 0;
  int cachedTok = 0;
  int outputTok = 0;

  /// 这一轮的墙钟总时长。
  ///
  /// **已知限制**：`Stopwatch` 是单调时钟，不会因系统时钟调整而跳，但它
  /// 会把「app 切到后台」的时间一并算进来。分析导出数据时要记得这一层，
  /// 否则一次切后台会被看成一次超慢的轮次。
  int turnTotalMs = 0;

  /// 轮末的历史估算（`AgentLoop._estimateTokens()` 口径）。
  int historyTok = 0;

  /// 这一轮花在 `_compact()` 上的时间。0 = 没压缩。
  int compactMs = 0;

  /// 这一轮丢弃了几条工具输出。
  int dropCount = 0;

  /// 这一轮模型请求了几个工具调用。
  int toolCallCount = 0;

  /// 这一轮新建了几条 TCP 连接。**只在 developer mode 下有值**
  /// （`debugCountConnections`），平时恒为 0。
  ///
  /// 0 = 全程复用了已有连接，这正是 `kProviderIdleTimeout` 想达到的效果。
  int newConnCount = 0;

  final List<ToolMetrics> tools = [];

  TurnMetrics(this.turn);

  Map<String, dynamic> toJson() => {
        'turn': turn,
        'ttftMs': ttftMs,
        'streamTotalMs': streamTotalMs,
        'inputTok': inputTok,
        'cachedTok': cachedTok,
        'outputTok': outputTok,
        'turnTotalMs': turnTotalMs,
        'historyTok': historyTok,
        'toolCallCount': toolCallCount,
        if (compactMs > 0) 'compactMs': compactMs,
        if (dropCount > 0) 'dropCount': dropCount,
        if (newConnCount > 0) 'newConnCount': newConnCount,
        'tools': [for (final t in tools) t.toJson()],
      };

  /// 从 [toJson] 读回。坏数据返回 null（调用方跳过这一条）。
  ///
  /// 用在会话恢复上：`StoppedEvent` 那行收工总结要显示的数字来自
  /// `MetricsRecorder`，而 recorder 是 loop 的内存状态 —— 不落盘的话
  /// 会话一结束（loop dispose）总结就消失。见 `MetricsRecorder.fromJson`。
  static TurnMetrics? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final turn = raw['turn'];
    if (turn is! int) return null;
    final t = TurnMetrics(turn)
      ..ttftMs = _intOf(raw['ttftMs'])
      ..streamTotalMs = _intOf(raw['streamTotalMs'])
      ..inputTok = _intOf(raw['inputTok'])
      ..cachedTok = _intOf(raw['cachedTok'])
      ..outputTok = _intOf(raw['outputTok'])
      ..turnTotalMs = _intOf(raw['turnTotalMs'])
      ..historyTok = _intOf(raw['historyTok'])
      ..compactMs = _intOf(raw['compactMs'])
      ..dropCount = _intOf(raw['dropCount'])
      ..toolCallCount = _intOf(raw['toolCallCount'])
      ..newConnCount = _intOf(raw['newConnCount']);
    final tools = raw['tools'];
    if (tools is List) {
      for (final item in tools) {
        final tm = ToolMetrics.fromJson(item);
        if (tm != null) t.tools.add(tm);
      }
    }
    return t;
  }
}

/// 一次用户提问的合计，见 [MetricsRecorder.currentRunTotals]。
typedef RunTotals = ({int totalMs, int toolCalls, int tokens});

/// 环形缓冲：只留最近 [kMaxTurnMetrics] 轮。
class MetricsRecorder {
  final List<TurnMetrics> _turns = [];

  /// 单调递增，**不因裁剪而回退** —— 导出的数据要能看出中间丢过多少轮。
  int _nextTurn = 0;

  List<TurnMetrics> get turns => List.unmodifiable(_turns);

  TurnMetrics? get current => _turns.isEmpty ? null : _turns.last;

  /// 本次用户提问从哪个 turn 编号开始。
  ///
  /// **记编号不记下标**：环形缓冲裁剪时下标会整体前移，记下标的话一次长
  /// 提问跑满 [kMaxTurnMetrics] 之后边界就指到别人身上去了。
  int _runStartTurn = 0;

  /// 标记一次新的用户提问开始。由 `AgentLoop._run()` 在进入轮次循环前调用。
  void beginRun() => _runStartTurn = _nextTurn;

  /// 本次用户提问的合计。
  ///
  /// UI 上的「本轮」是「用户发一条消息到收到回答」，而 [TurnMetrics] 的粒度
  /// 是**一次 LLM 请求** —— 中间每次工具调用都要再发一次请求。直接显示
  /// [current]（最后一条）等于把「最后一步」当成「本轮」：那一步正是模型
  /// 给最终文本的那次，它没有工具调用，于是一次跑了 4 个工具的提问会显示成
  /// 「0 次调用」。这是 2026-09-15 的真机回归。
  ///
  /// [tokens] 的口径与既有显示保持一致：`inputTok + outputTok`，**不含**
  /// 缓存命中（那部分在面板底部的会话累计里单独显示）。
  RunTotals get currentRunTotals {
    var ms = 0, calls = 0, tok = 0;
    for (final t in _turns) {
      if (t.turn < _runStartTurn) continue;
      ms += t.turnTotalMs;
      calls += t.toolCallCount;
      tok += t.inputTok + t.outputTok;
    }
    return (totalMs: ms, toolCalls: calls, tokens: tok);
  }

  TurnMetrics startTurn() {
    final t = TurnMetrics(_nextTurn++);
    _turns.add(t);
    while (_turns.length > kMaxTurnMetrics) {
      _turns.removeAt(0);
    }
    return t;
  }

  /// 每轮一行 JSON。空记录器返回空串。
  String toJsonl() {
    final buf = StringBuffer();
    for (final t in _turns) {
      buf.writeln(jsonEncode(t.toJson()));
    }
    return buf.toString();
  }

  /// 用 [other] 的内容**替换**自己的。
  ///
  /// 给 `AgentLoop._restore` 用：`_metrics` 是 final 字段，而恢复发生在构造
  /// 期（`_restore` 从构造函数里调），此时记录器还是空的。替换而不是把
  /// `fromJson` 的结果赋回去，是为了不把 `_metrics` 改成可变字段 —— 它没有
  /// 任何其他写入点。
  void adopt(MetricsRecorder other) {
    _turns
      ..clear()
      ..addAll(other._turns);
    _nextTurn = other._nextTurn;
    _runStartTurn = other._runStartTurn;
  }

  /// 归档用的完整状态。
  ///
  /// 与 [toJsonl]（导出的每轮一行）不同：这里还要带上 [_nextTurn] 与
  /// [_runStartTurn] —— 它们的**值**决定了 `currentRunTotals` 的边界。
  /// 只存 `turns` 的话恢复出来的 recorder 会把新轮的编号从 0 重新开始，
  /// 而 `currentRunTotals` 靠 `t.turn >= _runStartTurn` 过滤 —— 编号错位
  /// 会让它把旧轮算进本次提问（或反过来全部过滤掉，显示 0）。
  Map<String, dynamic> toJson() => {
        'turns': [for (final t in _turns) t.toJson()],
        'nextTurn': _nextTurn,
        'runStartTurn': _runStartTurn,
      };

  /// 从 [toJson] 读回。
  ///
  /// **坏数据一律降级成空记录器，不抛。** 与 `AgentLoop._restore` 里逐项
  /// try/catch 的风格一致：会话恢复时单块坏数据不该毁掉整段归档。
  /// 单条坏轮次（不是 Map、缺 `turn`）跳过，好的那条保留。
  static MetricsRecorder fromJson(Object? raw) {
    final r = MetricsRecorder();
    if (raw is! Map) return r;

    final turns = raw['turns'];
    if (turns is List) {
      for (final item in turns) {
        final t = TurnMetrics.fromJson(item);
        if (t != null) r._turns.add(t);
      }
    }
    // 环形缓冲上限仍然生效：归档里万一有超额（旧版本写的、或被手工改过），
    // 恢复后不能留一个超出上限的列表。
    while (r._turns.length > kMaxTurnMetrics) {
      r._turns.removeAt(0);
    }

    // `_nextTurn` 取「存的値」与「实际最大轮号 + 1」的较大者。
    //
    // 只信存的值是不够的：`_nextTurn` 是单调递增的，而 `_turns` 会被环形
    // 缓冲裁剪 —— 一份保留了 200 轮、`_nextTurn` 已经到 500 的存档，两个
    // 数并存是正常的，但如果存的値因为任何原因偏小（旧版本没写这个字段、
    // 或被截断），取 max 仍然能保证新轮编号不重用。
    var next = _intOf(raw['nextTurn']);
    for (final t in r._turns) {
      if (t.turn + 1 > next) next = t.turn + 1;
    }
    r._nextTurn = next;

    // 边界：存的值合法就用它；否则当作「本次提问从最后一轮开始」，
    // 至少不会把整段历史都算进当前提问。
    final start = _intOf(raw['runStartTurn']);
    r._runStartTurn = start <= next ? start : next;
    return r;
  }
}
