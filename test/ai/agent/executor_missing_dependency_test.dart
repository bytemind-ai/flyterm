import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_executors/app_executors.dart';
import 'package:flyterm/ai/agent/tool_executors/sftp_executors.dart';
import 'package:flyterm/ai/agent/tool_executors/transfer_executors.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import '_fakes.dart';

/// executor 的**依赖未注入**分支。
///
/// 这些分支此前一条测试都没有。它们不是死代码：`AgentAssemblyDeps` 里
/// `appControl` 是**可空**的（`context.read<AppControlService?>()`），
/// `sftpOpsProvider` 也是可空的 —— 没注入时这些工具必须回一句人话，而不是
/// 抛 null-check 错误。
///
/// 为什么值得单独测：这是「接线断了一处」时**唯一**挡住模型收到一个
/// 未捕获异常的东西。断言要钉两件事 —— 回的是 isError 结果（不是抛异常），
/// 且文案点明原因（模型据此判断是配置问题而不是目标机器的问题）。
void main() {
  test('app executor：没注入 AppControlService 时回不可用，不抛', () async {
    // 不传 appControl。
    final execs = AppExecutors(makeLoop(
      provider: FakeProvider([]),
      mode: PermissionMode.bypass,
    ));

    final r = await execs.stateRead(const ToolCall(
      id: '1',
      name: 'app_state_read',
      args: {'section': 'settings'},
    ));

    expect(r.isError, isTrue);
    expect(r.content, contains('not available'));
    expect(r.content, contains('App control'));
  });

  test('app executor：serverEntry 同样回不可用而不是抛', () async {
    final execs = AppExecutors(makeLoop(
      provider: FakeProvider([]),
      mode: PermissionMode.bypass,
    ));

    final r = await execs.serverEntry(const ToolCall(
      id: '1',
      name: 'server_entry_create',
      args: {'name': 'x', 'host': 'h', 'username': 'u'},
    ));

    expect(r.isError, isTrue);
    expect(r.content, contains('not available'));
  });

  test('sftp executor：没注入 sftpOpsProvider 时回不可用，不抛', () async {
    final execs = SftpExecutors(makeLoop(provider: FakeProvider([])));

    final r = await execs.run(const ToolCall(
      id: '1',
      name: 'sftp_stat',
      args: {'path': '/tmp'},
    ));

    expect(r.isError, isTrue);
    expect(r.content, contains('SFTP'));
    expect(r.content, contains('not available'));
  });

  test('transfer executor：没注入 sftpOpsProvider 时回不可用，不抛', () async {
    final execs = TransferExecutors(makeLoop(provider: FakeProvider([])));

    final r = await execs.download(const ToolCall(
      id: '1',
      name: 'download_file',
      args: {'remote_path': '/var/log/app.log', 'description': 'd'},
    ));

    expect(r.isError, isTrue);
    expect(r.content, contains('File transfer'));
    expect(r.content, contains('not available'));
  });

  test('transfer executor：没注入 sftpOpsProvider 时跨机拷贝回不可用', () async {
    // 跨机拷贝要先解析两台目标机，才轮到查 sftpOpsProvider —— 所以这里
    // 必须把服务器清单接上，否则会先撞上「找不到名为 a 的服务器」。
    final execs = TransferExecutors(makeLoop(
      provider: FakeProvider([]),
      servers: const [
        ServerListEntry(id: 'sa', name: 'a', host: '10.0.0.1', credsOk: true),
        ServerListEntry(id: 'sb', name: 'b', host: '10.0.0.2', credsOk: true),
      ],
    ));

    final r = await execs.copyBetweenServers(const ToolCall(
      id: '1',
      name: 'copy_between_servers',
      args: {
        'remote_path': '/x',
        'dest_path': '/y',
        'from_server': 'a',
        'to_server': 'b',
        'description': 'd',
      },
    ));

    expect(r.isError, isTrue);
    expect(r.content, contains('Cross-server copy'),
        reason: '依赖没接上时必须回一句人话，而不是抛未捕获异常');
    expect(r.content, contains('not available'));
  });
}
