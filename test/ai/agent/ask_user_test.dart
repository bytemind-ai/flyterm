import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ai/agent/ask_option.dart';
import 'package:flyterm/ai/agent/agent_prompt.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import '_fakes.dart';

void main() {
  test('ask_user 在 full 与 lean 两档都声明', () {
    for (final tier in AgentToolTier.values) {
      final names = agentToolSpecsFor(tier).map((s) => s.name).toList();
      expect(names, contains('ask_user'),
          reason: '小模型同样会遇到分叉，且它更需要问而不是猜');
    }
  });

  test('ToolCallEvent 能带选项，且挂起态归档成 rejected、不存 askOptions', () {
    final ev = ToolCallEvent(
      seq: 1,
      callId: 'c1',
      toolName: 'ask_user',
      displayCommand: 'ask: 改哪个实例？',
      description: '',
      check: const CheckResult(decision: ToolDecision.allow),
      askOptions: const [
        AskOption(label: '3306'),
        AskOption(label: '3307', description: '灰度实例'),
      ],
    )..status = ToolCallStatus.awaitingApproval;

    expect(ev.askOptions, hasLength(2));
    expect(ev.askOptions![1].description, '灰度实例');

    // 归档侧的既有行为：awaitingApproval 存成 rejected（「留个悬挂的审批
    // 按钮只会骗用户点」）。恢复出来的卡片不该有可点按钮，所以 askOptions
    // 也不进归档。
    final json = agentEventToJson(ev);
    expect(json['status'], ToolCallStatus.rejected.name);
    expect(json.containsKey('askOptions'), isFalse);
  });

  ToolCall askCall(String id, List<Map<String, Object?>> opts,
          {String q = '改哪个实例？'}) =>
      ToolCall(id: id, name: 'ask_user', args: {
        'question': q,
        'options': opts,
      });

  /// 等挂起真的建立起来。带上限，避免实现有问题时死循环。
  Future<void> waitAwaiting(AgentLoop loop) async {
    for (var i = 0; i < 2000; i++) {
      if (loop.state == AgentLoopState.awaitingAnswer) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('挂起状态始终没有建立（state=${loop.state}）');
  }

  test('header 进 description，超 12 字符截断', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'ask_user', args: const {
            'question': '改哪个实例？',
            // 13 个字符：原串比 kMaxAskHeaderChars(12) 多一个，
            // 才能真的触发截断（否则 12 字符的串正好卡在边界上，不会被切）。
            'header': '这是一个非常长的分类标签啊',
            'options': [
              {'label': '3306'},
              {'label': '3307'},
            ],
          }),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final done = loop.send('go');
    await waitAwaiting(loop);

    final ev = loop.events.whereType<ToolCallEvent>().last;
    expect(ev.description.length, kMaxAskHeaderChars,
        reason: '超长要在 executor 侧截断');
    expect(ev.description, '这是一个非常长的分类标签');

    loop.respondAnswer(ev.seq, '3306');
    await done;
  });

  test('header 缺失时 description 是空串，不是 "null"', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          askCall('c1', [
            {'label': 'a'},
            {'label': 'b'},
          ]),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final done = loop.send('go');
    await waitAwaiting(loop);

    final ev = loop.events.whereType<ToolCallEvent>().last;
    expect(ev.description, isEmpty);

    loop.respondAnswer(ev.seq, 'a');
    await done;
  });

  test('挂起 → 应答 → 答案进 tool_result，loop 继续', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          askCall('c1', [
            {'label': '3306'},
            {'label': '3307'},
          ]),
        ]),
        const AIResponse(text: '好，改 3306'),
      ]),
    );

    final done = loop.send('帮我改端口');
    await waitAwaiting(loop);

    final ev = loop.events.whereType<ToolCallEvent>().last;
    expect(ev.toolName, 'ask_user');
    expect(ev.askOptions, hasLength(2));

    loop.respondAnswer(ev.seq, '3306');
    await done;

    final results = loop.debugHistory
        .where((m) => m.role == 'tool')
        .expand((m) => m.toolResults ?? const <ToolResult>[]);
    expect(results.any((r) => r.content == '3306'), isTrue,
        reason: '答案要作为 tool_result 回给模型');
  });

  test(
      '同轮 ask_user + 两条需审批 bash：批次聚合卡不含 ask_user，'
      'ask_user 仍照常挂起等答案', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          // 两条不在 defaultAllowRules 里的命令，凑够聚合门槛
          // （`needApproval.length > 1`），与 batch_approval_test.dart
          // 里「一轮两个非传输的需审批命令仍然聚合」用的是同一对命令。
          ToolCall(id: 'b1', name: 'bash', args: {
            'command': 'systemctl restart nginx',
            'description': '重启 nginx',
          }),
          ToolCall(id: 'b2', name: 'bash', args: {
            'command': 'systemctl restart php-fpm',
            'description': '重启 php-fpm',
          }),
          askCall('ask1', [
            {'label': 'a'},
            {'label': 'b'},
          ]),
        ]),
        const AIResponse(text: 'done'),
      ]),
      mode: PermissionMode.readOnly,
    );

    final done = loop.send('重启两个服务，另外问一下');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // 断言 1：聚合卡只装两条 bash，不含 ask_user —— 否则它会被错当成
    // 「需要用户确认的操作」聚合进卡片，而它已经在自己的执行路径里挂起
    // 等答案了，这张卡永远不会有人来点（agent_loop.dart 里
    // `if (c.name == 'ask_user') continue;` 那段守卫）。
    final batches = loop.events.whereType<BatchApprovalEvent>().toList();
    expect(batches.length, 1);
    expect(batches.single.calls, hasLength(2));
    expect(batches.single.calls.every((c) => c.name == 'bash'), isTrue,
        reason: 'ask_user 不该混进这张卡');

    // 批准这两条 bash，serial 桶继续往下跑到 ask_user，它应该正常挂起。
    await loop.approveBatch();
    await waitAwaiting(loop);

    // 断言 2：ask_user 挂起之后仍能正常应答，答案照常进 tool_result ——
    // 证明「排除出聚合卡」没有连带破坏它自己的挂起/应答路径。
    final askEv = loop.events
        .whereType<ToolCallEvent>()
        .lastWhere((e) => e.toolName == 'ask_user');
    loop.respondAnswer(askEv.seq, 'a');
    await done;

    final results = loop.debugHistory
        .where((m) => m.role == 'tool')
        .expand((m) => m.toolResults ?? const <ToolResult>[]);
    expect(results.any((r) => r.content == 'a'), isTrue,
        reason: '答案要作为 tool_result 回给模型');
  });

  test('cancel() 能叫醒挂起的提问 —— 否则 loop 永久挂起、整段历史泄漏',
      () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          askCall('c1', [
            {'label': 'a'},
            {'label': 'b'},
          ]),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final done = loop.send('go');
    await waitAwaiting(loop);
    loop.cancel();
    await done.timeout(const Duration(seconds: 5));
    expect(loop.state, isNot(AgentLoopState.awaitingAnswer));
  });

  test('dispose() 同样能叫醒 —— 它和 cancel 是两条独立的路', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          askCall('c1', [
            {'label': 'a'},
            {'label': 'b'},
          ]),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final done = loop.send('go');
    await waitAwaiting(loop);
    loop.dispose();
    await done.timeout(const Duration(seconds: 5));
  });

  test('同轮第二次提问返回 isError，不静默丢弃', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          askCall('c1', [
            {'label': 'a'},
            {'label': 'b'},
          ]),
          askCall('c2', [
            {'label': 'x'},
            {'label': 'y'},
          ]),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final done = loop.send('go');
    await waitAwaiting(loop);
    final first = loop.events.whereType<ToolCallEvent>().first;
    loop.respondAnswer(first.seq, 'a');
    await done;

    final results = loop.debugHistory
        .where((m) => m.role == 'tool')
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .toList();
    expect(results.any((r) => r.callId == 'c2' && r.isError), isTrue,
        reason: '第二次要回 isError 让模型看到约束，而不是静默丢弃');
  });

  test('同一 seq 第二次应答静默丢弃，不抛异常', () async {
    final loop = makeLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          askCall('c1', [
            {'label': 'a'},
            {'label': 'b'},
          ]),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    final done = loop.send('go');
    await waitAwaiting(loop);
    final ev = loop.events.whereType<ToolCallEvent>().last;
    loop.respondAnswer(ev.seq, 'a');
    // 用户可能在通知和面板上各点一次。
    loop.respondAnswer(ev.seq, 'b');
    await done;
    final results = loop.debugHistory
        .where((m) => m.role == 'tool')
        .expand((m) => m.toolResults ?? const <ToolResult>[])
        .where((r) => r.callId == 'c1');
    expect(results, hasLength(1));
  });

  test('不在选项里的答案带 free-form 后缀，在选项里的不带', () async {
    Future<String> answerWith(String answer) async {
      final loop = makeLoop(
        provider: FakeProvider([
          AIResponse(toolCalls: [
            askCall('c1', [
              {'label': '3306'},
              {'label': '3307'},
            ]),
          ]),
          const AIResponse(text: 'done'),
        ]),
      );
      final done = loop.send('go');
      await waitAwaiting(loop);
      final ev = loop.events.whereType<ToolCallEvent>().last;
      loop.respondAnswer(ev.seq, answer);
      await done;
      return loop.debugHistory
          .where((m) => m.role == 'tool')
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .first
          .content;
    }

    expect(await answerWith('3306'), '3306');
    expect(
      await answerWith('3308，新加的'),
      '3308，新加的\n\n(free-form answer, not one of the offered options)',
    );
  });

  // 下面两条是 formatAskAnswerContent / truncateAskHeader 的纯函数单测：
  // 字符串拼接、截断的边界不需要装配一整轮 loop 才能测——道理与
  // ask_option_test.dart 里 parseAskOptions 的单测一致。跑完整 loop 的
  // 端到端用例只留一条（见上面「不在选项里的答案带 free-form 后缀」），
  // 它证明的是接线正确，与这里的格式正确是两件事。

  test('formatAskAnswerContent：截断说明与 free-form 后缀同时出现时，顺序与空行都对',
      () {
    // 5 个选项，超过 kMaxAskOptions(4)，parseAskOptions 会截到 4 项并
    // 带上 note；3308 不在截断后的选项 label 里，所以还要带 free-form 后缀。
    final parsed = parseAskOptions([
      {'label': 'a'},
      {'label': 'b'},
      {'label': 'c'},
      {'label': 'd'},
      {'label': 'e'},
    ]);

    final content = formatAskAnswerContent('3308，新加的', parsed);

    expect(
      content,
      '3308，新加的\n\n'
      '(free-form answer, not one of the offered options)\n\n'
      '(Only the first $kMaxAskOptions options were shown to the user; '
      'the rest were dropped.)',
    );
  });

  test('truncateAskHeader：截断点落在 emoji 代理对中间时不劈开代理对', () {
    // 11 个单 code unit 的字符 + 1 个占两个 code unit 的 emoji（U+1F600，
    // 代理对）+ 1 个尾字符：runes 数 13、code unit 数 14。
    //
    // 旧实现按 `.length`（14）判断超限、`substring(0, 12)` 截断——12 这个
    // 切点恰好落在 emoji 的代理对中间（前 11 个字符占 code unit 0..10，
    // emoji 占 11..12），切出来的结果末尾是一个孤立的高位代理项，
    // 渲染成乱码方块。新实现按 runes 截，第 12 个 rune 正好是完整的
    // emoji，第 13 个尾字符被丢弃——不会切碎代理对。
    const raw = 'abcdefghijk😀X';
    expect(raw.length, 14, reason: '确认测试数据本身就是 14 个 UTF-16 code unit');
    expect(raw.runes.length, 13, reason: '确认测试数据是 13 个码点');

    final result = truncateAskHeader(raw);

    expect(result, 'abcdefghijk😀', reason: '截到完整的第 12 个 rune（emoji），不切碎它');
    // 结果里没有孤立代理项：按 runes 重新拼回来应该和自己相等；孤立代理项
    // 会让 `String.fromCharCodes(result.runes)` 在往返时发生变化。
    expect(String.fromCharCodes(result.runes), result);
  });

  test('prompt 里有「先查再问」的引导与一轮一次的约束', () {
    final p = buildAgentSystemPrompt(cwd: null, terminalContext: null);
    expect(p, contains('ask_user'));
    expect(p, contains('at most once per turn'));
    expect(p, contains('never include an "Other"'),
        reason: '不加这句会出现两个「其他」：模型给的死选项 + UI 追加的输入框');
  });
}
