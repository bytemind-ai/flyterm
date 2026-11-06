import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

AIResponse _one(ToolCall c) => AIResponse(toolCalls: [c]);

/// 停在审批卡上的 `send()` 不会返回，测试不能 await 它。
///
/// 用完必须 `await settle(loop)` 收尾，否则 `cancel()` 之后那条 Future 还在
/// 事件循环里，测试框架会报「pending timer」。
void startSend(AgentLoop loop, String text) => unawaited(loop.send(text));

Future<void> settle(AgentLoop loop) async {
  loop.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

/// 等到 [cond] 成立，或超时。
///
/// **不要用固定 `Future.delayed` 去等一件异步的事发生。** 那是一场赛跑，
/// 而且输了不报错、只是让断言看到一个「还没发生」的中间状态。超时后
/// 这里也不抛 —— 让随后的 `expect` 去报错，那条消息比 TimeoutException
/// 有用得多。
Future<void> waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('需审批的 bash：ToolCallReady 一到就预热当前会话那台', () async {
    final warmed = <String?>[];
    // `rm -rf` 不在默认放行清单里 —— 一定需要审批，也就一定不可抢跑。
    final call = ToolCall(id: 'a', name: 'bash', args: {
      'command': 'rm -rf /tmp/x',
      'description': '删掉临时目录',
    });

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      prewarmProvider: (id) async => warmed.add(id),
    );

    // 不等 send 完成 —— 它会停在审批卡上。
    startSend(loop, '删一下');
    await waitUntil(() => warmed.isNotEmpty);

    expect(warmed, [null], reason: 'null = 当前会话那台');
    await settle(loop);
  });

  test('local 桶工具不触发预热', () async {
    final warmed = <String?>[];
    final call = ToolCall(id: 'a', name: 'set_plan', args: {
      'steps': ['一', '二'],
    });

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      toolSpecs: () => fullToolSpecs,
      prewarmProvider: (id) async => warmed.add(id),
    );

    // 确定性等待：`set_plan` 不可能触发预热，直接把这一轮跑到底再断言，
    // 不给它套 waitUntil ——等一个永远不会成立的条件只会白等 5 秒。
    await loop.send('列个计划');

    expect(warmed, isEmpty, reason: 'set_plan 不碰 SSH，预热它是白建连接');
  });

  test('save_skill 同样不触发预热 —— 它存在手机上', () async {
    final warmed = <String?>[];
    final call = ToolCall(id: 'a', name: 'save_skill', args: {
      'name': 'nginx-check',
      'description': '查 nginx',
      'body': 'systemctl status nginx',
    });

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      // **不能用裸的 `fullToolSpecs`。** 那个常量不含 `save_skill`——它是
      // `agentToolSpecsFor(AgentToolTier.full)` 在 tier == full 时才追加的
      // 一个工具，`_executeOneInner` 开头的白名单闸门会直接把它当成模型幻觉
      // 出的未知工具名拒掉，调用连 `_executeSaveSkill`（进而审批卡）都到不了
      // ——那样一来 `warmed` 恒为空,与「不该预热」这条断言的意图无关,是一次
      // 假阳性。必须走 `agentToolSpecsFor` 才能让 `save_skill` 真的进入
      // 审批流程。
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full),
      skillSaver: (n, d, b, a) async {},
      prewarmProvider: (id) async => warmed.add(id),
    );

    // 这里断言的是「不发生」，不能直接等一个不会发生的条件。`save_skill`
    // 会停在审批卡上（用 startSend 而不是 await send），所以正确的锚点是
    // 等一件确实会发生的事——审批卡出现——然后再断言 warmed 为空。
    startSend(loop, '记下来');
    await waitUntil(() => loop.pendingApprovals.isNotEmpty);

    expect(warmed, isEmpty);
    await settle(loop);
  });

  test('可抢跑的调用不额外预热 —— 它自己的 run 已经含 obtain', () async {
    final warmed = <String?>[];
    // `ps aux` 命中默认放行清单 → 可抢跑。
    final call = ToolCall(id: 'a', name: 'bash', args: {
      'command': 'ps aux',
      'description': '看进程',
    });

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      prewarmProvider: (id) async => warmed.add(id),
    );

    // 确定性：可抢跑的调用永远不会走预热分支，跑到底直接断言。
    await loop.send('看看');

    expect(warmed, isEmpty);
  });

  test('跨机需审批调用：预热的是那台机器的 id', () async {
    final warmed = <String?>[];
    final call = ToolCall(id: 'a', name: 'bash', args: {
      'command': 'rm -rf /tmp/x',
      'description': '删',
      'server': 'web-2',
    });

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      toolSpecs: () => fullToolSpecs,
      servers: const [
        ServerListEntry(id: 'id2', name: 'web-2', host: 'h2', credsOk: true),
      ],
      prewarmProvider: (id) async => warmed.add(id),
    );

    startSend(loop, '删一下');
    await waitUntil(() => warmed.isNotEmpty);

    expect(warmed, ['id2']);
    await settle(loop);
  });

  test('download_file 也预热 —— SFTP 用的是同一条 SSHClient', () async {
    final warmed = <String?>[];
    final call = ToolCall(id: 'a', name: 'download_file', args: {
      'path': '/var/log/syslog',
      'description': '把日志拉下来',
    });

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full),
      prewarmProvider: (id) async => warmed.add(id),
    );

    startSend(loop, '拉日志');
    await waitUntil(() => warmed.isNotEmpty);

    // `sftpOpsProvider`（terminal_screen.dart:1907）拿的是同一个
    // `AgentExecChannel` 的同一条 `SSHClient`，所以预热帮得到传输类工具 ——
    // 而它们恰恰是等待窗口最长的那几个（必须审批 + 传输本身耗时）。
    expect(warmed, [null]);
    await settle(loop);
  });

  test('预热抛错不影响会话，也不产生面板错误', () async {
    final call = ToolCall(id: 'a', name: 'bash', args: {
      'command': 'rm -rf /tmp/x',
      'description': '删',
    });

    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      mode: PermissionMode.bypass, // 不弹卡，直接跑完
      prewarmProvider: (id) async => throw StateError('no creds'),
    );

    await loop.send('删一下');

    expect(loop.errorMessage, isNull,
        reason: '预热失败必须静默 —— 真正的错误由随后的 run 报出');
  });

  test('跨机 check_job 不带 server：预热的是任务归属那台，不是当前会话', () async {
    const fleet = [
      ServerListEntry(
          id: 'id-1', name: 'web-1', host: '10.0.1.11', credsOk: true),
      ServerListEntry(
          id: 'id-2', name: 'web-2', host: '10.0.1.12', credsOk: true),
    ];

    // 两段式：轮询的 ToolCall 需要真实 jobId，起任务之前拿不到它。
    final origin = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'j1', name: 'run_background', args: {
            'command': 'apt upgrade -y',
            'description': '装包',
            'server': 'web-2',
          })
        ]),
        const AIResponse(text: 'ok'),
      ]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      runnersByServerId: {'id-1': FakeRunner(), 'id-2': FakeRunner()},
    );
    await origin.send('在 web-2 上升级');
    final job = origin.events.whereType<BackgroundJobEvent>().single;
    expect(job.serverId, 'id-2', reason: '前置条件：归属确实记在事件上');

    // 模型真实行为：只带 job_id、不带 server。
    final call = ToolCall(id: 'c1', name: 'check_job', args: {
      'job_id': job.jobId,
    });
    final warmed = <String?>[];
    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      runnersByServerId: {'id-1': FakeRunner(), 'id-2': FakeRunner()},
      prewarmProvider: (id) async => warmed.add(id),
      restoreFrom: origin.toArchive(),
    );

    await loop.send('看看进度');

    // 关键断言：预热必须与 `checkJob` 的归属解析顺序一致 —— 显式 server >
    // 事件记录的归属 > 当前会话。修好之前这里收到 null（预热了当前会话那台
    // 根本不会用的连接，真正需要的那条仍是冷的）。
    expect(warmed, ['id-2'],
        reason: '预热必须打在任务真正在跑的那台机器上，与 checkJob 一致');
  });

  test('显式 server 优先于事件归属 —— 不被事件覆盖', () async {
    const fleet = [
      ServerListEntry(
          id: 'id-1', name: 'web-1', host: '10.0.1.11', credsOk: true),
      ServerListEntry(
          id: 'id-2', name: 'web-2', host: '10.0.1.12', credsOk: true),
    ];
    final origin = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'j1', name: 'run_background', args: {
            'command': 'apt upgrade -y',
            'description': '装包',
            'server': 'web-2',
          })
        ]),
        const AIResponse(text: 'ok'),
      ]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      runnersByServerId: {'id-1': FakeRunner(), 'id-2': FakeRunner()},
    );
    await origin.send('在 web-2 上升级');
    final job = origin.events.whereType<BackgroundJobEvent>().single;

    final call = ToolCall(id: 'c1', name: 'check_job', args: {
      'job_id': job.jobId,
      'server': 'web-1',
    });
    final warmed = <String?>[];
    final loop = makeLoop(
      provider: FakeProvider(
        [const AIResponse(text: 'done')],
        streamScript: [
          [ToolCallReady(call), StreamDone(_one(call))],
          [const StreamDone(AIResponse(text: 'done'))],
        ],
      ),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: fleet,
      runnersByServerId: {'id-1': FakeRunner(), 'id-2': FakeRunner()},
      prewarmProvider: (id) async => warmed.add(id),
      restoreFrom: origin.toArchive(),
    );

    await loop.send('去 web-1 上查');

    expect(warmed, ['id-1'],
        reason: '显式 server 优先级最高，事件归属只是兜底');
  });
}
