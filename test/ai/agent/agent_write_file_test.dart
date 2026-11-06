import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

void main() {
  ToolCall writeCall(String path, String content) => ToolCall(
        id: 'c1',
        name: 'write_file',
        args: {'path': path, 'content': content, 'description': '写配置'},
      );

  test('write_file 弹审批，批准后写入', () async {
    final runner = FakeRunner(
        result: const CommandOutput(stdout: '', stderr: '', exitCode: 0));
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      mode: PermissionMode.readOnly,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [writeCall('/tmp/x.conf', 'hello\n')]),
        const AIResponse(text: 'done'),
      ]),
    );

    final f = loop.send('go');
    await Future.delayed(const Duration(milliseconds: 5));
    expect(loop.state, equals(AgentLoopState.awaitingApproval));

    final ev = loop.pendingApprovals.single;
    expect(ev.toolName, equals('write_file'));
    expect(ev.check.reason, equals(ApprovalReason.fileWrite));
    expect(ev.check.canRemember, isFalse);
    expect(ev.preview!.path, equals('/tmp/x.conf'));
    expect(ev.preview!.oldText, isNull);
    expect(ev.preview!.newText, equals('hello\n'));

    loop.respondApproval(ev.seq, ApprovalDecision.allowOnce);
    await f;

    expect(runner.ran, hasLength(1));
    // 载荷是 base64，解出来必须与 content 逐字节相同。
    // 锚定 `b64=` 前缀而不是裸的单引号片段：`shellQuote('/tmp/x.conf')`
    // 产出的 `'/tmp/x.conf'` 本身就落在 base64 字母表内，裸正则可能先
    // 匹配到路径而不是载荷。
    final m = RegExp(r"b64='([A-Za-z0-9+/=]+)'").firstMatch(runner.ran[0])!;
    expect(utf8.decode(base64.decode(m.group(1)!)), equals('hello\n'));
  });

  test('拒绝后不执行任何命令', () async {
    final runner = FakeRunner(
        result: const CommandOutput(stdout: '', stderr: '', exitCode: 0));
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      mode: PermissionMode.readOnly,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [writeCall('/tmp/x', 'x')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final f = loop.send('go');
    await Future.delayed(const Duration(milliseconds: 5));
    loop.respondApproval(loop.pendingApprovals.single.seq,
        ApprovalDecision.reject);
    await f;

    expect(runner.ran, isEmpty);
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
    expect(r.content, contains('rejected'));
  });

  test('内容超上限时不弹审批，直接回错误', () async {
    final runner = FakeRunner(
        result: const CommandOutput(stdout: '', stderr: '', exitCode: 0));
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      mode: PermissionMode.readOnly,
      runner: runner,
      provider: FakeProvider([
        AIResponse(toolCalls: [writeCall('/tmp/x', 'y' * 7000)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(runner.ran, isEmpty);
    expect(loop.pendingApprovals, isEmpty);
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
    expect(r.content, contains('6000'));
  });

  test('缺参数时回 isError，不弹审批', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      mode: PermissionMode.readOnly,
      provider: FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'write_file', args: {'path': '/tmp/x'})
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
    expect(r.content, contains('content'));
  });

  test('bypass 模式下不弹审批直接写', () async {
    final runner = FakeRunner(
        result: const CommandOutput(stdout: '', stderr: '', exitCode: 0));
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.bypass,
      provider: FakeProvider([
        AIResponse(toolCalls: [writeCall('/tmp/x', 'hi')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(runner.ran, hasLength(1));
  });

  test('凭据路径带 denyHit 警示', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      mode: PermissionMode.readOnly,
      provider: FakeProvider([
        AIResponse(toolCalls: [writeCall('/home/u/.ssh/id_rsa', 'k')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final f = loop.send('go');
    await Future.delayed(const Duration(milliseconds: 5));
    expect(loop.pendingApprovals.single.check.denyHit, isTrue);
    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.reject);
    await f;
  });

  test('写入失败时回 isError 并带远端信息', () async {
    final runner = FakeRunner(
        result: const CommandOutput(
            stdout: '', stderr: 'Permission denied', exitCode: 1));
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      runner: runner,
      mode: PermissionMode.bypass,
      provider: FakeProvider([
        AIResponse(toolCalls: [writeCall('/etc/x', 'hi')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
    expect(r.content, contains('Permission denied'));
  });
}
