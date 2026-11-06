// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'command_runner.dart';
import 'shell_guard.dart';

/// 远端 job 目录。
///
/// **`"$HOME"` 而不是 `~`**：这个片段会同时出现在两个位置 —— 外层 bash
/// 命令里（`~` 能展开）和被 [shellQuote] 包进单引号的内层脚本里（`~`
/// **不**展开，会变成一个名叫 `~` 的相对目录）。`$HOME` 在两处都由各自的
/// shell 正确展开，是唯一同时成立的写法。
///
/// 带引号是为了 home 路径含空格时不被拆词。
const String kJobDir = r'"$HOME"/.flyterm/jobs';

/// 远端脚本在「找不到这个 job」时使用的退出码。
///
/// 挑 91：1/2 太常见（普通命令失败），126/127 是 shell 保留的
/// 「不可执行 / 找不到命令」，137 是 SIGKILL 的 128+9。91 不与它们冲突。
const int kJobNotFoundExit = 91;

/// `check_job` 的 `wait` 上限（秒）。
///
/// 上限存在的理由是 [kJobPollTimeout]：wait 比它还长的话，命令会先被我们
/// 自己的超时杀掉，模型拿到的是一次无意义的失败。
const int kMaxJobWaitSeconds = 60;

/// 生成一个 job id。
///
/// 客户端生成而不是解析远端输出 —— 少一处解析就少一处能出错的地方。
///
/// [rand] 由调用方给（`Random().nextInt(0x10000)`），本函数保持纯粹以便
/// 测试。同一毫秒内起两个 job 靠它区分。
String newJobId(DateTime now, int rand) {
  final r = (rand & 0xFFFF).toRadixString(16).padLeft(4, '0');
  return 'job-${now.millisecondsSinceEpoch}-$r';
}

/// job id 的合法形状。
///
/// **这是路径穿越的唯一防线。** jobId 会被直接拼进 `$kJobDir/<id>.log`，
/// 一个 `../../../etc/shadow` 就能让轮询命令去读任意文件 —— 而 `check_job`
/// 刻意不走 `checkCommand`（命令由我们拼装、只读固定目录），没有第二道闸。
///
/// 校验放在拼命令**之前**，不是之后。
final RegExp _jobIdRe = RegExp(r'^job-\d{10,17}-[0-9a-f]{4}$');

bool isValidJobId(String id) => _jobIdRe.hasMatch(id);

/// [DateTime.fromMillisecondsSinceEpoch] 能接受的最大绝对值（其文档给出
/// 的上限）。
///
/// [_jobIdRe] 允许 10-17 位数字，但 17 位的值能远超这个上限——
/// `job-99999999999999999-aaaa` 能通过 [isValidJobId] 的形状校验，随后却
/// 让 `DateTime.fromMillisecondsSinceEpoch` 抛 RangeError。[parseJobList]
/// 用它在构造 [JobSummary] 之前挡掉这类 id，让 [JobSummary.startedAt]
/// 对「进了列表的实例」保持不会抛异常。
const int _kMaxEpochMillis = 8640000000000000;

/// 拼出「在后台起一个长命令」的脚本。
///
/// ## 为什么退出码要落盘
///
/// `setsid` 之后父 shell 立刻返回，拿不到退出码。查 pid 存活有两个坑：
/// pid 会被复用（长任务尤其容易撞上），进程可能变僵尸。`.exit` 文件
/// **在不在**是二值的，不会骗人。
///
/// `.pid` 仍然落盘，用途是取消（见 [buildJobKillCommand]）。
///
/// ## 三条不能动的结构约束（每一条都对应一个实测复现过的失效）
///
/// 1. **`mkdir` 与 `setsid` 之间必须是 `;`，不能是 `&&`。**
///    POSIX 里 `&` 的优先级**低于** `&&`，所以
///    `mkdir -p D && setsid ... &` 会被解析成 `{ mkdir -p D && setsid ...; } &`
///    —— 被后台化的是整条 AND-list，`mkdir` 也跟着异步了。全新机器上首次
///    运行时目录还不存在，前台紧接着的写 `.pid` 必然 `No such file`。
///
/// 2. **pid 由内层 `sh` 自己写 `$$`，不能由外层写 `$!`。**
///    承上：被后台化的既然是整条 list，`$!` 拿到的是那个**包装子 shell**
///    的 pid，不是任务的。而非交互 shell 关掉了 job control，包装壳不会
///    自成进程组，于是 `kill -TERM -<pid>` 因 pgid 不存在而 ESRCH，回落
///    到杀单个 pid 只干掉空壳，真正的任务活得好好的。更糟的是空壳死后
///    pid 立刻可复用，下一次 `kill -TERM -<同一个数>` 可能命中一个**无关
///    的进程组**，在用户的生产服务器上群发 SIGTERM。
///    `setsid` 之后内层 sh 就是新会话与新进程组的 leader，`$$` 即 pgid。
///
/// 3. **后台化的必须是简单命令，好让外层 shell 立刻退出。**
///    承上：包装子 shell 继承了 SSH exec channel 的 stdout 并一直活到任务
///    结束，`SshCommandRunner.run` 等的正是流关闭 —— 于是任何超过 20 秒的
///    后台任务都会撞 `kCommandTimeout`，而那恰恰是这个工具要解决的问题。
///
/// 三条是同一个根因的三个面。改这个函数前先读它们，并跑
/// `background_job_test.dart` 里那组真 shell 测试。
String buildJobStartCommand(String jobId, String command) {
  // inner 交给内层 `sh -c` 执行。`$$`、`$?`、`$HOME` 都要由**内层** shell
  // 展开，所以这里写成字面 `$` —— shellQuote 会把整段包进单引号，外层不
  // 会碰它们。
  //
  // `.exit` 先写 `.exit.tmp` 再 `mv`：`echo $? > f` 会先创建空文件再写入，
  // 轮询的退出条件是「文件存在」，撞进那个窗口会读到空内容、三段格式错位
  // 一行，`parseJobPoll` 于是报 notFound —— 模型会以为任务凭空消失了。
  // `mv` 在同一文件系统上是原子的，窗口就此消失。
  // 用户命令套一层子 shell `( ... )`：**没有它，命令里一个 `exit` 就能让
  // 退出码永远不落盘**。`sleep 1 || exit 1`、`set -e; ...`、`command || exit`
  // 这类写法模型给得很自然，而 `exit` 会直接终止内层 sh，后面记录退出码的
  // 两句一句都不执行 —— 任务于是永远停在 running，`check_job` 等一个不会
  // 到来的结束。子 shell 里的 `exit` 只退出子 shell，`$?` 照常拿到它的码。
  final inner = 'echo \$\$ > $kJobDir/$jobId.pid; '
      '( $command ); '
      'echo \$? > $kJobDir/$jobId.exit.tmp; '
      'mv $kJobDir/$jobId.exit.tmp $kJobDir/$jobId.exit';
  return 'mkdir -p $kJobDir; '
      'setsid sh -c ${shellQuote(inner)} > $kJobDir/$jobId.log 2>&1 &';
}

/// 拼出「等待并读取 job 新增输出」的脚本。
///
/// ## 输出格式（三段，供 [parseJobPoll] 解析）
///
/// ```
/// <第一行>  退出码数字，或字面量 running
/// <第二行>  日志文件当前总行数
/// <其余>    从 sinceLine+1 开始的新增日志
/// ```
///
/// 前两行由我们控制，其余全是日志内容 —— 日志里出现什么都不会破坏解析，
/// 因为解析只按「前两行」切。
///
/// ## 为什么要在远端阻塞等待
///
/// 若这条命令看一眼就返回，模型面对 3 分钟的 `apt upgrade` 会疯狂轮询，
/// **每一轮都重发整个对话**。阻塞等待把几十轮压到 3~4 轮。
String buildJobPollCommand(String jobId, int sinceLine, int waitSeconds) {
  final wait = waitSeconds.clamp(0, kMaxJobWaitSeconds);
  final log = '$kJobDir/$jobId.log';
  final exit = '$kJobDir/$jobId.exit';
  final from = sinceLine + 1;
  // 用 while 而不是 `seq`：BusyBox 的 seq 不总是存在。
  // 每秒检查两个退出条件：任务结束，或有新行到达。
  return 'if [ ! -f $log ]; then exit $kJobNotFoundExit; fi; '
      'i=0; '
      'while [ \$i -lt $wait ]; do '
      'if [ -f $exit ]; then break; fi; '
      'if [ "\$(wc -l < $log)" -gt $sinceLine ]; then break; fi; '
      'i=\$((i+1)); sleep 1; '
      'done; '
      'if [ -f $exit ]; then cat $exit; else echo running; fi; '
      'wc -l < $log; '
      'tail -n +$from $log';
}

/// 一次轮询的结果。
class JobPoll {
  /// 任务还在跑。
  final bool running;

  /// 已结束时的退出码。[running] 为 true 时恒为 null。
  final int? exitCode;

  /// 日志当前总行数，供下次轮询当 `sinceLine`。拿不到时为 null。
  final int? totalLines;

  /// 本次新增的日志内容。可能为空串。
  final String newOutput;

  /// 远端找不到这个 job（目录被清、服务器重启过）。
  ///
  /// **必须与「还在跑」区分开**：回一个空输出的 running 会让模型永远等
  /// 一个不存在的任务，把剩下的轮数全烧在轮询上。
  final bool notFound;

  const JobPoll({
    this.running = false,
    this.exitCode,
    this.totalLines,
    this.newOutput = '',
    this.notFound = false,
  });
}

/// 解析 [buildJobPollCommand] 的输出。
JobPoll parseJobPoll(CommandOutput out) {
  // 命令自己超时 → 任务大概率还在跑（我们等满了 wait 都没等到结束）。
  // 按 running 处理但不给 totalLines，让调用方沿用上一次的游标。
  if (out.timedOut) return const JobPoll(running: true);
  if (out.exitCode == kJobNotFoundExit) return const JobPoll(notFound: true);

  final lines = out.stdout.split('\n');
  if (lines.length < 2) return const JobPoll(notFound: true);

  final status = lines[0].trim();
  final total = int.tryParse(lines[1].trim());
  if (total == null) return const JobPoll(notFound: true);

  // `trimRight`：`tail` 的输出以换行结尾，split 之后末尾多一个空元素，
  // join 回去就多一个尾换行。对日志内容无意义，但会让「本次有没有新输出」
  // 的判断变得不确定（空输出会变成 '\n' 而不是 ''）。
  final body =
      lines.length > 2 ? lines.sublist(2).join('\n').trimRight() : '';

  if (status == 'running') {
    return JobPoll(running: true, totalLines: total, newOutput: body);
  }
  final code = int.tryParse(status);
  // status 既不是 running 也不是数字 → 我们不认识这个输出。宁可报
  // notFound 让模型停下问，也不要猜一个状态继续跑。
  if (code == null) return const JobPoll(notFound: true);
  return JobPoll(exitCode: code, totalLines: total, newOutput: body);
}

/// 一个 job 在看板上的样子。
///
/// [startedAt] 不落盘、不从远端取 —— job id 自带毫秒时间戳
/// （`job-<millis>-<rand4>`），[isValidJobId] 已经保证那一段是 10-17 位
/// 数字。多存一份就多一处能不一致的地方。
class JobSummary {
  final String id;
  final bool running;

  /// 已结束时的退出码。[running] 为 true 时恒为 null。
  final int? exitCode;
  final int totalLines;

  /// `.log` 的最后修改时刻。远端两种 `stat` 都不认时为 null。
  ///
  /// **看板靠它替代「判活」**：没有 `.exit` 的任务可能真在跑，也可能是服务器
  /// 重启后再也不会写 `.exit` 的僵尸。这两种在文件层面无法区分，所以不猜 ——
  /// 摆出「日志最后更新于何时」让用户自己判断。
  final DateTime? logMtime;

  const JobSummary({
    required this.id,
    required this.running,
    required this.totalLines,
    this.exitCode,
    this.logMtime,
  });

  /// **不变量**：这个 getter 对本类实例不会抛异常——由 [parseJobList]
  /// 维护，它在构造 [JobSummary] 之前会拒绝毫秒段超出 [_kMaxEpochMillis]
  /// 的 id。手工构造的 [JobSummary]（比如测试里直接 `JobSummary(...)`）
  /// 不享受这个保证。
  DateTime get startedAt =>
      DateTime.fromMillisecondsSinceEpoch(int.parse(id.split('-')[1]));
}

/// [parseJobList] 的结果。
///
/// [skipped] 必须回传给 UI。静默跳过会让「任务明明在跑但看板上没有」变成一个
/// 无法诊断的现象 —— 宁可在那一组尾部写「N 个条目无法识别」。
class JobListResult {
  final List<JobSummary> jobs;
  final int skipped;

  const JobListResult({this.jobs = const [], this.skipped = 0});
}

/// 拼出「列出这台机器上所有 job」的脚本。
///
/// 输出一行一个 job，`|` 分四段：`id|状态|日志行数|日志 mtime`。状态是
/// `running` 或退出码数字，与 [buildJobPollCommand] 的第一行同一套编码。
///
/// ## 两处不能省的防御
///
/// 1. **`[ -f "$f" ] || continue`** —— 目录里没有 `.log` 时，`"$d"/*.log`
///    会原样传下来（POSIX sh / bash / dash 默认不开 nullglob），参数展开
///    会把它当字面量算出一个名叫 `*` 的 id。（zsh 相反：默认 NOMATCH，
///    空目录会让 glob 直接报错、命令以非零退出。但这条命令走 SSH exec、
///    跑的是用户登录 shell，对调用方无害——[parseJobList] 对非零退出统一
///    返回空列表，和「确实没有 job」是同一个结果。）
/// 2. **`stat` 两级回退 + `|| echo 0`** —— GNU 是 `-c %Y`，BSD 是 `-f %m`；
///    两种都不认时给 0，让 [parseJobList] 把 mtime 判成未知，而不是让整次
///    扫描失败。BusyBox 支持前者。
///
/// `id` 用参数展开 `${f##*/}` / `${id%.log}` 而不是 `` `basename` ``——
/// 纯 shell 内建，每个 job 少一次 fork。BusyBox 里 `basename` 本身可用，
/// 这不是可用性取舍而是效率取舍，此文件已有同类先例：用 `while` 而不是
/// `seq`，因为 BusyBox 的 `seq` 不总是存在。
String buildJobListCommand() => 'd=$kJobDir; '
    '[ -d "\$d" ] || exit 0; '
    'for f in "\$d"/*.log; do '
    '[ -f "\$f" ] || continue; '
    'id=\${f##*/}; id=\${id%.log}; '
    'if [ -f "\$d/\$id.exit" ]; then s=\$(cat "\$d/\$id.exit"); '
    'else s=running; fi; '
    'm=\$(stat -c %Y "\$f" 2>/dev/null || stat -f %m "\$f" 2>/dev/null '
    '|| echo 0); '
    'echo "\$id|\$s|\$(wc -l < "\$f")|\$m"; '
    'done';

/// 解析 [buildJobListCommand] 的输出。
///
/// **每个 id 都要过 [isValidJobId]。** 那条注释说它是路径穿越的唯一防线时,
/// 指的是模型传进来的 id；现在多了一个来源（远端读回来的目录内容），而这些
/// id 下游同样会被拼进 [buildJobKillCommand] / [buildJobPollCommand]。
JobListResult parseJobList(CommandOutput out) {
  if (out.timedOut || out.exitCode != 0) return const JobListResult();

  final jobs = <JobSummary>[];
  var skipped = 0;
  for (final line in const LineSplitter().convert(out.stdout)) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('|');
    if (parts.length != 4) {
      skipped++;
      continue;
    }
    // id 只 trim 前后空白——isValidJobId 用的是锚定正则（^...$），trim
    // 不会放宽对内部字符的校验，纯粹是容忍远端输出可能带的空白。
    final id = parts[0].trim();
    // parts[2].trim()：GNU 的 `wc -l < f` 不填充，BSD/macOS 会左填充空格
    // 输出成 "       3"。`int.tryParse` 本身就会忽略首尾空白，所以这个
    // trim 单独删掉不会让任何现有测试变红——它是显式的、不依赖这一细节
    // 的防御，跟 id 那行一样，目的是不让这行代码的正确性偷偷绑在
    // int.tryParse 的空白容忍行为上。
    final total = int.tryParse(parts[2].trim());
    if (!isValidJobId(id) || total == null) {
      skipped++;
      continue;
    }
    // 形状合法不等于数值合法：17 位数字能超出 DateTime 能表示的范围，见
    // _kMaxEpochMillis 的文档。在这里挡住，[JobSummary.startedAt] 才能
    // 保证对任何进入列表的实例都不抛异常。
    final millis = int.parse(id.split('-')[1]);
    if (millis > _kMaxEpochMillis) {
      skipped++;
      continue;
    }
    final status = parts[1].trim();
    final code = status == 'running' ? null : int.tryParse(status);
    if (status != 'running' && code == null) {
      skipped++;
      continue;
    }
    final mtime = int.tryParse(parts[3].trim()) ?? 0;
    // 乘 1000 之前先判上界，而不是乘完再判：mtime 是远端 stat 给的任意
    // 整数，`mtime * 1000` 可能溢出 int64 回绕成另一个仍为正的值，让
    // fromMillisecondsSinceEpoch 照样抛 RangeError。降级路径必须和
    // mtime == 0 走同一条——buildJobListCommand 的注释写得很明白：stat
    // 给出看不懂的值时要让这里把 mtime 判成未知，而不是让整次扫描失败。
    final mtimeValid = mtime > 0 && mtime <= _kMaxEpochMillis ~/ 1000;
    jobs.add(JobSummary(
      id: id,
      running: status == 'running',
      exitCode: code,
      totalLines: total,
      logMtime:
          mtimeValid ? DateTime.fromMillisecondsSinceEpoch(mtime * 1000) : null,
    ));
  }
  return JobListResult(jobs: jobs, skipped: skipped);
}

/// 把 [parseJobList] 的结果写成给模型看的文案。
///
/// 单独一个纯函数而不是写在 executor 里，是为了能测 —— 全仓没有
/// `AgentToolContext` 的测试替身，而 executor 依赖它一大片接口。抽出来之后
/// executor 只剩三行编排。
String formatJobList(JobListResult r) {
  if (r.jobs.isEmpty) {
    return r.skipped > 0
        ? 'No background jobs found (${r.skipped} unreadable entries in the '
            'job directory).'
        : 'No background jobs on this server.';
  }
  final lines = <String>[];
  for (final j in r.jobs) {
    final status = j.running ? 'running' : 'exit ${j.exitCode}';
    final age = j.logMtime == null
        ? 'log mtime unknown'
        : 'log updated ${_agoEn(j.logMtime!)}';
    lines.add('`${j.id}` — $status, ${j.totalLines} lines, $age');
  }
  if (r.skipped > 0) {
    lines.add('(${r.skipped} unreadable entries skipped)');
  }
  // 这一句不能省。判据只有 `.exit` 在不在，而服务器重启后那个文件永远不会
  // 被写 —— 不说清楚，模型会把 running 当确凿事实，去等一个不会结束的任务。
  lines.add('Note: `running` only means there is no exit file yet — a job '
      'whose server rebooted stays `running` forever. Check the log mtime.');
  return lines.join('\n');
}

String _agoEn(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// 终止一个 job。
///
/// **负号 pid 杀的是整个进程组**。`setsid` 刚给它建了新会话，所以这一下
/// 能带走 `apt` 拉起的全部子进程；只杀父 pid 会留下一堆孤儿继续跑。
///
/// `|| true` 兜住「进程已经自己结束了」这种情形 —— 那不是失败。
String buildJobKillCommand(String jobId) {
  final pid = '$kJobDir/$jobId.pid';
  return 'if [ -f $pid ]; then kill -TERM -"\$(cat $pid)" 2>/dev/null || '
      'kill -TERM "\$(cat $pid)" 2>/dev/null || true; fi';
}

/// 清理已结束且超过 24 小时的 job。
///
/// ## 删除单位是 job，不是文件
///
/// 旧实现是 `find $kJobDir -type f -mtime +1 -delete`，按**每个文件各自的
/// mtime** 删。而一个 job 的三个文件 mtime 并不同步，于是有两个实测过的
/// 失效：
///
/// 1. **跑过 24 小时、仍在输出的任务**：`.log` 因持续写入 mtime 一直是新的、
///    保留；`.pid` 的 mtime 是启动那一刻、被删。于是
///    [buildJobKillCommand] 的 `if [ -f $pid ]` 直接跳过、整条命令静默成功
///    —— 那个任务再也杀不掉。
/// 2. **跑过 24 小时、不输出的任务**（`sleep`、等锁、静默编译）：三个文件
///    全删。[buildJobPollCommand] 返回 `notFound`，任务还在远端跑着而 App
///    侧彻底失联。
///
/// 现在以 `.exit` 为锚：它的 mtime 就是任务结束时刻，语义正好对上；还在跑
/// 的任务没有 `.exit`，三个文件一个都不会被碰。
///
/// 用 `find -mtime` 而不是自己算时间戳，因为 `-mtime` 是 POSIX、能过
/// BusyBox。整体 `|| true` 兜住空目录，防止打断调用方的 `&&` 链。
// `( ... )` 是真子 shell，不是 `{ ... }` 组合命令——差别在 `exit 0`：
// 组合命令跟当前 shell 共享执行上下文，组内的 `exit` 会直接终止调用方拼
// 进同一个 `-c` 脚本里的整条命令（例如 `cleanup() && echo done` 里的
// `&& echo done` 永远不会跑到）；子 shell 里的 `exit` 只结束子 shell 自己。
String buildJobCleanupCommand() => '( d=$kJobDir; '
    '[ -d "\$d" ] || exit 0; '
    'for e in "\$d"/*.exit; do '
    '[ -f "\$e" ] || continue; '
    'id=\${e##*/}; id=\${id%.exit}; '
    'if [ -n "\$(find "\$e" -mtime +1 2>/dev/null)" ]; then '
    'rm -f "\$d/\$id.log" "\$d/\$id.pid" "\$d/\$id.exit"; '
    'fi; '
    'done ) 2>/dev/null || true';
