import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/file_edit.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// 造出远端「读文件」命令应有的 stdout：三行 sha / size / base64，与
/// `buildReadForEditCommand` 的实际输出格式一致。
CommandOutput _readOut(String content) {
  final bytes = utf8.encode(content);
  return CommandOutput(
    stdout: '${sha256.convert(bytes)}\n${bytes.length}\n'
        '${base64.encode(bytes)}',
    stderr: '',
    exitCode: 0,
  );
}

ToolCall _editCall(String old, String neu, {String path = '/etc/x.conf'}) =>
    ToolCall(id: 'c1', name: 'edit_file', args: {
      'path': path,
      'old_string': old,
      'new_string': neu,
      'description': '改端口',
    });

/// 轮询等到「写审批」出现，而不是赌一个固定延迟。
///
/// 这条路径在弹审批之前先跑了一次真实的 [FakeRunner] 调用（读文件），
/// 后者用真实 `Timer` 模拟网络延迟（见 `_fakes.dart` 的说明）——比纯同步
/// 判定就能弹审批的 `write_file` 多一次 Timer 调度。固定的
/// `Future.delayed(10ms)` 在空闲机器上够用，但在并行跑全量测试、机器
/// 负载高时，实测连 50ms 都不稳定。轮询直到条件成立（或明确超时报错），
/// 不管机器多慢都不会误判。
Future<void> _waitForPendingApproval(AgentLoop loop) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (loop.pendingApprovals.isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for a pending approval');
    }
    await Future.delayed(const Duration(milliseconds: 5));
  }
}

/// 轮询等到**下一张**审批卡出现 —— 用于 `edit_file` 阶段一（读）应答之后
/// 等阶段二（写）。不能只判断 `pendingApprovals.isNotEmpty`：应答刚发出的
/// 那一刻，读的卡片可能还没被状态机翻成非 awaitingApproval，直接判空非空
/// 会偶发地在写审批出现前就误判命中（拿到的其实还是读那张旧卡）。
Future<void> _waitForNextApproval(AgentLoop loop, int excludeSeq) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (loop.pendingApprovals.isEmpty ||
      loop.pendingApprovals.single.seq == excludeSeq) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the next pending approval');
    }
    await Future.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('读—改—审批—写 的完整路径', () async {
    const original = 'server {\n  listen 80;\n}\n';
    final runner = FakeRunner(results: [
      _readOut(original),
      const CommandOutput(stdout: '', stderr: '', exitCode: 0),
    ]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.readOnly,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('listen 80;', 'listen 8080;')]),
        const AIResponse(text: 'done'),
      ]),
    );

    final f = loop.send('go');
    await _waitForPendingApproval(loop);

    // 审批时 diff 已经算好了——这是「改在客户端做」的全部意义
    final ev = loop.pendingApprovals.single;
    expect(ev.check.reason, equals(ApprovalReason.fileWrite));
    expect(ev.preview!.oldText, equals('listen 80;'));
    expect(ev.preview!.newText, equals('listen 8080;'));
    expect(ev.preview!.atLine, equals(2));

    loop.respondApproval(ev.seq, ApprovalDecision.allowOnce);
    await f;

    expect(runner.ran, hasLength(2));
    // 写回的是整份新内容。用锚定前缀的正则避免先命中被单引号包住的短路径
    // （比如写命令里 `$q` 本身也可能是一个单引号字面量）。
    final m = RegExp(r"b64='([A-Za-z0-9+/=]+)'").firstMatch(runner.ran[1])!;
    expect(utf8.decode(base64.decode(m.group(1)!)),
        equals('server {\n  listen 8080;\n}\n'));
    // 且写回命令里带着读到的 sha，做 TOCTOU 校验
    expect(runner.ran[1], contains('sha256sum'));
    expect(runner.ran[1],
        contains(sha256.convert(utf8.encode(original)).toString()));
  });

  test('old_string 命中多次：不弹审批，不写，告知次数', () async {
    final runner = FakeRunner(results: [_readOut('foo\nbar\nfoo\n')]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('foo', 'baz')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(runner.ran, hasLength(1), reason: '只读了，没写');
    expect(loop.pendingApprovals, isEmpty);
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
    expect(r.content, contains('2'));
  });

  test('old_string 命中 0 次：不写', () async {
    final runner = FakeRunner(results: [_readOut('nothing here\n')]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('listen 80;', 'x')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(runner.ran, hasLength(1));
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.content, contains('not found'));
  });

  test('文件不存在：读失败即止，不当成空文件新建', () async {
    final runner = FakeRunner(results: [
      const CommandOutput(
          stdout: '', stderr: 'No such file or directory', exitCode: 1),
    ]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('a', 'b')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(runner.ran, hasLength(1));
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
    // 不用 contains('read')：读失败之后如果被当成空文件继续执行（本该被
    // 挡住的那种回归），applyEdit 会在空内容里找不到非空 old_string，报
    // 「`old_string` not found in the file. Read the file first...」——
    // 这条错误消息里同样有 "read"，会让断言巧合命中，测不出真正的回归。
    // `write_file` 是读失败分支自己的措辞（「文件不存在的话用 write_file
    // 新建」），继续执行的分支不会提到它，才是真正区分两条路径的地方。
    expect(r.content, contains('write_file'),
        reason: 'edit_file 不负责创建，那是 write_file 的事');
  });

  test('哈希对不上：不写', () async {
    final bytes = utf8.encode('real content\n');
    final runner = FakeRunner(results: [
      CommandOutput(
        stdout: '${'0' * 64}\n${bytes.length}\n${base64.encode(bytes)}',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('real', 'fake')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(runner.ran, hasLength(1));
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.content, contains('hecksum'));
  });

  test('写回时文件已变（exit 65）：告知模型，不重试', () async {
    final runner = FakeRunner(results: [
      _readOut('a\n'),
      const CommandOutput(
          stdout: '', stderr: '', exitCode: kStaleFileExitCode),
    ]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.bypass,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('a', 'b')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
    expect(r.content, contains('changed on disk'));
    expect(r.content, contains('Nothing was written'));
  });

  test('拒绝后不写', () async {
    final runner = FakeRunner(results: [_readOut('a\n')]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.readOnly,
      provider: FakeProvider([
        AIResponse(toolCalls: [_editCall('a', 'b')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final f = loop.send('go');
    await _waitForPendingApproval(loop);
    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.reject);
    await f;
    expect(runner.ran, hasLength(1), reason: '只有那次读');
  });

  test('读取本身受 cat 判定约束：凭据路径先弹一次审批', () async {
    final runner = FakeRunner(results: [_readOut('secret\n')]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [
          // `.env` 命中凭据 deny 清单（与 `.ssh/config` 不同，`.ssh/config`
          // 本身不在 deny 正则里，只有 id_*/identity 之类的私钥文件名才命中）。
          _editCall('secret', 'x', path: '/home/u/.env')
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final f = loop.send('go');
    await _waitForPendingApproval(loop);

    // 第一次审批是「读」，带凭据警示
    final ev = loop.pendingApprovals.single;
    expect(ev.check.denyHit, isTrue);
    expect(ev.preview, isNull, reason: '还没读到内容，算不出 diff');

    loop.respondApproval(ev.seq, ApprovalDecision.reject);
    await f;
    expect(runner.ran, isEmpty);
  });

  // 回归测试：`_pending` 若按 callId 索引，读、写两个阶段的 `ToolCallEvent`
  // 共用同一个 callId，这里的「迟到应答」会误批准写。见 agent_loop.dart
  // 里 `_pending` 字段与 `respondApproval` 上的注释。
  test('写审批已注册后，重放读审批的旧标识不会误批写', () async {
    final runner = FakeRunner(results: [
      _readOut('password=old\n'),
      const CommandOutput(stdout: '', stderr: '', exitCode: 0),
    ]);
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      provider: FakeProvider([
        // `.env` 同时命中读（cat 判定）与写（永远审批）两道闸，
        // 于是这条调用会经历「读审批 → 读执行 → 写审批」完整两阶段。
        AIResponse(toolCalls: [
          _editCall('password=old', 'password=new', path: '/home/u/.env')
        ]),
        const AIResponse(text: 'done'),
      ]),
    );

    final f = loop.send('go');
    await _waitForPendingApproval(loop);

    // 阶段一：读审批。
    final readEv = loop.pendingApprovals.single;
    final readSeq = readEv.seq;
    loop.respondApproval(readSeq, ApprovalDecision.allowOnce);

    // 阶段二：写审批注册。修复前 `_pending` 按 callId 索引，读、写共用
    // 同一个 callId，写审批的 completer 会顶替刚被 remove 的读审批，
    // 落在同一个 map key 下。
    await _waitForNextApproval(loop, readSeq);
    final writeEv = loop.pendingApprovals.single;
    expect(writeEv.seq, isNot(equals(readSeq)), reason: '两张卡必须是不同的 seq');
    expect(writeEv.callId, equals(readEv.callId),
        reason: '前提：edit_file 的读写两阶段确实共用同一个 callId');

    // 模拟一次迟到的重复点击：带着读那张卡的旧标识再应答一次。
    // 按 callId 索引时，这次调用会命中写审批正等待的 completer（因为
    // map key 相同），把写错误地批准掉；按 seq 索引后，`readSeq` 对应的
    // completer 早已在阶段一被 remove，这次调用应被静默丢弃，不影响写。
    loop.respondApproval(readSeq, ApprovalDecision.allowOnce);
    await Future.delayed(const Duration(milliseconds: 20));

    expect(loop.pendingApprovals, hasLength(1),
        reason: '写审批不该被一个不属于它的旧标识误批准');
    expect(loop.pendingApprovals.single.seq, equals(writeEv.seq));
    expect(runner.ran, hasLength(1), reason: '只有读跑了，写不该被执行');

    // 用写审批真正的 seq 收尾，避免这条测试留下悬挂的 future。
    loop.respondApproval(writeEv.seq, ApprovalDecision.allowOnce);
    await f;
    expect(runner.ran, hasLength(2));
  });
}
