// SPDX-License-Identifier: GPL-3.0-or-later
import 'command_runner.dart';
// TruncateMode 在这里，不在 command_runner.dart。
import 'output_sanitizer.dart';
import '../../data/models/server.dart';

/// 没有可用目标机器时顶上的 runner。
///
/// 存在的理由是全局 AI 会话:它不绑定任何服务器,`runnerProvider(null)` 没有
/// 「当前会话那台」可用。让它返回 null 或抛异常都会把一次**可自纠的参数遗漏**
/// 变成整轮失败——模型漏传 `server` 是常见现实路径,工具层应当像
/// `resolveServerTarget`(`server_targets.dart:71`)那样回一句话让它重试。
///
/// 回非零 exitCode 而不是 `isError` 的 ToolResult:这一层只认识 [CommandOutput],
/// 上面的 `formatForModel` 会把 stderr 和 exit code 一起呈给模型。
/// 127 = shell 的「command not found」。借用它而不是自造一个数字,是因为
/// 模型对这个值有先验,不会把它误读成「命令跑了但失败了」。
const int kMissingServerExitCode = 127;

class MissingServerRunner implements CommandRunner {
  @override
  Future<CommandOutput> run(String command,
          {String? cwd,
          Duration? timeout,
          bool denoise = false,
          int? maxBytes,

          TruncateMode truncate = TruncateMode.head}) async =>
      const CommandOutput(
        stdout: '',
        stderr: 'No target server. This session is not attached to any '
            'machine, so you must pass `server` explicitly on every call. '
            'Call `list_servers` to get the exact names, then retry with '
            '`server` set.',
        exitCode: kMissingServerExitCode,
      );

  @override
  Future<void> dispose() async {}
}

/// 把「模型给的 serverId」+「本会话的默认机器」解析成一个可用的 runner。
///
/// 四种组合,前两种是正常路径,后两种都落到 [MissingServerRunner]:
///
/// | serverId | defaultServer | 结果 |
/// |---|---|---|
/// | null | 有 | 默认机器(终端页 AI 面板的现有行为) |
/// | 有 | — | 指定机器(跨机调用;也是全局会话的唯一正常路径) |
/// | null | null | MissingServerRunner(全局会话里模型漏传 `server`) |
/// | 查不到 | — | MissingServerRunner(机器在会话中途被用户删了) |
///
/// [serverById] 读的是调用方的服务器缓存快照,**必须是同步的** —— 本函数被
/// `AgentLoop.runnerProvider` 这个同步闭包调用,等不了异步查询。
CommandRunner resolveAgentRunner({
  required String? serverId,
  required Server? defaultServer,
  required Server? Function(String id) serverById,
  required CommandRunner Function(Server) runnerFor,
}) {
  final target = serverId == null ? defaultServer : serverById(serverId);
  if (target == null) return MissingServerRunner();
  return runnerFor(target);
}
