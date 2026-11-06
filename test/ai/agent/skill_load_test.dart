import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

void main() {
  ToolCall loadCall(String name, {String id = 'c1'}) =>
      ToolCall(id: id, name: 'load_skill', args: {'name': name});

  List<ToolSpec> withSkills() =>
      agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

  test('命中时把正文回填给模型，并且不弹审批', () async {
    final loop = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'SKILL_BODY_MARK',
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(loop.pendingApprovals, isEmpty, reason: 'load_skill 不走权限系统');
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.toolName, equals('load_skill'));
    expect(ev.status, equals(ToolCallStatus.done));
    expect(ev.output, contains('SKILL_BODY_MARK'));
  });

  test('回填带 [skill: name] 前缀 —— drop 时靠它认出这是哪个技能', () async {
    final loop = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'BODY',
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.events.whereType<ToolCallEvent>().single.output,
        startsWith('[skill: nginx]'));
  });

  test('名字不存在时报错并列出可用的', () async {
    final loop = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx', 'deploy'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => null,
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('mysql')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.failed));
    expect(ev.output, contains('nginx'));
    expect(ev.output, contains('deploy'));
  });

  test('大小写不同也能命中 —— 模型复述 name 时会改大小写', () async {
    final loop = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['Nginx-Check'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'BODY',
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx-check')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.events.whereType<ToolCallEvent>().single.status,
        equals(ToolCallStatus.done));
  });

  test('同一会话重复 load 只回一行提示，不再发一遍正文', () async {
    var bodyReads = 0;
    final loop = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async {
        bodyReads++;
        return 'SKILL_BODY_MARK';
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx', id: 'c1')]),
        AIResponse(toolCalls: [loadCall('nginx', id: 'c2')]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(bodyReads, equals(1), reason: '第二次不该再读库');
    final second = loop.events.whereType<ToolCallEvent>().last;
    expect(second.output, isNot(contains('SKILL_BODY_MARK')));
    expect(second.output, contains('already loaded'));
  });

  test('name 参数缺失时判成参数非法', () async {
    final loop = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'B',
      provider: FakeProvider([
        AIResponse(toolCalls: [
          const ToolCall(id: 'c1', name: 'load_skill', args: {})
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.events.whereType<ToolCallEvent>().single.status,
        equals(ToolCallStatus.failed));
  });
}
