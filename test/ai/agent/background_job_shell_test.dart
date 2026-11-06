@Tags(['shell'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/background_job.dart';
import 'package:flyterm/ai/agent/command_runner.dart';

/// 把 [buildJobStartCommand] 一类的产物**真的丢进 bash 执行**。
///
/// ## 为什么必须有这一组
///
/// 这个文件里的函数产出的是会在用户生产服务器上执行的命令字符串。字符串
/// 断言（`contains('setsid')`、`indexOf('mkdir') < indexOf('setsid')`）测
/// 不出 shell 的**语义**——而这里真实发生过的三个 bug 全都是语义层面的：
///
/// 1. `mkdir -p D && setsid ... &` 里 `&` 的优先级低于 `&&`，整条 AND-list
///    被后台化，`mkdir` 随之异步，全新机器首次运行必然写不出 `.pid`
/// 2. 同一个原因让 `$!` 拿到包装子 shell 而非任务，`kill -TERM -<pid>`
///    一个进程都杀不掉，还可能误伤无关进程组
/// 3. 包装壳继承 SSH channel 的 stdout 并活到任务结束，`run_background`
///    每次都撞 20 秒超时——恰好是它要解决的那个问题
///
/// 三个都带着「20 条字符串测试全绿」通过了评审前的所有关卡。真跑一遍是
/// 唯一能兜住这类错误的手段。
///
/// ## 跳过条件
///
/// `setsid` 是 util-linux 的东西，macOS 默认没有。非 Linux 或缺 setsid 时
/// 整组跳过而不是失败——跳过会在输出里明说，不会伪装成通过。
void main() {
  final canRun = Platform.isLinux &&
      Process.runSync('sh', ['-c', 'command -v setsid >/dev/null 2>&1'])
              .exitCode ==
          0;

  if (!canRun) {
    test('跳过：真 shell 测试需要 Linux 且有 setsid', () {
      printOnFailure('platform=${Platform.operatingSystem}');
      markTestSkipped('needs Linux with setsid');
    }, skip: 'needs Linux with setsid');
    return;
  }

  late Directory home;
  final started = <int>[];

  /// 在隔离的 HOME 下跑一条命令。`kJobDir` 用的是 `"$HOME"`，所以换掉
  /// HOME 就等于换掉整个 job 目录，不会碰到真实的 ~/.flyterm。
  ProcessResult sh(String command) => Process.runSync(
        'bash',
        ['-c', command],
        environment: {'HOME': home.path},
      );

  File jobFile(String id, String ext) =>
      File('${home.path}/.flyterm/jobs/$id.$ext');

  /// 等某个文件出现。远端脚本是异步起来的，落盘有毫秒级延迟。
  Future<bool> waitForFile(File f,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (f.existsSync()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  bool alive(int pid) => Process.runSync('ps', ['-p', '$pid']).exitCode == 0;

  setUp(() {
    home = Directory.systemTemp.createTempSync('flyterm_job_shell_');
    started.clear();
  });

  tearDown(() {
    // 先收干净可能还活着的任务，再删目录 —— 漏掉的 sleep 会在测试机上
    // 一直挂着，跑几十次之后很难查。
    for (final pid in started) {
      Process.runSync('sh', ['-c', 'kill -KILL -$pid 2>/dev/null; '
          'kill -KILL $pid 2>/dev/null; true']);
    }
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('外层 shell 立刻退出，不吃住 stdout（否则 run_background 必然超时）',
      () async {
    const id = 'job-1700000000001-aaaa';
    final sw = Stopwatch()..start();
    final r = sh(buildJobStartCommand(id, 'sleep 6'));
    sw.stop();

    expect(r.exitCode, equals(0), reason: 'stderr: ${r.stderr}');
    // Process.runSync 读 stdout 直到 EOF。若后台进程继承并持有 stdout，
    // 这里会一直等到 sleep 结束（6 秒）。真正的 SshCommandRunner 等的是
    // 同一件事，预算只有 20 秒。
    expect(sw.elapsedMilliseconds, lessThan(2000),
        reason: '外层没有立刻退出，说明后台化的不是简单命令');

    final pidFile = jobFile(id, 'pid');
    expect(await waitForFile(pidFile), isTrue);
    started.add(int.parse(pidFile.readAsStringSync().trim()));
  });

  test('全新 HOME 首次运行也能写出 .pid 与 .log（mkdir 必须是同步的）',
      () async {
    const id = 'job-1700000000002-bbbb';
    // home 是刚建的临时目录，~/.flyterm/jobs 不存在 —— 这正是首次部署的用户
    // 会遇到的状态。mkdir 若被卷进后台，前台的写 pid 会 No such file。
    expect(Directory('${home.path}/.flyterm/jobs').existsSync(), isFalse);

    final r = sh(buildJobStartCommand(id, 'sleep 3'));

    expect(r.exitCode, equals(0), reason: 'stderr: ${r.stderr}');
    expect(r.stderr.toString(), isNot(contains('No such file')));
    expect(await waitForFile(jobFile(id, 'pid')), isTrue);
    expect(jobFile(id, 'log').existsSync(), isTrue);
    started.add(int.parse(jobFile(id, 'pid').readAsStringSync().trim()));
  });

  test('.pid 记的是新进程组的 leader，负号 kill 能带走整棵子进程树',
      () async {
    const id = 'job-1700000000003-cccc';
    // 外层再套一层 sh，制造一棵真的子进程树：只杀父 pid 的话 sleep 会活下来
    sh(buildJobStartCommand(id, 'sh -c "sleep 30 & sleep 30"'));

    final pidFile = jobFile(id, 'pid');
    expect(await waitForFile(pidFile), isTrue);
    final pid = int.parse(pidFile.readAsStringSync().trim());
    started.add(pid);

    // setsid 之后内层 sh 自成会话与进程组，pgid 必须等于它自己的 pid ——
    // 这是 `kill -TERM -<pid>` 能成立的前提。
    final pgid = Process.runSync('ps', ['-o', 'pgid=', '-p', '$pid'])
        .stdout
        .toString()
        .trim();
    expect(pgid, equals('$pid'),
        reason: '.pid 不是进程组 leader，负号 kill 会 ESRCH');

    // 数一下这个进程组里有多少进程，确认确实是一棵树而不是单个进程
    final before = Process.runSync('ps', ['-o', 'pid=', '-g', '$pid'])
        .stdout
        .toString()
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .length;
    expect(before, greaterThan(1), reason: '测试没造出子进程树，这条就白测了');

    final killed = sh(buildJobKillCommand(id));
    expect(killed.exitCode, equals(0));

    // 给 SIGTERM 一点生效时间
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (alive(pid) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(alive(pid), isFalse, reason: '进程组 leader 还活着');
    final after = Process.runSync('ps', ['-o', 'pid=', '-g', '$pid'])
        .stdout
        .toString()
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .length;
    expect(after, equals(0), reason: '进程组里还有残留，子进程没被带走');
  });

  test('任务结束后 .exit 里是真实退出码，且不会读到空文件', () async {
    const id = 'job-1700000000004-dddd';
    sh(buildJobStartCommand(id, 'echo hello; exit 42'));

    final exitFile = jobFile(id, 'exit');
    expect(await waitForFile(exitFile), isTrue);
    // 原子写（tmp + mv）保证：文件一出现，内容就是完整的
    expect(exitFile.readAsStringSync().trim(), equals('42'));
    expect(jobFile(id, 'log').readAsStringSync().trim(), equals('hello'));
    // 中间文件不该留下
    expect(jobFile(id, 'exit.tmp').existsSync(), isFalse);
  });

  test('命令里的单引号不会截断脚本（awk 的 \$1 由 awk 自己拿到）', () async {
    const id = 'job-1700000000005-eeee';
    final data = File('${home.path}/data.txt')
      ..writeAsStringSync('alpha 1\nbeta 2\n');
    sh(buildJobStartCommand(id, "awk '{print \$1}' ${data.path}"));

    expect(await waitForFile(jobFile(id, 'exit')), isTrue);
    expect(jobFile(id, 'exit').readAsStringSync().trim(), equals('0'));
    // $1 若被任何一层 shell 展开，输出会是整行或空行
    expect(jobFile(id, 'log').readAsStringSync().trim(),
        equals('alpha\nbeta'));
  });

  test('轮询命令：running / 行数 / 增量三段都对得上', () async {
    const id = 'job-1700000000006-ffff';
    sh(buildJobStartCommand(id, 'echo one; echo two; sleep 5'));
    expect(await waitForFile(jobFile(id, 'log')), isTrue);
    started.add(int.parse(
        (await waitForFile(jobFile(id, 'pid')))
            ? jobFile(id, 'pid').readAsStringSync().trim()
            : '0'));

    // 等两行都落盘
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (jobFile(id, 'log').readAsLinesSync().length < 2 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final peek = sh(buildJobPollCommand(id, 0, 0));
    final parsed = parseJobPoll(CommandOutput(
      stdout: peek.stdout.toString(),
      stderr: peek.stderr.toString(),
      exitCode: peek.exitCode,
    ));

    expect(parsed.running, isTrue);
    expect(parsed.notFound, isFalse);
    expect(parsed.totalLines, equals(2));
    expect(parsed.newOutput, equals('one\ntwo'));

    // 第二次从游标之后取，应该没有新内容
    final second = sh(buildJobPollCommand(id, parsed.totalLines!, 0));
    final parsed2 = parseJobPoll(CommandOutput(
      stdout: second.stdout.toString(),
      stderr: second.stderr.toString(),
      exitCode: second.exitCode,
    ));
    expect(parsed2.newOutput, isEmpty);
  });

  test('log 不存在时轮询回 notFound，而不是伪装成还在跑', () {
    final r = sh(buildJobPollCommand('job-1700000000007-9999', 0, 0));
    expect(r.exitCode, equals(kJobNotFoundExit));

    final parsed = parseJobPoll(CommandOutput(
      stdout: r.stdout.toString(),
      stderr: r.stderr.toString(),
      exitCode: r.exitCode,
    ));
    expect(parsed.notFound, isTrue);
    expect(parsed.running, isFalse);
  });

  test('wait 真的会阻塞到有新输出（不是立刻返回）', () async {
    const id = 'job-1700000000008-8888';
    // 1 秒后才产出第一行
    sh(buildJobStartCommand(id, 'sleep 1; echo late'));
    expect(await waitForFile(jobFile(id, 'pid')), isTrue);
    started.add(int.parse(jobFile(id, 'pid').readAsStringSync().trim()));

    final sw = Stopwatch()..start();
    final r = sh(buildJobPollCommand(id, 0, 5));
    sw.stop();

    // 阻塞了至少 1 秒才拿到那一行 —— 若 wait 没生效会 <100ms 返回空
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(900));
    final parsed = parseJobPoll(CommandOutput(
      stdout: r.stdout.toString(),
      stderr: r.stderr.toString(),
      exitCode: r.exitCode,
    ));
    expect(parsed.newOutput, contains('late'));
  });

  test('cleanup 在目录不存在时也不打断调用方的 && 链', () {
    final r = sh('${buildJobCleanupCommand()} && echo CHAIN_OK');
    expect(r.exitCode, equals(0));
    expect(r.stdout.toString(), contains('CHAIN_OK'));
  });

  group('buildJobListCommand（真 shell）', () {
    test('空目录 → 空输出，退出码 0', () {
      final r = sh(buildJobListCommand());
      expect(r.exitCode, 0);
      expect((r.stdout as String).trim(), isEmpty);
    });

    test('目录不存在 → 空输出，退出码 0（全新机器首次打开看板）', () {
      final fresh = Directory.systemTemp.createTempSync('jobs_fresh');
      addTearDown(() => fresh.deleteSync(recursive: true));
      final r = Process.runSync('bash', ['-c', buildJobListCommand()],
          environment: {'HOME': fresh.path});
      expect(r.exitCode, 0);
      expect((r.stdout as String).trim(), isEmpty);
    });

    test('glob 不匹配时不产出名叫 * 的 id', () {
      // POSIX sh 默认不开 nullglob，`"$d"/*.log` 会原样传下来。少了
      // `[ -f "$f" ] || continue` 这一行，输出就是 `*|running|0|0`。
      Directory('${home.path}/.flyterm/jobs').createSync(recursive: true);
      final r = sh(buildJobListCommand());
      expect(r.exitCode, 0);
      expect((r.stdout as String), isNot(contains('*')));
      expect((r.stdout as String).trim(), isEmpty);
    });

    test('running 与已结束混合 —— 状态、行数、mtime 都对得上', () {
      final dir = Directory('${home.path}/.flyterm/jobs')
        ..createSync(recursive: true);
      File('${dir.path}/job-1757000000000-aaaa.log')
          .writeAsStringSync('a\nb\nc\n');
      File('${dir.path}/job-1757000000001-bbbb.log')
          .writeAsStringSync('done\n');
      File('${dir.path}/job-1757000000001-bbbb.exit').writeAsStringSync('0\n');

      final parsed = parseJobList(CommandOutput(
        stdout: sh(buildJobListCommand()).stdout as String,
        stderr: '',
        exitCode: 0,
      ));

      expect(parsed.skipped, 0);
      final byId = {for (final j in parsed.jobs) j.id: j};
      expect(byId['job-1757000000000-aaaa']!.running, isTrue);
      expect(byId['job-1757000000000-aaaa']!.totalLines, 3);
      expect(byId['job-1757000000000-aaaa']!.logMtime, isNotNull);
      expect(byId['job-1757000000001-bbbb']!.running, isFalse);
      expect(byId['job-1757000000001-bbbb']!.exitCode, 0);
    });

    test('HOME 含空格时不被拆词', () {
      // kJobDir 是 `"$HOME"/.flyterm/jobs`，带引号正是为了这个。
      final spaced =
          Directory.systemTemp.createTempSync('job board with space');
      addTearDown(() => spaced.deleteSync(recursive: true));
      final dir = Directory('${spaced.path}/.flyterm/jobs')
        ..createSync(recursive: true);
      File('${dir.path}/job-1757000000000-aaaa.log').writeAsStringSync('x\n');

      final r = Process.runSync('bash', ['-c', buildJobListCommand()],
          environment: {'HOME': spaced.path});
      expect(r.exitCode, 0);
      expect(r.stdout as String, contains('job-1757000000000-aaaa|running|1|'));
    });
  });

  group('buildJobCleanupCommand（真 shell）', () {
    /// 造一个 job 的三个文件，并把 mtime 设到 [daysAgo] 天前。
    void makeJob(String id,
        {required bool finished, required int daysAgo}) {
      final dir = Directory('${home.path}/.flyterm/jobs')
        ..createSync(recursive: true);
      File('${dir.path}/$id.log').writeAsStringSync('out\n');
      File('${dir.path}/$id.pid').writeAsStringSync('12345\n');
      if (finished) File('${dir.path}/$id.exit').writeAsStringSync('0\n');
      final stamp = DateTime.now().subtract(Duration(days: daysAgo));
      final ts = '${stamp.year}-${stamp.month.toString().padLeft(2, '0')}-'
          '${stamp.day.toString().padLeft(2, '0')} 12:00:00';
      for (final ext in ['log', 'pid', if (finished) 'exit']) {
        Process.runSync('touch', ['-d', ts, '${dir.path}/$id.$ext']);
      }
    }

    test('还在跑的老任务：三个文件一个都不许动', () {
      // 这是修掉的 bug 本体。旧实现按每个文件各自的 mtime 删，一个跑了
      // 25 小时仍在输出的任务会只丢 .pid（.log 因持续写入 mtime 是新的）
      // —— 于是 buildJobKillCommand 的 if [ -f $pid ] 静默跳过，任务
      // 再也杀不掉。
      makeJob('job-1757000000000-aaaa', finished: false, daysAgo: 3);
      sh(buildJobCleanupCommand());
      expect(jobFile('job-1757000000000-aaaa', 'log').existsSync(), isTrue);
      expect(jobFile('job-1757000000000-aaaa', 'pid').existsSync(), isTrue);
    });

    test('结束超过 24 小时的任务：三个文件全删', () {
      makeJob('job-1757000000001-bbbb', finished: true, daysAgo: 3);
      sh(buildJobCleanupCommand());
      expect(jobFile('job-1757000000001-bbbb', 'log').existsSync(), isFalse);
      expect(jobFile('job-1757000000001-bbbb', 'pid').existsSync(), isFalse);
      expect(jobFile('job-1757000000001-bbbb', 'exit').existsSync(), isFalse);
    });

    test('刚结束的任务留着——看板要能查到今天跑过什么', () {
      makeJob('job-1757000000002-cccc', finished: true, daysAgo: 0);
      sh(buildJobCleanupCommand());
      expect(jobFile('job-1757000000002-cccc', 'log').existsSync(), isTrue);
    });

    test('目录不存在时退出码为 0，不打断调用方的 && 链', () {
      final fresh = Directory.systemTemp.createTempSync('jobs_clean');
      addTearDown(() => fresh.deleteSync(recursive: true));
      final r = Process.runSync('bash', ['-c', buildJobCleanupCommand()],
          environment: {'HOME': fresh.path});
      expect(r.exitCode, 0);
    });
  });
}
