// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math';

import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../background_job.dart';
import '../command_runner.dart';
import '../output_sanitizer.dart';
import '../server_targets.dart';
import '../tool_models.dart';
import '../tool_registry.dart';
import '../turn_metrics.dart';
import 'arg_parsing.dart';

/// `run_background` 回填给模型的开头。
///
/// 定义在这里而不是 `AgentLoop` 上，理由同 `kSkillBodyPrefix`：生产者是下面
/// 的 `runBackground`，loop 只在「这条旧输出能不能丢」那处反过来认它 ——
/// job id 只活在这句回填里，丢掉它模型就再也查不到那个任务。
const String kJobStartedPrefix = 'Started background job `';

/// 拼出 `run_background` 回填给模型的那条消息。
///
/// **抽成函数是为了让提取端能做逆操作。** `session_facts.dart` 要从这条
/// 消息里把 job id 抠回来；两边各写一份对文案的假设，改了文案就会静默
/// 失配。共用这一个函数之后，round-trip 测试能钉死这件事。
String buildJobStartedMessage(String jobId) =>
    '$kJobStartedPrefix$jobId`. It is running now. Use '
    '`check_job` with a large `wait` to read its output — do not poll '
    'in a tight loop.';

/// 后台任务两件事：起一个长跑命令、轮询它的进展。
///
/// 第三个搬进 `tool_executors/` 的域。它比 transfer 与 skill 多要了一样
/// 东西：`check_job` 能阻塞几十秒等日志，所以要向 [AgentToolContext] 借
/// 「等用户按停止」的唤醒点（`registerCancelWaiter`）。
class JobExecutors {
  final AgentToolContext ctx;

  /// job id 的随机部分来源。做成字段而不是每次 new 一个 —— 同一毫秒内起
  /// 两个 job 时，两个新建的 Random 可能拿到相同种子。
  final Random _random = Random();

  JobExecutors(this.ctx);

  /// 起一个后台任务。
  ///
  /// 审批走的是与 `bash` **完全相同**的那条路：对**原始 command** 做
  /// `checkCommand`（不是 `buildJobStartCommand` 的产物 —— 那串自带 `&&`
  /// 和 `;`，会让每条都判成 shellMetachar）。plan 模式下同样能「加入方案」。
  Future<ToolResult> runBackground(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final cmd = call.args['command'];
    if (cmd is! String || cmd.trim().isEmpty) {
      ctx.noteInvalidArgs();
      return ToolResult(
        callId: call.id,
        content: 'Invalid arguments: `command` is required and must be a '
            'non-empty string.',
        isError: true,
      );
    }
    ctx.resetInvalidArgs();
    final plain = cmd.trim();
    final desc = call.args['description'] is String
        ? call.args['description'] as String
        : '';

    final servers =
        await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
    final target = resolveServerTarget(call.args['server'], servers);
    if (!target.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: target.error!, isError: true);
    }

    // 跨机执行时没有当前目录的概念：远端新连接起点是 HOME，与
    // bash/read_file 一致（`_resolve` 里同样判 `target.isRemote`）。
    final cwd = target.isRemote ? null : ctx.cwdProvider?.call();
    final check = checkCommand(
      plain,
      rules: ctx.rulesProvider(),
      mode: ctx.modeProvider(),
      cwd: cwd,
    );

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: target.isRemote ? '[${target.serverName}] $plain' : plain,
      description: desc,
      check: check,
      targetServerName: target.serverName,
    );
    ctx.addEvent(ev);

    if (!preApproved && check.decision == ToolDecision.needApproval) {
      final outcome = await ctx.timedAwaitApproval(ev, tm);
      if (outcome.decision == ApprovalDecision.reject) {
        return ctx.rejectedResult(ev, outcome);
      }
      if (outcome.decision == ApprovalDecision.addToPlan) {
        return ctx.deferOrRejectFromApproval(ev, call, check);
      }
    }

    ev.status = ToolCallStatus.running;
    ctx.enterState(AgentLoopState.executing);

    // `now` 同时用于 `ev.startedAt`、job id 生成与
    // `BackgroundJobEvent.startedAtMs`。
    final now = DateTime.now();
    ev.startedAt = now;
    final jobId = newJobId(now, _random.nextInt(0x10000));
    // 清理与启动合成一条命令：省一次网络往返，且清理失败不能挡住启动
    // （buildJobCleanupCommand 自带 `|| true`）。
    final wire =
        '${buildJobCleanupCommand()}; ${buildJobStartCommand(jobId, plain)}';

    final CommandOutput out;
    try {
      out = await ctx.runnerProvider(target.serverId).run(wire, cwd: cwd);
    } catch (e, st) {
      ctx.noteToolError(st);
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = toolErrorForCard(e, st);
      ctx.notifyChanged();
      return ToolResult(
        callId: call.id,
        content: 'Failed to start background job: $e',
        isError: true,
      );
    }

    if (!out.isSuccess) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = formatForModel(out);
      ev.exitCode = out.exitCode;
      ctx.notifyChanged();
      // 起不来的常见原因是 home 不可写或磁盘满。如实回给模型，它可以退回
      // 用普通 bash 跑一个更短的命令。
      return ToolResult(
        callId: call.id,
        content: 'Failed to start background job:\n${ev.output}',
        isError: true,
        exitCode: out.exitCode,
      );
    }

    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.exitCode = 0;
    ev.output = 'started as $jobId';
    ctx.addEvent(BackgroundJobEvent(
      seq: ctx.nextSeq(),
      jobId: jobId,
      command: plain,
      description: desc,
      startedAtMs: now.millisecondsSinceEpoch,
      // 归属记在事件上，后续 check/kill 靠它找回同一台机器。
      serverId: target.serverId,
      serverName: target.serverName,
    ));
    ctx.notifyChanged();

    final startedMsg = buildJobStartedMessage(jobId);
    return ToolResult(
      callId: call.id,
      content: startedMsg,
      exitCode: 0,
    );
  }

  /// 轮询一个后台任务。
  ///
  /// **不走 `checkCommand`**：命令完全由 [buildJobPollCommand] 拼装，只读
  /// `$HOME/.flyterm/jobs` 下一个固定形状的文件名，没有任何用户/模型可控的
  /// 路径成分 —— 前提是 [isValidJobId] 先把 id 挡住，所以那个校验是这条路
  /// 的安全边界本身，不是防御性编程。
  ///
  /// 我们自己拼的机制命令不该弹审批卡——它不是模型的意图。
  Future<ToolResult> checkJob(ToolCall call) async {
    final raw = call.args['job_id'];
    final jobId = raw is String ? raw.trim() : '';
    if (!isValidJobId(jobId)) {
      ctx.noteInvalidArgs();
      return ToolResult(
        callId: call.id,
        content: 'Invalid `job_id`. Pass the exact id returned by '
            '`run_background`.',
        isError: true,
      );
    }
    ctx.resetInvalidArgs();

    final job = ctx.events
        .whereType<BackgroundJobEvent>()
        .where((e) => e.jobId == jobId)
        .lastOrNull;

    // 归属解析顺序：模型显式指定的 server > 任务事件记录的归属 > 当前会话。
    //
    // 中间这一档是关键 —— 起任务时的回填文案不含机器名，模型很容易漏掉
    // `server` 参数；漏了却仍然去轮询当前会话那台，得到的是一句「job 不存在，
    // 日志可能被清理了，别再查了」，把模型引向完全错误的根因，同时
    // `job.exitCode ??= -1` 会把还在跑的任务永久标记成已完成。
    final String? targetServerId;
    final String? targetServerName;
    if (call.args['server'] != null) {
      final servers =
          await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
      final target = resolveServerTarget(call.args['server'], servers);
      if (!target.ok) {
        ctx.noteInvalidArgs();
        return ToolResult(
            callId: call.id, content: target.error!, isError: true);
      }
      targetServerId = target.serverId;
      targetServerName = target.serverName;
    } else {
      // 事件上的归属就是这个变量的唯一来源；job 为 null（id 不认识）时
      // 保持 null，退回当前会话——与改动前的行为一致。
      targetServerId = job?.serverId;
      targetServerName = job?.serverName;
    }

    // since_line 以**我们记住的游标**为准，模型给的值只作为兜底。
    // 模型经常把它忘掉或给错，而重复回填同一段日志既费 token 又让它困惑。
    final since = job?.lineCursor ??
        asPositiveInt(call.args['since_line'], 0, allowZero: true);
    final wait = asPositiveInt(call.args['wait'], 30, allowZero: true)
        .clamp(0, kMaxJobWaitSeconds);

    ctx.enterState(AgentLoopState.executing);
    // 必须先注册等待者，再发起那次可能阻塞 90 秒的调用——`onRun` 一类的
    // 同步回调（包括真实场景里几乎同时发生的用户点击取消）可能在
    // `runnerProvider().run(...)` 返回的 Future 完成之前就已经跑到
    // `cancel()`；`registerCancelWaiter` 若晚一步调用，那次唤醒就找不到人接，
    // 于是仍然要等满 [kJobPollTimeout]。
    final waiter = Completer<void>();
    ctx.registerCancelWaiter(waiter);
    final CommandOutput? out;
    try {
      final runFuture = ctx.runnerProvider(targetServerId).run(
        buildJobPollCommand(jobId, since, wait),
        // 跨机没有「当前目录」的概念：远端新连接起点是 HOME，与 bash/
        // read_file 一致（`runBackground` 同样判 `isRemote`）。
        cwd: targetServerId == null ? ctx.cwdProvider?.call() : null,
        // 轮询要在远端阻塞最多 60 秒，20 秒的默认预算会先把它杀掉。
        timeout: kJobPollTimeout,
        // 后台任务的输出就是日志 —— 正是去噪收益最高的那一类（实测同形状的
        // 应用日志省 56%）。
        //
        // 这里单独传，而不是跟 `bash` 一样走 `_Resolved.denoise`：`check_job`
        // 不经过 `agent_loop` 的 `_resolve`，它在顶级 switch 里直接分派到这个
        // 方法，命令由 `buildJobPollCommand` 自己拼。
        denoise: true,
        // 同样绕开 `_resolve`，所以这里也要单独标。轮询输出就是日志：刚发生
        // 的事在尾部，而任务是怎么起来的在头部，两端都要。
        truncate: TruncateMode.middle,
      );
      // `Future.any` 只保证第一个完成的分支被用作结果，不保证「输」的那个
      // 分支的错误会被消费——如果 waiter 先完成（用户取消），真正的远端
      // 调用仍在跑，它之后若抛错就会变成一次没人接住的 zone 异常。做法与
      // `SshCommandRunner.run` 里 `unawaited(collect.catchError(...))` 那处
      // 同一个理由：显式接住，转成一个占位结果，反正它不会被用到。
      unawaited(runFuture.catchError((_) => const CommandOutput(
            stdout: '',
            stderr: '',
            exitCode: -1,
            timedOut: true,
          )));
      out = await Future.any<CommandOutput?>([
        runFuture.then<CommandOutput?>((v) => v),
        waiter.future.then<CommandOutput?>((_) => null),
      ]);
    } catch (e, st) {
      ctx.noteToolError(st);
      return ToolResult(
        callId: call.id,
        content: 'Failed to check job: $e',
        isError: true,
      );
    } finally {
      ctx.unregisterCancelWaiter();
    }

    if (out == null) {
      // 被 cancel() 唤醒——远端那次轮询请求仍在跑（见上面的
      // unawaited/catchError），我们只是不再等它。据实告诉模型：任务本身
      // 没有停，只是这次工具调用被打断了。
      return ToolResult(
        callId: call.id,
        content: 'Cancelled while waiting for job output. The job itself is '
            'still running on the server.',
        isError: true,
      );
    }

    final poll = parseJobPoll(out);
    if (poll.notFound) {
      job?.exitCode ??= -1;
      ctx.notifyChanged();
      return ToolResult(
        callId: call.id,
        content: targetServerName == null
            ? 'Job `$jobId` was not found on the server. Its log may have '
                'been cleaned up, or the server restarted. Do not check it '
                'again.'
            // 跨机时点名机器：不点的话模型无法判断到底是「任务真没了」还是
            // 「这次又打错了机器」，而这两种处境的下一步动作正好相反。
            // 本机（serverName 为 null）用与改动前**逐字相同**的文案，
            // 既有的本机用例不受影响。
            : 'Job `$jobId` was not found on `$targetServerName`. Its log may '
                'have been cleaned up, or the server restarted. Do not check '
                'it again.',
        isError: true,
      );
    }

    if (job != null) {
      if (poll.totalLines != null) job.lineCursor = poll.totalLines!;
      job.appendTail(poll.newOutput);
      job.exitCode = poll.exitCode;
      // 这一行就是「确认」。无论任务是否已结束都要写：结束时写它，是为了
      // 让终态卡上的时间也有据可查。
      job.lastCheckedAtMs = DateTime.now().millisecondsSinceEpoch;
      ctx.notifyChanged();
    }

    final status = poll.running
        ? 'still running'
        : 'finished with exit code ${poll.exitCode}';
    final body = poll.newOutput.isEmpty ? '(no new output)' : poll.newOutput;
    return ToolResult(
      callId: call.id,
      content: 'Job `$jobId` is $status.\n'
          'lines: ${poll.totalLines ?? since}\n'
          '--- new output ---\n$body',
      exitCode: poll.exitCode,
    );
  }

  /// 列出这台机器上的后台任务。
  ///
  /// **不弹审批。** 命令由我们自己拼、只读固定目录，没有任何模型可控的参数
  /// 进入命令 —— 与 `check_job` 刻意不走 `checkCommand` 是同一个理由。
  ///
  /// 存在的理由是「孤儿任务」：job id 只活在模型上下文里，一次压缩或一次
  /// App 重启之后它就再也查不到那个任务了，而任务还在远端跑着。有了这个
  /// 工具，模型能自己把 id 找回来。
  ///
  /// ## 为什么省略 `server` 时是「当前会话那台」而不是像 `check_job` 那样回退
  ///
  /// `check_job` 有 job 归属可查（事件上记着 serverId），漏报 `server` 还能
  /// 自动纠正；`list_jobs` 列的是「这台机器上的**所有**任务」，没有单个 id
  /// 可回退，因此省略即当前会话 —— 与 `bash` 同一个语义。把它做成必填反而
  /// 让最常见的「看看本机有什么」多绕一步。
  ///
  /// **注意：这只在绑定式会话（`requireExplicitServer=false`）成立。**
  /// 全局会话（不挂任何机器）下 `server` 是必填（`_withRequiredServer` 与
  /// 其他带 `server` 的工具一视同仁地处理它），schema 会直接拒绝不带
  /// `server` 的调用。上面那句「省略即当前会话」讲的是绑定式会话下的语义，
  /// 不是「`list_jobs` 永不检查 server」。
  Future<ToolResult> listJobs(ToolCall call, {ToolMetrics? tm}) async {
    final servers =
        await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
    final target = resolveServerTarget(call.args['server'], servers);
    if (!target.ok) {
      ctx.noteInvalidArgs();
      return ToolResult(
          callId: call.id, content: target.error!, isError: true);
    }
    // 与 `runBackground` / `checkJob` 一致：参数一旦解析通过就把累加器清零。
    // 漏掉它的话，一次机器名笔误会让 `_consecutiveInvalidArgs` 在本轮剩余
    // 时间里保持累加（阈值 3），后续几次无害的调用叠上去就可能触发那个
    // 「你连着几次参数不对」的收尾——惩罚的是已经改对的一轮。
    ctx.resetInvalidArgs();

    ctx.enterState(AgentLoopState.executing);
    final CommandOutput out;
    try {
      out = await ctx.runnerProvider(target.serverId).run(
            buildJobListCommand(),
            // 跨机没有「当前目录」的概念：远端新连接起点是 HOME，与
            // bash/read_file/runBackground 一致。
            cwd: target.isRemote ? null : ctx.cwdProvider?.call(),
          );
    } catch (e, st) {
      ctx.noteToolError(st);
      return ToolResult(
        callId: call.id,
        content: 'Failed to list jobs: $e',
        isError: true,
      );
    }
    return ToolResult(
      callId: call.id,
      content: formatJobList(parseJobList(out)),
    );
  }
}
