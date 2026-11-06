import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/background_job.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

AIResponse startJob(String cmd) => AIResponse(toolCalls: [
      ToolCall(id: 'j1', name: 'run_background', args: {
        'command': cmd,
        'description': '装包',
      })
    ]);

AIResponse checkJob(String jobId, {int since = 0, int wait = 30}) =>
    AIResponse(toolCalls: [
      ToolCall(id: 'c1', name: 'check_job', args: {
        'job_id': jobId,
        'since_line': since,
        'wait': wait,
      })
    ]);

List<ToolSpec> _full() => fullToolSpecs;

void main() {
  test('run_background 起任务后立刻返回 job id，并产出任务卡事件', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      startJob('apt upgrade -y'),
      const AIResponse(text: 'started'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full);

    await loop.send('升级一下');

    final jobs = loop.events.whereType<BackgroundJobEvent>().toList();
    expect(jobs.length, equals(1));
    expect(jobs.single.command, equals('apt upgrade -y'));
    expect(jobs.single.exitCode, isNull);

    // 回填给模型的内容必须带 job id，否则它没法 check
    final toolMsg = provider.seen[1].lastWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.single.content, contains(jobs.single.jobId));
    expect(toolMsg.toolResults!.single.isError, isFalse);

    // 起任务只发一条命令：清理与启动合成一条（省一次网络往返，见
    // `_executeRunBackground` 的注释），所以 runner 只收到一次调用。
    // 明文比较：这条命令由
    // buildJobCleanupCommand + buildJobStartCommand 拼成。
    expect(runner.ran.length, equals(1));
    expect(runner.ran[0], contains('setsid'));
    expect(runner.ran[0], contains('find')); // buildJobCleanupCommand 的清理段
  });

  test('run_background 走 checkCommand——非白名单命令要弹审批', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      startJob('apt upgrade -y'),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
        provider: provider, runner: runner, toolSpecs: _full); // 默认 ask

    final f = loop.send('q');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final card = loop.events
        .whereType<ToolCallEvent>()
        .firstWhere((e) => e.status == ToolCallStatus.awaitingApproval);
    expect(card.toolName, equals('run_background'));
    expect(card.displayCommand, equals('apt upgrade -y'));
    loop.respondApproval(card.seq, ApprovalDecision.allowOnce);
    await f;

    expect(loop.events.whereType<BackgroundJobEvent>().length, equals(1));
  });

  test('审批被拒时不起任务，也不留任务卡', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([startJob('rm -rf /data')]);
    final loop =
        makeLoop(provider: provider, runner: runner, toolSpecs: _full);

    final f = loop.send('q');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final card = loop.events
        .whereType<ToolCallEvent>()
        .firstWhere((e) => e.status == ToolCallStatus.awaitingApproval);
    loop.respondApproval(card.seq, ApprovalDecision.reject);
    await f;

    expect(loop.events.whereType<BackgroundJobEvent>(), isEmpty);
    expect(runner.ran.where((c) => c.contains('setsid')), isEmpty);
  });

  test('check_job 回填新增日志与状态，并推进游标', () async {
    // 第一条是启动，第二条是轮询
    final runner = FakeRunner(results: [
      const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      const CommandOutput(
          stdout: 'running\n2\nGet:1 http://deb.debian.org\nGet:2 ...',
          stderr: '',
          exitCode: 0),
    ]);
    final provider = FakeProvider([
      startJob('apt upgrade -y'),
      const AIResponse(text: 'waiting'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full);
    await loop.send('q');

    final jobId = loop.events.whereType<BackgroundJobEvent>().single.jobId;

    final p2 = FakeProvider([
      checkJob(jobId, wait: 45),
      const AIResponse(text: 'done'),
    ]);
    final loop2 = makeLoop(
        provider: p2,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full,
        restoreFrom: loop.toArchive());
    await loop2.send('看看进度');

    final result = p2.seen[1].lastWhere((m) => m.role == 'tool').toolResults!;
    expect(result.single.content, contains('Get:1'));
    expect(result.single.content, contains('running'));
    // 游标推进到 2，任务卡上也要记住
    expect(loop2.events.whereType<BackgroundJobEvent>().single.lineCursor,
        equals(2));

    // check_job 就是「确认」的定义。不更新的话，卡上会一直显示启动那一刻，
    // 用户看到「3 小时前确认」而其实刚查过。
    //
    // 不直接断言 greaterThan(startedAtMs)：起任务与 check_job 都在同一条
    // 测试里飞速跑完，`DateTime.now()` 两次取值完全可能落在同一毫秒，那样
    // 写会偶发抽风。改成对比「check_job 之前」与「check_job 之后」两个值—
    // 证明的是「这一趟确确实实被写过一次」，不是「隔了多久」，抓的是同一个
    // 回归（漏写这一行）却不依赖真实时间差。
    final beforeCheck =
        loop.events.whereType<BackgroundJobEvent>().single.lastCheckedAtMs;
    final jobAfterCheck = loop2.events.whereType<BackgroundJobEvent>().single;
    expect(jobAfterCheck.lastCheckedAtMs,
        greaterThanOrEqualTo(jobAfterCheck.startedAtMs));
    expect(jobAfterCheck.lastCheckedAtMs, isNot(equals(beforeCheck)));
  });

  test('job 结束时任务卡记下退出码', () async {
    final runner = FakeRunner(results: [
      const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      const CommandOutput(
          stdout: '0\n5\nSetting up nginx', stderr: '', exitCode: 0),
    ]);
    final provider = FakeProvider([
      startJob('apt install nginx'),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full);
    await loop.send('q');
    final jobId = loop.events.whereType<BackgroundJobEvent>().single.jobId;

    final p2 = FakeProvider([checkJob(jobId), const AIResponse(text: 'fin')]);
    final loop2 = makeLoop(
        provider: p2,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full,
        restoreFrom: loop.toArchive());
    await loop2.send('q');

    expect(loop2.events.whereType<BackgroundJobEvent>().single.exitCode,
        equals(0));
  });

  test('job 不存在时回明确错误，绝不回空输出让模型无限等', () async {
    final runner = FakeRunner(
        result: const CommandOutput(
            stdout: '', stderr: '', exitCode: kJobNotFoundExit));
    final provider = FakeProvider([
      checkJob('job-1700000000000-abcd'),
      const AIResponse(text: 'oops'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full);
    await loop.send('q');

    final r = provider.seen[1].lastWhere((m) => m.role == 'tool').toolResults!;
    expect(r.single.isError, isTrue);
    expect(r.single.content.toLowerCase(), contains('not found'));
  });

  test('非法 job_id 一律拒绝——路径穿越必须在拼命令之前挡住', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'x', name: 'check_job', args: {
          'job_id': '../../../etc/shadow',
        })
      ]),
      const AIResponse(text: 'no'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full);
    await loop.send('q');

    // 一条命令都不该发出去
    expect(runner.ran, isEmpty);
    final r = provider.seen[1].lastWhere((m) => m.role == 'tool').toolResults!;
    expect(r.single.isError, isTrue);
  });

  test('任务卡进归档并能恢复——否则重开面板那个 apt 就没人认领了', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      startJob('docker build .'),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full);
    await loop.send('q');

    final archive = loop.toArchive();
    final restored = makeLoop(
        provider: FakeProvider([]),
        runner: runner,
        toolSpecs: _full,
        restoreFrom: archive);

    final job = restored.events.whereType<BackgroundJobEvent>().single;
    expect(job.command, equals('docker build .'));
    expect(job.jobId, isNotEmpty);
    expect(job.startedAtMs, greaterThan(0));
  });

  test('killJob 发的是负号 pid，并把卡标成已终止', () async {
    final runner = FakeRunner();
    final provider = FakeProvider([
      startJob('sleep 3600'),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
        provider: provider,
        runner: runner,
        mode: PermissionMode.bypass,
        toolSpecs: _full);
    await loop.send('q');
    final job = loop.events.whereType<BackgroundJobEvent>().single;

    final ok = await loop.killJob(job.jobId);

    expect(ok, isTrue);
    expect(job.killed, isTrue);
    expect(runner.ran.last, contains('kill -TERM -'));
  });
}
