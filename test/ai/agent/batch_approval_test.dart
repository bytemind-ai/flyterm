import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

final fleet = [
  const ServerListEntry(
      id: 'id-1', name: 'web-1', groupName: 'prod', host: '10.0.1.11',
      credsOk: true),
  const ServerListEntry(
      id: 'id-2', name: 'web-2', groupName: 'prod', host: '10.0.1.12',
      credsOk: true),
];

/// 同一条需审批的命令打两台机器。`systemctl restart` 不在 defaultAllowRules 里。
AIResponse restartBoth() => AIResponse(toolCalls: [
      ToolCall(id: 'a', name: 'bash', args: {
        'command': 'systemctl restart nginx',
        'description': '重启 nginx',
        'server': 'web-1',
      }),
      ToolCall(id: 'b', name: 'bash', args: {
        'command': 'systemctl restart nginx',
        'description': '重启 nginx',
        'server': 'web-2',
      }),
    ]);

void main() {
  test('一轮多条需审批 → 聚合成一个事件，不是多张卡', () async {
    final loop = makeLoop(
      provider: FakeProvider([restartBoth()]),
      servers: fleet,
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('重启两台的 nginx');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final batches = loop.events.whereType<BatchApprovalEvent>().toList();
    expect(batches.length, equals(1));
    expect(batches.single.calls.length, equals(2));
    expect(loop.pendingApprovals, isEmpty,
        reason: '聚合之后不该再有单张审批卡');

    loop.discardBatch();
    await f;
  });

  test('整批拒绝 → 每条各回一条 rejected result，runner 上零调用', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([restartBoth(), const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: provider,
      runner: runner,
      servers: fleet,
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('重启');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    loop.discardBatch();
    await f;

    expect(runner.ran, isEmpty);
    final results = provider.seen[1]
        .lastWhere((m) => m.role == 'tool')
        .toolResults!;
    expect(results.length, equals(2),
        reason: '一个 tool_use 必须对一个 tool_result');
    expect(results.every((r) => r.isError), isTrue);
  });

  test('整批批准 → 两条都执行，各打各的机器', () async {
    final r1 = FakeRunner();
    final r2 = FakeRunner();
    final loop = makeLoop(
      provider: FakeProvider([restartBoth(), const AIResponse(text: 'ok')]),
      runnersByServerId: {'id-1': r1, 'id-2': r2},
      servers: fleet,
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('重启');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await loop.approveBatch();
    await f;

    expect(r1.ran, contains('systemctl restart nginx'));
    expect(r2.ran, contains('systemctl restart nginx'));
  });

  test('等待中的批次存档后恢复为已拒绝 —— 不留悬挂按钮', () async {
    final loop = makeLoop(
      provider: FakeProvider([restartBoth()]),
      servers: fleet,
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('重启');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final archived = loop.toArchive();
    final restored = makeLoop(
      provider: FakeProvider([]),
      restoreFrom: archived,
    );
    expect(restored.events.whereType<BatchApprovalEvent>(), isEmpty,
        reason: '重启后没人能再应答它，恢复成卡片只会骗用户点');

    loop.discardBatch();
    await f;
  });

  test('单条需审批时不聚合，仍走原来的单张卡', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'a', name: 'bash', args: {
            'command': 'systemctl restart nginx',
            'description': 'x',
          })
        ])
      ]),
      servers: fleet,
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('重启');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(loop.events.whereType<BatchApprovalEvent>(), isEmpty);
    expect(loop.pendingApprovals.length, equals(1));

    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.reject);
    await f;
  });

  test('聚合审批挂起时 cancel → 不泄漏，loop 能回到终态', () async {
    final runner = FakeRunner();
    final loop = makeLoop(
      provider: FakeProvider([restartBoth(), const AIResponse(text: 'ok')]),
      runner: runner,
      servers: fleet,
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('重启');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(loop.events.whereType<BatchApprovalEvent>().length, equals(1));

    loop.cancel();
    // 不加超时地 await —— 泄漏时这里会永久挂住，测试超时失败正是我们要的信号
    await f;

    expect(loop.isRunning, isFalse);
    expect(runner.ran, isEmpty);
  });

  test('一轮两个 download_file 不聚合 —— 传输的审批卡不能被降级成一行', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'd1', name: 'download_file', args: {
            'remote_path': '/var/log/a.log',
            'description': '拉 a',
          }),
          ToolCall(id: 'd2', name: 'download_file', args: {
            'remote_path': '/home/u/.ssh/id_rsa',
            'description': '拉 b',
          }),
        ]),
      ]),
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('拉两个');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(loop.events.whereType<BatchApprovalEvent>(), isEmpty,
        reason: '聚合卡显示不出 remote_path，也丢掉凭据警示与文件大小');

    loop.cancel();
    await f;
  });

  test('一轮两个非传输的需审批命令仍然聚合 —— 不能把聚合功能整个关掉', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'a', name: 'bash', args: {
            'command': 'systemctl restart nginx',
            'description': 'x',
          }),
          ToolCall(id: 'b', name: 'bash', args: {
            'command': 'systemctl restart php-fpm',
            'description': 'y',
          }),
        ]),
      ]),
      mode: PermissionMode.readOnly,
      toolSpecs: () => fullToolSpecs,
    );

    final f = loop.send('重启');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(loop.events.whereType<BatchApprovalEvent>().length, equals(1));

    loop.discardBatch();
    await f;
  });
}
