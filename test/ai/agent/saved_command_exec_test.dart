import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/data/models/favorite_command.dart';

import '_fakes.dart';

void main() {
  const deploy = FavoriteCommand(
    id: 'd',
    name: '部署服务',
    command: 'deploy-cli deploy --service {{service}} --version {{version}}',
    aiEnabled: true,
  );

  ToolCall runCall(Map<String, dynamic> args, {String id = 'c1'}) =>
      ToolCall(id: id, name: 'run_saved_command', args: args);

  List<ToolSpec> withCmds() =>
      agentToolSpecsFor(AgentToolTier.full, hasSavedCommands: true);

  test('展开后执行，跑的是填好参数的完整命令', () async {
    final runner = FakeRunner(results: const [
      CommandOutput(stdout: 'ok', stderr: '', exitCode: 0),
    ]);
    final loop = makeLoop(
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: withCmds,
      savedCommandProvider: (n) =>
          n.toLowerCase() == deploy.name.toLowerCase() ? deploy : null,
      savedCommandNamesProvider: () => [deploy.name],
      provider: FakeProvider([
        AIResponse(toolCalls: [
          runCall({
            'name': '部署服务',
            'params': {'service': 'payment-api', 'version': 'v2.3.1'},
          })
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop.send('go');

    expect(runner.ran.single,
        contains('deploy-cli deploy --service payment-api --version v2.3.1'));
  });

  test('审批卡显示展开后的完整命令，description 带命令名与参数', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: withCmds,
      savedCommandProvider: (n) => deploy,
      savedCommandNamesProvider: () => [deploy.name],
      provider: FakeProvider([
        AIResponse(toolCalls: [
          runCall({
            'name': '部署服务',
            'params': {'service': 'payment-api', 'version': 'v2.3.1'},
          })
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop.send('go');

    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.displayCommand, contains('--service payment-api'));
    expect(ev.description, contains('部署服务'));
    expect(ev.description, contains('payment-api'));
  });

  test('名字不存在时报错并列出可用的', () async {
    // 名字没命中时 `_resolve` 在创建 `ToolCallEvent` 之前就返回了 error
    // （`_executeCommandTool` 顶部 `if (r.error != null)` 那条早退路径）——
    // 这条调用压根不会生成卡片，回填只能从「发给模型的下一轮消息」里找，
    // 与既有的「非法 tool args」「未知工具名」两个回归测试是同一种断言方式
    // （见 agent_loop_test.dart 175/204 行）。
    final p = FakeProvider([
      AIResponse(toolCalls: [runCall({'name': '不存在'})]),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: withCmds,
      savedCommandProvider: (n) => null,
      savedCommandNamesProvider: () => [deploy.name],
      provider: p,
    );
    await loop.send('go');
    final toolMsg = p.seen.last.firstWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.single.isError, isTrue);
    expect(toolMsg.toolResults!.single.content, contains('部署服务'));
  });

  test('缺参数被拒，且不执行任何命令', () async {
    final runner = FakeRunner(results: const []);
    final loop = makeLoop(
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: withCmds,
      savedCommandProvider: (n) => deploy,
      savedCommandNamesProvider: () => [deploy.name],
      provider: FakeProvider([
        AIResponse(toolCalls: [
          runCall({'name': '部署服务', 'params': {'service': 'api'}})
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop.send('go');

    expect(runner.ran, isEmpty, reason: '参数不全就不该跑任何东西');
  });

  test('注入参数被拒，且不执行任何命令', () async {
    final runner = FakeRunner(results: const []);
    final loop = makeLoop(
      runner: runner,
      mode: PermissionMode.bypass,
      toolSpecs: withCmds,
      savedCommandProvider: (n) => deploy,
      savedCommandNamesProvider: () => [deploy.name],
      provider: FakeProvider([
        AIResponse(toolCalls: [
          runCall({
            'name': '部署服务',
            'params': {'service': 'a; rm -rf /', 'version': 'v1'},
          })
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop.send('go');

    expect(runner.ran, isEmpty, reason: 'bypass 也不能让注入通过 —— 第一层在权限判定之前');
  });

  test('多余的键不报错，但回填里提了一句', () async {
    // 这条调用成功执行，`ToolCallEvent.output` 是 `formatForModel(out)`
    // （命令的 stdout/exit code），warning 只前置在**发给模型的**
    // `ToolResult.content` 里（见 `_executeCommandTool` 末尾），两者不是
    // 同一个字符串 —— 断言必须对着后者。
    final p = FakeProvider([
      AIResponse(toolCalls: [
        runCall({
          'name': '部署服务',
          'params': {'service': 'api', 'version': 'v1', 'extra': 'x'},
        })
      ]),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      toolSpecs: withCmds,
      savedCommandProvider: (n) => deploy,
      savedCommandNamesProvider: () => [deploy.name],
      provider: p,
    );
    await loop.send('go');
    final toolMsg = p.seen.last.firstWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.single.content, contains('extra'));
  });

  test('第二层仍然生效：危险命令即使参数干净也要弹卡', () async {
    const danger = FavoriteCommand(
      id: 'x',
      name: '清理',
      command: 'rm -rf {{path}}',
      aiEnabled: true,
    );
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: withCmds,
      savedCommandProvider: (n) => danger,
      savedCommandNamesProvider: () => [danger.name],
      provider: FakeProvider([
        AIResponse(toolCalls: [
          runCall({'name': '清理', 'params': {'path': '/var'}})
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final fut = loop.send('go');
    await Future<void>.delayed(Duration.zero);

    expect(loop.pendingApprovals, hasLength(1),
        reason: '参数白名单管不了「这条命令危不危险」');
    loop.respondApproval(
        loop.pendingApprovals.first.seq, ApprovalDecision.reject);
    await fut;
  });

  test('一轮里 run_saved_command + 需审批的 bash 不聚合成一张卡', () async {
    final loop = makeLoop(
      mode: PermissionMode.ask,
      toolSpecs: withCmds,
      savedCommandProvider: (n) => deploy,
      savedCommandNamesProvider: () => [deploy.name],
      provider: FakeProvider([
        AIResponse(toolCalls: [
          runCall({
            'name': '部署服务',
            'params': {'service': 'api', 'version': 'v1'},
          }, id: 'c1'),
          const ToolCall(
              id: 'c2',
              name: 'bash',
              args: {'command': 'systemctl restart nginx', 'description': 'd'}),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final fut = loop.send('go');
    await Future<void>.delayed(Duration.zero);

    expect(loop.events.whereType<BatchApprovalEvent>(), isEmpty,
        reason: 'BatchApprovalCard._detail 只认 args[command]/[path]，'
            'run_saved_command 的 name/params 全对不上，聚合卡上只会剩一行工具名');

    // 收尾：串行桶按顺序逐条执行，两次审批不会同时挂起——第一条（
    // run_saved_command）被拒之后，串行循环才会去跑第二条（bash）并注册
    // 它自己的审批。原始写法「只收集一次 pendingApprovals 就拒光」会漏掉
    // 第二张卡，`fut` 永远等不到它完成，整个测试挂到超时。这里边跑边拒，
    // 直到 `fut` 真正结束。
    var settled = false;
    unawaited(fut.whenComplete(() => settled = true));
    while (!settled) {
      for (final ev in loop.pendingApprovals.toList()) {
        loop.respondApproval(ev.seq, ApprovalDecision.reject);
      }
      await Future<void>.delayed(Duration.zero);
    }
    await fut;
  });
}
