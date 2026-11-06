// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../../util/dlog.dart';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../ssh/legacy_path_migration.dart';
import '../../ssh/ssh_connection.dart' show isSshChannelSetupFailure;
import 'output_sanitizer.dart';
import 'shell_guard.dart';

class CommandOutput {
  /// **给模型的**：脱敏 → 去噪 → 列折叠 → 8 KiB 截断。
  ///
  /// 默认字段是精简版而不是完整版，是刻意的：调用方漏用 [displayStdout]
  /// 的后果是「UI 也显示精简版」（可接受），反过来默认给全量则是「模型吃
  /// 下 58 行相同的内容」—— 那正是要修的问题。安全的默认值朝向更省的那边。
  final String stdout;
  final String stderr;
  final int exitCode;
  final bool timedOut;

  /// **给 UI 的**：只做脱敏与宽松截断，不去噪、不折叠。
  ///
  /// null = 与 [stdout] 逐字相同（绝大多数输出没有可折叠的结构，存两份
  /// 纯属浪费）。调用方一律写 `displayStdout ?? stdout`。
  ///
  /// 为什么要分：两者的需求正好相反。模型只需要能支撑下一步判断的最小
  /// 证据，多一行都在稀释注意力；而用户在排查时往往要看全量，他得自己
  /// 判断 AI 有没有漏看什么。此前两者共用一份，于是为了迁就用户，模型
  /// 吃下了整整 58 行 `9256788*4096`。
  final String? displayStdout;
  final String? displayStderr;

  const CommandOutput({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    this.timedOut = false,
    this.displayStdout,
    this.displayStderr,
  });

  bool get isSuccess => exitCode == 0 && !timedOut;
}

const Duration kCommandTimeout = Duration(seconds: 20);

/// 后台任务轮询命令的超时预算。
///
/// `kCommandTimeout`（20 秒）是给**模型发的普通命令**定的上限，它同时是
/// 一条产品承诺（「命令最多挂 20 秒」）。轮询命令是**我们自己发的**，它的
/// 全部目的就是在远端阻塞等待，不该受那条承诺管。
///
/// 90 秒 = `wait` 参数的上限 60 秒 + 30 秒余量（建立 channel、日志读取、
/// 弱网抖动）。已知风险：这个数字要在真机弱网下验，若 NAT 回收
/// 空闲 channel，就把 `wait` 上限降到 30 秒。
const Duration kJobPollTimeout = Duration(seconds: 90);

const int kMaxOutputBytes = 8 * 1024;

/// 给 UI 的输出上限。比模型那份宽得多 —— 它不占 token，只占内存，而用户
/// 在排查时需要看到 AI 实际拿到了什么。仍然设上限：一条 `find /` 的输出
/// 能到几十 MB，全塞进事件流会让面板卡死。
const int kMaxDisplayBytes = 64 * 1024;

/// 把执行结果整理成回填给模型的文本。
///
/// stdout / stderr / exitCode **分开呈现**，因为它们语义不同：`grep` 无匹配
/// 是 exit 1 且无输出，那不是错误；`systemctl status` 对 inactive 服务返回
/// exit 3，那是有效信息。合并成一坨会让模型误判。
/// 给 UI 的渲染文本：用未折叠的完整输出。
///
/// 与 [formatForModel] 的唯一区别是取 `displayStdout ?? stdout`。两者刻意
/// 分成两个函数而不是加布尔参数：调用点一眼能看出这一处是给谁的。
String formatForDisplay(CommandOutput o) => _format(
      timedOut: o.timedOut,
      stdout: o.displayStdout ?? o.stdout,
      stderr: o.displayStderr ?? o.stderr,
      exitCode: o.exitCode,
    );

String formatForModel(CommandOutput o) => _format(
      timedOut: o.timedOut,
      stdout: o.stdout,
      stderr: o.stderr,
      exitCode: o.exitCode,
    );

/// 两种格式化共用的排版。抽出来而不是复制一份：排版规则（stderr 分节、
/// exit code 行、空输出占位）改一次就该两边都生效。
String _format({
  required bool timedOut,
  required String stdout,
  required String stderr,
  required int exitCode,
}) {
  final buf = StringBuffer();
  if (timedOut) {
    // 中性文案，不带秒数：普通命令用 kCommandTimeout（20s），轮询命令用
    // kJobPollTimeout（90s），给 CommandOutput 加一个字段太重。秒数对
    // 模型没有决策价值——它已经知道自己发了什么命令——而写错的秒数会误导。
    buf.writeln('[timed out and was killed]');
  }
  if (stdout.isNotEmpty) buf.writeln(stdout);
  if (stderr.isNotEmpty) {
    buf.writeln('--- stderr ---');
    buf.writeln(stderr);
  }
  if (stdout.isEmpty && stderr.isEmpty && !timedOut) {
    buf.writeln('(no output)');
  }
  buf.write('--- exit code: $exitCode ---');
  return buf.toString().trim();
}

/// 执行命令的抽象。
///
/// v1 只有 [SshCommandRunner] 一个实现。将来 loop 下沉到 `flyterm-server`
/// 时换成走 AQT Exec 帧的实现，`AgentLoop` 与规则引擎一行不改。
abstract class CommandRunner {
  /// [timeout] 为 null 时用 [kCommandTimeout]。只有后台任务轮询会传别的值。
  ///
  /// [denoise] = true 时对输出做内容感知去噪（见 `denoiseOutput`）。
  ///
  /// **默认 false，这是刻意的。** `read_file` 通过 `sed` 走这条路径，折叠
  /// 会让行号错位、并让模型从输出里抄到文件中根本不存在的标记文本，
  /// `edit_file` 的 `old_string` 随后匹配失败。漏传的后果应该是「少省一点
  /// token」，不是「文件内容被悄悄改了形状」。
  ///
  /// [truncate] 决定输出撞上 8 KiB 时丢哪一段（见 [TruncateMode]）。
  ///
  /// [maxBytes] 覆盖默认的 [kMaxOutputBytes]（8 KiB）。**只有需要把结构化
  /// 载荷整体搬回来的调用方**（如技能目录的 tar 包）才该动它：那个默认值
  /// 是给模型看的文本定的，而一份技能的正文 + 附件上限就到 24 KiB，用 8 KiB
  /// 去接等于必然截断。误用方向是“把一大段输出塞进上下文”，所以它没有
  /// 默认值、必须显式传。
  ///
  /// **默认 head，与 `truncateForModel` 一致。** 判定在 `AgentLoop._resolve()`
  /// 里按工具名做，这里只负责透传 —— 与 [denoise] 同一条路径、同一个理由：
  /// 执行层不该知道自己在为哪个工具服务。
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,
      TruncateMode truncate = TruncateMode.head});
  Future<void> dispose();
}

/// 通过 SSH exec channel 执行命令。
///
/// [clientProvider] 每次调用时才取 client，让 [AgentExecChannel] 有机会
/// 懒建立或在断线后重建连接。
class SshCommandRunner implements CommandRunner {
  final Future<SSHClient> Function() clientProvider;

  /// 连接开不出 channel 时回调，参数是那条坏连接。上游据此丢弃它，下一次
  /// [clientProvider] 就会给出一条新的。传 null 则不做自愈重试。
  final void Function(SSHClient bad)? onDeadChannel;

  SshCommandRunner(this.clientProvider, {this.onDeadChannel});

  /// 这台机器上的「旧品牌路径迁移」跑过没有。
  ///
  /// 实例级而非全局：runner 的生命周期跟着一条 SSH 连接走，换服务器就是新
  /// 实例，正好是「每台机器迁移一次」的粒度。迁移本身幂等，所以实例被重建
  /// 导致的重复执行只多花两个 `[ -d ]` 判断。
  bool _legacyMigrationDone = false;

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,
      TruncateMode truncate = TruncateMode.head}) async {
    final budget = timeout ?? kCommandTimeout;
    // 只记录命令的头一个 token（程序名），不记录参数 —— 参数里可能带密码、
    // 路径等敏感内容，而定位「连接层 vs 规则层」只需要知道命令发出去了没有。
    final head = command.trimLeft().split(RegExp(r'\s+')).first;
    // 顺序至关重要：调用方已在原始命令上做过元字符检测，此处才做包装。
    //
    // 首次命令前置一段旧路径迁移。拼在 wire 前面而不是单独发一次 exec，是
    // 为了零额外往返 —— `wrapForSsh` 产出的是 `echo <b64>|base64 -d|bash`，
    // 前面用 `;` 接一段 POSIX shell 不改变它的语义。agent 读 `~/.flyterm/
    // AGENTS.md` 和 skills/ 都走这条路，迁移必须赶在第一次读之前。
    final wire = (_legacyMigrationDone ? '' : kLegacyRemoteMigration) +
        wrapForSsh(command, cwd: cwd);
    _legacyMigrationDone = true;

    var retriedOnDeadChannel = false;
    while (true) {
      final SSHClient client;
      try {
        client = await clientProvider();
      } catch (e) {
        // agent「一发指令就失败」的两种成因在此分野：走到这里的是**连接层**
        // 失败（AgentExecChannel.obtain 抛错）；被 permission_rules /
        // shell_guard 拦下的命令根本到不了 run()，日志里不会有这一行。
        dlog('AgentRun', '取连接失败 head=$head: ${e.runtimeType}: $e');
        rethrow;
      }
      dlog('AgentRun', 'exec head=$head budget=${budget.inSeconds}s '
          'cwd=${cwd != null}');

      // 单一预算：建立 channel 与收集输出**共用** budget。
      // 各给一次会让最坏情况变成两倍，而对外承诺的是这个预算本身。
      final deadline = DateTime.now().add(budget);
      final SSHSession session;
      try {
        session = await client.execute(wire).timeout(budget);
      } catch (e) {
        // **这是唯一能安全重试的窗口**：channel 没建起来，命令根本没发到
        // 远端，重跑一次不会重复触发任何副作用（rm、写文件、重启服务……）。
        // 一旦 session 建立，后面无论怎么失败都不再重试。
        //
        // 针对的是 `isClosed` 判不出来的半死连接：TCP 还在、dartssh2 说没关，
        // 服务端却拒绝新 session channel。不丢弃它的话，agent 每条命令都会
        // 失败且永不自愈（详见 isSshChannelSetupFailure 的文档）。
        if (!retriedOnDeadChannel &&
            onDeadChannel != null &&
            isSshChannelSetupFailure(e)) {
          retriedOnDeadChannel = true;
          dlog('AgentRun', 'channel 开不出 head=$head，'
              '丢弃这条连接并重试一次: ${e.runtimeType}: $e');
          onDeadChannel!(client);
          continue;
        }
        dlog('AgentRun', 'exec 建 channel 失败 head=$head: '
            '${e.runtimeType}: $e');
        rethrow;
      }

      try {
        return await _collect(session, deadline, head,
            denoise: denoise, maxBytes: maxBytes, truncate: truncate);
      } catch (e) {
        dlog('AgentRun', 'exec 读取失败 head=$head: ${e.runtimeType}: $e');
        rethrow;
      } finally {
        session.close();
      }
    }
  }

  /// 收集一次已建立的 session 的输出。**不重试** —— 命令此时已在远端跑过了。
  Future<CommandOutput> _collect(
    SSHSession session,
    DateTime deadline,
    String head, {
    bool denoise = false,
    int? maxBytes,
    TruncateMode truncate = TruncateMode.head,
  }) async {
    final out = <int>[];
    final err = <int>[];
    final collect = Future.wait([
      session.stdout.forEach(out.addAll),
      session.stderr.forEach(err.addAll),
    ]);

    var timedOut = false;
    final remaining = deadline.difference(DateTime.now());
    if (remaining.isNegative || remaining == Duration.zero) {
      timedOut = true;
      session.kill(SSHSignal.KILL);
      unawaited(collect.catchError((_) => <void>[]));
    } else {
      try {
        await collect.timeout(remaining);
      } on TimeoutException {
        timedOut = true;
        session.kill(SSHSignal.KILL);
        // kill 之后 collect 仍在等两条流关闭。不 await 它，但也不能
        // 就这么丢着 —— 未被观察的 Future 抛错会变成未捕获异常。
        unawaited(collect.catchError((_) => <void>[]));
      }
    }

    final o = _prepare(Uint8List.fromList(out),
        denoise: denoise, maxBytes: maxBytes, truncate: truncate);
    final e = _prepare(Uint8List.fromList(err),
        denoise: denoise, maxBytes: maxBytes, truncate: truncate);
    final stdout = o.model;
    final stderr = e.model;
    final exitCode = timedOut ? -1 : (session.exitCode ?? -1);
    dlog('AgentRun', 'exec 结束 head=$head exit=$exitCode '
        'timedOut=$timedOut out=${stdout.length}B err=${stderr.length}B');
    return CommandOutput(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      timedOut: timedOut,
      displayStdout: o.display,
      displayStderr: e.display,
    );
  }

  /// 解码 → 剥 ANSI → 脱敏 → [去噪] → 截断。顺序固定：
  /// 脱敏必须在截断**之前**，否则被截掉的尾巴里的秘密不会被计数，
  /// 而截断标记又会让人以为「后面没东西了」。
  static ({String model, String? display}) _prepare(Uint8List bytes,
      {bool denoise = false, int? maxBytes, TruncateMode truncate = TruncateMode.head}) {
    final decoded = decodeOutput(bytes);
    if (decoded.startsWith('[binary output,')) {
      return (model: decoded, display: null);
    }
    final clean = stripAnsi(decoded);
    final redacted = redactSecrets(clean);
    // 去噪在脱敏**之后**，两个理由：
    // 1. 与下面那条「脱敏必须在截断之前」同源 —— 折叠同样会吃掉尚未计数
    //    的秘密，模型于是看到「1 个值被脱敏」这种假信息。
    // 2. 顺带提高收益：脱敏把含密码的多行都变成同一串
    //    `[redacted by FlyTerm]`，正好可折叠。
    //
    // 在截断**之前**：去噪把 8 KiB 的额度腾给真实内容，所以它不只省 token，
    // 还提高了模型能看到的信息量。
    final denoised = denoise ? denoiseOutput(redacted.text) : redacted.text;
    // 列折叠在去噪**之后**：denoiseOutput 先吃掉整行重复，剩下的「结构
    // 相同、一列不同」才是这一步的目标。两者互补，不重叠。
    final folded = denoise ? foldColumnar(denoised) : denoised;
    // 顺序有讲究，两条都踩过：
    // 1. 脱敏必须在截断**之前** —— 否则被截掉的尾巴里的秘密不会被计数
    // 2. notice 必须在截断**之后**追加 —— 它写在末尾，若在截断前追加，
    //    输出一超长它自己就被截掉了，模型于是看不到「有 N 个值被脱敏」，
    //    会把 `[redacted by FlyTerm]` 当成真实值去诊断
    final truncated =
        truncateForModel(folded, maxBytes ?? kMaxOutputBytes, mode:
            pickTruncateMode(
          original: denoised,
          folded: folded,
          requested: truncate,
        ));
    final modelText = appendRedactionNotice(truncated, redacted.count);

    // 给 UI 的那份：**跳过去噪与折叠**，只脱敏 + 宽松截断。用户在排查时
    // 要能看到 AI 实际拿到了什么，折叠摘要对他没有价值。
    //
    // 脱敏不能跳 —— 那是安全边界，两份都必须过。
    final displayText = appendRedactionNotice(
      truncateForModel(redacted.text, kMaxDisplayBytes,
          mode: TruncateMode.middle),
      redacted.count,
    );
    // 逐字相同就不存第二份（绝大多数输出没有可折叠的结构）。
    return (
      model: modelText,
      display: displayText == modelText ? null : displayText,
    );
  }

  @override
  Future<void> dispose() async {}
}
