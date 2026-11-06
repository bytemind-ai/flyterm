import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

void main() {
  test('supersededByEdit 跨归档往返', () {
    final ev = UserTurnEvent('旧问法')..supersededByEdit = true;
    final restored =
        agentEventsFromJson([agentEventToJson(ev)]).single as UserTurnEvent;
    expect(restored.text, '旧问法');
    expect(restored.supersededByEdit, isTrue);
  });

  test('没有标记的用户轮恢复后也没有标记', () {
    final restored = agentEventsFromJson([
      agentEventToJson(UserTurnEvent('普通一轮')),
    ]).single as UserTurnEvent;
    expect(restored.supersededByEdit, isFalse);
  });

  group('_history 截断边界', () {
    // 顺序刻意反常：assistant 文本排在 tool 结果之前。这是为了让「不留孤儿」
    // 这条断言真的对错误边界敏感 —— 若严格按真实顺序 call 紧邻 result，任何
    // 后缀切点（`removeRange(idx, length)`）要么把这一对整体删掉、要么整体
    // 保留，永远切不散，测不出裂开。隔一条 assistant 消息进去，才能让「按
    // assistant 搜索」这个错误边界精确落在 call 和 result 中间。
    List<AIMessage> sampleHistory() => [
          const AIMessage(role: 'system', content: 'sys'),
          const AIMessage(role: 'user', content: '第一轮'),
          const AIMessage(role: 'assistant', content: '答一'),
          const AIMessage(role: 'user', content: '第二轮'),
          const AIMessage(role: 'assistant', content: '', toolCalls: [
            ToolCall(id: 't1', name: 'bash', args: {}),
          ]),
          const AIMessage(role: 'assistant', content: '答二'),
          const AIMessage(role: 'tool', content: '', toolResults: [
            ToolResult(callId: 't1', content: 'ok'),
          ]),
        ];

    test('从最后一条 user 起整段移除', () {
      final h = sampleHistory();
      truncateHistoryForResend(h);
      expect(h.map((m) => m.role).toList(), ['system', 'user', 'assistant']);
      expect(h.last.content, '答一');
    });

    test('截断后不留孤儿 tool_use —— 这条是整个功能的安全底线', () {
      final h = sampleHistory();
      truncateHistoryForResend(h);

      final callIds = <String>{};
      final resultIds = <String>{};
      for (final m in h) {
        for (final c in m.toolCalls ?? const <ToolCall>[]) {
          callIds.add(c.id);
        }
        for (final r in m.toolResults ?? const <ToolResult>[]) {
          resultIds.add(r.callId);
        }
      }
      expect(callIds, resultIds,
          reason: 'tool_use 与 tool_result 必须一一对应，'
              '否则下一次请求会被 provider 400 拒掉');
    });

    test('没有 user 消息时什么都不做', () {
      final h = [const AIMessage(role: 'system', content: 'sys')];
      truncateHistoryForResend(h);
      expect(h, hasLength(1));
    });

    test('第一条就是 user 时截到只剩 system', () {
      final h = [
        const AIMessage(role: 'system', content: 'sys'),
        const AIMessage(role: 'user', content: '唯一一轮'),
        const AIMessage(role: 'assistant', content: '答'),
      ];
      truncateHistoryForResend(h);
      expect(h.map((m) => m.role).toList(), ['system']);
    });

    // 上面那个 sampleHistory 是**人造**形态：它刻意把一条 assistant 插在
    // toolCalls 与 toolResults 中间，好让「边界切错」这件事能被观察到
    // （相邻时 removeRange 是纯后缀删除，切点要么整对删掉要么整对保留，
    // 永远切不散，那条孤儿断言也就守不住任何东西 —— mutation 验证发现的）。
    //
    // 代价是真实形态反而没人覆盖了。真实 history 里 tool 消息紧跟在
    // assistant(toolCalls) 之后，这一条补上那个缺口。
    test('真实形态（tool 紧跟 assistant）截断后同样不留孤儿', () {
      final h = [
        const AIMessage(role: 'system', content: 'sys'),
        const AIMessage(role: 'user', content: '第一轮'),
        const AIMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'a1', name: 'bash', args: {}),
        ]),
        const AIMessage(role: 'tool', content: '', toolResults: [
          ToolResult(callId: 'a1', content: 'ok'),
        ]),
        const AIMessage(role: 'assistant', content: '答一'),
        const AIMessage(role: 'user', content: '第二轮'),
        const AIMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'b1', name: 'bash', args: {}),
        ]),
        const AIMessage(role: 'tool', content: '', toolResults: [
          ToolResult(callId: 'b1', content: 'ok'),
        ]),
      ];
      truncateHistoryForResend(h);

      // 第二轮整段没了，第一轮的 call/result 对完整留下。
      expect(h.map((m) => m.role).toList(),
          ['system', 'user', 'assistant', 'tool', 'assistant']);

      final callIds = <String>{};
      final resultIds = <String>{};
      for (final m in h) {
        for (final c in m.toolCalls ?? const <ToolCall>[]) {
          callIds.add(c.id);
        }
        for (final r in m.toolResults ?? const <ToolResult>[]) {
          resultIds.add(r.callId);
        }
      }
      expect(callIds, {'a1'});
      expect(callIds, resultIds);
    });
  });

  test('prepareResend 标记最后一轮并返回原文', () async {
    final provider = FakeProvider([const AIResponse(text: '答')]);
    final loop = makeLoop(provider: provider);
    await loop.send('第一轮');

    final text = loop.prepareResend();
    expect(text, '第一轮');
    final marked = loop.events.whereType<UserTurnEvent>().last;
    expect(marked.supersededByEdit, isTrue);
    expect(loop.events.whereType<UserTurnEvent>(), hasLength(1),
        reason: '事件不该被删除，只该被标记');
  });
}
