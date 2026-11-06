// SPDX-License-Identifier: GPL-3.0-or-later
import '../../../ai/agent/agent_loop.dart';
import '../../../l10n/app_localizations.dart';

/// 运行条的文案。
///
/// 抽成不依赖 [AgentLoop] 和 `BuildContext` 的纯函数，理由与当初把滑动
/// 窗口抽出来一样：这套分支值得单独锁死，而通过 widget 去
/// 驱动它需要先造出一个处在特定状态的 loop —— 那是在测别的东西。
///
/// [state] 只会是四个运行态之一：运行条由 `if (loop.isRunning)` 控制渲染，
/// 终态下根本不构建。为终态写分支是死代码，因此这里对它们一律回退到通用
/// 文案而不单独处理。
///
/// [elapsed] 为 null 表示「起点未知」（loop 刚构造、还没进过任何阶段），
/// 此时退回不带秒数的旧文案而不是显示 `0s` —— 后者是在断言一件我们并不
/// 知道的事。
String runningBarLabel(
  AppLocalizations l, {
  required AgentLoopState state,
  required Duration? elapsed,
  required List<String> runningCommands,
  required Duration? rateLimitRemaining,
  int runToolCalls = 0,
}) {
  final secs = elapsed?.inSeconds;

  // 本轮到目前为止的工具调用次数，作为后缀拼到下面几个「正在做事」的分支上。
  //
  // 只拼在后缀位置而不是自成一个分支：它回答的是「做了多少」，而运行条
  // 主干回答的是「卡在哪一阶段」—— 两者是并列信息，不是二选一。
  //
  // 0 次不拼：「已调用 0 次」是噪音（还没动手时读起来像出错）。
  final calls = runToolCalls > 0 ? l.agentRunningCalls(runToolCalls) : null;
  String withCalls(String base) => calls == null ? base : '$base · $calls';

  switch (state) {
    case AgentLoopState.rateLimited:
      // 向上取整：剩 0.4 秒时显示「0 秒后重试」比「1 秒」更让人困惑。
      // 与改动前的 _RunningBar 保持同一口径。
      return l.agentRateLimited(
          ((rateLimitRemaining?.inMilliseconds ?? 0) / 1000).ceil());

    case AgentLoopState.awaitingApproval:
      // 这段是人类时间，`ToolMetrics.waitApprovalMs` 在记账时都要
      // 把它排除掉，呈现层同理 —— 给它配一个走秒的计时器只会变成催促。
      return withCalls(l.agentAwaitingYou);

    case AgentLoopState.awaitingAnswer:
      // 与 awaitingApproval 同样是人类时间，不配走秒计时器（那只会变成
      // 催促）。文案分开：「等你确认」是批不批一个动作，「等你回答」是回答
      // 一个问题——点几个选项里的一个，或者自己打字——对用户是两件事。
      return withCalls(l.agentAwaitingAnswer);

    case AgentLoopState.thinking:
      return withCalls(
          secs == null ? l.agentThinking : l.agentThinkingFor(secs));

    case AgentLoopState.executing:
      if (secs == null) {
        // 起点未知，只说在执行，不编秒数。
        return withCalls(l.agentRunning);
      }
      // **不写具体命令。** 那条命令此刻正完整显示在工具卡上（带转圈和
      // 「已运行 N 秒」），运行条在它正下方重复一遍是冗余；而且运行条是
      // 单行、还要给 Stop 按钮让位，长命令必然被 ellipsis 砍掉尾部 ——
      // 而命令的信息量恰恰在尾部（路径、参数）。
      //
      // 职责划分：运行条回答「卡在哪个阶段」，工具卡回答「在跑什么」。
      // `awaitingApproval` 那档同样不写是哪条命令在等批准，此处一致。
      //
      // 唯一的例外是并行多条：那是卡片给不了的信息（用户得逐张数），
      // 所以报条数。
      if (runningCommands.length > 1) {
        return withCalls(l.agentExecutingMany(runningCommands.length, secs));
      }
      return withCalls(l.agentRunningFor(secs));

    case AgentLoopState.idle:
    case AgentLoopState.done:
    case AgentLoopState.cancelled:
    case AgentLoopState.failed:
      return l.agentRunning;
  }
}

/// 一轮墙钟时长的展示格式：`42s` / `3m42s`。
///
/// 不做「1h」档：`maxTurns` 是 25，跑到一小时的轮次不存在；真出现了显示
/// `73m5s` 也读得懂，比多一档分支划算。
String formatTurnDuration(int ms) {
  final total = ms ~/ 1000;
  final m = total ~/ 60;
  final s = total % 60;
  return m == 0 ? '${s}s' : '${m}m${s}s';
}
