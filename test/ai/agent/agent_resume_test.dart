import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
// AIMessage 由 ai_provider.dart 转出（agent_loop.dart 顶部注释解释过：
// 直接 import ai_message.dart 会被判 unnecessary_import）。
import 'package:flyterm/ai/ai_provider.dart';

import '_fakes.dart';

void main() {
  test('归档的 history 末尾不含孤儿 toolCalls', () {
    final loop = makeLoop(provider: FakeProvider([]));

    // 造出「模型请求了工具，结果还没回来」的中间态——被杀那一刻的形状
    loop.debugSeedToolCall(
      ToolCall(id: 'c1', name: 'bash', args: {'command': 'systemctl restart nginx'}),
    );

    final history = loop.toArchive()['history'] as List;
    final last = history.isEmpty ? null : history.last as Map;

    expect(last?['toolCalls'], isNull,
        reason: '孤儿 tool_use 必须在落盘层被消灭，恢复层才不用补占位 result');

    loop.dispose();
  });

  test('配对完整的历史全部落盘', () {
    final loop = makeLoop(provider: FakeProvider([]));
    loop.debugSeedToolCall(
      ToolCall(id: 'c1', name: 'bash', args: {'command': 'df -h'}),
    );
    loop.debugSeedToolResult(const ToolResult(callId: 'c1', content: 'ok'));

    final history = loop.toArchive()['history'] as List;
    // system 不进归档，所以是 assistant + tool 两条
    expect(history, hasLength(2));
    expect((history.last as Map)['role'], 'tool');

    loop.dispose();
  });

  test('恢复出的历史可直接作为请求体（无孤儿 tool_use）', () async {
    final seed = makeLoop(provider: FakeProvider([]));
    seed.debugSeedToolCall(
      ToolCall(id: 'c1', name: 'bash', args: {'command': 'df -h'}),
    );
    final archive = seed.toArchive();
    seed.dispose();

    final provider = FakeProvider([const AIResponse(text: 'ok')]);
    final loop = makeLoop(provider: provider, restoreFrom: archive);
    await loop.send('继续');

    final sent = provider.seen.single;
    for (var i = 0; i < sent.length; i++) {
      final calls = sent[i].toolCalls;
      if (calls == null || calls.isEmpty) continue;
      expect(i + 1, lessThan(sent.length));
      expect(sent[i + 1].role, 'tool');
    }

    loop.dispose();
  });

  test('pendingInputs 往返：归档 → 恢复后仍在', () async {
    final provider = FakeProvider([
      bashCall('c1', 'sleep 1'),
      const AIResponse(text: 'done'),
    ]);
    final seed = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
    );
    final running = seed.send('查一下 nginx');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    seed.send('顺便看下 disk');
    // 在运行中归档——模拟进程被杀那一刻
    final archive = seed.toArchive();
    await running;
    seed.dispose();

    expect(archive['pendingInputs'], ['顺便看下 disk']);

    final restored = makeLoop(provider: FakeProvider([]), restoreFrom: archive);
    expect(restored.pendingInputs, ['顺便看下 disk']);
    restored.dispose();
  });

  test('缺 pendingInputs 字段的旧 archive 能正常恢复', () {
    final loop = makeLoop(
      provider: FakeProvider([]),
      restoreFrom: const {
        'events': [
          {'t': 'user', 'text': '旧会话'},
          {'t': 'stopped', 'reason': 'completed'},
        ],
        'history': [
          {'role': 'user', 'content': '旧会话'},
        ],
      },
    );

    expect(loop.pendingInputs, isEmpty);
    expect(loop.events, hasLength(2));
    loop.dispose();
  });

  test('SessionInterruptedEvent json 往返', () {
    final ev = SessionInterruptedEvent(['bash(systemctl restart nginx)']);
    final json = agentEventToJson(ev);
    expect(json['t'], 'interrupted');

    final back = agentEventsFromJson([json]).single;
    expect(back, isA<SessionInterruptedEvent>());
    expect((back as SessionInterruptedEvent).lastCalls,
        ['bash(systemctl restart nginx)']);
  });

  test('无调用名的中断事件也能往返', () {
    final json = agentEventToJson(SessionInterruptedEvent(const []));
    final back = agentEventsFromJson([json]).single;
    expect((back as SessionInterruptedEvent).lastCalls, isEmpty);
  });

  test('事件流结尾非终态 → 恢复后追加 SessionInterruptedEvent', () {
    final loop = makeLoop(
      provider: FakeProvider([]),
      restoreFrom: const {
        'events': [
          {'t': 'user', 'text': '查一下 nginx'},
          {
            't': 'tool',
            'seq': 0,
            'callId': 'c1',
            'toolName': 'bash',
            'displayCommand': 'systemctl restart nginx',
            'description': '重启',
            'status': 'running',
          },
        ],
        'history': [],
      },
    );

    expect(loop.events.last, isA<SessionInterruptedEvent>());
    expect((loop.events.last as SessionInterruptedEvent).lastCalls,
        ['bash(systemctl restart nginx)']);

    // 运行中的卡片必须收尾，否则永远转圈
    final card = loop.events.whereType<ToolCallEvent>().single;
    expect(card.status, isNot(ToolCallStatus.running));
    expect(card.output, isNotNull);

    loop.dispose();
  });

  test('事件流结尾是 StoppedEvent → 不误报中断', () {
    final loop = makeLoop(
      provider: FakeProvider([]),
      restoreFrom: const {
        'events': [
          {'t': 'user', 'text': '查一下 nginx'},
          {'t': 'stopped', 'reason': 'completed'},
        ],
        'history': [],
      },
    );

    expect(loop.events.whereType<SessionInterruptedEvent>(), isEmpty);
    expect(loop.stopReason, AgentStopReason.completed);
    loop.dispose();
  });

  test('空事件流不产生中断事件', () {
    final loop = makeLoop(
      provider: FakeProvider([]),
      restoreFrom: const {'events': <dynamic>[], 'history': <dynamic>[]},
    );
    expect(loop.events, isEmpty);
    loop.dispose();
  });

  test('buildInterruptNotice 含调用名且显式禁止两个方向的假设', () {
    final notice = buildInterruptNotice(['bash(systemctl restart nginx)']);
    expect(notice, contains('systemctl restart nginx'));
    expect(notice.toLowerCase(), contains('unknown'));
    expect(notice.toLowerCase(), contains('do not assume'));
  });

  test('无调用名时提示仍然成立', () {
    final notice = buildInterruptNotice(const []);
    expect(notice.toLowerCase(), contains('interrupted'));
    expect(notice.toLowerCase(), contains('do not assume'));
  });

  test('resume 把提示注入历史并继续跑', () async {
    final provider = FakeProvider([const AIResponse(text: '确认过了，没重启')]);
    final loop = makeLoop(
      provider: provider,
      restoreFrom: const {
        'events': [
          {'t': 'user', 'text': '重启 nginx'},
          {
            't': 'tool',
            'seq': 0,
            'callId': 'c1',
            'toolName': 'bash',
            'displayCommand': 'systemctl restart nginx',
            'description': '重启',
            'status': 'running',
          },
        ],
        'history': [
          {'role': 'user', 'content': '重启 nginx'},
        ],
      },
    );

    expect(loop.events.last, isA<SessionInterruptedEvent>());
    await loop.resume();

    expect(loop.events.whereType<SessionInterruptedEvent>(), isEmpty);
    final sent = provider.seen.single;
    expect(sent.where((m) => m.content.contains('systemctl restart nginx')),
        isNotEmpty);
    expect(loop.stopReason, AgentStopReason.completed);

    loop.dispose();
  });

  test('末尾不是中断事件时 resume 是空操作', () async {
    final provider = FakeProvider([const AIResponse(text: 'x')]);
    final loop = makeLoop(
      provider: provider,
      restoreFrom: const {
        'events': [
          {'t': 'stopped', 'reason': 'completed'},
        ],
        'history': [],
      },
    );

    await loop.resume();
    expect(provider.seen, isEmpty, reason: '没有中断可续，不该发请求');
    loop.dispose();
  });

  group('读侧也剥孤儿 tool_use', () {
    // 写侧的 `_archivableHistory` 只管住这个版本之后落的盘。旧版本的
    // 「新建会话」「打开历史段」没有 isRunning 门禁，在一轮工具执行中途点
    // 下去，落盘的 history 末尾就是没有 tool_result 配对的 assistant。
    test('旧 archive 带孤儿 toolCalls → 恢复后历史合法', () async {
      final provider = FakeProvider([const AIResponse(text: 'ok')]);
      final loop = makeLoop(
        provider: provider,
        restoreFrom: {
          'events': const [
            {'t': 'user', 'text': '重启 nginx'},
          ],
          'history': [
            {'role': 'user', 'content': '重启 nginx'},
            // 老规则写出来的孤儿：有 tool_use，后面没有 tool_result
            AIMessage(
              role: 'assistant',
              content: '',
              toolCalls: [
                ToolCall(id: 'c1', name: 'bash', args: {'command': 'x'})
              ],
            ).toJson(),
          ],
        },
      );

      await loop.send('继续');

      // 不剥的话 wire 上是 tool_use 后面跟 user 文本 → 服务端 400，
      // 而且这一段会话此后每一句都 400。
      final sent = provider.seen.single;
      for (var i = 0; i < sent.length; i++) {
        final calls = sent[i].toolCalls;
        if (calls == null || calls.isEmpty) continue;
        expect(i + 1, lessThan(sent.length),
            reason: '孤儿 tool_use 没被剥掉，这段历史会被服务端拒掉');
        expect(sent[i + 1].role, 'tool');
      }
      loop.dispose();
    });
  });

  test('中断后直接发新消息 → 横幅摘掉，不留静默死键', () async {
    final provider = FakeProvider([const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: provider,
      restoreFrom: const {
        'events': [
          {'t': 'user', 'text': '重启 nginx'},
          {
            't': 'tool',
            'seq': 0,
            'callId': 'c1',
            'toolName': 'bash',
            'displayCommand': 'systemctl restart nginx',
            'description': '重启',
            'status': 'running',
          },
        ],
        'history': [
          {'role': 'user', 'content': '重启 nginx'},
        ],
      },
    );
    expect(loop.events.last, isA<SessionInterruptedEvent>());

    // 用户没点「继续」，直接问了别的
    await loop.send('先看看 disk');

    // 不摘的话这条事件永久留在流里，永久渲染一颗可点的「继续」按钮，
    // 而 resume() 的守卫要求它必须在末尾——点下去每次都静默 early-return。
    expect(
      loop.events.whereType<SessionInterruptedEvent>(),
      isEmpty,
      reason: '发了新消息就等于放弃续跑，横幅该走',
    );
    loop.dispose();
  });

  test('_dropOldestOutput 跑过之后，落盘仍取到正确前缀', () {
    final loop = makeLoop(provider: FakeProvider([]));
    // 一轮完整的（会被 drop 换成 marker）
    loop.debugSeedToolCall(
      ToolCall(id: 'c1', name: 'bash', args: {'command': 'journalctl -n 500'}),
    );
    loop.debugSeedToolResult(
      ToolResult(callId: 'c1', content: 'x' * 4000),
    );
    // 再来一条没有结果的——被杀那一刻的形状
    loop.debugSeedToolCall(
      ToolCall(id: 'c2', name: 'bash', args: {'command': 'df -h'}),
    );

    expect(loop.debugDropOldestOutput(), isTrue);

    // 判据是现算的，所以 drop 改动 _history 之后它依然指对位置。
    // 换成维护索引水位的实现，这里就会从中间某处截断。
    final history = loop.toArchive()['history'] as List;
    expect((history.last as Map)['toolCalls'], isNull);
    expect(history, hasLength(2), reason: 'drop 不删条目，只该少掉末尾那条孤儿');

    loop.dispose();
  });

  // 下面两条防的是本功能最坏的失败模式：**每次正常重开面板都弹中断横幅**。
  //
  // 「结尾是 StoppedEvent → 不误报」那条用的是手工构造的存档，锁的是判据
  // 本身；这两条走真实链路（真跑一轮 → toArchive → restore），锁的是
  // 「判据在真实归档上也成立」。两者不能互相替代：判据对、但真实归档恰好
  // 不以终态事件收尾的话，用户每次开面板都会看到那条横幅。
  group('不误报中断', () {
    test('真实跑完一轮 → 归档 → 恢复', () async {
      final seed = makeLoop(
        provider: FakeProvider([
          bashCall('c1', 'tail error.log'),
          const AIResponse(text: '查完了'),
        ]),
        mode: PermissionMode.bypass,
        runner: FakeRunner(),
      );
      await seed.send('查一下 nginx');
      expect(seed.stopReason, AgentStopReason.completed);
      final archive = seed.toArchive();
      seed.dispose();

      final restored =
          makeLoop(provider: FakeProvider([]), restoreFrom: archive);
      expect(
        restored.events.whereType<SessionInterruptedEvent>(),
        isEmpty,
        reason: '正常跑完再重开面板绝不能弹中断横幅',
      );
      restored.dispose();
    });

    test('plan 模式提案终态 → 归档 → 恢复', () async {
      final seed = makeLoop(
        provider: FakeProvider([
          AIResponse(toolCalls: [
            ToolCall(id: 'c1', name: 'write_file', args: {
              'path': '/tmp/x.conf',
              'content': 'a',
              'description': 'w',
            })
          ]),
          const AIResponse(text: '方案就这些'),
        ]),
        mode: PermissionMode.ask,
        runner: FakeRunner(),
      );
      await seed.send('改配置');
      final archive = seed.toArchive();
      seed.dispose();

      final restored =
          makeLoop(provider: FakeProvider([]), restoreFrom: archive);
      expect(
        restored.events.whereType<SessionInterruptedEvent>(),
        isEmpty,
        // `_restoreTerminalState` 的 switch 把 PlanProposalEvent 映射为
        // completed —— 它是终态，不是硬杀。
        reason: 'PlanProposalEvent 是终态，不是硬杀',
      );
      restored.dispose();
    });
  });
}
