import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_partition.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

ToolCall _c(String id, String name, Map<String, dynamic> args) =>
    ToolCall(id: id, name: name, args: args);

void main() {
  const rules = PermissionRuleSet([]);

  test('四个本地工具进 local 桶', () {
    final p = partitionToolCalls(
      [
        _c('1', 'read_terminal', const {}),
        _c('2', 'load_skill', const {'name': 'x'}),
        _c('3', 'set_plan', const {
          'steps': ['a']
        }),
        _c('4', 'list_servers', const {}),
      ],
      rules: rules,
      mode: PermissionMode.ask,
    );
    expect(p.local, [0, 1, 2, 3]);
    expect(p.parallel, isEmpty);
    expect(p.serial, isEmpty);
  });

  test('只读且放行的 bash 仍进 parallel，需审批的仍进 serial', () {
    final p = partitionToolCalls(
      [
        _c('1', 'bash', const {'command': 'ls -la'}),
        _c('2', 'bash', const {'command': 'rm -rf /tmp/x'}),
      ],
      rules: const PermissionRuleSet(defaultAllowRules),
      mode: PermissionMode.ask,
    );
    expect(p.parallel, [0]);
    expect(p.serial, [1]);
    expect(p.local, isEmpty);
  });

  test('三桶混合时下标各归各位，且互不重叠、并集完整', () {
    final calls = [
      _c('1', 'bash', const {'command': 'ls'}),
      _c('2', 'set_plan', const {
        'steps': ['a']
      }),
      _c('3', 'write_file', const {'path': '/a', 'content': 'x'}),
    ];
    final p = partitionToolCalls(calls,
        rules: const PermissionRuleSet(defaultAllowRules),
        mode: PermissionMode.bypass);
    expect(p.local, [1]);
    expect(p.parallel, [0]);
    expect(p.serial, [2]);
    final all = {...p.local, ...p.parallel, ...p.serial};
    expect(all.length, calls.length, reason: '三桶必须互不重叠');
    expect(all, {0, 1, 2}, reason: '三桶并集必须覆盖全部下标');
  });

  test('bypass 模式下本地工具照样进 local 桶', () {
    final p = partitionToolCalls([_c('1', 'read_terminal', const {})],
        rules: rules, mode: PermissionMode.bypass);
    expect(p.local, [0]);
  });

  test('set_plan 在审批卡还挂着的时候就已经生效', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      // 一轮两个调用，顺序刻意把需审批的放前面：模型先发 bash 后发
      // set_plan，如果 local 桶不是「无视模型给出的顺序、总是最先跑」，
      // 这条测试就会在 set_plan 前面卡住等审批。
      AIResponse(toolCalls: [
        const ToolCall(
            id: 'c1', name: 'bash', args: {'command': 'rm -rf /tmp/x'}),
        ToolCall(id: 'c2', name: 'set_plan', args: const {
          'steps': ['查日志', '重启']
        }),
      ]),
      const AIResponse(text: 'done'),
    ]);
    // 默认 ask 模式：'rm -rf /tmp/x' 不在 defaultAllowRules 里，必弹审批。
    // set_plan / list_servers 不在 leanToolSpecs 里（makeLoop 的默认档），
    // 必须换成 fullToolSpecs，否则 `_executeOneInner` 的闸门会把它们当成
    // 「模型幻觉出的工具名」直接拒掉，压根走不到 `_executeSetPlan`。
    final loop = makeLoop(
        provider: provider, runner: runner, toolSpecs: () => fullToolSpecs);

    final f = loop.send('go');
    // 等审批卡真正出现——`_awaitApproval` 是异步挂起的，出现时机取决于
    // 事件循环调度，不能猜一个固定延迟。
    while (loop.pendingApprovals.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    // 关键断言：此时审批卡还挂着，set_plan 已经生效了。
    expect(loop.plan, ['查日志', '重启'],
        reason: 'set_plan 属于 local 桶，必须先于审批执行');

    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.allowOnce);
    await f;
  });

  test('local 桶的工具会被执行，结果不是「未执行」', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      AIResponse(toolCalls: [
        const ToolCall(id: 'c1', name: 'list_servers', args: {}),
        const ToolCall(
            id: 'c2', name: 'bash', args: {'command': 'uptime'}),
      ]),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs);

    await loop.send('go');

    // list_servers 和 set_plan 一样不建 ToolCallEvent（见 `_executeSetPlan`
    // 的注释：它们不走审批系统，`events` 里看不到它们），真正装着执行结果
    // 的是喂回模型的 `_history`——这条是防回归的：local 桶接入前，
    // list_servers 与 bash 都不会被 `_executeRound` 遍历到，两条 ToolResult
    // 都会 fallback 成「Not executed」。
    final toolResults = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .toList();
    expect(toolResults, hasLength(2));
    for (final r in toolResults) {
      expect(r.content, isNot(contains('Not executed')));
    }
  });
}
