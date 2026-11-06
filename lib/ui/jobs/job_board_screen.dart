// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_exec_channel.dart';
import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/background_job.dart';
import '../../ai/agent/command_runner.dart';
import '../../ai/agent/exec_channel_factory.dart';
import '../../data/models/server.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/secure_storage.dart';
import '../../ssh/session_manager.dart';
import '../../l10n/l10n.dart';
import '../ai/widgets/dense_event_row.dart';
import 'job_board_controller.dart';

/// 后台任务看板。
///
/// 修的是「App 重开丢 job id，任务变孤儿」：状态本来就在远端
/// `~/.flyterm/jobs/` 下，缺的只是扫一遍目录和一个入口。
///
/// 每行用 [DenseEventRow] —— 它不依赖 `AgentEvent`，换个数据源就能复用。
/// 这是 2026-09-09 信息密度那轮把它做成「调用方拼 spans」的红利。**改那个
/// 组件要同时跑 `test/ui/ai/widgets/dense_event_row_test.dart` 和
/// `test/ui/jobs/job_board_screen_test.dart`**，它从此有两个消费域。
class JobBoardScreen extends StatefulWidget {
  final JobBoardController controller;

  /// 「让模型接手」按钮是否可点：这台服务器现在有没有活跃的终端 tab。
  ///
  /// 可选而不是直接 `context.read<SessionManager>()`——那样会让这个纯粹
  /// 的展示组件绑死 provider 树，5 个既有 widget 测试用的是裸
  /// `MaterialApp` + 假 controller，没有挂 provider。默认值 `null` 时一律
  /// 当作「没有 tab」处理（按钮 disabled），生产环境由 [JobBoardHost] 显式
  /// 传入真正的判断。
  final bool Function(String serverId)? hasTabFor;

  const JobBoardScreen({super.key, required this.controller, this.hasTabFor});

  @override
  State<JobBoardScreen> createState() => _JobBoardScreenState();
}

class _JobBoardScreenState extends State<JobBoardScreen> {
  /// 按 job id 缓存 `tailLog` 的 Future。
  ///
  /// `refreshAll()` 每扫完一台机器就 `notifyListeners()` → `_onChange` →
  /// `setState` → rebuild —— 如果 `future:` 在 `build()` 里现造
  /// （`FutureBuilder<String>(future: widget.controller.tailLog(...))`），
  /// 每个已展开的日志都会跟着这次无关的 rebuild 重新发一次 SSH 命令。真机
  /// 上是展开区闪烁 + 无谓的流量。缓存住之后，一个 job 的日志只在**第一次
  /// 展开**和**手动点刷新**（见 [_refresh]）时才会真的走一次网络。
  final Map<String, Future<String>> _logCache = {};

  /// 键必须带上 serverId——`tailLog` 是按 `(server, job)` 取的，光用
  /// job id 当键，两台机器在同一毫秒生成同一个 4 位随机后缀的 job id
  /// 就会撞车（概率虽低，但后果是显示另一台机器的日志）。
  String _logCacheKey(JobServerGroup g, JobSummary j) => '${g.server.id}/${j.id}';

  Future<String> _tailLog(JobServerGroup g, JobSummary j) => _logCache
      .putIfAbsent(_logCacheKey(g, j), () => widget.controller.tailLog(g.server, j));

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    widget.controller.refreshAll();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// AppBar 上的手动刷新：用户明确要「重新看一眼」，这时缓存的日志也该
  /// 跟着作废——否则点了刷新，任务状态更新了，展开区里的日志尾部却还是
  /// 缓存里那份旧的，看起来像没生效。
  void _refresh() {
    _logCache.clear();
    widget.controller.refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.jobBoardTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: switch (c.emptyKind) {
        JobBoardEmpty.noServers => Center(child: Text(l.jobBoardNoServers)),
        JobBoardEmpty.noJobs => Center(child: Text(l.jobBoardNoJobs)),
        JobBoardEmpty.none => ListView(
            children: [for (final g in c.groups) ..._group(g)],
          ),
      },
    );
  }

  List<Widget> _group(JobServerGroup g) {
    final l = context.l10n;
    return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(g.server.name,
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              if (g.state == JobLoadState.loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        if (g.state == JobLoadState.failed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(g.error ?? l.jobBoardScanFailed,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
                TextButton(
                  onPressed: () => widget.controller.refreshOne(g.server.id),
                  child: Text(l.jobBoardRetry),
                ),
              ],
            ),
          ),
        for (final j in g.jobs) _row(g, j),
        if (g.skipped > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
            child: Text(l.jobBoardSkippedEntries(g.skipped),
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ];
  }

  Widget _row(JobServerGroup g, JobSummary j) {
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;
    return DenseEventRow(
      leading: Icon(
        j.running ? Icons.play_circle_outline : Icons.check_circle_outline,
        size: 16,
        color: j.running ? scheme.primary : scheme.onSurfaceVariant,
      ),
      spans: [
        TextSpan(text: j.id),
        TextSpan(
          text: j.running
              ? '  ${l.jobBoardRunning}'
              : '  ${l.jobBoardExitCode('${j.exitCode}')}',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        // 判活不猜，摆事实：没有 .exit 的任务可能真在跑，也可能是服务器
        // 重启后再也不会写 .exit 的僵尸。两者在文件层面无法区分。
        TextSpan(
          text: j.logMtime == null
              ? '  ${l.jobBoardLogTimeUnknown}'
              : '  ${l.jobBoardLogUpdatedAgo(_ago(j.logMtime!))}',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ],
      trailingLabel: l.jobBoardLineCount(j.totalLines),
      expanded: (_) => _expanded(g, j),
    );
  }

  Widget _expanded(JobServerGroup g, JobSummary j) {
    final hasTab = widget.hasTabFor?.call(g.server.id) ?? false;
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder<String>(
          future: _tailLog(g, j),
          builder: (_, snap) => Text(
            snap.hasError
                ? l.jobBoardReadLogFailed('${snap.error}')
                : (snap.data ?? l.jobBoardReadingLog),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: l.jobBoardKillTooltip,
              onPressed: j.running ? () => _confirmKill(g, j) : null,
            ),
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: l.jobBoardCopyJobIdTooltip,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: j.id));
                _toast(l.jobBoardCopiedJobId);
              },
            ),
            IconButton(
              icon: const Icon(Icons.smart_toy_outlined),
              tooltip:
                  hasTab ? l.jobBoardHandOffTooltip : l.jobBoardNeedTabTooltip,
              // 没有活跃 tab 时 disabled。`_openAIPanel` 要一个
              // SessionTab（它要终端上下文：cwd、终端内容快照），而孤儿
              // 任务恰恰常在没开 tab 的机器上 —— 那种情况由「复制 job
              // id」兜底。让看板去连接一台机器会给这个页面加上第二个
              // 职责，这不在看板的目标之内。
              onPressed: hasTab ? () => _handOff(g, j) : null,
            ),
          ],
        ),
      ],
    );
  }

  /// 把这个任务交给模型：投递一句 prompt，回到终端页，让它自己消费。
  ///
  /// 只有 [widget.hasTabFor] 为真时才会被触发（按钮 disabled 时点不到这
  /// 里），所以不再重复判断 —— `context.read<AgentSessionManager>()` 在这
  /// 里安全，因为生产环境的 [JobBoardHost] 本来就挂在整棵 provider 树下。
  void _handOff(JobServerGroup g, JobSummary j) {
    context.read<AgentSessionManager>().stagePrompt(
          g.server.id,
          context.l10n.jobBoardHandOffPrompt(j.id),
        );
    // 回到根（终端），让 terminal_screen 消费那个槽并打开面板。
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _confirmKill(JobServerGroup g, JobSummary j) async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.jobBoardConfirmKillTitle),
        content: Text(l.jobBoardConfirmKillContent(j.id, g.server.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.jobBoardKillTooltip),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.controller.kill(g.server, j);
    // kill 之后状态会通过 refreshOne 翻成「退出码 N」，但展开区的日志
    // 还是 kill 之前缓存的那份——SIGTERM 之后进程往往还要往日志里写
    // 收尾的几行，是最会让日志尾部变化的操作之一。同 `_refresh()` 的
    // 道理：状态更新了、日志却是旧的，看起来像没生效。
    _logCache.remove(_logCacheKey(g, j));
    // **不能写「已终止」。** buildJobKillCommand 自带 || true、永远返回
    // 成功；`.pid` 不存在时整条命令直接跳过、静默无效。而 SIGTERM 之后
    // 任务本来也可能要几秒才退。两种情况在客户端无法区分，那就不区分，
    // 只说我们确实做了什么。
    _toast(context.l10n.jobBoardKillSent);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _ago(DateTime t) {
    final l = context.l10n;
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return l.timeJustNow;
    if (d.inMinutes < 60) return l.timeMinutesAgo(d.inMinutes);
    if (d.inHours < 24) return l.timeHoursAgo(d.inHours);
    return l.timeDaysAgo(d.inDays);
  }
}

/// 路由入口：从 provider 组装依赖，把 SSH 那部分喂给纯粹的
/// [JobBoardController]。
///
/// 分成两层是为了让 controller 完全不碰 provider 与 SSH —— 它的测试因此
/// 不需要任何 widget 树。
class JobBoardHost extends StatefulWidget {
  const JobBoardHost({super.key});

  @override
  State<JobBoardHost> createState() => _JobBoardHostState();
}

class _JobBoardHostState extends State<JobBoardHost> {
  JobBoardController? _c;
  // 「让模型接手」按钮要知道这台服务器现在有没有活跃 tab——存成字段而不是
  // `_build()` 里的局部变量，因为 `build()` 组装 [JobBoardScreen] 时也要用它。
  SessionManager? _sessions;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    final servers = await context.read<ServerRepository>().findAll();
    if (!mounted) return;
    final mgr = context.read<AgentSessionManager>();
    final sessions = context.read<SessionManager>();
    _sessions = sessions;
    final storage = context.read<SecureStorageService>();

    AgentExecChannel chan(Server s) => execChannelForServer(
        mgr: mgr, server: s, sessions: sessions, storage: storage);

    setState(() {
      _c = JobBoardController(
        servers: servers,
        probe: (s) => chan(s).hasLiveConnection,
        run: (s, cmd) {
          final ch = chan(s);
          return SshCommandRunner(ch.obtain, onDeadChannel: ch.invalidate)
              .run(cmd);
        },
      );
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return JobBoardScreen(
      controller: c,
      hasTabFor: (serverId) => _sessions?.activeTabForServer(serverId) != null,
    );
  }
}
