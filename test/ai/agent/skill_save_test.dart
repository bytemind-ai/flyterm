import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

void main() {
  ToolCall saveCall({
    String name = 'nginx',
    String description = '排查 502',
    String body = 'BODY',
  }) =>
      ToolCall(id: 'c1', name: 'save_skill', args: {
        'name': name,
        'description': description,
        'body': body,
      });

  List<ToolSpec> full() =>
      agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

  test('ask 模式下弹审批，批准后落库', () async {
    final saved = <String>[];
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: full,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async => saved.add('$n|$d|$b'),
      provider: FakeProvider([
        AIResponse(toolCalls: [saveCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final fut = loop.send('go');
    await Future<void>.delayed(Duration.zero);

    expect(loop.pendingApprovals, hasLength(1));
    loop.respondApproval(
        loop.pendingApprovals.first.seq, ApprovalDecision.allowOnce);
    await fut;

    expect(saved, equals(['nginx|排查 502|BODY']));
  });

  test('plan 模式也是弹卡，不进提案队列 —— 它写的不是这台服务器', () async {
    final saved = <String>[];
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: full,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async => saved.add(n),
      provider: FakeProvider([
        AIResponse(toolCalls: [saveCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final fut = loop.send('go');
    await Future<void>.delayed(Duration.zero);

    expect(loop.pendingApprovals, hasLength(1),
        reason: 'plan 模式下也必须弹卡');
    expect(loop.events.whereType<PlanProposalEvent>(), isEmpty,
        reason: '绝不能进服务器变更提案队列');
    loop.respondApproval(
        loop.pendingApprovals.first.seq, ApprovalDecision.allowOnce);
    await fut;
    expect(saved, equals(['nginx']));
  });

  test('bypass 模式直接放行 —— 那个模式下 bash 都能无审批跑', () async {
    final saved = <String>[];
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async => saved.add(n),
      provider: FakeProvider([
        AIResponse(toolCalls: [saveCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(loop.pendingApprovals, isEmpty);
    expect(saved, equals(['nginx']));
  });

  test('用户拒绝时不落库，且回填说明被拒', () async {
    final saved = <String>[];
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: full,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async => saved.add(n),
      provider: FakeProvider([
        AIResponse(toolCalls: [saveCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    final fut = loop.send('go');
    await Future<void>.delayed(Duration.zero);
    loop.respondApproval(
        loop.pendingApprovals.first.seq, ApprovalDecision.reject);
    await fut;

    expect(saved, isEmpty);
    expect(loop.events.whereType<ToolCallEvent>().single.status,
        equals(ToolCallStatus.rejected));
  });

  test('正文超 8 KiB 时判成参数非法，不弹卡', () async {
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: full,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async {},
      provider: FakeProvider([
        AIResponse(toolCalls: [saveCall(body: 'x' * 9000)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(loop.pendingApprovals, isEmpty);
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.failed));
    expect(ev.output, contains('8192'));
  });

  test('description 超 200 字节时判成参数非法并说明理由', () async {
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: full,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async {},
      provider: FakeProvider([
        AIResponse(toolCalls: [saveCall(description: 'd' * 300)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.events.whereType<ToolCallEvent>().single.status,
        equals(ToolCallStatus.failed));
  });

  test('缺字段时判成参数非法', () async {
    final loop = makeLoop(
      toolSpecs: full,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async {},
      provider: FakeProvider([
        AIResponse(toolCalls: [
          const ToolCall(id: 'c1', name: 'save_skill', args: {'name': 'x'})
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.events.whereType<ToolCallEvent>().single.status,
        equals(ToolCallStatus.failed));
  });

  test('撞名时 displayCommand 说的是「更新」而不是「保存」', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: full,
      skillNamesProvider: () => ['nginx'],
      skillSaver: (n, d, b, a) async {},
      provider: FakeProvider([
        AIResponse(toolCalls: [saveCall()]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.displayCommand, contains('update'));
  });
}
