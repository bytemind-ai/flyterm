// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ai/agent/background_job.dart';
import '../../ai/agent/command_runner.dart';
import '../../data/models/server.dart';

/// 跑一条命令。生产环境由 screen 用 `execChannelForServer` +
/// `SshCommandRunner` 组装；测试里注入假的。
///
/// 控制器只依赖这个函数与 [LiveConnectionProbe]，因此完全不碰 SSH、可以
/// device-free 地测。
typedef JobCommandRunner = Future<CommandOutput> Function(
    Server server, String command);

/// 这台机器现在有活连接吗？用于决定先扫谁，不做正确性依赖。
typedef LiveConnectionProbe = bool Function(Server server);

enum JobLoadState { pending, loading, done, failed }

enum JobBoardEmpty { none, noServers, noJobs }

/// 一台服务器在看板上的一组。
class JobServerGroup {
  final Server server;
  JobLoadState state;
  List<JobSummary> jobs;
  int skipped;
  String? error;

  JobServerGroup(this.server)
      : state = JobLoadState.pending,
        jobs = const [],
        skipped = 0;
}

/// 看板的页面级状态。**刻意不是全局 Provider** —— 关掉页面就释放。
///
/// 做成全局常驻 + 后台定期刷新的方案被否决了：它换来的「任务完成主动提醒」
/// 正确实现是服务端推送（`rust/flyterm-server/` 目前对 job 零引用），用手机端
/// 轮询去换等于给将来的正确实现挖坑。
class JobBoardController extends ChangeNotifier {
  /// 建连并发上限。
  ///
  /// **不能借用并行桶的 `_kMaxParallel`**（`lib/ai/agent/agent_loop.dart`）
  /// —— 那个约束的是同一台机器上的命令数，这里约束的是同时进行的 SSH
  /// 握手数。移动网络上同时开二十条握手会互相拖慢到全部超时。
  static const int kMaxConcurrentConnects = 4;

  final List<JobServerGroup> _groups;
  final JobCommandRunner _run;
  final LiveConnectionProbe _probe;
  bool _disposed = false;

  JobBoardController({
    required List<Server> servers,
    required JobCommandRunner run,
    required LiveConnectionProbe probe,
  })  : _run = run,
        _probe = probe,
        // `serverType == 'ssh'` 过滤：`local` 是本地 PTY、跑不了
        // `run_background`，列出来只会是个恒空的分组。
        _groups = [
          for (final s in servers)
            if (s.serverType == 'ssh') JobServerGroup(s)
        ];

  /// **顺序固定为传入顺序**，不随加载完成顺序变化。
  List<JobServerGroup> get groups => List.unmodifiable(_groups);

  JobBoardEmpty get emptyKind {
    if (_groups.isEmpty) return JobBoardEmpty.noServers;
    final allDone = _groups.every((g) => g.state == JobLoadState.done);
    if (allDone && _groups.every((g) => g.jobs.isEmpty)) {
      return JobBoardEmpty.noJobs;
    }
    return JobBoardEmpty.none;
  }

  /// 扫全部服务器。有活连接的排队首（先出结果），但**仍然**受
  /// [kMaxConcurrentConnects] 约束——`_probe` 是 TOCTOU 的（见其文档注释），
  /// 判错的代价必须只是「那台机器慢一点」，不能是绕过并发上限。
  Future<void> refreshAll() async {
    if (_groups.isEmpty) return;
    final warm = _groups.where((g) => _probe(g.server)).toList();
    final cold = _groups.where((g) => !_probe(g.server)).toList();

    // warm 排队首只影响“谁先出结果”，不豁免配额：全部误判为 warm 时
    // （例如 Wi-Fi 切蜂窝、`isClosed` 还没翻）仍然只有 kMaxConcurrentConnects
    // 条并发在飞，不会绕过 worker 池同时发起 N 条握手。
    final ordered = [...warm, ...cold];

    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= ordered.length) return;
        await _load(ordered[i]);
      }
    }

    await Future.wait([
      for (var i = 0; i < kMaxConcurrentConnects && i < ordered.length; i++)
        worker(),
    ]);
  }

  /// 只重扫一台。杀掉任务之后用。
  Future<void> refreshOne(String serverId) async {
    final g = _groups.firstWhere((g) => g.server.id == serverId);
    await _load(g);
  }

  /// dispose 之后再调 notifyListeners 会触发 ChangeNotifier 的 assert。
  /// 冷机器建连可能要十几秒（命令超时上限 20 秒），用户打开看板又立刻退回去
  /// 是最常见的操作序列之一——那时 `_load` 还在飞，dispose 后到达的结果
  /// 必须静默丢弃。
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load(JobServerGroup g) async {
    g.state = JobLoadState.loading;
    g.error = null;
    _safeNotify();
    try {
      final parsed = parseJobList(await _run(g.server, buildJobListCommand()));
      // 运行中的排前面（那是你可能要干预的），各自再按 startedAt 倒序。
      final sorted = [...parsed.jobs]..sort((a, b) {
          if (a.running != b.running) return a.running ? -1 : 1;
          return b.startedAt.compareTo(a.startedAt);
        });
      g.jobs = sorted;
      g.skipped = parsed.skipped;
      g.state = JobLoadState.done;
    } catch (e) {
      g.jobs = const [];
      g.skipped = 0;
      g.error = '$e';
      g.state = JobLoadState.failed;
    }
    _safeNotify();
  }

  /// 读日志尾部。复用 [buildJobPollCommand] 并传 `wait: 0` —— 它退化成
  /// 「取快照」，不用为看板写第二条读日志的命令。
  Future<String> tailLog(Server server, JobSummary job,
      {int lines = 200}) async {
    final since = job.totalLines > lines ? job.totalLines - lines : 0;
    final out = await _run(server, buildJobPollCommand(job.id, since, 0));
    return parseJobPoll(out).newOutput;
  }

  /// 终止一个任务。
  ///
  /// 返回给 UI 的文案只能说「已发送终止信号」，**不能说「已终止」**：
  /// [buildJobKillCommand] 自带 `|| true`、永远返回成功，`.pid` 不存在时
  /// 整条命令直接跳过、静默无效；而 SIGTERM 之后任务本来也可能要几秒才退。
  /// 这两种情况在客户端无法区分，那就不区分。
  Future<void> kill(Server server, JobSummary job) async {
    await _run(server, buildJobKillCommand(job.id));
    await refreshOne(server.id);
  }
}
