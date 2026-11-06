import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

void main() {
  ToolCall loadCall(String name, {required String id}) =>
      ToolCall(id: id, name: 'load_skill', args: {'name': name});

  List<ToolSpec> withSkills() =>
      agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

  test('drop 掉技能正文之后，再次 load 会重新发一遍正文', () async {
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
        const AIResponse(text: 'first done'),
        AIResponse(toolCalls: [loadCall('nginx', id: 'c2')]),
        const AIResponse(text: 'second done'),
      ]),
    );
    await loop.send('go');
    expect(bodyReads, equals(1));

    // 手动触发一次丢弃，模拟上下文超预算把这条正文丢成 marker
    expect(loop.debugDropOldestOutput(), isTrue);

    await loop.send('again');

    expect(bodyReads, equals(2),
        reason: '正文已被丢弃，模型再要时必须真的重新发一遍');
    expect(loop.events.whereType<ToolCallEvent>().last.output,
        contains('SKILL_BODY_MARK'));
  });

  test('drop 掉的是别的工具输出时，技能记账不受影响', () async {
    var bodyReads = 0;
    final loop = makeLoop(
      runner: FakeRunner(results: const [
        CommandOutput(stdout: 'xxxxxxxxxxxxxxxxxxxx', stderr: '', exitCode: 0),
      ]),
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async {
        bodyReads++;
        return 'BODY';
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [
          const ToolCall(
              id: 'b1',
              name: 'bash',
              args: {'command': 'ls', 'description': 'd'}),
        ]),
        AIResponse(toolCalls: [loadCall('nginx', id: 'c1')]),
        const AIResponse(text: 'done'),
        AIResponse(toolCalls: [loadCall('nginx', id: 'c2')]),
        const AIResponse(text: 'done2'),
      ]),
    );
    await loop.send('go');
    expect(bodyReads, equals(1));

    // 最早的可丢输出是 bash 那条，不是技能正文
    expect(loop.debugDropOldestOutput(), isTrue);

    await loop.send('again');

    expect(bodyReads, equals(1),
        reason: '技能正文还在历史里，不该重发');
  });

  test('两个 load_skill 同轮到达时不弹聚合审批卡 —— 它只读本地库', () async {
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx', 'deploy'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'BODY_$n',
      provider: FakeProvider([
        AIResponse(toolCalls: [
          loadCall('nginx', id: 'c1'),
          loadCall('deploy', id: 'c2'),
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(loop.pendingApprovals, isEmpty,
        reason: 'load_skill 不需要审批，聚合卡不该列出它');
    expect(loop.events.whereType<BatchApprovalEvent>(), isEmpty);
    final evs = loop.events.whereType<ToolCallEvent>().toList();
    expect(evs, hasLength(2));
    expect(evs.every((e) => e.status == ToolCallStatus.done), isTrue);
  });

  /// 模型在 `_history` 里看到的那条 tool result 内容（最后一条）。
  ///
  /// **不能看 `loop.events`** —— 那是给 UI 的事件流，`_dropOldestOutput` 只改
  /// `_history`，events 里始终留着完整正文。拿 events 断言会看到「丢弃前后
  /// 一模一样」的假象。
  String histLastToolContent(AgentLoop l) {
    for (final m in l.debugHistory.reversed) {
      if (m.role != 'tool') continue;
      for (final r in m.toolResults ?? const <ToolResult>[]) {
        return r.content;
      }
    }
    return '(未找到)';
  }

  test('技能正文被丢弃时，marker 要点名是哪个技能并提示可以重新 load', () async {
    // 缺这个提示，模型就只能凭残留印象往下做：它看到的是一条通用的
    // `[output dropped: N lines]`，既不知道那曾是技能正文，而 system prompt
    // 又要求「每个技能一次会话只 load 一次」，于是不会重新取 —— 表现就是
    // 「聊了一阵之后不再按技能执行」。记账那边早就摘干净了（见本文件第一条
    // 用例），差的只是告诉模型这件事。
    final loop = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'STEP 1\nSTEP 2\nSTEP 3',
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx', id: 'c1')]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop.send('go');
    expect(histLastToolContent(loop), contains('STEP 1'),
        reason: '前置条件：正文在上下文里');

    expect(loop.debugDropOldestOutput(), isTrue);

    final marker = histLastToolContent(loop);
    expect(marker, contains('nginx'),
        reason: '要点名是哪个技能，否则模型无从判断该不该重新 load');
    expect(marker, contains('load_skill'),
        reason: '要明确指出重新 load 这个动作');
    expect(marker, startsWith('[output dropped'),
        reason: '前缀必须保持 —— _dropOldestOutput 靠它判断「这条已经丢过」，'
            '失配会让调用方的 while 退不出去');
    expect(marker, isNot(contains('STEP 1')), reason: '正文必须真的没了');
  });

  test('非技能输出的丢弃 marker 不受影响', () async {
    final loop = makeLoop(
      runner: FakeRunner(results: const [
        CommandOutput(stdout: 'aaaa\nbbbb\ncccc', stderr: '', exitCode: 0),
      ]),
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'BODY',
      provider: FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(
              id: 'b1',
              name: 'bash',
              args: {'command': 'ls', 'description': 'd'}),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop.send('go');
    expect(loop.debugDropOldestOutput(), isTrue);

    final marker = histLastToolContent(loop);
    expect(marker, startsWith('[output dropped'));
    expect(marker, isNot(contains('load_skill')),
        reason: 'bash 输出被丢弃时不该冒出技能相关的提示');
    expect(marker, contains('exit 0'), reason: '原有的退出码信息要保留');
  });
}
