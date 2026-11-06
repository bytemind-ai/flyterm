import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/knowledge.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

KnowledgeCandidate cand([String name = 'nginx-502']) => KnowledgeCandidate(
      target: KnowledgeTarget.skill,
      name: name,
      description: 'd',
      body: 'b',
    );

ToolCall bash(String cmd, {String id = 'c1'}) =>
    ToolCall(id: id, name: 'bash', args: {'command': cmd, 'description': 'd'});

/// 三轮 bash + 一轮收尾文本 —— 正好过门控（3 次成功调用，含实际动作）。
FakeProvider goodRun() => FakeProvider([
      AIResponse(toolCalls: [bash('echo 1', id: 'c1')]),
      AIResponse(toolCalls: [bash('echo 2', id: 'c2')]),
      AIResponse(toolCalls: [bash('echo 3', id: 'c3')]),
      const AIResponse(text: '查完了，是 upstream 挂了'),
    ]);

void main() {
  test('够格的会话收尾时出提议卡', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: goodRun(),
      knowledgeDistiller: (events) async => [cand()],
    );
    await loop.send('go');
    await Future<void>.delayed(Duration.zero);

    final ev = loop.events.whereType<KnowledgeProposalEvent>().singleOrNull;
    expect(ev, isNotNull);
    expect(ev!.candidates.single.name, equals('nginx-502'));
  });

  test('不够格的会话不调用提炼 —— 门控在花钱之前', () async {
    var called = 0;
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: FakeProvider([const AIResponse(text: '不用查，就是这样')]),
      knowledgeDistiller: (events) async {
        called++;
        return [cand()];
      },
    );
    await loop.send('go');
    await Future<void>.delayed(Duration.zero);

    expect(called, equals(0));
    expect(loop.events.whereType<KnowledgeProposalEvent>(), isEmpty);
  });

  test('提炼返回空列表时不加卡片', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: goodRun(),
      knowledgeDistiller: (events) async => const [],
    );
    await loop.send('go');
    await Future<void>.delayed(Duration.zero);
    expect(loop.events.whereType<KnowledgeProposalEvent>(), isEmpty);
  });

  test('提炼抛异常时静默 —— loop 不受影响', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: goodRun(),
      knowledgeDistiller: (events) async => throw StateError('boom'),
    );
    await loop.send('go');
    await Future<void>.delayed(Duration.zero);

    expect(loop.events.whereType<KnowledgeProposalEvent>(), isEmpty);
    expect(loop.stopReason, equals(AgentStopReason.completed));
  });

  test('没有注入 distiller 时什么都不发生', () async {
    final loop = makeLoop(mode: PermissionMode.bypass, provider: goodRun());
    await loop.send('go');
    await Future<void>.delayed(Duration.zero);
    expect(loop.events.whereType<KnowledgeProposalEvent>(), isEmpty);
  });

  test('一次会话只提议一次', () async {
    var called = 0;
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: FakeProvider([
        AIResponse(toolCalls: [bash('echo 1', id: 'c1')]),
        AIResponse(toolCalls: [bash('echo 2', id: 'c2')]),
        AIResponse(toolCalls: [bash('echo 3', id: 'c3')]),
        const AIResponse(text: '第一轮结论'),
        AIResponse(toolCalls: [bash('echo 4', id: 'c4')]),
        AIResponse(toolCalls: [bash('echo 5', id: 'c5')]),
        AIResponse(toolCalls: [bash('echo 6', id: 'c6')]),
        const AIResponse(text: '第二轮结论'),
      ]),
      knowledgeDistiller: (events) async {
        called++;
        return [cand()];
      },
    );
    await loop.send('第一个问题');
    await Future<void>.delayed(Duration.zero);
    await loop.send('第二个问题');
    await Future<void>.delayed(Duration.zero);

    expect(called, equals(1));
    expect(loop.events.whereType<KnowledgeProposalEvent>(), hasLength(1));
  });

  test('取消收场不提议', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: goodRun(),
      knowledgeDistiller: (events) async => [cand()],
    );
    final fut = loop.send('go');
    loop.cancel();
    await fut;
    await Future<void>.delayed(Duration.zero);
    expect(loop.events.whereType<KnowledgeProposalEvent>(), isEmpty);
  });

  test('stopReason 仍然是 completed，卡片不改变终态', () async {
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: goodRun(),
      knowledgeDistiller: (events) async => [cand()],
    );
    await loop.send('go');
    await Future<void>.delayed(Duration.zero);
    expect(loop.stopReason, equals(AgentStopReason.completed));
  });

  // 提炼是 unawaited 起飞的，回来时用户可能已经开始了新一轮。硬塞会让卡片
  // 插在新一轮 UserTurnEvent 后面，位置错乱。
  //
  // 代码本身（`send()` 在任何 await 之前就同步把 `_stopReason` 置 null）看着
  // 是对的，但这正是最容易被后来者悄悄改坏的一处 —— 把守卫钉死在测试里。
  test('提炼回来晚了、用户已发新消息时丢弃提议', () async {
    final gate = Completer<List<KnowledgeCandidate>>();
    final loop = makeLoop(
      mode: PermissionMode.bypass,
      provider: FakeProvider([
        AIResponse(toolCalls: [bash('echo 1', id: 'c1')]),
        AIResponse(toolCalls: [bash('echo 2', id: 'c2')]),
        AIResponse(toolCalls: [bash('echo 3', id: 'c3')]),
        const AIResponse(text: '第一轮结论'),
        const AIResponse(text: '第二轮结论'),
      ]),
      knowledgeDistiller: (events) => gate.future,
    );

    await loop.send('第一个问题');
    await Future<void>.delayed(Duration.zero);
    // 提炼还卡在 gate 上，此时用户又问了一句 —— loop 重新跑起来
    final second = loop.send('第二个问题');
    // 现在才让提炼返回
    gate.complete([cand()]);
    await second;
    await Future<void>.delayed(Duration.zero);

    expect(loop.events.whereType<KnowledgeProposalEvent>(), isEmpty,
        reason: '回来晚了就该丢弃，不能插进新一轮的事件流里');
  });

  group('resolveKnowledgeProposal', () {
    // 落盘的唯一触发点是 notify。UI 层若直接改事件对象上的可变 `resolved`，
    // 那次变化只活在内存里：进程被杀后卡片变回未处理，用户再点一次「存入」，
    // 机器笔记就被追加了第二遍同样的内容。落点虽然已经搬进手机本地
    // SQLite、不再是「写在用户真实服务器上、不可逆」，但这份笔记依然是
    // 持久资产、依然每轮塞进 system prompt、依然可能夹带凭据 —— 重复追加
    // 仍然是真实代价，只是不可逆和「在别人机器上留痕」这两条不再成立。
    test('标记已处理会触发 notify（落盘契约）', () async {
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        provider: goodRun(),
        knowledgeDistiller: (events) async => [cand()],
      );
      await loop.send('go');
      await Future<void>.delayed(Duration.zero);
      final ev = loop.events.whereType<KnowledgeProposalEvent>().single;

      var notified = 0;
      loop.addListener(() => notified++);
      loop.resolveKnowledgeProposal(ev, 0);

      expect(ev.resolved, contains(0));
      expect(notified, equals(1), reason: '不 notify 就不会落盘');
    });

    test('重复标记同一条不再 notify —— 幂等，不白写一次库', () async {
      final loop = makeLoop(
        mode: PermissionMode.bypass,
        provider: goodRun(),
        knowledgeDistiller: (events) async => [cand()],
      );
      await loop.send('go');
      await Future<void>.delayed(Duration.zero);
      final ev = loop.events.whereType<KnowledgeProposalEvent>().single;
      loop.resolveKnowledgeProposal(ev, 0);

      var notified = 0;
      loop.addListener(() => notified++);
      loop.resolveKnowledgeProposal(ev, 0);

      expect(notified, equals(0));
    });
  });
}
