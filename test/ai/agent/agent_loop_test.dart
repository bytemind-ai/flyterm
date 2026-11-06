import 'package:flutter_test/flutter_test.dart';
// ai_provider.dart 已 export ai_message.dart，不再单独引入
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

void main() {
  test('无 tool call 时一轮结束', () async {
    final p = FakeProvider([const AIResponse(text: 'all good')]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    await loop.send('status?');

    expect(loop.state, equals(AgentLoopState.done));
    expect(loop.stopReason, equals(AgentStopReason.completed));
    expect(r.ran, isEmpty);
    expect(loop.events.whereType<AssistantTextEvent>().single.text,
        equals('all good'));
  });

  test('规则放行的命令自动执行并回填', () async {
    final p = FakeProvider([
      bashCall('c1', 'systemctl status nginx'),
      const AIResponse(text: 'nginx is down'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    await loop.send('why 502?');

    expect(r.ran, equals(['systemctl status nginx']));
    expect(loop.stopReason, equals(AgentStopReason.completed));
    final tool = loop.events.whereType<ToolCallEvent>().single;
    expect(tool.status, equals(ToolCallStatus.done));
    expect(tool.output, contains('ok'));
    // 第二轮请求里应带上 tool 结果
    expect(p.seen.last.any((m) => m.role == 'tool'), isTrue);
  });

  test('未匹配规则的命令停在等审批', () async {
    final p = FakeProvider([bashCall('c1', 'systemctl restart nginx')]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    final future = loop.send('fix it');
    await Future.delayed(Duration.zero);

    expect(loop.state, equals(AgentLoopState.awaitingApproval));
    expect(r.ran, isEmpty);
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.awaitingApproval));
    expect(ev.check.canRemember, isTrue);
    expect(ev.check.suggestedRule, equals('systemctl restart *'));

    loop.respondApproval(ev.seq, ApprovalDecision.allowOnce);
    await future;

    expect(r.ran, equals(['systemctl restart nginx']));
  });

  test('批准并记住会生成规则', () async {
    final added = <PermissionRule>[];
    final p = FakeProvider([bashCall('c1', 'systemctl restart nginx')]);
    final loop = makeLoop(provider: p, added: added);

    final future = loop.send('fix');
    await Future.delayed(Duration.zero);
    loop.respondApproval(loop.pendingApprovals.single.seq,
        ApprovalDecision.allowOnce,
        rememberRule: 'systemctl restart *');
    await future;

    expect(added.single.pattern, equals('systemctl restart *'));
    expect(added.single.builtin, isFalse);
  });

  test('拒绝时命令不执行，回填一条 rejected 结果', () async {
    final p = FakeProvider([
      bashCall('c1', 'rm -rf /data'),
      const AIResponse(text: 'understood'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    final future = loop.send('clean up');
    await Future.delayed(Duration.zero);
    loop.respondApproval(loop.pendingApprovals.single.seq,
        ApprovalDecision.reject);
    await future;

    expect(r.ran, isEmpty);
    expect(loop.events.whereType<ToolCallEvent>().single.status,
        equals(ToolCallStatus.rejected));
    final toolMsg = p.seen.last.firstWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.single.isError, isTrue);
    expect(toolMsg.toolResults!.single.content, contains('rejected'));
  });

  test('同一 seq 重复应答被幂等丢弃', () async {
    final p = FakeProvider([bashCall('c1', 'systemctl restart nginx')]);
    final loop = makeLoop(provider: p);

    final future = loop.send('fix');
    await Future.delayed(Duration.zero);
    final seq = loop.pendingApprovals.single.seq;
    loop.respondApproval(seq, ApprovalDecision.allowOnce);
    // 第二次（例如用户在通知和面板上都点了）不应抛异常
    loop.respondApproval(seq, ApprovalDecision.reject);
    await future;

    expect(loop.stopReason, isNot(equals(AgentStopReason.error)));
  });

  test('bypass 模式下未匹配规则也直接跑', () async {
    final p = FakeProvider([
      bashCall('c1', 'rm -rf /tmp/build'),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r, mode: PermissionMode.bypass);

    await loop.send('clean');

    expect(r.ran, equals(['rm -rf /tmp/build']));
  });

  test('bypass 模式下 deny 仍然弹审批', () async {
    final p = FakeProvider([bashCall('c1', 'cat ~/.ssh/id_rsa')]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r, mode: PermissionMode.bypass);

    final future = loop.send('show key');
    await Future.delayed(Duration.zero);

    expect(loop.state, equals(AgentLoopState.awaitingApproval));
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.check.denyHit, isTrue);
    expect(ev.check.canRemember, isFalse);

    loop.respondApproval(ev.seq, ApprovalDecision.reject);
    await future;
  });

  test('轮数上限会停下并给出原因', () async {
    final p = FakeProvider(
        List.generate(10, (i) => bashCall('c$i', 'ls /tmp')));
    final loop = makeLoop(provider: p, maxTurns: 3);

    await loop.send('loop forever');

    expect(loop.stopReason, equals(AgentStopReason.maxTurns));
    expect(loop.events.whereType<ToolCallEvent>().length, equals(3));
  });

  test('中断后立即停止', () async {
    final p = FakeProvider(
        List.generate(10, (i) => bashCall('c$i', 'ls /tmp')));
    final loop = makeLoop(provider: p);

    final future = loop.send('go');
    await Future.delayed(Duration.zero);
    loop.cancel();
    await future;

    expect(loop.stopReason, equals(AgentStopReason.userCancelled));
    expect(loop.state, equals(AgentLoopState.cancelled));
  });

  test('非法 tool args 回填 isError 且 loop 不中断', () async {
    final p = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'bash', args: {'description': 'no command'})
      ]),
      const AIResponse(text: 'sorry, fixed'),
    ]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    expect(loop.stopReason, equals(AgentStopReason.completed));
    final toolMsg = p.seen.last.firstWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.single.isError, isTrue);
    expect(toolMsg.toolResults!.single.content, contains('command'));
  });

  test('连续 3 次非法 args 后中止', () async {
    const bad = AIResponse(toolCalls: [
      ToolCall(id: 'c1', name: 'bash', args: {})
    ]);
    final p = FakeProvider([bad, bad, bad, bad]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    expect(loop.stopReason, equals(AgentStopReason.invalidArgs));
  });

  test('未知工具名回填错误而不是崩溃', () async {
    final p = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'k8s_get', args: {'resource': 'pods'})
      ]),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    final toolMsg = p.seen.last.firstWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.single.isError, isTrue);
    expect(toolMsg.toolResults!.single.content, contains('k8s_get'));
  });

  test('read_file 转成 sed 命令执行', () async {
    final p = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'read_file', args: {
          'path': '/etc/nginx/nginx.conf',
          'offset': 10,
          'limit': 5,
        })
      ]),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    await loop.send('read it');

    expect(r.ran.single, equals("sed -n '10,14p' -- '/etc/nginx/nginx.conf'"));
  });

  // 回归测试：`_asPositiveInt` 一度只认 `num`，于是字符串数字静默退化成默认
  // 值——不报错、不提示，模型以为自己从第 10 行读，实际读的是第 1 行。
  //
  // 这不是假想的输入：模型自己会给 `"10"`，中间的 OpenAI 兼容代理也常把数字
  // 序列化成字符串（`tool_models.dart` 的 `asTokenCount` 上方为同一件事写过
  // 一段说明）。
  test('read_file 的 offset/limit 吃字符串数字，不静默退化成默认值', () async {
    final p = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'read_file', args: {
          'path': '/etc/hosts',
          'offset': '10',
          'limit': '5',
        })
      ]),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    await loop.send('read it');

    // 退化的话会是 offset=1 / limit=200 → "sed -n '1,200p'"
    expect(r.ran.single, equals("sed -n '10,14p' -- '/etc/hosts'"));
  });

  test('read_file 的 offset 给 10.0 这种浮点也认', () async {
    final p = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'read_file', args: {
          'path': '/etc/hosts',
          'offset': 10.0,
          'limit': 5,
        })
      ]),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    await loop.send('read it');

    expect(r.ran.single, equals("sed -n '10,14p' -- '/etc/hosts'"));
  });

  test('read_file 的 deny 路径照常拦截', () async {
    final p = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'read_file', args: {'path': '/root/.ssh/id_rsa'})
      ])
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    final future = loop.send('read key');
    await Future.delayed(Duration.zero);

    expect(loop.events.whereType<ToolCallEvent>().single.check.denyHit, isTrue);
    loop.respondApproval(
        loop.pendingApprovals.single.seq, ApprovalDecision.reject);
    await future;
    expect(r.ran, isEmpty);
  });

  test('上下文超预算时丢最早的工具输出，保留推理文本', () async {
    final big = 'x' * 4000;
    final p = FakeProvider([
      bashCall('c1', 'ls /a'),
      bashCall('c2', 'ls /b'),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner(
        result: CommandOutput(stdout: big, stderr: '', exitCode: 0));
    // tokenBudget 设得很小，强制在第一轮回填后就触发丢弃
    final loop = AgentLoop(
      providerProvider: () => p,
      runnerProvider: (_) => r,
      rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
      modeProvider: () => PermissionMode.ask,
      onRuleAdded: (_) {},
      systemPromptProvider: (_) => 'test',
      toolSpecsProvider: () => leanToolSpecs,
      tokenBudget: 2000,
    );

    await loop.send('go');

    // 最后一次请求里，最早那条 tool 结果已被替换成丢弃标记
    final toolMsgs =
        p.seen.last.where((m) => m.role == 'tool').toList();
    expect(toolMsgs.first.toolResults!.single.content,
        contains('output dropped'));
    // assistant 的推理文本一条都没丢
    expect(p.seen.last.where((m) => m.role == 'assistant').length,
        greaterThanOrEqualTo(1));
  });

  test('context_length_exceeded 时先丢上下文再重试一次', () async {
    // 第一轮先产生工具输出，第二轮才抛 —— 否则没有可丢的东西，重试没意义。
    final p = FakeProvider([
      bashCall('c1', 'ls /tmp'),
      Exception('400: context_length_exceeded'),
      const AIResponse(text: 'recovered'),
    ]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    expect(p.seen.length, equals(3)); // 第一轮 + 抛的那次 + 重试
    expect(loop.stopReason, equals(AgentStopReason.completed));
    // 重试时最早的工具输出已被丢弃
    final toolMsg = p.seen.last.firstWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.single.content, contains('output dropped'));
  });

  test('没有可丢的输出时不重试，直接失败', () async {
    final p = FakeProvider([Exception('400: context_length_exceeded')]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    expect(p.seen.length, equals(1));
    expect(loop.stopReason, equals(AgentStopReason.error));
  });

  test('非上下文类错误不重试，直接失败', () async {
    final p = FakeProvider([
      bashCall('c1', 'ls /tmp'),
      Exception('401: API Key 无效'),
      const AIResponse(text: 'never reached'),
    ]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    expect(p.seen.length, equals(2)); // 没有第三次
    expect(loop.stopReason, equals(AgentStopReason.error));
    expect(loop.errorMessage, contains('401'));
  });

  test('dispose 时挂起的审批被唤醒 —— loop 不能卡死', () async {
    // _executeOne 卡在 await completer.future 上。若 dispose 不 complete 它，
    // _run() 永远回不来，这条 loop 连同它持有的历史都回收不掉，
    // 而用户以为会话已经关了。
    final p = FakeProvider([bashCall('c1', 'systemctl restart nginx')]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    final future = loop.send('fix');
    await Future.delayed(Duration.zero);
    expect(loop.state, equals(AgentLoopState.awaitingApproval));

    loop.dispose();

    // 关键：这里不能超时
    await future.timeout(const Duration(seconds: 2),
        onTimeout: () => fail('dispose 之后 _run() 没有返回，loop 卡死了'));
    expect(r.ran, isEmpty);
  });

  test('token 估算把命令本身算进去', () async {
    final p = FakeProvider([
      bashCall('c1', 'ls /tmp'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: p);
    await loop.send('go');

    // 历史里既有 assistant 的 toolCalls 也有 tool 的 results。
    // 估算若只数 content，长命令完全不占预算 —— 正好在最该停下时不停。
    final withArgs = loop.debugEstimateTokens();
    expect(withArgs, greaterThan(0));
  });

  test('终止横幅不累积', () async {
    final p = FakeProvider(
        List.generate(20, (i) => bashCall('c$i', 'ls /tmp')));
    final loop = makeLoop(provider: p, maxTurns: 2);

    await loop.send('go');
    expect(loop.events.whereType<StoppedEvent>().length, equals(1));

    // 用户点「继续」再跑一轮，仍然只该有一条终止横幅
    await loop.send('continue');
    expect(loop.events.whereType<StoppedEvent>().length, equals(1));
  });

  test('dispose 可以安全地调用两次', () async {
    // cancel() 与 respondApproval() 都做了重复调用安全，dispose 也必须 ——
    // 它恰恰是 Flutter 里最容易被调两次的那个（widget 销毁竞态、
    // Provider 自动 dispose、错误处理路径）。
    final p = FakeProvider([const AIResponse(text: 'done')]);
    final loop = makeLoop(provider: p);
    await loop.send('go');

    loop.dispose();
    expect(loop.dispose, returnsNormally);
  });

  test('overflow 只重试一次 —— 第二次直接失败', () async {
    // 只放一次 overflow 的脚本区分不了「重试一次」和「无限重试」。
    // 这里连着抛两次，且历史里有两条可丢的工具输出。
    final p = FakeProvider([
      bashCall('c1', 'ls /a'),
      bashCall('c2', 'ls /b'),
      Exception('400: context_length_exceeded'),
      Exception('400: context_length_exceeded'),
      const AIResponse(text: 'never reached'),
    ]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    expect(loop.stopReason, equals(AgentStopReason.error));
    // 两轮工具 + 第一次抛 + 重试（再抛）= 4 次 provider 调用，没有第五次
    expect(p.seen.length, equals(4));
  });

  test('token 估算确实把命令算进去了 —— 不是靠别的内容凑出的正数', () async {
    final short = FakeProvider([
      bashCall('c1', 'ls'),
      const AIResponse(text: 'done'),
    ]);
    final loopShort = makeLoop(provider: short);
    await loopShort.send('go');

    final long = FakeProvider([
      bashCall('c1', 'ls ${'x' * 4000}'),
      const AIResponse(text: 'done'),
    ]);
    final loopLong = makeLoop(provider: long);
    await loopLong.send('go');

    // 两边除了命令长度外完全一样。若估算漏掉 toolCalls，两个数会相等。
    expect(loopLong.debugEstimateTokens(),
        greaterThan(loopShort.debugEstimateTokens() + 500));
  });

  test('跨轮重复的 callId 不会产生重复的事件 key', () async {
    // Ollama 不返回 id，我们按下标合成 ollama_call_0，每轮从头计数。
    // UI 拿 callId 做 Flutter widget key 会撞车，所以事件另带 seq。
    final p = FakeProvider([
      bashCall('ollama_call_0', 'ls /a'),
      bashCall('ollama_call_0', 'ls /b'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: p);

    await loop.send('go');

    final evs = loop.events.whereType<ToolCallEvent>().toList();
    expect(evs.length, equals(2));
    expect(evs[0].callId, equals(evs[1].callId));
    expect(evs[0].seq, isNot(equals(evs[1].seq)));
  });

  test('一轮内多个 tool call 串行执行并合并回填', () async {
    final p = FakeProvider([
      const AIResponse(toolCalls: [
        ToolCall(id: 'c1', name: 'bash', args: {'command': 'df -h', 'description': 'disk'}),
        ToolCall(id: 'c2', name: 'bash', args: {'command': 'free -h', 'description': 'mem'}),
      ]),
      const AIResponse(text: 'both fine'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(provider: p, runner: r);

    await loop.send('check');

    expect(r.ran, equals(['df -h', 'free -h']));
    final toolMsg = p.seen.last.firstWhere((m) => m.role == 'tool');
    expect(toolMsg.toolResults!.length, equals(2));
  });

  test('累计 usage 跨轮相加', () async {
    final loop = makeLoop(
      provider: FakeProvider(
        [
          const AIResponse(
            text: '',
            toolCalls: [
              ToolCall(id: 'c1', name: 'bash', args: {'command': 'uptime'})
            ],
            usage: TokenUsage(inputTokens: 100, cachedTokens: 900),
          ),
          const AIResponse(
            text: 'done',
            usage: TokenUsage(inputTokens: 50, cachedTokens: 1200),
          ),
        ],
      ),
    );
    await loop.send('check');

    expect(loop.totalUsage.inputTokens, equals(150));
    expect(loop.totalUsage.cachedTokens, equals(2100));
  });

  test('未声明的工具名被拒，不执行', () async {
    var ran = 0;
    final loop = makeLoop(
      toolSpecs: () => leanToolSpecs, // lean 档：没有 write_file
      runner: FakeRunner(onRun: (_) => ran++),
      provider: FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'write_file', args: {
            'path': '/etc/nginx/nginx.conf',
            'content': 'destroyed',
            'description': 'x',
          })
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');

    expect(ran, equals(0),
        reason: 'lean 档下 write_file 的实现是存在的、只是没声明给模型；'
            '少了这道闸门，幻觉调用会真的写文件');
    final results = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .toList();
    expect(results.single.isError, isTrue);
    expect(results.single.content, contains('Unknown tool'));
    // 错误消息里要列出**当前档**的工具，不能列全部
    expect(results.single.content, contains('bash'));
    expect(results.single.content.contains('edit_file'), isFalse);
  });

  // `set_plan` 的执行逻辑由 agent_set_plan_test.dart 完整覆盖。这里只保留「full 档下声明过的工具能过闸门，不被当成幻觉」
  // 这一件事：闸门放行之后走到了真正的执行逻辑，成功回填，不再是
  // hallucination 措辞的 `Unknown tool`。
  test('full 档下声明过的工具能过闸门（不被当成幻觉）', () async {
    final loop = makeLoop(
      toolSpecs: () => fullToolSpecs,
      provider: FakeProvider([
        const AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'set_plan', args: {'steps': ['a', 'b']})
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final results = loop.debugHistory
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .toList();
    // 闸门已放行 —— 走到了 `_executeSetPlan`，而不是被拦在 `_executeOne` 开头。
    expect(results.single.content, isNot(contains('Unknown tool')));
    expect(results.single.isError, isFalse);
  });

  test('发给 provider 的工具清单来自闭包，每轮现取', () async {
    final seen = <int>[];
    var tier = AgentToolTier.lean;
    final loop = makeLoop(
      toolSpecs: () => agentToolSpecsFor(tier),
      provider: FakeProvider(
        onCall: (tools) {
          seen.add(tools.length);
          tier = AgentToolTier.full; // 第一轮之后用户改了档
        },
        [
          const AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'bash', args: {
              'command': 'uptime',
              'description': 'x',
            })
          ]),
          const AIResponse(text: 'ok'),
        ],
      ),
    );
    await loop.send('go');
    // 这条断言的重点是「换档立刻生效」，具体工具数只是观测手段，不是意图
    // 本身——直接从 agentToolSpecsFor 现算期望值，而不是写死数字，这样
    // full/lean 档合法扩张（比如加新工具）时不用回来改这条断言。
    // （当前实际值：lean 3 个，full 13 个——12 个老工具 + save_skill；
    // hasSkills 用默认值 false，所以不含 load_skill。）
    expect(
      seen,
      equals([
        agentToolSpecsFor(AgentToolTier.lean).length,
        agentToolSpecsFor(AgentToolTier.full).length,
      ]),
      reason: '换档不该要求重建 loop，与 provider/rules/cwd 的现取风格一致',
    );
  });

  group('system prompt 每轮现取', () {
    test('改了自定义说明，下一轮就带上新的——不必清空对话', () async {
      // 这是用户报的 bug 的回归：systemPrompt 曾是构造时的 final String，
      // 而 loop 由 AgentSessionManager 长期持有、关面板都不销毁。于是改完
      // 说明后唯一的生效办法是点「清空对话」，那会把整段排查历史一起丢掉。
      var prompt = 'v1';
      final p = FakeProvider([
        bashCall('c1', 'systemctl status nginx'),
        const AIResponse(text: 'done'),
      ]);
      final loop = AgentLoop(
        providerProvider: () => p,
        runnerProvider: (_) => FakeRunner(),
        rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
        modeProvider: () => PermissionMode.ask,
        toolSpecsProvider: () => leanToolSpecs,
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => prompt,
        cwdProvider: () => '/tmp',
      );

      await loop.send('why 502?');
      // 第一轮用的是 v1
      expect(p.seen.first.first.content, equals('v1'));

      // 用户去设置里改了说明
      prompt = 'v2';
      await loop.send('and now?');

      // 同一个 loop、没有重建，新一轮已经用上 v2
      expect(p.seen.last.first.role, equals('system'));
      expect(p.seen.last.first.content, equals('v2'));
    });

    test('内容没变时不动 _history[0]——prompt cache 不该被无谓打断', () async {
      // 每轮现取但值不变时，system 消息必须保持原样。缓存看的是内容，
      // 所以这一条本身不影响命中；断言它是为了让「我们不是每轮重建 prompt」
      // 这个意图有测试兜着。
      final p = FakeProvider([
        bashCall('c1', 'systemctl status nginx'),
        bashCall('c2', 'systemctl status nginx'),
        const AIResponse(text: 'done'),
      ]);
      final loop = AgentLoop(
        providerProvider: () => p,
        runnerProvider: (_) => FakeRunner(),
        rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
        modeProvider: () => PermissionMode.ask,
        toolSpecsProvider: () => leanToolSpecs,
        onRuleAdded: (_) {},
        systemPromptProvider: (_) => 'stable',
        cwdProvider: () => '/tmp',
      );

      await loop.send('why 502?');

      // 每一轮送出去的第一条都得是同样那句
      for (final round in p.seen) {
        expect(round.first.role, equals('system'));
        expect(round.first.content, equals('stable'));
      }
    });
  });
}
