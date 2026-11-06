import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

void main() {
  ToolCall planCall(List<String> steps, {int? current}) => ToolCall(
        id: 'c1',
        name: 'set_plan',
        args: {'steps': steps, if (current != null) 'current': current},
      );

  test('产生 PlanUpdatedEvent，不需要审批也不执行命令', () async {
    final runner = FakeRunner(results: const []);
    final loop = makeLoop(
      runner: runner,
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        AIResponse(toolCalls: [planCall(['查日志', '看端口'], current: 0)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(runner.ran, isEmpty, reason: 'set_plan 什么都不执行');
    expect(loop.pendingApprovals, isEmpty);
    final ev = loop.events.whereType<PlanUpdatedEvent>().single;
    expect(ev.steps, equals(['查日志', '看端口']));
    expect(ev.current, equals(0));
  });

  test('再次调用整体替换，且只保留最后一份', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        AIResponse(toolCalls: [planCall(['a'])]),
        AIResponse(toolCalls: [planCall(['a', 'b'], current: 1)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.plan, equals(['a', 'b']));
    expect(loop.planCurrent, equals(1));
  });

  test('空列表表示清空', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        AIResponse(toolCalls: [planCall(['a'])]),
        AIResponse(toolCalls: [planCall(const [])]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.plan, isEmpty);
  });

  test('steps 不是列表时回 isError', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'set_plan', args: {'steps': 'a,b'})
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final r = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .single;
    expect(r.isError, isTrue);
  });

  test('非字符串元素被转成字符串，不抛', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'set_plan', args: {'steps': [1, true]})
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.plan, equals(['1', 'true']));
  });

  test('current 越界时钳到合法范围', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        AIResponse(toolCalls: [planCall(['a', 'b'], current: 9)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    // 上界是 length（不是 length - 1）——见下一条。
    expect(loop.planCurrent, equals(2));
  });

  test('current 等于步骤数是合法的「全部做完」，不被钳回最后一步', () async {
    // 工具描述让模型收工时发 current == steps.length，清单据此把每一步都
    // 渲染成打勾、不留「正在做」的那一行。钳到 length - 1 的话最后一步永远
    // 停在「正在做」，一次排查结束了清单还在转。
    //
    // 放开上界是安全的：planCurrent 全仓库只透传给 PlanUpdatedEvent 渲染，
    // 没有任何地方拿它做索引取值。
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        AIResponse(toolCalls: [planCall(['a', 'b', 'c'], current: 3)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.planCurrent, equals(3));
  });

  test('存档往返后 plan 还在', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        AIResponse(toolCalls: [planCall(['a', 'b'], current: 1)]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    final restored = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider(const []),
      restoreFrom: loop.toArchive(),
    );
    expect(restored.plan, equals(['a', 'b']));
    expect(restored.planCurrent, equals(1));
  });
}
