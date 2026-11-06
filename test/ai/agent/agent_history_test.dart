import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

class _NullProvider extends AIProvider {
  @override
  String get displayName => 'null';
  @override
  String get providerType => 'null';
  @override
  Future<String> complete(List<AIMessage> m) async => '';
}

class _NullRunner implements CommandRunner {
  @override
  Future<CommandOutput> run(String command,
          {String? cwd,
          Duration? timeout,
          bool denoise = false,
          int? maxBytes,

          TruncateMode truncate = TruncateMode.head}) async =>
      const CommandOutput(stdout: '', stderr: '', exitCode: 0);
  @override
  Future<void> dispose() async {}
}

AgentLoop _idleLoop() => AgentLoop(
      providerProvider: () => _NullProvider(),
      runnerProvider: (_) => _NullRunner(),
      rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
      modeProvider: () => PermissionMode.ask,
      onRuleAdded: (_) {},
      systemPromptProvider: (_) => 'p',
      toolSpecsProvider: () => leanToolSpecs,
    );

void main() {
  group('事件序列化', () {
    test('用户与助手文本往返', () {
      final events = <AgentEvent>[
        UserTurnEvent('why 502?'),
        AssistantTextEvent('checking'),
      ];
      final back = agentEventsFromJson(
          events.map(agentEventToJson).toList());
      expect(back.length, equals(2));
      expect((back[0] as UserTurnEvent).text, equals('why 502?'));
      expect((back[1] as AssistantTextEvent).text, equals('checking'));
    });

    test('工具卡往返保留命令、输出与退出码', () {
      final ev = ToolCallEvent(
        seq: 7,
        callId: 'c1',
        toolName: 'bash',
        displayCommand: 'systemctl status nginx',
        description: 'check',
        check: const CheckResult(decision: ToolDecision.allow),
        status: ToolCallStatus.done,
      )
        ..output = 'active'
        ..exitCode = 0;

      final back = agentEventsFromJson([agentEventToJson(ev)]).single
          as ToolCallEvent;
      expect(back.displayCommand, equals('systemctl status nginx'));
      expect(back.output, equals('active'));
      expect(back.exitCode, equals(0));
      expect(back.status, equals(ToolCallStatus.done));
    });

    test('superseded 能存进 JSON 再恢复', () {
      final ev = ToolCallEvent(
        seq: 9,
        callId: 'c1',
        toolName: 'bash',
        displayCommand: 'systemctl status nginx',
        description: 'check',
        check: const CheckResult(decision: ToolDecision.allow),
        status: ToolCallStatus.done,
      )..superseded = true;

      final json = agentEventToJson(ev);
      final back =
          agentEventsFromJson([json]).single as ToolCallEvent;
      expect(back.superseded, isTrue);

      final ev2 = ToolCallEvent(
        seq: 10,
        callId: 'c2',
        toolName: 'bash',
        displayCommand: 'ls',
        description: 'list',
        check: const CheckResult(decision: ToolDecision.allow),
        status: ToolCallStatus.done,
      );
      final json2 = agentEventToJson(ev2);
      // 与 undone 一致的省略约定：false 值不进 JSON，省字节。
      expect((json2 as Map)['superseded'], isNull);
      final back2 =
          agentEventsFromJson([json2]).single as ToolCallEvent;
      expect(back2.superseded, isFalse);
    });

    test('等审批的卡片恢复成已拒绝 —— 不留悬挂卡片', () {
      final ev = ToolCallEvent(
        seq: 8,
        callId: 'c1',
        toolName: 'bash',
        displayCommand: 'rm -rf /tmp/x',
        description: 'clean',
        check: const CheckResult(decision: ToolDecision.needApproval),
        status: ToolCallStatus.awaitingApproval,
      );

      final back = agentEventsFromJson([agentEventToJson(ev)]).single
          as ToolCallEvent;
      expect(back.status, equals(ToolCallStatus.rejected));
    });

    test('停止事件往返', () {
      final back =
          agentEventsFromJson([agentEventToJson(StoppedEvent(AgentStopReason.maxTurns))])
              .single as StoppedEvent;
      expect(back.reason, equals(AgentStopReason.maxTurns));
    });

    test('未知事件类型被跳过而不是抛异常', () {
      final back = agentEventsFromJson([
        {'t': 'something_from_the_future'},
        {'t': 'user', 'text': 'ok'},
      ]);
      expect(back.length, equals(1));
    });
  });

  group('AgentLoop 存档往返', () {
    test('恢复后事件与对话历史都在', () {
      final loop = _idleLoop();
      // 直接构造一份存档，模拟上次会话
      final archive = {
        'events': [
          agentEventToJson(UserTurnEvent('why 502?')),
          agentEventToJson(AssistantTextEvent('nginx was down')),
        ],
        'history': [
          {'role': 'user', 'content': 'why 502?'},
          {'role': 'assistant', 'content': 'nginx was down'},
        ],
      };

      final restored = AgentLoop(
        providerProvider: loop.providerProvider,
        runnerProvider: loop.runnerProvider,
        rulesProvider: loop.rulesProvider,
        modeProvider: loop.modeProvider,
        onRuleAdded: loop.onRuleAdded,
        systemPromptProvider: (_) => 'NEW prompt',
        toolSpecsProvider: () => leanToolSpecs,
        restoreFrom: archive,
      );

      // 事件流结尾是 AssistantTextEvent —— 不是任何终态事件，`_restoreTerminalState`
      // 据此判定上次是被硬杀的，追加一条 SessionInterruptedEvent（见
      // agent_resume_test.dart 的「事件流结尾非终态」用例）。
      expect(restored.events.length, equals(3));
      expect(restored.events.last, isA<SessionInterruptedEvent>());
      expect(restored.state, equals(AgentLoopState.idle));
      // system prompt 用**新的** —— cwd 与终端内容已经变了
      expect(restored.debugHistory.first.role, equals('system'));
      expect(restored.debugHistory.first.content, equals('NEW prompt'));
      expect(restored.debugHistory.length, equals(3));
    });

    test('恢复后新分配的 seq 接着最大恢复 seq 走，不与旧事件相撞', () async {
      // 第一段会话：一条自动放行的 bash 命令，产生一个 seq=0 的
      // ToolCallEvent。
      final p1 = FakeProvider([
        bashCall('c1', 'uptime'),
        const AIResponse(text: 'up 3 days'),
      ]);
      final loop1 = makeLoop(provider: p1);
      await loop1.send('status?');
      final firstSeq =
          loop1.events.whereType<ToolCallEvent>().single.seq;
      final archive = loop1.toArchive();

      // 恢复，再跑一轮新的 bash 命令。若 `_nextSeq` 没有接着恢复的最大值
      // 往下走（构造时的初值是 0），这里分配出来的 seq 会和上面那条
      // 恢复进来的 seq 撞在一起——两个不同的 ToolCallEvent 共享同一个
      // seq，UI 拿它当 ValueKey 用，正是 seq 本身要杜绝的那类问题。
      final p2 = FakeProvider([
        bashCall('c2', 'df -h'),
        const AIResponse(text: 'disk ok'),
      ]);
      final loop2 = makeLoop(provider: p2, restoreFrom: archive);
      await loop2.send('more');

      final allSeqs =
          loop2.events.whereType<ToolCallEvent>().map((e) => e.seq).toList();
      expect(allSeqs.length, equals(2), reason: '一条恢复的 + 一条新的');
      expect(allSeqs.toSet().length, equals(2),
          reason: 'seq 不能在恢复前后重复');
      expect(allSeqs.first, equals(firstSeq),
          reason: '恢复进来的那条事件应保留它原来的 seq');
      expect(allSeqs.last, greaterThan(firstSeq),
          reason: '新分配的 seq 必须接着恢复的最大值往下走');
    });

    test('损坏的存档不崩，退化成空会话', () {
      final loop = _idleLoop();
      final restored = AgentLoop(
        providerProvider: loop.providerProvider,
        runnerProvider: loop.runnerProvider,
        rulesProvider: loop.rulesProvider,
        modeProvider: loop.modeProvider,
        onRuleAdded: loop.onRuleAdded,
        systemPromptProvider: (_) => 'p',
        toolSpecsProvider: () => leanToolSpecs,
        restoreFrom: const {'events': 'not a list'},
      );
      expect(restored.events, isEmpty);
      expect(restored.debugHistory.length, equals(1));
    });
  });

  group('丢弃 marker', () {
    test('带行数与退出码', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
        const ToolResult(
            callId: 'c1', content: 'a\nb\nc', exitCode: 0),
      );
      expect(loop.debugDropOldestOutput(), isTrue);

      final dropped = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .single;
      expect(dropped.content, equals('[output dropped: 3 lines, exit 0]'));
    });

    test('失败的命令保留非零退出码', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
        const ToolResult(callId: 'c1', content: 'boom', exitCode: 1),
      );
      loop.debugDropOldestOutput();
      final dropped = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .single;
      expect(dropped.content, contains('exit 1'));
    });

    test('没有退出码时只写行数', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
        const ToolResult(
            callId: 'c1', content: 'User rejected this command.',
            isError: true),
      );
      loop.debugDropOldestOutput();
      final dropped = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .single;
      expect(dropped.content, equals('[output dropped: 1 lines]'));
    });

    // 这条是本任务的安全网。marker 变成动态字符串之后，等值比较会让同一条
    // 消息被无限重复丢弃 —— 函数永远返回 true，调用方的 while 循环永远
    // 退不出去，同步霸占 isolate（在 app 里就是 UI 线程冻死）。
    test('已丢弃的不会被再丢一次', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
        const ToolResult(callId: 'c1', content: 'x\ny', exitCode: 0),
      );
      expect(loop.debugDropOldestOutput(), isTrue);
      expect(loop.debugDropOldestOutput(), isFalse,
          reason: '第二次必须返回 false，否则 _dropOldOutputsIfNeeded 的 '
              'while 会无限循环并冻死 isolate');
    });

    test('多条时按时间顺序逐条丢', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
          const ToolResult(callId: 'c1', content: 'first', exitCode: 0));
      loop.debugSeedToolResult(
          const ToolResult(callId: 'c2', content: 'second', exitCode: 0));

      expect(loop.debugDropOldestOutput(), isTrue);
      final results = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .toList();
      expect(results[0].content, startsWith('[output dropped'));
      expect(results[1].content, equals('second'));

      expect(loop.debugDropOldestOutput(), isTrue);
      expect(loop.debugDropOldestOutput(), isFalse);
    });

    test('空内容的行数算成 0', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
        const ToolResult(callId: 'c1', content: '', exitCode: 0),
      );
      loop.debugDropOldestOutput();
      final dropped = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .single;
      expect(dropped.content, equals('[output dropped: 0 lines, exit 0]'));
    });

    // SshCommandRunner 超时时把 exitCode 设成 -1 —— 那是「没有真实退出码」
    // 的哨兵值（POSIX 退出码范围是 0-255），不是任何进程真的会返回的数字。
    // marker 里不能出现 `exit -1`：模型没有「负数退出码 = 异常终止」的
    // 先验，容易当成解析错误或直接忽略。超时又是排查场景里的高频失败
    // 模式，值得单独标出来。
    test('超时的命令写 timed out，不写 exit -1', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
        const ToolResult(
            callId: 'c1',
            content: '[timeout after 20s]\npartial output',
            exitCode: -1,
            timedOut: true),
      );
      loop.debugDropOldestOutput();
      final dropped = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .single;
      expect(dropped.content, equals('[output dropped: 2 lines, timed out]'));
      expect(dropped.content, isNot(contains('exit -1')));
    });

    // exitCode == -1 但 timedOut == false：命令跑完了但拿不到真实退出码
    // （同一个哨兵值的另一种成因）。同样不能写 `exit -1`。
    test('拿不到退出码（非超时）时写 no exit code，不写 exit -1', () {
      final loop = _idleLoop();
      loop.debugSeedToolResult(
        const ToolResult(callId: 'c1', content: 'weird', exitCode: -1),
      );
      loop.debugDropOldestOutput();
      final dropped = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .single;
      expect(
          dropped.content, equals('[output dropped: 1 lines, no exit code]'));
      expect(dropped.content, isNot(contains('exit -1')));
    });

    // 安全网：一条消息里可能同时有「已丢过」和「还没丢」的 ToolResult ——
    // 一轮并行工具调用产生的真实形状。单结果消息一丢就整条被 indexWhere
    // 跳过，测不出「已丢的会不会被连累重算」；必须用多结果消息才能让已丢
    // 的那条重新进入 `.map`。规格明确警告过：如果不保留原样，一条 47 行
    // 的输出被连累重算会变成 `[output dropped: 1 lines]`（marker 自身只有
    // 一行），元信息反而丢了。
    test('同一条消息里，已丢的结果不会被还没丢的兄弟结果连累重算', () {
      final loop = _idleLoop();
      loop.debugSeedToolResults([
        const ToolResult(
            callId: 'already',
            content: '[output dropped: 47 lines, exit 0]',
            exitCode: 0),
        const ToolResult(callId: 'pending', content: 'x\ny', exitCode: 0),
      ]);
      expect(loop.debugDropOldestOutput(), isTrue);
      final results = loop.debugHistory
          .expand((m) => m.toolResults ?? const <ToolResult>[])
          .toList();
      // 已丢的那条必须原样保留 —— 不能因为混进 .map 而被按自己的 marker
      // 文本重新计算行数。
      expect(results[0].content, equals('[output dropped: 47 lines, exit 0]'));
      // 还没丢的那条正常被丢弃。
      expect(results[1].content, equals('[output dropped: 2 lines, exit 0]'));
    });
  });
}
