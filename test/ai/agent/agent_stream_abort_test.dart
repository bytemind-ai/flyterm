import 'dart:io' show HttpException;

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

/// 先把一轮完整地说完（含 [StreamDone]），再让流以传输错误结束。
///
/// 这不是假想的畸形输入：兼容端点在 `[DONE]` 之后不发 chunked 终止块就关掉
/// 连接，dart:io 抛的正是这个 `HttpException`。provider 那层已经把「说完了
/// 之后才断」吞掉了（见三个 *_stream_test.dart），这里守的是更靠里的一道：
/// provider 是可插拔的，任何一家只要把 StreamDone 发出来了，之后再抛什么都
/// 不该让这一轮变成失败。
class _DoneThenAbortProvider extends FakeProvider {
  _DoneThenAbortProvider() : super(const []);

  @override
  Stream<AgentChunk> completeWithToolsStream(
      List<AIMessage> messages, List<ToolSpec> tools,
      {String? sessionKey}) async* {
    yield TextDelta('说完了');
    yield const StreamDone(AIResponse(
      text: '说完了',
      usage: TokenUsage(inputTokens: 100, outputTokens: 20),
    ));
    throw const HttpException('Connection closed while receiving data');
  }
}

void main() {
  test('StreamDone 已到手，之后的传输错误不该把这一轮判成失败', () async {
    final loop = makeLoop(provider: _DoneThenAbortProvider(), runner: FakeRunner());

    await loop.send('hi');

    expect(loop.stopReason, equals(AgentStopReason.completed));
    expect(loop.errorMessage, isNull);
    expect(loop.events.whereType<AssistantTextEvent>().single.text,
        equals('说完了'));
    // 这一轮的 usage 必须记进去 —— 真机上看到的 `本轮 0 token` 就是它被
    // 连同整轮一起丢掉的结果。
    expect(loop.totalUsage.outputTokens, equals(20));
  });
}
