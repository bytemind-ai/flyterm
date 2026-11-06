import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import 'eval_harness.dart';
import '../ai/agent/_fakes.dart' show FakeProvider;

void main() {
  // rootBundle 读 assets/builtin_skills/ 需要它 —— 没有的话
  // `BuiltinSkillManager.load()` 会静默加载不到任何技能，而 runScenario
  // 现在会为此抛 StateError（见那里的注释）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapRunner', () {
    test('按命令返回预设输出', () async {
      final r = MapRunner({'systemctl status nginx': 'Active: inactive (dead)'});
      final out = await r.run('systemctl status nginx');
      expect(out.stdout, 'Active: inactive (dead)');
      expect(out.exitCode, 0);
    });

    test('子串匹配 —— 模型不会逐字复现预设的命令', () async {
      final r = MapRunner({'systemctl status nginx': 'inactive'});
      final out = await r.run('systemctl status nginx --no-pager 2>&1');
      expect(out.stdout, 'inactive',
          reason: '模型总会加 --no-pager 之类，精确匹配会全部落空');
    });

    // 未预设的命令返回空输出而不是 command not found：后者会把模型带进
    // 一条与被测行为无关的错误恢复路径。
    test('未预设的命令返回空输出 + exit 0，并记录下来', () async {
      final r = MapRunner({});
      final out = await r.run('uname -a');
      expect(out.stdout, isEmpty);
      expect(out.exitCode, 0);
      expect(r.unmatched, contains('uname -a'));
    });

    test('执行过的命令按顺序记录', () async {
      final r = MapRunner({});
      await r.run('one');
      await r.run('two');
      expect(r.ran, ['one', 'two']);
    });
  });

  group('extractToolCalls', () {
    test('从历史里按顺序提取 assistant 的工具调用', () {
      final history = [
        const AIMessage(role: 'system', content: 'sys'),
        const AIMessage(role: 'user', content: 'nginx 挂了'),
        const AIMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'a', name: 'load_skill', args: {'name': 'troubleshoot'}),
        ]),
        const AIMessage(role: 'tool', content: ''),
        const AIMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'b', name: 'bash', args: {'command': 'df'}),
        ]),
      ];
      final calls = extractToolCalls(history);
      expect(calls.map((c) => c.name), ['load_skill', 'bash']);
      expect(calls.first.args['name'], 'troubleshoot');
    });

    test('一条 assistant 消息里的并行调用全部保留且保序', () {
      final history = [
        const AIMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'a', name: 'bash', args: {'command': 'one'}),
          ToolCall(id: 'b', name: 'bash', args: {'command': 'two'}),
        ]),
      ];
      expect(extractToolCalls(history), hasLength(2));
    });

    test('没有工具调用时返回空', () {
      expect(extractToolCalls([const AIMessage(role: 'user', content: 'hi')]),
          isEmpty);
    });
  });

  group('打分', () {
    test('3 次全中 → 3/3，通过', () {
      const s = ScenarioResult(name: 'x', runs: [true, true, true],
          model: 'm', transcripts: []);
      expect(s.hits, 3);
      expect(s.total, 3);
      expect(s.passed(threshold: 2), isTrue);
      expect(s.score, '3/3');
    });

    test('2/3 通过但分数如实记录 —— 退化的早期征兆不能被藏起来', () {
      const s = ScenarioResult(name: 'x', runs: [true, false, true],
          model: 'm', transcripts: []);
      expect(s.passed(threshold: 2), isTrue);
      expect(s.score, '2/3');
    });

    test('1/3 不通过', () {
      const s = ScenarioResult(name: 'x', runs: [true, false, false],
          model: 'm', transcripts: []);
      expect(s.passed(threshold: 2), isFalse);
    });

    test('报告里带模型名 —— 跨时间比分数必须知道用的哪个模型', () {
      const s = ScenarioResult(name: 'x', runs: [true],
          model: 'claude-haiku-4-5', transcripts: []);
      expect(s.format(threshold: 1), contains('claude-haiku-4-5'));
    });

    test('失败时报告里带上实际的调用序列', () {
      const s = ScenarioResult(
        name: 'x',
        runs: [false],
        model: 'm',
        transcripts: [['bash', 'bash']],
      );
      final out = s.format(threshold: 1);
      expect(out, contains('bash'));
    });

    test('全中时不打印序列 —— 报告要短', () {
      const s = ScenarioResult(name: 'x', runs: [true], model: 'm',
          transcripts: [['load_skill']]);
      expect(s.format(threshold: 1), isNot(contains('load_skill')));
    });
  });

  group('runScenario（用 FakeProvider，不花钱）', () {
    test('跑完一次会话，提取出工具调用序列', () async {
      final result = await runScenario(
        name: '排障触发',
        userMessage: 'nginx 挂了',
        commandOutputs: const {'systemctl status nginx': 'inactive'},
        verdict: (calls) => true,
        provider: () => FakeProvider([
          const AIResponse(toolCalls: [
            ToolCall(
                id: 'a', name: 'load_skill', args: {'name': 'troubleshoot'}),
          ]),
          const AIResponse(toolCalls: [
            ToolCall(id: 'b', name: 'bash', args: {
              'command': 'systemctl status nginx',
            }),
          ]),
          const AIResponse(text: 'done'),
        ]),
        model: 'fake-model',
        times: 1,
      );
      expect(result.transcripts.first, ['load_skill', 'bash']);
    });

    test('判据命中时 runs 记 true', () async {
      final result = await runScenario(
        name: 'x',
        userMessage: '看下磁盘',
        commandOutputs: const {},
        verdict: (calls) => calls.any((c) => c.name == 'bash'),
        provider: () => FakeProvider([
          const AIResponse(toolCalls: [
            ToolCall(id: 'a', name: 'bash', args: {'command': 'df'}),
          ]),
          const AIResponse(text: 'done'),
        ]),
        model: 'fake-model',
        times: 1,
      );
      expect(result.runs, [true]);
    });

    test('超过 maxTurns 判失败，且序列仍然被记录下来', () async {
      // FakeProvider 永远返回工具调用，不收尾。
      final result = await runScenario(
        name: 'x',
        userMessage: '一直查下去',
        commandOutputs: const {},
        verdict: (calls) => false,
        provider: () => FakeProvider(List.generate(
          10,
          (i) => AIResponse(toolCalls: [
            ToolCall(id: '$i', name: 'bash', args: const {'command': 'df'}),
          ]),
        )),
        model: 'fake-model',
        times: 1,
        maxTurns: 3,
      );
      expect(result.runs, [false]);
      expect(result.transcripts.first, isNotEmpty);
    });

    test('跑 3 次得到 3 条记录', () async {
      final result = await runScenario(
        name: 'x',
        userMessage: 'hi',
        commandOutputs: const {},
        verdict: (calls) => true,
        provider: () => FakeProvider(const [AIResponse(text: 'done')]),
        model: 'fake-model',
        times: 3,
      );
      expect(result.total, 3);
    });
  });

  // ## 这一组是一个真实 bug 的护栏
  //
  // `runScenario` 早先写的是 `systemPromptProvider: (_) => 'eval prompt'`
  // —— 一个硬编码占位串。模型于是看不到技能索引、看不到那条「有一点可能
  // 适用就先 load」的铁律，四个场景测的都是「空 prompt 下模型会不会碰巧调
  // load_skill」，与生产行为毫无关系。
  //
  // 而 `FakeProvider` 按脚本返回、根本不读 prompt —— 当时 17 条单测全绿。
  // 这一组把「prompt 是真实组装的」这件事本身钉住。
  group('system prompt 是真实组装的', () {
    Future<ScenarioResult> run({Set<String> disabled = const {}}) =>
        runScenario(
          name: 'x',
          userMessage: 'hi',
          commandOutputs: const {},
          verdict: (calls) => true,
          provider: () => FakeProvider(const [AIResponse(text: 'done')]),
          model: 'fake-model',
          times: 1,
          disabledBuiltinSkills: disabled,
        );

    test('内置技能索引在 prompt 里', () async {
      final r = await run();
      expect(r.systemPrompt, contains('troubleshoot'));
      expect(r.systemPrompt, contains('plan-change'));
    });

    // 铁律是内置技能能不能被触发的关键 —— 没有它，模型看到索引也不会优先
    // 去 load。
    test('那条铁律也在', () async {
      final r = await run();
      expect(r.systemPrompt.toLowerCase(), contains('too simple'));
      expect(r.systemPrompt, contains('load_skill'));
    });

    test('禁用的技能不出现在索引里 —— 「禁用生效」场景靠这条成立', () async {
      final r = await run(disabled: {'plan-change'});
      expect(r.systemPrompt, contains('troubleshoot'));
      expect(r.systemPrompt, isNot(contains('plan-change')));
    });

    test('没有禁用时两条都在', () async {
      final r = await run();
      expect(r.systemPrompt, contains('plan-change'));
    });
  });
}
