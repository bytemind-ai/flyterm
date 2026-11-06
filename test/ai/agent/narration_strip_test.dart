import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';
import '_fakes.dart';

void main() {
  // 这组守的是「叙述不进回填历史」。
  //
  // 背景：同一个问题修过两次都失败了 —— 先在内置技能正文里写
  // "Keep it to a few lines"，再在 system prompt 加 "Never announce what
  // you are about to do"。两次都是加文字，两次模型都照样违反。
  //
  // 根因假设是自我强化：叙述文本进了 _history，下一轮原样发回模型，模型
  // 看到自己上一轮在叙述就接着叙述，轮次越多越严重。断掉这个循环比再加
  // 一条规则更根本。
  group('带工具调用的 assistant turn 不把叙述写进历史', () {
    test('叙述被剥离，工具调用保留', () async {
      final loop = makeLoop(
        provider: FakeProvider([
          const AIResponse(
            text: 'Let me check disk usage across all servers.',
            toolCalls: [
              ToolCall(id: 'c1', name: 'bash', args: {
                'command': 'df -h',
                'description': 'x',
              })
            ],
          ),
          const AIResponse(text: 'done'),
        ]),
      );
      await loop.send('go');

      final withCalls = loop.debugHistory
          .where((m) => m.role == 'assistant' && (m.toolCalls?.isNotEmpty ?? false));
      expect(withCalls, isNotEmpty);
      for (final m in withCalls) {
        expect(m.content, isEmpty,
            reason: '叙述进了历史，下一轮会把它当范例继续叙述');
        expect(m.toolCalls, isNotEmpty, reason: '工具调用必须保留');
      }
    });

    test('最终回复的正文照常保留 —— 那是答案不是叙述', () async {
      final loop = makeLoop(
        provider: FakeProvider([
          const AIResponse(text: 'the answer is 42'),
        ]),
      );
      await loop.send('go');

      final finals = loop.debugHistory.where(
          (m) => m.role == 'assistant' && (m.toolCalls?.isEmpty ?? true));
      expect(finals.single.content, 'the answer is 42');
    });

    // UI 走 _events，与 _history 是两条路。剥离历史不该让用户看不见。
    test('用户仍然看得到那段文字 —— UI 走事件流不走历史', () async {
      final loop = makeLoop(
        provider: FakeProvider([
          const AIResponse(
            text: 'Let me check disk usage.',
            toolCalls: [
              ToolCall(id: 'c1', name: 'bash', args: {
                'command': 'df -h',
                'description': 'x',
              })
            ],
          ),
          const AIResponse(text: 'done'),
        ]),
      );
      await loop.send('go');

      final texts = loop.events
          .whereType<AssistantTextEvent>()
          .map((e) => e.text)
          .join(' ');
      expect(texts, contains('Let me check disk usage'),
          reason: '剥离的是回填历史，不是用户可见内容');
    });

    test('下一轮发给 provider 的消息里没有上一轮的叙述', () async {
      final provider = FakeProvider([
        const AIResponse(
          text: 'Let me look at that.',
          toolCalls: [
            ToolCall(id: 'c1', name: 'bash', args: {
              'command': 'uptime',
              'description': 'x',
            })
          ],
        ),
        const AIResponse(text: 'ok'),
      ]);
      final loop = makeLoop(provider: provider);
      await loop.send('go');

      // 第二轮收到的**整个**消息列表里都不该出现第一轮的叙述
      expect(provider.seen.length, greaterThanOrEqualTo(2));
      final secondRound =
          provider.seen.last.map((m) => m.content).join(String.fromCharCode(10));
      expect(secondRound, isNot(contains('Let me look at that')),
          reason: '自我强化循环没断：模型又看到了自己上一轮的叙述');
    });
  });

  // 剥离之后，带 tool_call 的 assistant 消息 content 恒为空 —— 这条路径
  // 以前只在「模型恰好没说话」时才走到，现在 100% 都走。各 provider 必须
  // 都能把空 content 序列化成合法请求，否则线上直接 400。
  //
  // Anthropic: content.isEmpty 时不加 text block（text 块不允许空字符串）
  // OpenAI:    content.isEmpty ? null（Gemini 继承它，走 OpenAI 兼容端点）
  // Ollama:    直传空串，本地推理不校验
  group('空 content 的 assistant 消息对各 provider 合法', () {
    test('Anthropic 不产出空 text block', () {
      final msg = AIMessage(
        role: 'assistant',
        content: '',
        toolCalls: const [ToolCall(id: 'c1', name: 'bash', args: {})],
      );
      final p = AnthropicProvider(apiKey: 'k', model: 'm');
      final body = p.buildToolMessagesForTest([msg]);
      final blocks = body.single['content'] as List;
      expect(blocks.every((b) => (b as Map)['type'] != 'text'), isTrue,
          reason: 'Anthropic 拒绝空 text block');
      expect(blocks.any((b) => (b as Map)['type'] == 'tool_use'), isTrue);
    });
  });
}
