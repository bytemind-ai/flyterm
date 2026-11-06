@Tags(['shell'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 把 hook 脚本**真的丢进 sh 执行**，而不是断言它们的字符串内容。
///
/// ## 为什么必须真跑
///
/// 这三个脚本会跑在用户的生产服务器上，挂在 Claude Code 的 hook 链里。
/// 它们的失败模式全都是 shell 语义层面的，字符串断言一个都测不出来：
///
/// 1. `Stop` hook 任何非零退出都会出事 —— exit 2 直接阻止 Claude 停止，
///    把它卡在循环里。而脚本里每一条命令都可能失败（flyterm 没装、
///    TMPDIR 不可写、时间戳文件被清理），必须验证任何路径都 exit 0。
/// 2. `sed` 提取 session_id 的正则对着真实 JSON 才知道对不对。
/// 3. 耗时门槛是 `[ "$elapsed" -ge N ]` 算术比较 —— 时间戳文件内容为空
///    或非数字时，未加保护的 `$(( ))` 会让整个脚本以非零码退出。
///
/// ## 时间怎么模拟
///
/// 不真等 60 秒。`turn-start.sh` 把 `date +%s` 写进时间戳文件，测试直接
/// 覆写那个文件为「过去某一时刻」，再跑 `turn-done.sh`。
///
/// ## 跳过条件
///
/// 需要 POSIX sh。非 Linux/macOS 平台整组跳过而不是失败 —— 跳过会在输出
/// 里明说，不会伪装成通过。
void main() {
  if (!Platform.isLinux && !Platform.isMacOS) {
    test('跳过：hook 脚本测试需要 POSIX shell', () {
      printOnFailure('platform=${Platform.operatingSystem}');
    }, skip: '非 POSIX 平台');
    return;
  }

  final repoRoot = Directory.current.path;
  final turnStart = '$repoRoot/docs/examples/hooks/turn-start.sh';
  final turnDone = '$repoRoot/docs/examples/hooks/turn-done.sh';

  late Directory sandbox;
  late String tmpDir;
  late String fakeAiterm;
  late File callLog;

  /// 每个用例一个隔离沙箱：自己的 TMPDIR（时间戳文件落在这里）+ 一个把
  /// 调用参数追加进 callLog 的假 flyterm。
  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('flyterm_hooks_test_');
    tmpDir = '${sandbox.path}/tmp';
    Directory(tmpDir).createSync();
    callLog = File('${sandbox.path}/calls.log');
    fakeAiterm = '${sandbox.path}/fake-flyterm';
    File(fakeAiterm).writeAsStringSync(
      '#!/bin/sh\nprintf \'%s\\n\' "\$*" >> "${callLog.path}"\nexit 0\n',
    );
    Process.runSync('chmod', ['+x', fakeAiterm]);
  });

  tearDown(() => sandbox.deleteSync(recursive: true));

  /// 跑一个 hook 脚本，把 [stdinJson] 喂进它的 stdin。
  ///
  /// 用 `sh -c 'printf ... | sh script'` 而不是直接 runSync 脚本：
  /// `Process.runSync` 没有 stdin 参数，而这三个脚本都以 `cat` 读 stdin
  /// 开头，不喂会挂住。
  ///
  /// `environment` 是**合并**进父进程环境的（`includeParentEnvironment`
  /// 默认 true），所以脚本仍能在 PATH 上找到 sed/date/cat。
  ProcessResult runHook(
    String script,
    String stdinJson, {
    String? flytermBin,
    String? minSeconds,
  }) {
    final quoted = stdinJson.replaceAll("'", "'\\''");
    return Process.runSync(
      'sh',
      ['-c', "printf '%s' '$quoted' | sh '$script'"],
      environment: {
        'TMPDIR': tmpDir,
        'FLYTERM_BIN': flytermBin ?? fakeAiterm,
        if (minSeconds != null) 'FLYTERM_NOTIFY_MIN_SECONDS': minSeconds,
      },
    );
  }

  List<String> calls() =>
      callLog.existsSync() ? callLog.readAsLinesSync() : <String>[];

  String stampFile(String sid) => '$tmpDir/flyterm-hooks/$sid';

  const sampleJson =
      '{"session_id":"abc123","hook_event_name":"Stop","cwd":"/home/u/p"}';

  group('turn-start.sh', () {
    test('把时间戳写进以 session_id 命名的文件', () {
      final r = runHook(turnStart, sampleJson);
      expect(r.exitCode, 0);
      final f = File(stampFile('abc123'));
      expect(f.existsSync(), isTrue);
      expect(int.tryParse(f.readAsStringSync().trim()), isNotNull);
    });

    test('JSON 里没有 session_id 时落到 default', () {
      final r = runHook(turnStart, '{"hook_event_name":"UserPromptSubmit"}');
      expect(r.exitCode, 0);
      expect(File(stampFile('default')).existsSync(), isTrue);
    });

    test('TMPDIR 不可写时仍退出 0', () {
      // 本文件头部把「TMPDIR 不可写」列为脚本可能非零退出的三个诱因之一，
      // 却一直没有用例真的模拟它 —— 声称测了却没测到，最终审查抓出来的
      // 缺口。脚本靠 `mkdir -p ... 2>/dev/null` 加末尾无条件 exit 0 兜住。
      final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
      if (uid == '0') {
        // root 忽略文件权限，chmod 555 拦不住它。这种环境下本用例测不到
        // 任何东西，明确跳过而不是假通过。
        markTestSkipped('以 root 运行，chmod 555 无法模拟不可写目录');
        return;
      }
      Process.runSync('chmod', ['555', tmpDir]);
      late final ProcessResult r;
      try {
        r = runHook(turnStart, sampleJson);
      } finally {
        // 立刻恢复：tearDown 要递归删掉沙箱，目录只读会让它失败。
        Process.runSync('chmod', ['755', tmpDir]);
      }
      expect(r.exitCode, 0);
      expect(File(stampFile('abc123')).existsSync(), isFalse,
          reason: '写不进去是预期的；这个用例要的是「没有因此非零退出」');
    });
  });

  group('turn-done.sh', () {
    test('耗时超过阈值时通知，文案带秒数', () {
      runHook(turnStart, sampleJson);
      // 把开始时间改写成 120 秒前
      final past =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 120;
      File(stampFile('abc123')).writeAsStringSync('$past\n');

      final r = runHook(turnDone, sampleJson);
      expect(r.exitCode, 0);
      expect(calls(), hasLength(1));
      expect(calls().first, contains('notify'));
      expect(calls().first, contains('120'));
    });

    test('耗时低于阈值时不通知', () {
      runHook(turnStart, sampleJson);
      // 前置断言不是冗余：没有它，turn-start 完全没跑（脚本缺失、TMPDIR
      // 不可写）时 calls() 同样是空的，这个用例会假通过。
      expect(File(stampFile('abc123')).existsSync(), isTrue,
          reason: '前置条件：turn-start 应该已写下时间戳');
      final r = runHook(turnDone, sampleJson);
      expect(r.exitCode, 0);
      expect(calls(), isEmpty);
    });

    test('阈值可用 FLYTERM_NOTIFY_MIN_SECONDS 覆盖', () {
      runHook(turnStart, sampleJson);
      final past = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 5;
      File(stampFile('abc123')).writeAsStringSync('$past\n');

      final r = runHook(turnDone, sampleJson, minSeconds: '1');
      expect(r.exitCode, 0);
      expect(calls(), hasLength(1));
    });

    test('消费后删除时间戳文件，不在 TMPDIR 里堆积', () {
      runHook(turnStart, sampleJson);
      // 「已被删除」的断言在「从未创建」时同样成立 —— 先钉住文件确实存在，
      // 否则这个用例在脚本缺失时会绿着骗人（TDD 阶段实测确认过它会）。
      expect(File(stampFile('abc123')).existsSync(), isTrue,
          reason: '前置条件：turn-start 应该已写下时间戳');
      runHook(turnDone, sampleJson);
      expect(File(stampFile('abc123')).existsSync(), isFalse);
    });

    test('没有配对的 turn-start 时静默退出 0', () {
      final r = runHook(turnDone, sampleJson);
      expect(r.exitCode, 0);
      expect(calls(), isEmpty);
    });

    test('时间戳文件内容损坏时退出 0 而不是算术报错', () {
      Directory('$tmpDir/flyterm-hooks').createSync(recursive: true);
      File(stampFile('abc123')).writeAsStringSync('not-a-number\n');
      final r = runHook(turnDone, sampleJson);
      expect(r.exitCode, 0);
      expect(calls(), isEmpty);
    });

    test('flyterm 不存在时仍退出 0 —— 绝不能把 Claude 卡在循环里', () {
      runHook(turnStart, sampleJson);
      final past = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 120;
      File(stampFile('abc123')).writeAsStringSync('$past\n');

      final r = runHook(turnDone, sampleJson,
          flytermBin: '/nonexistent/flyterm');
      expect(r.exitCode, 0);
    });

    test('不同 session 的耗时判定互不干扰', () {
      const jsonA = '{"session_id":"aaa"}';
      const jsonB = '{"session_id":"bbb"}';
      runHook(turnStart, jsonA);
      runHook(turnStart, jsonB);
      // bbb 的「刚开始」状态是这个用例的一半 —— 它必须真的有时间戳文件，
      // 而不是因为 turn-start 没跑所以走了「没有配对」那条路径。两条路都
      // 不通知，结果一样，但测到的东西完全不同。
      expect(File(stampFile('aaa')).existsSync(), isTrue);
      expect(File(stampFile('bbb')).existsSync(), isTrue);

      final past = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 120;
      File(stampFile('aaa')).writeAsStringSync('$past\n');
      // bbb 保持「刚开始」

      runHook(turnDone, jsonA);
      runHook(turnDone, jsonB);
      expect(calls(), hasLength(1)); // 只有 aaa 该通知
    });
  });

  group('approval.sh', () {
    final approval = '$repoRoot/docs/examples/hooks/approval.sh';

    test('无条件通知并退出 0', () {
      final r = runHook(approval,
          '{"session_id":"abc","hook_event_name":"Notification"}');
      expect(r.exitCode, 0);
      expect(calls(), hasLength(1));
      expect(calls().first, contains('notify'));
    });

    test('flyterm 不存在时仍退出 0', () {
      final r = runHook(approval, '{"session_id":"abc"}',
          flytermBin: '/nonexistent/flyterm');
      expect(r.exitCode, 0);
    });

    test('读干净 stdin，不因 SIGPIPE 挂掉', () {
      // CC 会把完整 payload 灌进来；脚本必须消费掉它。
      final big = '{"session_id":"abc","blob":"${'x' * 20000}"}';
      final r = runHook(approval, big);
      expect(r.exitCode, 0);
    });
  });

  group('文档与脚本一致性', () {
    /// 从 docs/agent-notifications.md 里抠出某个脚本的 heredoc 正文。
    String extractFromDoc(String name) {
      final doc =
          File('$repoRoot/docs/agent-notifications.md').readAsStringSync();
      final begin = "cat > ~/.flyterm-server/hooks/$name.sh <<'FLYTERM_EOF'\n";
      final i = doc.indexOf(begin);
      expect(i, isNonNegative, reason: '文档里找不到 $name.sh 的安装块');
      final start = i + begin.length;
      final end = doc.indexOf('\nFLYTERM_EOF\n', start);
      expect(end, isNonNegative, reason: '$name.sh 的 heredoc 没有闭合');
      return doc.substring(start, end + 1);
    }

    for (final name in ['turn-start', 'turn-done', 'approval']) {
      test('$name.sh 与文档内联版本逐字节相同', () {
        final onDisk =
            File('$repoRoot/docs/examples/hooks/$name.sh').readAsStringSync();
        expect(extractFromDoc(name), onDisk,
            reason: '改了脚本要同步 docs/agent-notifications.md 的 heredoc');
      });
    }
  });
}
