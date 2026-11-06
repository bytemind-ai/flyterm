// SPDX-License-Identifier: GPL-3.0-or-later
import '../../ai/agent/background_job.dart';
import '../../ai/agent/command_runner.dart';
import '../../data/models/server.dart';

/// 扫出每台机器上**运行中**的后台任务数，供服务器列表的行内徽标使用。
///
/// ## 为什么要 `shouldScan` 而不是直接扫全部
///
/// `job_board_controller.dart` 的类文档记着一条既有决策：「全局常驻 + 后台
/// 定期刷新的方案被否决了」——它换来的「任务完成主动提醒」正确实现是服务端
/// 推送，用手机端轮询去换等于给将来的正确实现挖坑。
///
/// 扫一台**冷机器**要走完整 SSH 握手（命令超时上限 20 秒）。若服务器列表每行
/// 都常驻显示 job 数，就等于一进首页对所有机器发起轮询，正是上面被否掉的
/// 方案。所以调用方传进来的 `shouldScan` 默认只放行**已有活连接**的机器
/// （复用已有通道跑一条命令，无握手），冷机器留给用户下拉时的显式扫描。
///
/// ## 返回值的三态
///
/// - **key 不存在** = 没扫（`shouldScan` 为 false）或扫失败 → 不显示徽标
/// - **值为 0** = 扫了，确实没有运行中的任务 → 同样不显示徽标，但在测试里
///   与「没扫」可区分
/// - **值 > 0** = 显示徽标
///
/// 失败的机器不进 Map 而不是映射成 0：扫失败说明这台机器现在的状态**未知**，
/// 宣称它「0 个任务」是在编造信息。
Future<Map<String, int>> loadRunningJobCounts({
  required List<Server> servers,
  required bool Function(Server) shouldScan,
  required Future<CommandOutput> Function(Server server, String command) run,
  int maxConcurrent = 4,
}) async {
  // `serverType == 'ssh'` 过滤与 `JobBoardController` 的构造函数同一个理由：
  // local 是本地 PTY、跑不了 run_background，扫它只会得到恒空的结果。
  final targets = [
    for (final s in servers)
      if (s.serverType == 'ssh' && shouldScan(s)) s,
  ];
  if (targets.isEmpty) return const {};

  final result = <String, int>{};
  var next = 0;

  // worker 池而不是 `Future.wait(targets.map(...))`：约束的是同时进行的 SSH
  // 握手数。移动网络上同时开二十条握手会互相拖慢到全部超时。上限与
  // `JobBoardController.kMaxConcurrentConnects` 同值。
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= targets.length) return;
      final s = targets[i];
      try {
        final parsed = parseJobList(await run(s, buildJobListCommand()));
        result[s.id] = parsed.jobs.where((j) => j.running).length;
      } catch (_) {
        // 这一台的结果未知 —— 不进 Map，徽标就不显示。
        // 吞掉而不是上抛：一台连不上不该让其余九台的结果一起丢。
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < maxConcurrent && i < targets.length; i++) worker(),
  ]);

  return result;
}
