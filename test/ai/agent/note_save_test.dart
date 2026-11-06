import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// `save_note` 执行器的连线测试。
///
/// 真正的读-改-写/超限/两种失败语义已经在
/// `test/ai/agent/server_notes_manager_test.dart` 里钉死了（包括一条明确
/// 提到 `save_note` 的用例），这里只管「工具层有没有如实转发」：参数怎么
/// 校验、审批怎么弹、`server` 名字怎么解析成 id、`ctx.serverNoteSaver` 的
/// 返回值怎么翻译成模型看到的文本。骨架与 `skill_save_test.dart` 一致。
void main() {
  ToolCall noteCall({
    String? body = 'uses podman, not docker',
    String? heading,
    String? server,
  }) =>
      ToolCall(id: 'c1', name: 'save_note', args: {
        if (body != null) 'body': body,
        if (heading != null) 'heading': heading,
        if (server != null) 'server': server,
      });

  List<ToolSpec> full() =>
      agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

  test('body 为空时判成参数非法，不写库', () async {
    var called = false;
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      serverNoteSaver: (id, h, b) async {
        called = true;
        return const ServerNoteSaveResult.accepted();
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [noteCall(body: '')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(called, isFalse);
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.failed));
    expect(ev.output, contains('body'));
  });

  test('ask 模式下弹审批，批准后落库并转发 heading/body/server', () async {
    final calls = <(String?, String, String)>[];
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: full,
      serverNoteSaver: (id, h, b) async {
        calls.add((id, h, b));
        return const ServerNoteSaveResult.accepted();
      },
      provider: FakeProvider([
        AIResponse(
            toolCalls: [noteCall(body: 'uses podman', heading: 'containers')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final fut = loop.send('go');
    await Future<void>.delayed(Duration.zero);

    expect(loop.pendingApprovals, hasLength(1));
    loop.respondApproval(
        loop.pendingApprovals.first.seq, ApprovalDecision.allowOnce);
    await fut;

    expect(calls, equals([(null, 'containers', 'uses podman')]));
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.done));
  });

  test('bypass 模式直接放行 —— 与 save_skill 同理由', () async {
    var saved = false;
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      serverNoteSaver: (id, h, b) async {
        saved = true;
        return const ServerNoteSaveResult.accepted();
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [noteCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(loop.pendingApprovals, isEmpty);
    expect(saved, isTrue);
  });

  test('用户拒绝审批时不写库', () async {
    var saved = false;
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: full,
      serverNoteSaver: (id, h, b) async {
        saved = true;
        return const ServerNoteSaveResult.accepted();
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [noteCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final fut = loop.send('go');
    await Future<void>.delayed(Duration.zero);
    loop.respondApproval(
        loop.pendingApprovals.first.seq, ApprovalDecision.reject);
    await fut;

    expect(saved, isFalse);
    expect(loop.events.whereType<ToolCallEvent>().single.status,
        equals(ToolCallStatus.rejected));
  });

  test('超限时把 overflowBytes 的数字原样告诉模型', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      serverNoteSaver: (id, h, b) async =>
          const ServerNoteSaveResult.rejected(37),
      provider: FakeProvider([
        AIResponse(toolCalls: [noteCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.failed));
    expect(ev.output, contains('37'));
  });

  test('failed 时把 error 原文转发，不套自己的模板', () async {
    const customError = 'This machine\'s notes are already 900 bytes over '
        'the limit and must be trimmed in Settings first.';
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      serverNoteSaver: (id, h, b) async =>
          const ServerNoteSaveResult.failed(customError),
      provider: FakeProvider([
        AIResponse(toolCalls: [noteCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.failed));
    expect(ev.output, equals(customError));
  });

  test('server 传了一个未知名字 —— 报错并附可用名单，不猜一个落点', () async {
    var called = false;
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      servers: const [
        ServerListEntry(id: 's1', name: 'dk', host: 'h', credsOk: true),
      ],
      serverNoteSaver: (id, h, b) async {
        called = true;
        return const ServerNoteSaveResult.accepted();
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [noteCall(server: 'no-such-box')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(called, isFalse);
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.failed));
    expect(ev.output, contains('dk'));
  });

  test('server 传了已保存的名字 —— 解析成 id 转发，而不是原样传名字', () async {
    String? capturedId;
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      servers: const [
        ServerListEntry(id: 's1', name: 'dk', host: 'h', credsOk: true),
      ],
      serverNoteSaver: (id, h, b) async {
        capturedId = id;
        return const ServerNoteSaveResult.accepted();
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [noteCall(server: 'dk')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(capturedId, equals('s1'));
  });
}
