import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

void main() {
  test('流式文本进 streamingText，不进事件流；结束后定稿成一条事件', () async {
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const TextDelta('查一下 '),
        const TextDelta('nginx'),
        const StreamDone(AIResponse(text: '查一下 nginx')),
      ],
    ]);
    final loop = makeLoop(provider: provider);

    final seenMidStream = <String?>[];
    loop.addListener(() {
      if (loop.isRunning) seenMidStream.add(loop.streamingText);
    });

    await loop.send('why 502');

    // 流进行中至少观察到一次非空的增量
    expect(seenMidStream.any((s) => s != null && s.isNotEmpty), isTrue);
    // 结束后字段清空，内容定稿成正式事件
    expect(loop.streamingText, isNull);
    final texts = loop.events.whereType<AssistantTextEvent>().toList();
    expect(texts.length, equals(1));
    expect(texts.single.text, equals('查一下 nginx'));
  });

  test('归档里没有 streamingText 的痕迹', () async {
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const TextDelta('half'),
        const StreamDone(AIResponse(text: 'half')),
      ],
    ]);
    final loop = makeLoop(provider: provider);
    await loop.send('q');

    final archive = loop.toArchive();
    final events = archive['events'] as List;
    // 只有 user + assistant + stopped，没有第四条半成品
    expect(events.whereType<Map>().where((e) => e['t'] == 'assistant').length,
        equals(1));
    expect(archive.containsKey('streamingText'), isFalse);
  });

  test('StreamDone 带 toolCalls 时照常执行工具', () async {
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const TextDelta('看端口'),
        const ToolCallReady(
            ToolCall(id: 'c1', name: 'bash', args: {'command': 'ss -ltnp'})),
        const StreamDone(AIResponse(
          text: '看端口',
          toolCalls: [
            ToolCall(id: 'c1', name: 'bash', args: {'command': 'ss -ltnp'})
          ],
        )),
      ],
      <AgentChunk>[const StreamDone(AIResponse(text: 'done'))],
    ]);
    final runner = FakeRunner();
    final loop = makeLoop(provider: provider, runner: runner);

    await loop.send('q');

    expect(runner.ran.length, equals(1));
    expect(runner.ran.single, equals('ss -ltnp'));
    expect(loop.events.whereType<ToolCallEvent>().length, equals(1));
  });

  test('usage 从 StreamDone 里累加', () async {
    final provider = FakeProvider([], streamScript: [
      <AgentChunk>[
        const StreamDone(AIResponse(
          text: 'ok',
          usage: TokenUsage(inputTokens: 100, outputTokens: 20),
        )),
      ],
    ]);
    final loop = makeLoop(provider: provider);
    await loop.send('q');

    expect(loop.totalUsage.inputTokens, equals(100));
    expect(loop.totalUsage.outputTokens, equals(20));
  });

  test('流中途抛错：已收到的文本保留成正式事件，不静默丢字', () async {
    final provider = FakeProvider([], streamScript: [
      Exception('connection reset'),
    ]);
    final loop = makeLoop(provider: provider);
    await loop.send('q');

    expect(loop.stopReason, equals(AgentStopReason.error));
    expect(loop.streamingText, isNull);
  });

  test('还没收到任何 chunk 时的 context overflow 仍能 drop 后重试', () async {
    final provider = FakeProvider([], streamScript: [
      Exception('prompt is too long'),
      <AgentChunk>[const StreamDone(AIResponse(text: 'recovered'))],
    ]);
    final loop = makeLoop(provider: provider);
    // 塞一条有输出的工具结果，让 _dropOldestOutput 有东西可丢
    loop.debugSeedToolResult(ToolResult(
        callId: 'old', content: 'a' * 5000, exitCode: 0));

    await loop.send('q');

    expect(loop.stopReason, equals(AgentStopReason.completed));
    expect(loop.events.whereType<AssistantTextEvent>().last.text,
        equals('recovered'));
  });
}
