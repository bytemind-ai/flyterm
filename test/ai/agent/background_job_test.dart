import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ai/agent/background_job.dart';
import 'package:flyterm/ai/agent/command_runner.dart';

void main() {
  group('newJobId', () {
    test('形如 job-<毫秒>-<4位>，同一毫秒内两次不重复', () {
      final a = newJobId(DateTime.fromMillisecondsSinceEpoch(1700000000000), 7);
      final b = newJobId(DateTime.fromMillisecondsSinceEpoch(1700000000000), 8);
      expect(a, matches(RegExp(r'^job-\d+-[0-9a-f]{4}$')));
      expect(a, isNot(equals(b)));
    });

    test('不含 shell 特殊字符——它会被直接拼进命令里', () {
      final id = newJobId(DateTime.now(), 1234);
      expect(id, matches(RegExp(r'^[A-Za-z0-9\-]+$')));
    });
  });

  group('buildJobStartCommand', () {
    test('用 setsid 脱离会话，退出码落盘到 .exit', () {
      final c = buildJobStartCommand('job-1-abcd', 'apt upgrade -y');
      expect(c, contains('setsid'));
      expect(c, contains('apt upgrade -y'));
      expect(c, contains('job-1-abcd.exit'));
      expect(c, contains('job-1-abcd.log'));
      expect(c, contains('job-1-abcd.pid'));
    });

    test('命令里的单引号被正确转义，不会截断脚本', () {
      final c = buildJobStartCommand(
          'job-1-abcd', "awk '{print \$1}' /var/log/x");
      // shellQuote 的 POSIX 手法：'\'' 结束再重开
      expect(c, contains(r"'\''"));
    });

    test('内层用 \$HOME 而非 ~ ——单引号里 ~ 不展开', () {
      final c = buildJobStartCommand('job-1-abcd', 'sleep 5');
      // inner 段（被单引号包住的那部分）不能出现 ~
      final innerStart = c.indexOf("sh -c '");
      final innerEnd = c.indexOf("' >", innerStart);
      final inner = c.substring(innerStart, innerEnd);
      expect(inner.contains('~'), isFalse);
      expect(inner, contains(r'$HOME'));
    });

    // 这一组守的是 shell **结构**，不是字符出现与否。
    //
    // 原先这里只有一条 `indexOf('mkdir -p') < indexOf('setsid')`，它断言的
    // 是字符串位置——而字符串位置恰恰不等于执行顺序。真实的 bug（`&&` 与
    // `&` 的优先级导致 mkdir 被卷进后台）就从这条测试底下大摇大摆走过去了，
    // 20 条测试全绿。
    test('mkdir 与 setsid 之间是 `;` 而不是 `&&`', () {
      final c = buildJobStartCommand('job-1-abcd', 'sleep 1');
      // `&&` 会让 `&` 把整条 AND-list 一起后台化，mkdir 随之变成异步
      expect(c, isNot(contains('&&')));
      expect(c, contains('mkdir -p "\$HOME"/.flyterm/jobs; setsid '));
    });

    test('pid 由内层 sh 写 \$\$，而不是外层写 \$!', () {
      final c = buildJobStartCommand('job-1-abcd', 'sleep 1');
      // `$!` 拿到的会是包装子 shell 而非任务本身，kill 会杀错对象
      expect(c, isNot(contains(r'$!')));
      expect(c, contains(r'echo $$ > "$HOME"/.flyterm/jobs/job-1-abcd.pid'));
    });

    test('后台化的是最后一条简单命令，命令以 & 结尾', () {
      final c = buildJobStartCommand('job-1-abcd', 'sleep 1');
      // 结尾的 `&` 之后不能再挂东西——挂了就说明后台化的不是简单命令，
      // 外层 shell 不会立刻退出，SSH channel 的 stdout 就被吃住了
      expect(c.trimRight(), endsWith('&'));
    });

    test('用户命令被子 shell 包住——否则一个 exit 就让退出码永远不落盘', () {
      final c = buildJobStartCommand('job-1-abcd', 'foo || exit 1');
      expect(c, contains('( foo || exit 1 )'));
    });

    test('.exit 先写 .tmp 再 mv，避免读到刚创建的空文件', () {
      final c = buildJobStartCommand('job-1-abcd', 'sleep 1');
      expect(c, contains('.exit.tmp'));
      expect(c, contains('mv "\$HOME"/.flyterm/jobs/job-1-abcd.exit.tmp '
          '"\$HOME"/.flyterm/jobs/job-1-abcd.exit'));
    });

    // golden：整串一次性锁死。片段断言看不出运算符优先级，而这个函数的
    // 每一个字符都会被送到别人的生产服务器上执行。任何结构改动都应该在
    // 这里显式地被看见一次。
    test('完整命令串（golden）', () {
      expect(
        buildJobStartCommand('job-1-abcd', 'apt upgrade -y'),
        equals(
          'mkdir -p "\$HOME"/.flyterm/jobs; '
          'setsid sh -c '
          "'echo \$\$ > \"\$HOME\"/.flyterm/jobs/job-1-abcd.pid; "
          '( apt upgrade -y ); '
          'echo \$? > "\$HOME"/.flyterm/jobs/job-1-abcd.exit.tmp; '
          'mv "\$HOME"/.flyterm/jobs/job-1-abcd.exit.tmp '
          "\"\$HOME\"/.flyterm/jobs/job-1-abcd.exit' "
          '> "\$HOME"/.flyterm/jobs/job-1-abcd.log 2>&1 &',
        ),
      );
    });
  });

  group('buildJobPollCommand', () {
    test('wait 被夹在 [0, 60]', () {
      expect(buildJobPollCommand('j', 0, 999), contains('-lt 60'));
      expect(buildJobPollCommand('j', 0, -5), contains('-lt 0'));
      expect(buildJobPollCommand('j', 0, 15), contains('-lt 15'));
    });

    test('从 sinceLine+1 行开始取新增日志', () {
      expect(buildJobPollCommand('j', 42, 0), contains('tail -n +43'));
    });

    test('输出以状态行与总行数开头，供 parseJobPoll 解析', () {
      final c = buildJobPollCommand('j', 0, 0);
      expect(c, contains('.exit'));
      expect(c, contains('wc -l'));
    });
  });

  group('parseJobPoll', () {
    CommandOutput out(String stdout, {int exitCode = 0}) =>
        CommandOutput(stdout: stdout, stderr: '', exitCode: exitCode);

    test('running + 行数 + 新增日志', () {
      final p = parseJobPoll(out('running\n12\nline A\nline B'));
      expect(p.running, isTrue);
      expect(p.exitCode, isNull);
      expect(p.totalLines, equals(12));
      expect(p.newOutput, equals('line A\nline B'));
    });

    test('已结束时 exitCode 取自 .exit 文件内容', () {
      final p = parseJobPoll(out('0\n3\ndone'));
      expect(p.running, isFalse);
      expect(p.exitCode, equals(0));
    });

    test('非零退出码照样解析', () {
      final p = parseJobPoll(out('137\n5\nkilled'));
      expect(p.running, isFalse);
      expect(p.exitCode, equals(137));
    });

    test('日志为空时 newOutput 是空串而不是 null', () {
      final p = parseJobPoll(out('running\n0\n'));
      expect(p.newOutput, isEmpty);
    });

    test('job 不存在时明确报 notFound——绝不能当成「还在跑」', () {
      // 远端脚本找不到目录时以 kJobNotFoundExit 退出
      final p = parseJobPoll(out('', exitCode: kJobNotFoundExit));
      expect(p.notFound, isTrue);
      expect(p.running, isFalse);
    });

    test('输出格式不认识时报 notFound 而不是猜', () {
      final p = parseJobPoll(out('garbage'));
      expect(p.notFound, isTrue);
    });

    // 下面两条各自钉住一个独立的 notFound 分支。上面那条 'garbage' 命中的
    // 是「行数不足 2」，走不到这两支——少了它们，行数栏或状态栏是垃圾时的
    // 行为其实没人验证过。
    test('行数栏不是数字时报 notFound', () {
      final p = parseJobPoll(out('running\nabc\nsome log'));
      expect(p.notFound, isTrue);
      expect(p.running, isFalse);
    });

    test('状态栏既不是 running 也不是数字时报 notFound，不猜一个状态继续跑',
        () {
      final p = parseJobPoll(out('weird\n5\nsome log'));
      expect(p.notFound, isTrue);
      expect(p.running, isFalse);
      expect(p.exitCode, isNull);
    });

    test('命令本身超时——按「还在跑」处理，下一轮再问', () {
      final p = parseJobPoll(const CommandOutput(
          stdout: '', stderr: '', exitCode: -1, timedOut: true));
      expect(p.running, isTrue);
      expect(p.notFound, isFalse);
      expect(p.totalLines, isNull);
    });
  });

  group('buildJobKillCommand', () {
    test('杀整个进程组——负号 pid', () {
      final c = buildJobKillCommand('job-1-abcd');
      expect(c, contains('kill -TERM -'));
      expect(c, contains('job-1-abcd.pid'));
    });
  });

  test('buildJobCleanupCommand 以 .exit 为锚，删 24 小时前已结束的 job 且永不失败',
      () {
    final c = buildJobCleanupCommand();
    // 删除单位是 job（三个文件一起删），锚点是 .exit 的 mtime——不是
    // `find -type f -mtime +1 -delete` 那种按文件各自 mtime 删的老实现。
    // 旧实现会把一个跑了 25 小时仍在输出的任务的 .pid 单独删掉（.log 因
    // 持续写入 mtime 是新的），导致 kill 命令的 `if [ -f $pid ]` 静默
    // 跳过、任务再也杀不掉——所以这里不能再断言 `-type f` 或字面量
    // `-delete`（旧实现的 -delete 是 find 内建，新实现改用 rm -f）。
    expect(c, isNot(contains('-type f')));
    expect(c, contains('.exit'));
    expect(c, contains('-mtime +1'));
    expect(c, contains('rm -f'));
    // 目录不存在时 find/for 都不该报错并打断调用方的 && 链
    expect(c, contains('true'));
  });

  group('isValidJobId', () {
    test('接受自己生成的 id', () {
      expect(isValidJobId(newJobId(DateTime.now(), 42)), isTrue);
    });

    test('拒绝路径穿越与各种畸形输入', () {
      for (final bad in [
        '../../../etc/shadow',
        'job-1-abcd/../../x',
        'job-abc-1234',
        'job-1700000000000-ABCD',
        'job-1700000000000-abc',
        '',
        'job-1700000000000-abcd ',
        r'job-1700000000000-abcd;rm -rf /',
      ]) {
        expect(isValidJobId(bad), isFalse, reason: bad);
      }
    });
  });

  group('parseJobList', () {
    CommandOutput ok(String stdout) =>
        CommandOutput(stdout: stdout, stderr: '', exitCode: 0);

    test('正常三行——running 与两种退出码都解析对', () {
      final r = parseJobList(ok(
          'job-1757000000000-aaaa|running|12|1757000001\n'
          'job-1757000000001-bbbb|0|340|1757000002\n'
          'job-1757000000002-cccc|137|5|1757000003\n'));
      expect(r.jobs, hasLength(3));
      expect(r.skipped, 0);
      expect(r.jobs[0].running, isTrue);
      expect(r.jobs[0].exitCode, isNull);
      expect(r.jobs[0].totalLines, 12);
      expect(r.jobs[1].running, isFalse);
      expect(r.jobs[1].exitCode, 0);
      expect(r.jobs[2].exitCode, 137);
      // 唯一的单位换算（秒→毫秒）没有别的测试断言具体值——用 0 的两条
      // mtime 测试测不出 `* 1000` 掉了会怎样。1757000001 秒 = 2025-09
      // 某天，换算错了会变成 1970-01-21 附近，用户看到的是一个假时间。
      expect(r.jobs[0].logMtime,
          equals(DateTime.fromMillisecondsSinceEpoch(1757000001000)));
    });

    test('startedAt 从 id 还原，不需要远端给', () {
      final r = parseJobList(ok('job-1757000000000-aaaa|running|0|0\n'));
      expect(r.jobs.single.startedAt.millisecondsSinceEpoch, 1757000000000);
    });

    test('17 位 id（形状合法）若毫秒值超出 DateTime 上限，整行被跳过', () {
      // _jobIdRe 允许 10-17 位数字，但 DateTime.fromMillisecondsSinceEpoch
      // 的上限是 8640000000000000（16 位）。job-9999999999999999-aaaa 能
      // 通过 isValidJobId，若不在这里挡住，会在消费方调用 startedAt 时
      // 抛 RangeError——而 startedAt 将来会在 build() 里被调用，一个畸形
      // 文件名就能让整个看板红屏。
      final r = parseJobList(
          ok('job-9999999999999999-aaaa|running|3|1757000001\n'));
      expect(r.jobs, isEmpty);
      expect(r.skipped, 1);
    });

    test('mtime 为 0 → logMtime 是 null，不是 1970 年', () {
      // 远端两种 stat 都不认时脚本回落到 `echo 0`。当成时间戳会显示
      // 「1970-01-01」——那比不显示更糟，它看起来像个真的时间。
      final r = parseJobList(ok('job-1757000000000-aaaa|running|3|0\n'));
      expect(r.jobs.single.logMtime, isNull);
    });

    test('mtime 畸形到乘 1000 会溢出时，按未知处理而不是抛 RangeError', () {
      // int.tryParse('99999999999999999') 能成功（int64 装得下），但乘
      // 1000 之后会溢出 int64、回绕，再喂给 fromMillisecondsSinceEpoch 会
      // 抛 RangeError——这正是 buildJobListCommand 的注释说要避免的：stat
      // 给出看不懂的值时，parseJobList 该把它判成未知，而不是让整次扫描
      // 失败。
      final r = parseJobList(
          ok('job-1757000000000-aaaa|running|3|99999999999999999\n'));
      expect(r.jobs, hasLength(1));
      expect(r.skipped, 0);
      expect(r.jobs.single.logMtime, isNull);
    });

    test('字段数不对的行被跳过并计数，不让整台机器失败', () {
      final r = parseJobList(ok('job-1757000000000-aaaa|running|3|1757000001\n'
          'garbage line without pipes\n'
          'job-1757000000001-bbbb|0|1\n'));
      expect(r.jobs, hasLength(1));
      expect(r.skipped, 2);
    });

    test('字段数「过多」的行同样被跳过——不能被悄悄放宽成 length < 4', () {
      // 测试名叫「字段数不对」，但上面那条的两个坏样本都是过少（1 段、
      // 2 段）。把实现里的 `!= 4` 改成 `< 4` 照样能让上面那条测试全绿——
      // 得靠这条锁住「过多」也是不对」这一半。
      final r = parseJobList(ok(
          'job-1757000000000-aaaa|running|3|1757000001|extra-field\n'));
      expect(r.jobs, isEmpty);
      expect(r.skipped, 1);
    });

    test('状态既非 running 也非数字的行被跳过，不造出非法状态的 JobSummary',
        () {
      // 删掉这个分支的守卫，测试照样全绿——但会造出
      // running == false && exitCode == null 的实例，违反 JobSummary 的
      // 注释里写的不变量。输入不是臆想：.exit 被截断或手工建成空文件时，
      // 远端脚本里 `s=$(cat ...)` 就是空串。
      final r = parseJobList(
          ok('job-1757000000000-aaaa|weird|3|1757000001\n'));
      expect(r.jobs, isEmpty);
      expect(r.skipped, 1);
    });

    test('日志行数栏带前导空格时被 trim 掉——BSD/macOS 的 `wc -l < f` 会左'
        '填充空格', () {
      // GNU wc -l < f 不填充，BSD/macOS 会输出 "       3" 这种形式。
      // parts[2].trim() 就是防这个的；删掉它这条测试会先挂在
      // int.tryParse 上（带空格的字符串解析失败），从而暴露这个防御点。
      final r = parseJobList(
          ok('job-1757000000000-aaaa|running|      3|1757000001\n'));
      expect(r.jobs, hasLength(1));
      expect(r.jobs.single.totalLines, 3);
    });

    test('非法 id 被跳过——它下游会被拼进 kill / poll 命令', () {
      // 这条同时是路径穿越防线的测试。id 现在有第二个来源（远端读回来的
      // 目录内容），防线要跟着覆盖。
      final r = parseJobList(ok('../../../etc/shadow|running|3|1757000001\n'
          'job-1757000000000-aaaa|running|3|1757000001\n'));
      expect(r.jobs.single.id, 'job-1757000000000-aaaa');
      expect(r.skipped, 1);
    });

    test('空输出 → 空列表，这是「没有任务」的正常态', () {
      expect(parseJobList(ok('')).jobs, isEmpty);
      expect(parseJobList(ok('\n')).skipped, 0);
    });

    test('命令超时或非零退出 → 丢弃已有输出，不展示残缺看板', () {
      // stdout 必须非空：喂空串的话，把这条守卫整个删掉测试照样绿 ——
      // 它断言的就成了「空进空出」，与守卫无关。真正要守的是「超时截断了
      // 半截输出时，丢弃而不是展示一个残缺的看板」。
      const t = CommandOutput(
          stdout: 'job-1757000000000-aaaa|running|3|1757000001\n',
          stderr: '', exitCode: -1, timedOut: true);
      expect(parseJobList(t).jobs, isEmpty);
      expect(parseJobList(t).skipped, 0);
    });
  });

  group('formatJobList', () {
    JobSummary job(String id,
            {bool running = true, int? exitCode, int lines = 1}) =>
        JobSummary(
            id: id, running: running, exitCode: exitCode, totalLines: lines);

    test('列出每个任务的 id、状态、行数', () {
      final s = formatJobList(JobListResult(jobs: [
        job('job-1757000000000-aaaa', lines: 12),
        job('job-1757000000001-bbbb',
            running: false, exitCode: 0, lines: 340),
      ]));
      expect(s, contains('job-1757000000000-aaaa'));
      expect(s, contains('running'));
      expect(s, contains('exit 0'));
      expect(s, contains('340 lines'));
    });

    test('空列表时说明白，不回空串', () {
      // 空串会让模型以为工具坏了，进而重试或改用 bash 去 ls —— 那正是这个
      // 工具要省掉的往返。
      final s = formatJobList(const JobListResult());
      expect(s.toLowerCase(), contains('no background jobs'));
    });

    test('无法识别的条目数回填给模型', () {
      final s = formatJobList(const JobListResult(skipped: 2));
      expect(s, contains('2 unreadable'));
    });

    test('必须带上「running 只表示还没有 exit 文件」这句', () {
      // 不说清楚，模型会把 running 当确凿事实，去等一个服务器已经重启过、
      // 永远不会写 .exit 的任务。
      final s = formatJobList(JobListResult(jobs: [job('job-1757000000000-aaaa')]));
      expect(s, contains('exit file'));
    });
  });

  group('BackgroundJobEvent.lastCheckedAtMs', () {
    BackgroundJobEvent make({int? lastCheckedAtMs}) => BackgroundJobEvent(
          seq: 1,
          jobId: 'j1',
          command: 'sleep 300',
          description: '等锁',
          startedAtMs: 1000,
          lineCursor: 0,
          tail: '',
          lastCheckedAtMs: lastCheckedAtMs,
        );

    test('不传时等于 startedAtMs —— 启动那一刻我们确实确认过', () {
      expect(make().lastCheckedAtMs, 1000);
    });

    test('归档往返保住它', () {
      final ev = make(lastCheckedAtMs: 5000);
      final back = agentEventsFromJson([agentEventToJson(ev)]).single
          as BackgroundJobEvent;
      expect(back.lastCheckedAtMs, 5000);
    });

    test('老存档没有这个字段时回落到 startedAtMs，不是 0 也不是 now', () {
      // 三个候选里只有 startedAtMs 是诚实的：now 会谎称「刚确认过」，
      // 0 会显示「56 年前」。这条是本设计里最容易写错、错了又最难发现的
      // 一处——错成 now 的话 UI 看起来完全正常。
      final legacy = {
        't': 'job',
        'seq': 1,
        'jobId': 'j1',
        'command': 'sleep 300',
        'description': '等锁',
        'startedAtMs': 1000,
        'lineCursor': 0,
      };
      final back =
          agentEventsFromJson([legacy]).single as BackgroundJobEvent;
      expect(back.lastCheckedAtMs, 1000);
    });
  });
}
