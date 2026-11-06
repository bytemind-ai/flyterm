import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';
import '../../sftp/sftp_transfer_task_test.dart' show FakeTransferOps;

final fleet = [
  const ServerListEntry(
      id: 'id-1', name: 'web-1', groupName: 'prod', host: '10.0.1.11',
      credsOk: true),
  const ServerListEntry(
      id: 'id-2', name: 'web-2', groupName: 'prod', host: '10.0.1.12',
      credsOk: true),
];

AIResponse copyCall({
  String from = 'web-1',
  String to = 'web-2',
  String path = '/etc/nginx/nginx.conf',
  String? dest,
}) =>
    AIResponse(toolCalls: [
      ToolCall(id: 'c1', name: 'copy_between_servers', args: {
        'from_server': from,
        'to_server': to,
        'remote_path': path,
        if (dest != null) 'dest_path': dest,
        'description': '统一配置',
      })
    ]);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flyterm_relay');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 建一个两端都有的 loop。src 吐 [bytes]，dst 记录收到的。
  ({AgentLoop loop, FakeTransferOps src, FakeTransferOps dst, FakeProvider p})
      build({
    List<int> bytes = const [1, 2, 3],
    int? srcSize,
    int? dstStatSize,
    PermissionMode mode = PermissionMode.ask,
  }) {
    final src = FakeTransferOps()
      ..statSize = srcSize ?? bytes.length
      ..chunks = [bytes];
    // dstStatSize 为 null = 目标不存在（stat 抛）
    final dst = FakeTransferOps()..statSize = dstStatSize;
    final p = FakeProvider([copyCall(), const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: p,
      mode: mode,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      sftpOpsByServerId: {'id-1': src, 'id-2': dst},
      relayTempDirProvider: () async => tmp,
    );
    return (loop: loop, src: src, dst: dst, p: p);
  }

  Future<void> approveAndSettle(AgentLoop loop, Future<void> sent) async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);
    await sent;
  }

  test('正常路径：源下载、目标上传，字节一致，临时文件被删掉', () async {
    final b = build(bytes: [10, 20, 30, 40]);
    final f = b.loop.send('把配置同步过去');
    await approveAndSettle(b.loop, f);

    expect(b.src.downloadCalls, equals(1));
    expect(b.dst.uploaded, equals([10, 20, 30, 40]));
    expect(b.dst.lastUploadPath, equals('/etc/nginx/nginx.conf'));

    final tev = b.loop.events.whereType<TransferEvent>().single;
    expect(tev.direction, equals(TransferDirection.relay));
    expect(tev.fromServerName, equals('web-1'));
    expect(tev.toServerName, equals('web-2'));
    expect(tev.status, equals(TransferStatus.done));

    // 临时文件必须删干净 —— 中转是实现细节，不留痕迹
    expect(await tmp.list().isEmpty, isTrue,
        reason: '临时目录里不该留下任何东西');
  });

  test('dest_path 省略时默认与源路径相同', () async {
    final b = build();
    final f = b.loop.send('同步');
    await approveAndSettle(b.loop, f);
    expect(b.dst.lastUploadPath, equals('/etc/nginx/nginx.conf'));
  });

  test('超过 100 MB → 不弹卡、不传，错误里指向 scp 退路', () async {
    final b = build(srcSize: 200 * 1024 * 1024);
    await b.loop.send('搬个大文件');

    expect(b.loop.pendingApprovals, isEmpty, reason: '不该弹卡');
    expect(b.src.downloadCalls, equals(0));
    final r = b.p.seen[1].lastWhere((m) => m.role == 'tool')
        .toolResults!.single;
    expect(r.isError, isTrue);
    expect(r.content.toLowerCase(), contains('scp'),
        reason: '不给退路模型会反复重试同一个被拒的调用');
  });

  test('from == to → 拒绝，提示用 cp', () async {
    final src = FakeTransferOps()..statSize = 3;
    final p = FakeProvider(
        [copyCall(from: 'web-1', to: 'web-1'), const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      sftpOpsByServerId: {'id-1': src},
      relayTempDirProvider: () async => tmp,
    );

    await loop.send('拷一下');

    expect(src.downloadCalls, equals(0));
    final r =
        p.seen[1].lastWhere((m) => m.role == 'tool').toolResults!.single;
    expect(r.isError, isTrue);
  });

  test('机器名找不到 → 错误里附可用列表', () async {
    final p = FakeProvider(
        [copyCall(to: 'ghost'), const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      sftpOpsByServerId: {'id-1': FakeTransferOps()..statSize = 3},
      relayTempDirProvider: () async => tmp,
    );

    await loop.send('拷一下');

    final r =
        p.seen[1].lastWhere((m) => m.role == 'tool').toolResults!.single;
    expect(r.isError, isTrue);
    expect(r.content, contains('web-2'));
  });

  test('目标已存在 → rename 备份在 upload 之前', () async {
    final b = build(dstStatSize: 999);
    final f = b.loop.send('同步');
    await approveAndSettle(b.loop, f);

    expect(b.dst.renamedBeforeUpload, isTrue,
        reason: '上传会 truncate，之后再备份只能备份到空文件');
    final tev = b.loop.events.whereType<TransferEvent>().single;
    expect(tev.backupPath, contains('.flyterm.bak.'));
  });

  test('bypass 模式下也必须弹审批卡 —— 传输不可免审', () async {
    final b = build(mode: PermissionMode.bypass);
    final f = b.loop.send('同步');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(b.loop.pendingApprovals.length, equals(1));
    expect(b.src.downloadCalls, equals(0));

    b.loop.cancel();
    await f;
  });

  test('凭据路径 → 事件标记 credentialDeny', () async {
    final src = FakeTransferOps()
      ..statSize = 3
      ..chunks = [
        [1, 2, 3]
      ];
    final dst = FakeTransferOps()..statSize = null;
    final p = FakeProvider([
      copyCall(path: '/home/u/.ssh/id_rsa'),
      const AIResponse(text: 'ok')
    ]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      sftpOpsByServerId: {'id-1': src, 'id-2': dst},
      relayTempDirProvider: () async => tmp,
    );

    final f = loop.send('搬私钥');
    await approveAndSettle(loop, f);

    expect(loop.events.whereType<TransferEvent>().single.credentialDeny,
        isTrue);
  });

  test('上传段失败 → 临时文件仍被删，回填声明目标可能不完整', () async {
    final src = FakeTransferOps()
      ..statSize = 3
      ..chunks = [
        [1, 2, 3]
      ];
    final dst = FakeTransferOps()
      ..statSize = null
      ..throwOnUpload = true;
    final p = FakeProvider([copyCall(), const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.ask,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      sftpOpsByServerId: {'id-1': src, 'id-2': dst},
      relayTempDirProvider: () async => tmp,
    );

    final f = loop.send('同步');
    await approveAndSettle(loop, f);

    expect(await tmp.list().isEmpty, isTrue, reason: '失败也要删临时文件');
    final r =
        p.seen[1].lastWhere((m) => m.role == 'tool').toolResults!.single;
    expect(r.isError, isTrue);
    expect(r.content.toLowerCase(), contains('incomplete'),
        reason: '不说明的话模型会以为拷贝成功，接着去重启服务');
  });
}
