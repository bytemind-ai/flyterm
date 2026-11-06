import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// full 档、有多机、有技能——这样 `more_tools` 和它解锁的三个 transfer
/// 工具都在入参里，与 `kToolGroups` 断言用的清单一致。
List<ToolSpec> _fullTools() => agentToolSpecsFor(AgentToolTier.full,
    hasSkills: true, hasOtherServers: true);

/// 造一个会调用 `more_tools(group)` 的 loop，[times] 次（默认 1 次），
/// 最后回一句文本收尾。
AgentLoop makeLoopForMoreTools({required String group, int times = 1}) {
  final script = <Object>[
    for (var i = 0; i < times; i++)
      AIResponse(toolCalls: [
        ToolCall(id: 'c$i', name: 'more_tools', args: {'group': group}),
      ]),
    const AIResponse(text: 'done'),
  ];
  return makeLoop(
    provider: FakeProvider(script),
    mode: PermissionMode.bypass,
    toolSpecs: _fullTools,
    // 这个文件测的就是解锁机制本身，必须从「一个组都没解锁」起步。
    unlockedGroups: const {},
  );
}

/// 造一个直接调用某个（大概率被锁住的）工具名的 loop，不先解锁。
AgentLoop makeLoopCallingLockedTool(String toolName) {
  return makeLoop(
    provider: FakeProvider([
      AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: toolName, args: const {}),
      ]),
      const AIResponse(text: 'done'),
    ]),
    mode: PermissionMode.bypass,
    toolSpecs: _fullTools,
    unlockedGroups: const {},
  );
}

void main() {
  test('解锁后下一轮工具清单里出现那一组', () async {
    final loop = makeLoopForMoreTools(group: 'transfer');
    await loop.send('把日志传到手机');
    expect(loop.activeToolNames, contains('upload_file'));
    expect(loop.activeToolNames, contains('download_file'));
    expect(loop.activeToolNames, isNot(contains('web_fetch')));
  });

  test('幂等：连解锁两次同一组，第二次成功且清单不变', () async {
    final loop = makeLoopForMoreTools(group: 'transfer', times: 2);
    await loop.send('传文件');
    final evs = loop.events.whereType<ToolCallEvent>().toList();
    expect(evs, hasLength(2));
    expect(evs[1].status, ToolCallStatus.done, reason: '重复解锁不该报错');
    expect(loop.activeToolNames, contains('upload_file'));
  });

  test('未知组名：回可用组列表，且 invalidArgs 计数不增加', () async {
    final loop = makeLoopForMoreTools(group: 'nope');
    await loop.send('x');
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, ToolCallStatus.failed);
    expect(ev.output, contains('transfer'));
    expect(ev.output, contains('web'));
    expect(loop.debugConsecutiveInvalidArgs, 0,
        reason: '猜错组名是合理尝试，不该触发连续无效参数的熔断');
  });

  test('未解锁就调 upload_file：错误文案指名道姓要 more_tools', () async {
    // 这条走的是 `_executeOneInner` 开头的档位闸门，不是
    // `MoreToolsExecutors` —— 与「未声明的工具名被拒」那条闸门共用同一处
    // 代码，压根不会创建 `ToolCallEvent`（见 `agent_metrics_test.dart` 里
    // 同一个闸门的注释），所以断言要落在 `debugHistory` 的 `toolResults`
    // 上，而不是 `events`。
    final loop = makeLoopCallingLockedTool('upload_file');
    await loop.send('传文件');
    final results = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .toList();
    expect(results.single.isError, isTrue);
    expect(results.single.content, contains('more_tools'));
    expect(results.single.content, contains('transfer'),
        reason: '要说清该解锁哪个组，只说「工具不存在」模型会改口说做不到');
  });
}
