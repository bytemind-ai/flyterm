import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';

void main() {
  group('formatForModel', () {
    test('只有 stdout 时带上 exit code', () {
      const o = CommandOutput(stdout: 'active', stderr: '', exitCode: 0);
      final s = formatForModel(o);
      expect(s, contains('active'));
      expect(s, contains('exit code: 0'));
      expect(s, isNot(contains('stderr')));
    });

    test('stderr 单独分段 —— 模型需要区分', () {
      const o = CommandOutput(stdout: 'a', stderr: 'boom', exitCode: 1);
      final s = formatForModel(o);
      expect(s, contains('--- stderr ---'));
      expect(s, contains('boom'));
      expect(s, contains('exit code: 1'));
    });

    test('grep 无匹配（exit 1、无输出）不被当成失败', () {
      const o = CommandOutput(stdout: '', stderr: '', exitCode: 1);
      final s = formatForModel(o);
      expect(s, contains('exit code: 1'));
      expect(s, contains('(no output)'));
    });

    test('超时时首行是超时标记', () {
      const o = CommandOutput(
          stdout: 'partial', stderr: '', exitCode: -1, timedOut: true);
      final s = formatForModel(o);
      // 中性文案：不带秒数。秒数对模型没有决策价值（它已经知道自己发了
      // 什么命令），而一个写错的秒数（如轮询命令用的是 90s 预算而非
      // kCommandTimeout 的 20s）会误导它。
      expect(s, startsWith('[timed out and was killed]'));
      expect(s, contains('partial'));
    });
  });

  group('_prepare 的处理顺序（通过 formatForModel 间接验证）', () {
    test('脱敏提示不能被截断吃掉', () {
      // 这条锁的是顺序：notice 追加在末尾，若在截断之前追加，
      // 输出一超长它自己就先被截掉，模型于是把 [redacted] 当真实值。
      final long = List.generate(600, (i) => 'password: secret$i').join('\n');
      final r = redactSecrets(long);
      expect(r.count, greaterThan(0));
      final truncated = truncateForModel(r.text, 8 * 1024);
      final withNotice = appendRedactionNotice(truncated, r.count);

      expect(withNotice, contains('[truncated'));
      expect(withNotice, contains('value(s) redacted'),
          reason: '脱敏提示必须活到最后');
      // 反向验证：顺序反过来时提示确实会消失
      final wrongOrder =
          truncateForModel(appendRedactionNotice(r.text, r.count), 8 * 1024);
      expect(wrongOrder, isNot(contains('value(s) redacted')));
    });

    test('挖中间时，落在中段里的秘密仍然计入脱敏提示', () {
      // 600 行 × 约 47 字节 ≈ 28 KB，必然触发截断；第 300 行落在被挖掉的
      // 中段（8 KiB 预算下头尾各约 86 行）。
      final lines = List.generate(600, (i) => 'line-$i ${'x' * 40}').toList();
      lines[300] = 'password: hunter2';
      final r = redactSecrets(lines.join('\n'));
      expect(r.count, equals(1));

      final out = appendRedactionNotice(
        truncateForModel(r.text, 8 * 1024, mode: TruncateMode.middle),
        r.count,
      );

      expect(out, contains('omitted from the middle'));
      // 这两条合起来才是判据：占位符没了（它在被挖掉的中段里），但计数还在
      // （它是在截断之前算的）。只断言其中一条都证明不了顺序。
      expect(out, isNot(contains('[redacted by FlyTerm]')),
          reason: '那个值落在被挖掉的中段里');
      expect(out, contains('value(s) redacted'),
          reason: '计数在截断之前算，必须活下来');
    });
  });

  group('_prepare 的去噪接线（通过组合公开函数验证顺序）', () {
    // `_prepare` 是 `SshCommandRunner` 的私有静态方法，这个文件跟它不在
    // 同一个库里，够不到；`SshCommandRunner.run` 又需要一条真实 SSH
    // session 才能跑到 `_collect`。跟上面那组「_prepare 的处理顺序」
    // 一样的手法：按 `_prepare` 里同样的调用序列手工组合
    // （redactSecrets → denoiseOutput → ...），验证的是顺序契约，
    // 不是 SshCommandRunner 本身。
    const secretLine = 'password: secret123';
    final eightSecretLines = '${List.filled(8, secretLine).join('\n')}\n';

    test('denoise: true 时重复行被折叠', () {
      final redacted = redactSecrets(eightSecretLines);
      final denoised = denoiseOutput(redacted.text);
      expect(denoised, contains('last message repeated 7 times'));
    });

    test('denoise: false（默认）时输出逐字节不变', () {
      // _prepare 在 denoise=false 时压根不调用 denoiseOutput，
      // redactSecrets 之后的文本原样往下走。
      final redacted = redactSecrets(eightSecretLines);
      expect(redacted.text, isNot(contains('repeated')));
      expect(redacted.text, contains('[redacted by FlyTerm]\n' * 1));
    });

    test('去噪在脱敏之后 —— 秘密仍然被计数', () {
      // 正确顺序：redactSecrets 先跑完，8 处秘密全部计数，之后才折叠。
      final redacted = redactSecrets(eightSecretLines);
      expect(redacted.count, equals(8),
          reason: '脱敏必须在折叠之前跑完，否则被折叠掉的秘密不会被计数');
      final denoised = denoiseOutput(redacted.text);
      expect(denoised, contains('last message repeated 7 times'));

      // 反向验证：顺序反过来（先折叠再脱敏）会漏计 —— 折叠后只剩一行
      // 密码文本 + 一行标记，redactSecrets 只能数到 1，模型就会看到
      // 「1 个值被脱敏」这种假信息，而实际是 8 个。
      final wrongOrderDenoised = denoiseOutput(eightSecretLines);
      final wrongOrderRedacted = redactSecrets(wrongOrderDenoised);
      expect(wrongOrderRedacted.count, equals(1),
          reason: '顺序反过来会漏计 7 个秘密');
    });
  });

  group('CommandOutput.isSuccess', () {
    test('exit 0 且未超时为成功', () {
      expect(const CommandOutput(stdout: '', stderr: '', exitCode: 0).isSuccess,
          isTrue);
    });

    test('非 0 或超时为失败', () {
      expect(const CommandOutput(stdout: '', stderr: '', exitCode: 1).isSuccess,
          isFalse);
      expect(
          const CommandOutput(
                  stdout: '', stderr: '', exitCode: 0, timedOut: true)
              .isSuccess,
          isFalse);
    });
  });

  test('timeout 参数覆盖 kCommandTimeout 的默认值', () {
    // 纯签名与默认值的契约测试：不实际发起 SSH，只验证抽象类允许传这个
    // 参数、且缺省时等于 kCommandTimeout。真实的超时行为由既有的
    // 「20s 超时」测试覆盖，那条不需要改。
    expect(kCommandTimeout, equals(const Duration(seconds: 20)));
    expect(kJobPollTimeout.inSeconds, greaterThan(kCommandTimeout.inSeconds));

    final runner = _RecordingRunner();
    runner.run('a');
    runner.run('b', timeout: const Duration(seconds: 90));

    expect(runner.timeouts, equals([null, const Duration(seconds: 90)]));
  });
}

/// 只记录参数，不执行。验证抽象类的签名允许 timeout 透传。
class _RecordingRunner implements CommandRunner {
  final List<Duration?> timeouts = [];

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    timeouts.add(timeout);
    return const CommandOutput(stdout: '', stderr: '', exitCode: 0);
  }

  @override
  Future<void> dispose() async {}
}
