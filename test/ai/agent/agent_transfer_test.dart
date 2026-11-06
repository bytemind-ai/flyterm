import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';
import '../../sftp/sftp_transfer_task_test.dart' show FakeTransferOps;

void main() {
  AIResponse dl(String path) => AIResponse(toolCalls: [
        ToolCall(id: 'd1', name: 'download_file', args: {
          'remote_path': path,
          'description': '把日志拉下来',
        })
      ]);

  group('download_file', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('flyterm_agent_dl');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('bypass 模式下也必须弹审批卡 —— 传输不可免审', () async {
      final ops = FakeTransferOps()
        ..statSize = 5
        ..chunks = [[1, 2, 3, 4, 5]];
      final loop = makeLoop(
        provider: FakeProvider([dl('/var/log/app.log')]),
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        downloadDirProvider: () async => tmp,
      );

      // 不 await —— 它会挂在审批上。
      final f = loop.send('拉日志');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final pending = loop.pendingApprovals;
      expect(pending.length, equals(1),
          reason: 'bypass 也不能跳过传输审批');
      expect(ops.downloadCalls, equals(0), reason: '批准之前一个字节都不能传');

      loop.cancel();
      await f;
    });

    test('拒绝审批 → SftpOps 上零调用', () async {
      final ops = FakeTransferOps()..statSize = 5;
      final loop = makeLoop(
        provider: FakeProvider([
          dl('/var/log/app.log'),
          const AIResponse(text: '好的，不下了'),
        ]),
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        downloadDirProvider: () async => tmp,
      );

      final f = loop.send('拉日志');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      loop.respondApproval(loop.pendingApprovals.single.seq,
          ApprovalDecision.reject);
      await f;

      expect(ops.downloadCalls, equals(0));
      expect(loop.events.whereType<TransferEvent>(), isEmpty);
    });

    test('批准 → 落盘、TransferEvent 入列，且回填不含文件内容', () async {
      final ops = FakeTransferOps()
        ..statSize = 5
        ..chunks = [[65, 66, 67, 68, 69]]; // "ABCDE"
      final provider = FakeProvider([
        dl('/var/log/app.log'),
        const AIResponse(text: '下好了'),
      ]);
      final loop = makeLoop(
        provider: provider,
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        downloadDirProvider: () async => tmp,
      );

      final f = loop.send('拉日志');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      loop.respondApproval(loop.pendingApprovals.single.seq,
          ApprovalDecision.allowOnce);
      await f;

      final tev = loop.events.whereType<TransferEvent>().single;
      expect(tev.status, equals(TransferStatus.done));
      expect(tev.localPath, equals('${tmp.path}/app.log'));
      expect(tev.bytesDone, equals(5));
      expect(await File(tev.localPath!).readAsString(), equals('ABCDE'));

      // 回填给模型的内容：有路径有大小，没有文件内容。
      final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
      final content = toolMsg.toolResults!.single.content;
      expect(content, contains('app.log'));
      expect(content, contains('5'));
      expect(content, isNot(contains('ABCDE')),
          reason: '文件内容一个字节都不能进上下文');
    });

    test('凭据路径：照常可下，但事件标记 credentialDeny', () async {
      final ops = FakeTransferOps()
        ..statSize = 3
        ..chunks = [[1, 2, 3]];
      final loop = makeLoop(
        provider: FakeProvider([
          dl('/home/u/.ssh/id_rsa'),
          const AIResponse(text: 'ok'),
        ]),
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        downloadDirProvider: () async => tmp,
      );

      final f = loop.send('拉私钥');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      loop.respondApproval(loop.pendingApprovals.single.seq,
          ApprovalDecision.allowOnce);
      await f;

      expect(loop.events.whereType<TransferEvent>().single.credentialDeny,
          isTrue);
    });

    test('相对路径不弹卡，直接回错误', () async {
      final ops = FakeTransferOps();
      final provider = FakeProvider([
        dl('var/log/app.log'),
        const AIResponse(text: 'ok'),
      ]);
      final loop = makeLoop(
        provider: provider,
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        downloadDirProvider: () async => tmp,
      );

      await loop.send('拉日志');

      expect(loop.pendingApprovals, isEmpty);
      final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
      expect(toolMsg.toolResults!.single.isError, isTrue);
      expect(toolMsg.toolResults!.single.content, contains('absolute'));
    });

    test('没有 sftpOpsProvider 时回一条明确的错误，不崩', () async {
      final provider = FakeProvider([
        dl('/var/log/app.log'),
        const AIResponse(text: 'ok'),
      ]);
      final loop = makeLoop(
        provider: provider,
        toolSpecs: () => fullToolSpecs,
      );

      await loop.send('拉日志');

      final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
      expect(toolMsg.toolResults!.single.isError, isTrue);
    });
  });

  AIResponse ul(String dir) => AIResponse(toolCalls: [
        ToolCall(id: 'u1', name: 'upload_file', args: {
          'remote_dir': dir,
          'description': '传张图上去',
        })
      ]);

  group('upload_file', () {
    late Directory tmp;
    late File local;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('flyterm_agent_ul');
      local = File('${tmp.path}/pic.jpg');
      await local.writeAsBytes([1, 2, 3]);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('picker 在审批卡之前打开', () async {
      final ops = FakeTransferOps()..statSize = 0;
      var pickerOpened = false;
      final loop = makeLoop(
        provider: FakeProvider([ul('/www/img')]),
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        pickLocalFile: () async {
          pickerOpened = true;
          return local.path;
        },
      );

      final f = loop.send('传图');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(pickerOpened, isTrue, reason: 'picker 必须先开');
      expect(loop.pendingApprovals.length, equals(1));
      // 卡上要能说出文件名和大小 —— 那是 picker 先开的全部理由。
      expect(loop.pendingApprovals.single.displayCommand, contains('pic.jpg'));
      expect(loop.pendingApprovals.single.displayCommand, contains('3'));

      loop.cancel();
      await f;
    });

    test('picker 取消 → 非错误，不弹卡', () async {
      final ops = FakeTransferOps();
      final provider = FakeProvider([ul('/www/img'), const AIResponse(text: 'ok')]);
      final loop = makeLoop(
        provider: provider,
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        pickLocalFile: () async => null,
      );

      await loop.send('传图');

      expect(loop.pendingApprovals, isEmpty);
      final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
      expect(toolMsg.toolResults!.single.isError, isFalse,
          reason: '用户改主意不是错误');
      expect(toolMsg.toolResults!.single.content.toLowerCase(),
          contains('cancel'));
    });

    test('批准 → 字节送达，路径由 remote_dir + 文件名拼出', () async {
      final ops = FakeTransferOps()..statSize = null;
      final loop = makeLoop(
        provider: FakeProvider([ul('/www/img'), const AIResponse(text: 'ok')]),
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        pickLocalFile: () async => local.path,
      );

      final f = loop.send('传图');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      loop.respondApproval(
          loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);
      await f;

      expect(ops.lastUploadPath, equals('/www/img/pic.jpg'));
      expect(ops.uploaded, equals([1, 2, 3]));
      final tev = loop.events.whereType<TransferEvent>().single;
      expect(tev.status, equals(TransferStatus.done));
      expect(tev.direction, equals(TransferDirection.upload));
      expect(tev.backupPath, isNull, reason: '没发生覆盖');
    });

    test('目标已存在 → 先备份，卡上说明，事件记下备份路径', () async {
      // statSize 非 null = 目标文件已存在
      final ops = FakeTransferOps()..statSize = 999;
      final loop = makeLoop(
        provider: FakeProvider([ul('/www/img'), const AIResponse(text: 'ok')]),
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => ops,
        pickLocalFile: () async => local.path,
      );

      final f = loop.send('传图');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final card = loop.pendingApprovals.single;
      expect(card.displayCommand.toLowerCase(), contains('overwrite'));
      loop.respondApproval(card.seq, ApprovalDecision.allowOnce);
      await f;

      final tev = loop.events.whereType<TransferEvent>().single;
      expect(tev.backupPath, contains('.flyterm.bak.'));
    });

    test('相对目录不弹卡也不开 picker', () async {
      var pickerOpened = false;
      final provider = FakeProvider([ul('www/img'), const AIResponse(text: 'ok')]);
      final loop = makeLoop(
        provider: provider,
        toolSpecs: () => fullToolSpecs,
        sftpOpsProvider: () async => FakeTransferOps(),
        pickLocalFile: () async {
          pickerOpened = true;
          return local.path;
        },
      );

      await loop.send('传图');

      expect(pickerOpened, isFalse, reason: '路径都不合法，不该骚扰用户');
      final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
      expect(toolMsg.toolResults!.single.isError, isTrue);
    });
  });

  test('TransferEvent 归档 round-trip 字段全等', () {
    final ev = TransferEvent(
      seq: 3,
      direction: TransferDirection.download,
      remotePath: '/var/log/app.log',
      filename: 'app.log',
      totalBytes: 4096,
    )
      ..localPath = '/storage/Download/app.log'
      ..bytesDone = 4096
      ..status = TransferStatus.done
      ..credentialDeny = true;

    final json = agentEventToJson(ev);
    expect(json['t'], equals('transfer'));

    final back = agentEventsFromJson([json]).single as TransferEvent;
    expect(back.seq, equals(3));
    expect(back.direction, equals(TransferDirection.download));
    expect(back.remotePath, equals('/var/log/app.log'));
    expect(back.localPath, equals('/storage/Download/app.log'));
    expect(back.filename, equals('app.log'));
    expect(back.totalBytes, equals(4096));
    expect(back.bytesDone, equals(4096));
    expect(back.status, equals(TransferStatus.done));
    expect(back.credentialDeny, isTrue);
  });

  test('运行中的传输存档时落成 interrupted —— 重启后它已经死了', () {
    final ev = TransferEvent(
      seq: 1,
      direction: TransferDirection.upload,
      remotePath: '/www/img/a.png',
      filename: 'a.png',
      totalBytes: 100,
    )
      ..bytesDone = 40
      ..status = TransferStatus.running;

    final back =
        agentEventsFromJson([agentEventToJson(ev)]).single as TransferEvent;
    expect(back.status, equals(TransferStatus.interrupted),
        reason: '留一个永远转圈的进度条只会骗用户');
  });

  test('未知的 status 字符串兜到 failed，不抛', () {
    final back = agentEventsFromJson([
      {
        't': 'transfer',
        'seq': 0,
        'direction': 'download',
        'remotePath': '/f',
        'filename': 'f',
        'status': 'from_the_future',
      }
    ]).single as TransferEvent;
    expect(back.status, equals(TransferStatus.failed));
  });

  group('injectLocalFile', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('flyterm_inject');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('小文件整份注入，模型下一轮就能看到', () async {
      final f = File('${tmp.path}/a.log');
      await f.writeAsString('line1\nline2\n');

      final provider = FakeProvider([const AIResponse(text: '看到了')]);
      final loop = makeLoop(provider: provider, toolSpecs: () => fullToolSpecs);

      await loop.injectLocalFile(f.path);

      final userMsgs = provider.seen.last.where((m) => m.role == 'user');
      expect(userMsgs.last.content, contains('line1'));
      expect(userMsgs.last.content, contains('a.log'));
    });

    test('超过 64 KiB 只注入前 64 KiB 并明写截断', () async {
      final f = File('${tmp.path}/big.log');
      await f.writeAsString('x' * (70 * 1024));

      final provider = FakeProvider([const AIResponse(text: 'ok')]);
      final loop = makeLoop(provider: provider, toolSpecs: () => fullToolSpecs);

      await loop.injectLocalFile(f.path);

      final msg = provider.seen.last.lastWhere((m) => m.role == 'user');
      expect(msg.content.length, lessThan(70 * 1024));
      expect(msg.content, contains('${70 * 1024}'),
          reason: '要告诉模型原文件真实大小，否则它会以为自己看全了');
      expect(msg.content.toLowerCase(), contains('truncat'));
    });

    test('文件不存在时不崩、不发请求', () async {
      final provider = FakeProvider([const AIResponse(text: 'ok')]);
      final loop = makeLoop(provider: provider, toolSpecs: () => fullToolSpecs);

      await loop.injectLocalFile('${tmp.path}/nope.log');

      expect(provider.seen, isEmpty, reason: '读不到就别浪费一轮');
    });
  });

  test('中转的三个新字段进归档，phase 不进', () {
    final ev = TransferEvent(
      seq: 5,
      direction: TransferDirection.relay,
      remotePath: '/etc/nginx/nginx.conf',
      filename: 'nginx.conf',
      totalBytes: 3200,
      fromServerName: 'web-1',
      toServerName: 'web-2',
      destPath: '/etc/nginx/nginx.conf',
      phase: TransferPhase.uploading,
    )..status = TransferStatus.done;

    final json = agentEventToJson(ev);
    expect(json.containsKey('phase'), isFalse,
        reason: '恢复出来一律是 interrupted，phase 没有可操作性');

    final back = agentEventsFromJson([json]).single as TransferEvent;
    expect(back.direction, equals(TransferDirection.relay));
    expect(back.fromServerName, equals('web-1'));
    expect(back.toServerName, equals('web-2'));
    expect(back.destPath, equals('/etc/nginx/nginx.conf'));
    expect(back.phase, isNull);
  });
}
