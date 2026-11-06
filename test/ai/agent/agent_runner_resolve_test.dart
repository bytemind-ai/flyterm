import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_runner_resolve.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
// TruncateMode 定义在 output_sanitizer.dart，command_runner.dart 只是 import
// 它、没有 re-export —— 实现 CommandRunner 必须单独引这一行。
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/data/models/server.dart';

Server _server(String id, String name) => Server(
      id: id,
      name: name,
      host: '10.0.0.1',
      port: 22,
      username: 'root',
      authType: 'password',
    );

/// 占位 runner —— 这组测试只关心「选中了哪台机器」,不关心真的跑命令。
class _FakeRunner implements CommandRunner {
  final String serverId;
  _FakeRunner(this.serverId);

  @override
  Future<CommandOutput> run(String command,
          {String? cwd,
          Duration? timeout,
          bool denoise = false,
          int? maxBytes,

          TruncateMode truncate = TruncateMode.head}) async =>
      const CommandOutput(stdout: '', stderr: '', exitCode: 0);

  @override
  Future<void> dispose() async {}
}

void main() {
  final web1 = _server('id-1', 'web-1');
  final web2 = _server('id-2', 'web-2');

  CommandRunner build(Server s) => _FakeRunner(s.id);
  Server? byId(String id) => {'id-1': web1, 'id-2': web2}[id];

  test('serverId 为 null 且有默认机器 → 用默认机器', () {
    final r = resolveAgentRunner(
      serverId: null,
      defaultServer: web1,
      serverById: byId,
      runnerFor: build,
    );
    expect((r as _FakeRunner).serverId, 'id-1');
  });

  test('serverId 非 null → 用指定机器,忽略默认机器', () {
    final r = resolveAgentRunner(
      serverId: 'id-2',
      defaultServer: web1,
      serverById: byId,
      runnerFor: build,
    );
    expect((r as _FakeRunner).serverId, 'id-2');
  });

  test('serverId 与默认机器都没有 → MissingServerRunner', () {
    final r = resolveAgentRunner(
      serverId: null,
      defaultServer: null,
      serverById: byId,
      runnerFor: build,
    );
    expect(r, isA<MissingServerRunner>());
  });

  test('serverId 查不到(机器已被删) → MissingServerRunner', () {
    final r = resolveAgentRunner(
      serverId: 'id-gone',
      defaultServer: web1,
      serverById: byId,
      runnerFor: build,
    );
    expect(r, isA<MissingServerRunner>());
  });

  test('MissingServerRunner 回非零退出码与可操作的 stderr', () async {
    final out = await MissingServerRunner().run('ls');
    expect(out.isSuccess, isFalse);
    expect(out.exitCode, isNot(0));
    // 模型要能从这句话里知道下一步该做什么。
    expect(out.stderr, contains('list_servers'));
    expect(out.stderr, contains('server'));
  });
}
