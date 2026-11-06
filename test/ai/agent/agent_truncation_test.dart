import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';

void main() {
  test('TruncatedEvent 归档 round-trip', () {
    final ev = TruncatedEvent(42);
    final back =
        agentEventsFromJson([agentEventToJson(ev)]).single as TruncatedEvent;
    expect(back.droppedEvents, equals(42));
  });

  test('第二次截断累加同一条，不出现两条', () {
    final loop = _bareLoop();

    // 塞满到刚好超出上限
    for (var i = 0; i < AgentLoop.debugMaxEvents + 3; i++) {
      loop.debugAddEvent(AssistantTextEvent('e$i'));
    }
    loop.debugTrimEvents();

    final first = loop.events.whereType<TruncatedEvent>().toList();
    expect(first.length, equals(1));
    expect(first.single.droppedEvents, equals(3));
    expect(loop.events.first, isA<TruncatedEvent>(),
        reason: '它代表「这之前还有」，必须在时间线最前面');

    // 再塞 5 条再裁一次
    for (var i = 0; i < 5; i++) {
      loop.debugAddEvent(AssistantTextEvent('x$i'));
    }
    loop.debugTrimEvents();

    final second = loop.events.whereType<TruncatedEvent>().toList();
    expect(second.length, equals(1), reason: '不该出现第二条');
    expect(second.single.droppedEvents, equals(8));
  });

  test('TruncatedEvent 自己不占事件配额', () {
    final loop = _bareLoop();
    for (var i = 0; i < AgentLoop.debugMaxEvents + 1; i++) {
      loop.debugAddEvent(AssistantTextEvent('e$i'));
    }
    loop.debugTrimEvents();

    // 内容条数应当恰好等于上限，TruncatedEvent 额外挂在头上
    final content =
        loop.events.where((e) => e is! TruncatedEvent).length;
    expect(content, equals(AgentLoop.debugMaxEvents));
    expect(loop.events.length, equals(AgentLoop.debugMaxEvents + 1));
  });

  test('没超上限时不插入 TruncatedEvent', () {
    final loop = _bareLoop();
    loop.debugAddEvent(AssistantTextEvent('only one'));
    loop.debugTrimEvents();
    expect(loop.events.whereType<TruncatedEvent>(), isEmpty);
  });
}

/// 一个不跑任何请求的 loop —— 这些测试只关心事件列表的裁剪。
AgentLoop _bareLoop() => AgentLoop(
      providerProvider: () => throw StateError('not used'),
      runnerProvider: (_) => throw StateError('not used'),
      rulesProvider: () => throw StateError('not used'),
      modeProvider: () => throw StateError('not used'),
      onRuleAdded: (_) {},
      systemPromptProvider: (_) => 'test',
      toolSpecsProvider: () => const [],
    );
