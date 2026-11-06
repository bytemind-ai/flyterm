import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/remote_skills.dart';

import '_fakes.dart';
import '_tar_bundle.dart';

/// `fetchRemoteSkills` 的语义：拿到什么、失败怎么报。
///
/// 打包格式本身（tar.gz + base64 的解包）由 `remote_skills_bundle_test.dart`
/// 覆盖，这里只测**命令之外**的那些分支。两条都用同一份 `_tar_bundle.dart`
/// 造远端会产出的字节。
void main() {
  String payload(Map<String, String> files) =>
      '===FLYTERM-SKILL:${tarGzBase64(files)}';

  test('解析出多份 skill', () async {
    final runner = FakeRunner(results: [
      CommandOutput(
        stdout: payload({
          'nginx.md': skillMd('nginx', '排查 502', '正文A'),
          'deploy.md': skillMd('deploy', '部署', '正文B'),
        }),
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final r = await fetchRemoteSkills(runner);
    expect(r.error, isNull);
    expect(r.skills, hasLength(2));
    expect(r.skills.first.name, equals('nginx'));
    expect(r.skills.first.body, equals('正文A'));
  });

  test('文件名做 name 的回落 —— 去掉 .md 后缀', () async {
    final runner = FakeRunner(results: [
      CommandOutput(
        stdout: payload({'my-skill.md': '---\ndescription: d\n---\n正文'}),
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final r = await fetchRemoteSkills(runner);
    expect(r.skills.single.name, equals('my-skill'));
  });

  test('目录形态带附件', () async {
    final runner = FakeRunner(results: [
      CommandOutput(
        stdout: payload({
          'deploy/SKILL.md': skillMd('deploy', 'd', '正文'),
          'deploy/scripts/run.sh': '#!/bin/sh\necho hi',
        }),
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final r = await fetchRemoteSkills(runner);
    expect(r.skills.single.name, equals('deploy'));
    expect(r.skills.single.assets.single.path, equals('scripts/run.sh'));
    expect(r.skills.single.assets.single.executable, isTrue);
  });

  test('目录不存在时是「没有」而不是错误', () async {
    final runner = FakeRunner(results: const [
      CommandOutput(stdout: '', stderr: 'No such file', exitCode: 0),
    ]);
    final r = await fetchRemoteSkills(runner);
    expect(r.error, isNull);
    expect(r.skills, isEmpty);
  });

  test('超时要报错给用户 —— 与后台静默刷新的语义不同', () async {
    final runner = FakeRunner(results: const [
      CommandOutput(stdout: '', stderr: '', exitCode: -1, timedOut: true),
    ]);
    final r = await fetchRemoteSkills(runner);
    expect(r.error, isNotNull);
  });

  test('连接抛异常时报错，不抛出去', () async {
    final r = await fetchRemoteSkills(ThrowingRunner());
    expect(r.error, isNotNull);
    expect(r.skills, isEmpty);
  });

  test('单份解析失败不影响其余几份', () async {
    final runner = FakeRunner(results: [
      CommandOutput(
        stdout: payload({
          'bad.md': '没有 frontmatter',
          'good.md': skillMd('good', 'd', '正文'),
        }),
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final r = await fetchRemoteSkills(runner);
    expect(r.skills.map((s) => s.name), equals(['good']));
    expect(r.skipped, equals(1));
  });

  test('拉取命令里带上了目录与 tar', () async {
    final runner = FakeRunner();
    await fetchRemoteSkills(runner);
    final cmd = runner.ran.single;
    // 用 `$HOME` 而不是 `~`：命令把目录先存进变量再用双引号引，而 `~` 在
    // 双引号里不会展开（只有不带引号或在变量赋值右侧才会）。
    expect(cmd, contains('.flyterm/skills'));
    expect(cmd, contains('tar'));
    expect(cmd, contains('base64'));
  });
}

/// 连接压根建立不起来的 runner。
class ThrowingRunner implements CommandRunner {
  @override
  Future<CommandOutput> run(String command,
          {String? cwd,
          Duration? timeout,
          bool denoise = false,
          int? maxBytes,
          TruncateMode truncate = TruncateMode.head}) =>
      throw StateError('no connection');

  @override
  Future<void> dispose() async {}
}
