import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart' show TruncateMode;
import 'package:flyterm/ai/agent/remote_skills.dart';

import '_tar_bundle.dart';

/// 一个只回放固定 stdout 的 runner。
class _CannedRunner implements CommandRunner {
  final String stdout;
  final int exitCode;
  final bool timedOut;
  _CannedRunner(
    this.stdout, {
    this.exitCode = 0,
    this.timedOut = false,
  });

  @override
  Future<CommandOutput> run(String command,
          {String? cwd,
          Duration? timeout,
          bool denoise = false,
          int? maxBytes,
          TruncateMode truncate = TruncateMode.head}) async =>
      CommandOutput(
          stdout: stdout, stderr: '', exitCode: exitCode, timedOut: timedOut);

  @override
  Future<void> dispose() async {}
}

String skillMd(String name, String desc, String body) =>
    '---\nname: $name\ndescription: $desc\n---\n\n$body\n';

void main() {
  group('tar.gz + base64 解包', () {
    test('目录形态：SKILL.md + 附件', () async {
      final payload = tarGzBase64({
        'deploy/SKILL.md': skillMd('deploy', 'd', 'steps'),
        'deploy/scripts/check.sh': '#!/bin/sh\necho hi',
      });
      final r = await fetchRemoteSkills(
          _CannedRunner('===FLYTERM-SKILL:$payload\n'));
      expect(r.error, isNull);
      expect(r.skills, hasLength(1));
      final s = r.skills.single;
      expect(s.name, equals('deploy'));
      expect(s.body, equals('steps'));
      expect(s.assets.map((a) => a.path), equals(['scripts/check.sh']));
      expect(s.assets.single.content, contains('echo hi'));
      expect(s.assets.single.executable, isTrue);
    });

    test('扁平形态仍然工作（改造前的老目录）', () async {
      final payload = tarGzBase64({'nginx.md': skillMd('nginx', 'n', 'body')});
      final r = await fetchRemoteSkills(
          _CannedRunner('===FLYTERM-SKILL:$payload'));
      expect(r.skills.single.name, equals('nginx'));
      expect(r.skills.single.assets, isEmpty);
    });

    test('两种形态共存', () async {
      final payload = tarGzBase64({
        'deploy/SKILL.md': skillMd('deploy', 'd', 'b'),
        'deploy/x.sh': 'z',
        'flat.md': skillMd('flat', 'f', 'b'),
      });
      final r = await fetchRemoteSkills(
          _CannedRunner('===FLYTERM-SKILL:$payload'));
      expect(r.skills.map((s) => s.name).toSet(), equals({'deploy', 'flat'}));
    });

    test('base64 被 76 列换行过也能解', () async {
      final payload = tarGzBase64({'a.md': skillMd('a', 'x', 'b')});
      // 每 76 字符插一个换行，模拟默认 base64 行为。
      final wrapped = [
        for (var i = 0; i < payload.length; i += 76)
          payload.substring(i, (i + 76).clamp(0, payload.length)),
      ].join('\n');
      final r = await fetchRemoteSkills(
          _CannedRunner('===FLYTERM-SKILL:$wrapped'));
      expect(r.skills.single.name, equals('a'));
    });

    test('目录不存在（无标记）→ 空结果，不算失败', () async {
      final r = await fetchRemoteSkills(_CannedRunner(''));
      expect(r.skills, isEmpty);
      expect(r.error, isNull);
    });

    test('载荷坏掉 → 报错而不是空结果', () async {
      final r = await fetchRemoteSkills(
          _CannedRunner('===FLYTERM-SKILL:not-valid-base64!!!'));
      expect(r.error, isNotNull);
      expect(r.skills, isEmpty);
    });

    test('载荷被截断 → 报错', () async {
      final payload = tarGzBase64({'a.md': skillMd('a', 'x', 'b' * 200)});
      final r = await fetchRemoteSkills(
          _CannedRunner('===FLYTERM-SKILL:${payload.substring(0, 40)}'));
      expect(r.error, isNotNull);
    });

    test('超时 / 退出码异常分别报错', () async {
      final t = await fetchRemoteSkills(_CannedRunner('', timedOut: true));
      expect(t.error, contains('Timed out'));
      final e = await fetchRemoteSkills(_CannedRunner('', exitCode: -1));
      expect(e.error, contains('did not complete'));
    });

    test('拉取时显式抬高了输出上限', () async {
      // 8 KiB 默认值接不下正文 8 KiB + 附件 16 KiB 的技能，必须显式抬。
      int? seen;
      final runner = _MaxBytesProbe((v) => seen = v);
      await fetchRemoteSkills(runner);
      expect(seen, equals(kRemoteSkillFetchBytes));
      expect(kRemoteSkillFetchBytes, greaterThan(kMaxOutputBytes));
    });
  });
}

/// 记录 `maxBytes` 的探针 runner。
class _MaxBytesProbe implements CommandRunner {
  final void Function(int?) onMaxBytes;
  _MaxBytesProbe(this.onMaxBytes);

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,
      TruncateMode truncate = TruncateMode.head}) async {
    onMaxBytes(maxBytes);
    return const CommandOutput(stdout: '', stderr: '', exitCode: 0);
  }

  @override
  Future<void> dispose() async {}
}
