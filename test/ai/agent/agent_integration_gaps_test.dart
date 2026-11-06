import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// 集成审查发现的四个跨任务缺口：单个任务各自都对，组合起来才会露馅。
/// 每组测试对应一个缺口，组内的注释解释的是「这条测试踩的是哪个真实场景」，
/// 不是重复实现里已经写过的道理。

AIResponse _startJob(String cmd) => AIResponse(toolCalls: [
      ToolCall(id: 'j1', name: 'run_background', args: {
        'command': cmd,
        'description': '装包',
      })
    ]);

AIResponse _checkJob(String jobId, {int since = 0, int wait = 30}) =>
    AIResponse(toolCalls: [
      ToolCall(id: 'c1', name: 'check_job', args: {
        'job_id': jobId,
        'since_line': since,
        'wait': wait,
      })
    ]);

void main() {
  group('F1: run_background 的回填绝不能被 _dropOldestOutput 丢掉', () {
    test('反复丢到返回 false 为止，job 已启动的回填全程原样', () {
      final loop = makeLoop(provider: FakeProvider([]), runner: FakeRunner());
      const jobContent = 'Started background job `job-1700000000000-abcd`. '
          'It is running now. Use `check_job` with a large `wait` to read '
          'its output — do not poll in a tight loop.';
      loop.debugSeedToolResult(
          const ToolResult(callId: 'a', content: 'first\noutput', exitCode: 0));
      loop.debugSeedToolResult(
          const ToolResult(callId: 'j1', content: jobContent, exitCode: 0));
      loop.debugSeedToolResult(
          const ToolResult(callId: 'b', content: 'third\noutput', exitCode: 0));

      var drops = 0;
      while (loop.debugDropOldestOutput()) {
        drops++;
        // 安全网：真出了回归，断言失败之前先别把测试跑成死循环。
        expect(drops, lessThan(10), reason: '不该无限循环丢下去');
      }

      // 三条里只有两条是普通输出，job 回填不算在「可丢」范围内。
      expect(drops, equals(2));

      final results = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .toList();
      expect(results[0].content, startsWith('[output dropped'));
      expect(results[1].content, equals(jobContent),
          reason: 'job 已启动的回填必须全程原样——它是模型找回这个任务的'
              '唯一入口，job id 不在 ToolCall.args 里');
      expect(results[1].content, contains('job-1700000000000-abcd'));
      expect(results[2].content, startsWith('[output dropped'));
    });

    test('history 里同时有 job 回填与普通命令输出：普通的被丢，job 回填原样保留', () {
      final loop = makeLoop(provider: FakeProvider([]), runner: FakeRunner());
      const jobContent = 'Started background job `job-1700000000002-cafe`. '
          'It is running now. Use `check_job` with a large `wait` to read '
          'its output — do not poll in a tight loop.';
      // job 回填是更早的一条消息——indexWhere 必须越过它去找后面那条
      // 真正可丢的，而不是被它挡在最前面误判成「没有可丢的了」。
      loop.debugSeedToolResult(
          const ToolResult(callId: 'j1', content: jobContent, exitCode: 0));
      loop.debugSeedToolResult(const ToolResult(
          callId: 'c1', content: 'ls output\nfile1\nfile2', exitCode: 0));

      expect(loop.debugDropOldestOutput(), isTrue);

      final results = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .toList();
      expect(results[0].content, equals(jobContent));
      expect(results[1].content, startsWith('[output dropped'));

      // 现在只剩 job 回填这一条候选（不可丢），必须返回 false——否则
      // _dropOldOutputsIfNeeded 的 while 会无限循环冻死 isolate。
      expect(loop.debugDropOldestOutput(), isFalse);
    });

    test('同一条消息里，job 回填不会被还没丢的普通兄弟结果连累重算', () {
      // 对照 agent_history_test.dart 里「已丢的不会被还没丢的兄弟结果连累
      // 重算」那条——这里的「已经不能动」不是因为丢过了，是因为它是 job
      // 回填。单结果消息测不出这个：一丢就整条被 indexWhere 跳过，只有
      // 多结果消息才会让 job 回填重新进 `.map`。
      final loop = makeLoop(provider: FakeProvider([]), runner: FakeRunner());
      const jobContent = 'Started background job `job-1700000000003-babe`. '
          'It is running now. Use `check_job` with a large `wait` to read '
          'its output — do not poll in a tight loop.';
      loop.debugSeedToolResults([
        const ToolResult(callId: 'j1', content: jobContent, exitCode: 0),
        const ToolResult(callId: 'pending', content: 'x\ny', exitCode: 0),
      ]);
      expect(loop.debugDropOldestOutput(), isTrue);
      final results = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .toList();
      expect(results[0].content, equals(jobContent));
      expect(results[1].content, equals('[output dropped: 2 lines, exit 0]'));
    });
  });

  group('F2: cancel() 落在流式文本中途', () {
    test('后续 chunk 不再进 streamingText，已收到的文本落成正式事件，stopReason 是 userCancelled',
        () async {
      late AgentLoop loop;
      var cancelled = false;
      final provider = FakeProvider(
        [],
        streamScript: [
          <AgentChunk>[
            const TextDelta('Hello'),
            const TextDelta(', world'),
            const TextDelta('! more text that must never arrive'),
            const StreamDone(AIResponse(
                text: 'Hello, world! more text that must never arrive')),
          ],
        ],
      );
      loop = makeLoop(provider: provider, runner: FakeRunner());

      // 用监听器而不是赌延迟：第一个 TextDelta 落地、streamingText 变成
      // 'Hello' 的那一刻同步触发 cancel()，精确命中「流到一半」这个窗口，
      // 不依赖 FakeProvider 里那 1ms 的 chunk 间延迟够不够长。
      loop.addListener(() {
        if (!cancelled && loop.streamingText == 'Hello') {
          cancelled = true;
          loop.cancel();
        }
      });

      await loop.send('go').timeout(const Duration(seconds: 5),
          onTimeout: () => fail('取消落在流式文本中途时 loop 卡死了'));

      // (a) 后续 chunk 不再进 streamingText——取消之后不该还挂着一段
      // 「正在转」的半截话。
      expect(loop.streamingText, isNull);

      // (c) 已经流出去的文本必须原样落成正式事件，后续 chunk 不能追加
      // 进去、也不能被静默丢掉。
      final texts = loop.events.whereType<AssistantTextEvent>().toList();
      expect(texts, hasLength(1));
      expect(texts.single.text, equals('Hello'));
      expect(
          loop.events
              .whereType<AssistantTextEvent>()
              .any((e) => e.text.contains('must never arrive')),
          isFalse);

      // (b) stopReason 必须是 userCancelled，不是 completed——后者会让
      // `_StoppedBanner` 渲染成 SizedBox.shrink()，用户看不到任何取消提示。
      expect(loop.stopReason, equals(AgentStopReason.userCancelled));
    });
  });

  group('F3: _executeRound 单调用快路径也要认 cancel', () {
    // 这里没有走 send()/cancel() 的公开流程，而是用 debugExecuteRoundAfterCancel
    // 直接驱动。原因见该方法上的长注释：F2 的修复（await-for 循环体首行
    // break + 循环后、done == null 判断之前的取消检查）已经把「取消发生
    // 在拿到完整模型响应之前或期间」这条路堵死了——一旦 _cancelRequested
    // 在流结束前的任意检查点变成 true，_run() 会在进 _executeRound 之前
    // 就直接返回，根本不会走到这条快路径。而从「循环后检查通过」到
    // 「调用 _executeRound」之间是一段没有 await 的同步代码，外部的
    // cancel() 不可能插进去。也就是说，在真实的 send()/cancel() 驱动流程
    // 里，这条竞态已经不可复现了（F2 修复的良性副作用）；但 _executeRound
    // 自己的这道检查依然是必要的防御，要独立验证它本身的正确性，只能
    // 像这样直接驱动。
    test('单个 run_background 调用，cancel 已经落地时这条调用不会被派发', () async {
      final runner = FakeRunner();
      final loop = makeLoop(
        provider: FakeProvider([]),
        runner: runner,
        toolSpecs: () => fullToolSpecs,
      );

      const call = ToolCall(id: 'j1', name: 'run_background', args: {
        'command': 'apt upgrade -y',
        'description': '升级',
      });
      final results = await loop.debugExecuteRoundAfterCancel([call]);

      // (a) 一条命令都不该被发出去。
      expect(runner.ran, isEmpty);
      // (b) 没有任务卡产出——任务压根没起来。
      expect(loop.events.whereType<BackgroundJobEvent>(), isEmpty);

      // (c) results.length 必须仍等于 calls.length（这里是 1），否则这条
      // 历史在下一次请求时会被服务端 400 拒掉。
      expect(results, hasLength(1));
      expect(results.single.isError, isTrue);
      expect(
          results.single.content,
          equals('Not executed: the session was cancelled before this '
              'tool ran.'),
          reason: '文案要跟多调用兜底路径的措辞完全一致');
    });
  });

  group('F7: check_job 的阻塞轮询要能被 cancel 打断', () {
    test('轮询期间 cancel：不必等满 90 秒，返回的结果说明 job 仍在远端跑', () async {
      // 阶段一：起一个 job，拿到 job id 之后把 loop 归档，模拟「关掉面板
      // 再打开」——check_job 是在一条新 loop 上发生的，跟 agent_background_test
      // 里 check_job 的既有测试用同一个套路。
      final startRunner = FakeRunner();
      final p1 = FakeProvider([
        _startJob('apt upgrade -y'),
        const AIResponse(text: 'started'),
      ]);
      final loop1 = makeLoop(
        provider: p1,
        runner: startRunner,
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs,
      );
      await loop1.send('go');
      final jobId = loop1.events.whereType<BackgroundJobEvent>().single.jobId;
      final archive = loop1.toArchive();

      // 阶段二：check_job。轮询命令一被 runner.run() 收到就立刻 cancel——
      // 这精确命中「已经发起了那次最长可阻塞 90 秒的远端调用，但还没等到
      // 结果」这个窗口，不依赖真的等一段时间（那样要么测试跑 90 秒，要么
      // 靠运气赌时序）。
      late AgentLoop loop2;
      final pollRunner = FakeRunner(onRun: (_) => loop2.cancel());
      final p2 = FakeProvider([
        _checkJob(jobId, wait: 45),
        const AIResponse(text: 'done'),
      ]);
      loop2 = makeLoop(
        provider: p2,
        runner: pollRunner,
        mode: PermissionMode.bypass,
        toolSpecs: () => fullToolSpecs,
        restoreFrom: archive,
      );

      final sw = Stopwatch()..start();
      await loop2.send('看看进度').timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                fail('取消没能打断 check_job 的阻塞轮询——90 秒的等待没被唤醒'),
          );
      sw.stop();

      // (a) 远早于 kJobPollTimeout（90 秒）。用 fake runner + Stopwatch 而
      // 不是真的等 90 秒，2 秒的阈值留了足够余量给 CI 机器的抖动。
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));

      // (b) 结果要标 isError，且措辞说明「job 本身还在远端跑，只是这次
      // 工具调用被打断了」——不能让模型误以为任务已经停止。
      final toolMsg = loop2.debugHistory.lastWhere((m) => m.role == 'tool');
      expect(toolMsg.toolResults, hasLength(1));
      expect(toolMsg.toolResults!.single.isError, isTrue);
      final content = toolMsg.toolResults!.single.content.toLowerCase();
      expect(content, contains('cancelled'));
      expect(content, contains('still running'));

      // (c) stopReason 必须是 userCancelled。
      expect(loop2.stopReason, equals(AgentStopReason.userCancelled));
    });
  });
}
