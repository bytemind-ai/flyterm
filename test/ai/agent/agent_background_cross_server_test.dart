import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

const _fleet = [
  ServerListEntry(
      id: 'id-1',
      name: 'web-1',
      groupName: 'prod',
      host: '10.0.1.11',
      credsOk: true),
  ServerListEntry(
      id: 'id-2',
      name: 'web-2',
      groupName: 'prod',
      host: '10.0.1.12',
      credsOk: true),
];

AIResponse backgroundCall({String? server}) => AIResponse(toolCalls: [
      ToolCall(id: 'j1', name: 'run_background', args: {
        'command': 'apt upgrade -y',
        'description': '装包',
        if (server != null) 'server': server,
      })
    ]);

AIResponse checkJobCall(String jobId, {String? server}) =>
    AIResponse(toolCalls: [
      ToolCall(id: 'c1', name: 'check_job', args: {
        'job_id': jobId,
        if (server != null) 'server': server,
      })
    ]);

AIResponse listJobsCall({String? server}) => AIResponse(toolCalls: [
      ToolCall(id: 'l1', name: 'list_jobs', args: {
        if (server != null) 'server': server,
      })
    ]);

void main() {
  test('run_background spec 带 server 参数', () {
    final spec = agentToolSpecsFor(AgentToolTier.full)
        .firstWhere((s) => s.name == 'run_background');
    final props = spec.parameters['properties'] as Map;
    expect(props.containsKey('server'), isTrue,
        reason: '跨机起后台任务是调度功能的前置能力');
  });

  test('带 server 参数时命令打到目标机器的 runner', () async {
    final p = FakeProvider([
      backgroundCall(server: 'web-2'),
      const AIResponse(text: 'ok'),
    ]);
    // 两台机器各记一条 —— 断言「哪条命令打了哪台」必须分开记，
    // 一个共享的 FakeRunner 看不出目标解析有没有生效。
    final onId1 = FakeRunner();
    final onId2 = FakeRunner();
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
    );

    await loop.send('在 web-2 上升级');

    expect(onId2.ran.length, equals(1), reason: '跨机命令该打到 id-2');
    expect(onId2.ran.single, contains('apt upgrade -y'));
    expect(onId1.ran, isEmpty, reason: '本机不该收到任何命令');
    // 跨机没有「当前目录」的概念：远端新连接起点是 HOME，与 bash/read_file 一致。
    expect(onId2.cwds.single, isNull);

    final jobs = loop.events.whereType<BackgroundJobEvent>().toList();
    expect(jobs.length, equals(1));
    expect(jobs.single.exitCode, isNull);
  });

  test('任务卡事件记住它跑在哪台机器上', () async {
    final p = FakeProvider([
      backgroundCall(server: 'web-2'),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': FakeRunner(), 'id-2': FakeRunner()},
    );

    await loop.send('在 web-2 上升级');

    final job = loop.events.whereType<BackgroundJobEvent>().single;
    // 归属必须落在事件上，不能让模型每次 check/kill 时重报 —— 它很容易
    // 漏掉 `server` 参数，一漏就会去打当前会话那台机器。
    expect(job.serverId, equals('id-2'));
    expect(job.serverName, equals('web-2'));
  });

  test('归档往返后归属不丢 —— 丢了 killJob 就退化成打当前机器', () async {
    // 前半段照搬上面的用例：起一个跨机任务，拿到真实事件。
    final p = FakeProvider([
      backgroundCall(server: 'web-2'),
      const AIResponse(text: 'ok'),
    ]);
    final origin = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': FakeRunner(), 'id-2': FakeRunner()},
    );
    await origin.send('在 web-2 上升级');
    final job = origin.events.whereType<BackgroundJobEvent>().single;

    // 走真实的归档往返：`toArchive()` 里的事件就是这两行序列化的产物，
    // 恢复时 `_restore()` 又从 `agentEventsFromJson` 读回来。直接对事件
    // 做 json round-trip 等价于这条链路（连同 pair 的拼写错误一起测）。
    final restoredEvents = agentEventsFromJson([agentEventToJson(job)]);

    // 字段值层面：归属没在往返里被丢掉。
    final restoredJob = restoredEvents.whereType<BackgroundJobEvent>().single;
    expect(restoredJob.serverId, equals('id-2'),
        reason: '归档往返丢了归属，恢复后 killJob 就找不到那台机器了');
    expect(restoredJob.serverName, equals('web-2'));

    // 后果层面 —— 这一条才是真正的防线。只比字段值的话，把 killJob 的
    // 路由改回 runnerProvider(null) 照样能过。
    final onId1 = FakeRunner();
    final onId2 = FakeRunner();
    final resumed = makeLoop(
      provider: FakeProvider([const AIResponse(text: 'ok')]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
      // 模拟从存档恢复：事件流换成往返后的那份，归属只可能来自
      // serverId 字段本身。
      restoreFrom: {'events': [agentEventToJson(restoredJob)]},
    );

    final ok = await resumed.killJob(restoredJob.jobId);

    expect(ok, isTrue);
    expect(onId2.ran.single, contains(restoredJob.jobId),
        reason: '恢复后的 kill 必须仍然打到任务真正在跑的那台机器');
    expect(onId1.ran, isEmpty,
        reason: '退化的表现是「命令成功执行了」：UI 显示已终止而任务还在烧 CPU');
    expect(onId2.cwds.single, isNull,
        reason: '跨机没有「当前目录」的概念，与 runBackground 一致');
  });

  test('killJob 打到任务所属那台机器，而不是当前会话那台', () async {
    final p = FakeProvider([
      backgroundCall(server: 'web-2'),
      const AIResponse(text: 'ok'),
    ]);
    final onId1 = FakeRunner();
    final onId2 = FakeRunner();
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
    );

    await loop.send('在 web-2 上升级');
    final job = loop.events.whereType<BackgroundJobEvent>().single;
    // 只保留 kill 那一次 —— 起任务时也打了 id-2，那是另一条命令。
    onId1.ran.clear();
    onId2.ran.clear();
    onId1.cwds.clear();
    onId2.cwds.clear();

    final ok = await loop.killJob(job.jobId);

    expect(ok, isTrue);
    expect(onId2.ran.single, contains(job.jobId),
        reason: 'kill 命令必须落到任务真正在跑的那台机器');
    expect(onId1.ran, isEmpty,
        reason: '打错机器的表现是「命令成功执行了」，UI 会显示已终止而任务还在烧 CPU');
    // 跨机没有「当前目录」的概念，与 runBackground 一致。
    expect(onId2.cwds.single, isNull);
  });

  test('check_job spec 带 server 参数', () {
    final spec = agentToolSpecsFor(AgentToolTier.full)
        .firstWhere((s) => s.name == 'check_job');
    final props = spec.parameters['properties'] as Map;
    expect(props.containsKey('server'), isTrue,
        reason: '事件里的归属只是兜底，模型仍要能显式覆盖它');
    // 与 run_background 的关键差别：这里**不能**是必填。归属已经记在任务
    // 事件上，模型不带 server 时我们要靠它自动路由；若标成必填，模型不带
    // 参数就会在进 checkJob 之前被拦下，兜底那条路等于白写。
    final required = spec.parameters['required'] as List;
    expect(required.contains('server'), isFalse,
        reason: 'check_job 的 server 必须可选，否则事件里的归属永远用不上');
  });

  test('不带 server 参数时，轮询打到任务所属那台机器', () async {
    // 两段式：轮询的 ToolCall 需要真的 jobId，而起任务之前拿不到它，
    // 所以照搬既有用例的「起任务 → 归档 → 恢复后调 check」套路。
    final onId1 = FakeRunner();
    final onId2 = FakeRunner();
    final origin = makeLoop(
      provider: FakeProvider([
        backgroundCall(server: 'web-2'),
        const AIResponse(text: 'ok'),
      ]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
    );
    await origin.send('在 web-2 上升级');
    final job = origin.events.whereType<BackgroundJobEvent>().single;

    // 起任务时已经打过 id-2 一次，清掉才能看清 check 打到了哪。
    onId1.ran.clear();
    onId2.ran.clear();
    onId1.cwds.clear();
    onId2.cwds.clear();

    final p = FakeProvider([
      checkJobCall(job.jobId),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
      restoreFrom: origin.toArchive(),
    );

    // 模型的真实行为：只带 job_id，不带 server。
    await loop.send('看看进度');

    expect(onId2.ran.single, contains(job.jobId),
        reason: '轮询必须回到任务真正在跑的那台机器');
    expect(onId1.ran, isEmpty,
        reason: '打错机器会得到「job 不存在，别再查了」，'
            '同时把还在跑的任务用 exitCode ??= -1 永久标记成已完成');
    // 跨机没有「当前目录」的概念，与 runBackground 一致。
    expect(onId2.cwds.single, isNull);
  });

  test('显式带 server 参数时优先用它（覆盖事件记录）', () async {
    final onId1 = FakeRunner();
    final onId2 = FakeRunner();
    final origin = makeLoop(
      provider: FakeProvider([
        backgroundCall(server: 'web-2'),
        const AIResponse(text: 'ok'),
      ]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
    );
    await origin.send('在 web-2 上升级');
    final job = origin.events.whereType<BackgroundJobEvent>().single;
    onId1.ran.clear();
    onId2.ran.clear();

    final loop = makeLoop(
      provider: FakeProvider([
        checkJobCall(job.jobId, server: 'web-1'),
        const AIResponse(text: 'ok'),
      ]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
      restoreFrom: origin.toArchive(),
    );

    await loop.send('去 web-1 上查');

    expect(onId1.ran.single, contains(job.jobId),
        reason: '模型显式指定时以它为准，事件记录只是兜底默认值');
    expect(onId2.ran, isEmpty);
  });

  test('check_job 给未知机器名时报错，并附上可用名字列表', () async {
    final p = FakeProvider([
      checkJobCall('job-1700000000000-abcd', server: 'nope'),
      const AIResponse(text: 'ok'),
    ]);
    final onId1 = FakeRunner();
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': FakeRunner()},
    );

    await loop.send('去 nope 上查');

    // 不给可用名单，模型会开始编造名字并连续几轮撞在同一处。
    final r = p.seen[1].lastWhere((m) => m.role == 'tool').toolResults!;
    expect(r.single.isError, isTrue);
    expect(r.single.content, contains('web-1'));
    expect(r.single.content, contains('web-2'));
    // 解析失败必须在发命令之前挡下——打错的机器上并没有这个 job。
    expect(onId1.ran, isEmpty);
  });

  test('list_jobs spec 带 server 参数，且是可选的', () {
    final spec = agentToolSpecsFor(AgentToolTier.full)
        .firstWhere((s) => s.name == 'list_jobs');
    final props = spec.parameters['properties'] as Map;
    expect(props.containsKey('server'), isTrue,
        reason: '跨机列任务要和起/查/杀一样能指定机器，否则四件套只缺一件');
    // 与 check_job 同构：list_jobs 列的是「这台机器上的所有任务」，没有单个
    // job 归属可回退，所以省略时就是当前会话那台（与 bash 一致）。把它标成
    // 必填会让模型每次都得多写一个参数，白费一轮 token 且容易写错。
    final required = spec.parameters['required'] as List? ?? const [];
    expect(required.contains('server'), isFalse,
        reason: '省略时应落到当前会话，不该拦下模型');
  });

  test('list_jobs 显式带 server 时打到那台机器', () async {
    final onId1 = FakeRunner();
    final onId2 = FakeRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        listJobsCall(server: 'web-2'),
        const AIResponse(text: 'ok'),
      ]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
    );

    await loop.send('web-2 上有哪些后台任务');

    expect(onId2.ran.length, equals(1), reason: '跨机列举该打到 id-2');
    expect(onId2.ran.single, contains('.flyterm/jobs'),
        reason: '列的得是后台任务目录，而不是别的什么');
    expect(onId1.ran, isEmpty, reason: '本机不该收到任何命令');
    // 跨机没有「当前目录」的概念：远端新连接起点是 HOME，与 bash/read_file 一致。
    expect(onId2.cwds.single, isNull);
  });

  test('list_jobs 不带 server 时打到当前会话那台', () async {
    // 这一条钉的是「与改动前一致」：list_jobs 没有事件归属可回退，省略就是
    // 当前会话，退化的表现会是列表里什么都没有，模型据此以为任务都结束了。
    final current = FakeRunner();
    final onId1 = FakeRunner();
    final onId2 = FakeRunner();
    final loop = makeLoop(
      provider: FakeProvider([
        listJobsCall(),
        const AIResponse(text: 'ok'),
      ]),
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      // 不给 null 这个 key，让默认 runner 接住「当前会话那台」。
      runner: current,
      runnersByServerId: {'id-1': onId1, 'id-2': onId2},
    );

    await loop.send('这台机器上有哪些后台任务');

    expect(current.ran.length, equals(1), reason: '省略 server 就是当前会话那台');
    expect(current.ran.single, contains('.flyterm/jobs'));
    // 本机仍要带 cwd —— runBackground/checkJob 只有跨机才传 null。
    expect(current.cwds.single, equals('/tmp'));
    expect(onId1.ran, isEmpty);
    expect(onId2.ran, isEmpty);
  });

  test('list_jobs 给未知机器名时报错，并附上可用名字列表', () async {
    final current = FakeRunner();
    final p = FakeProvider([
      listJobsCall(server: 'nope'),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      runner: current,
      toolSpecs: () => fullToolSpecs,
      servers: _fleet,
      runnersByServerId: {'id-1': FakeRunner(), 'id-2': FakeRunner()},
    );

    await loop.send('nope 上有哪些后台任务');

    // 不给可用名单，模型会开始编造名字并连续几轮撞在同一处。
    final r = p.seen[1].lastWhere((m) => m.role == 'tool').toolResults!;
    expect(r.single.isError, isTrue);
    expect(r.single.content, contains('web-1'));
    expect(r.single.content, contains('web-2'));
    // 解析失败必须在发命令之前挡下 —— 打错的机器上列出来的东西毫无意义。
    expect(current.ran, isEmpty);
  });
}
