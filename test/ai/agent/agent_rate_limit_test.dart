import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

/// 等到 [cond] 成立或超时。不抛 —— 让随后的 `expect` 去报错，那条消息比
/// TimeoutException 有用。
Future<void> waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('429 退避后重试，第二次成功则会话正常收工', () async {
    final provider = FakeProvider([
      // 第一次抛 429（Retry-After 1 秒，测试等得起）
      const RateLimitedException('429：限流', retryAfter: Duration(seconds: 1)),
      const AIResponse(text: '查完了'),
    ]);
    final loop = makeLoop(provider: provider);

    await loop.send('查一下');

    expect(loop.state, AgentLoopState.done);
    expect(loop.stopReason, AgentStopReason.completed);
    expect(provider.seen.length, 2, reason: '第一次被限流，第二次才成功');
    expect(loop.errorMessage, isNull);
  });

  test('重试上限是 2 次，用尽之后当错误终止', () async {
    final provider = FakeProvider([
      const RateLimitedException('429：限流一', retryAfter: Duration(seconds: 1)),
      const RateLimitedException('429：限流二', retryAfter: Duration(seconds: 1)),
      const RateLimitedException('429：限流三', retryAfter: Duration(seconds: 1)),
      const AIResponse(text: '不该走到这里'),
    ]);
    final loop = makeLoop(provider: provider);

    await loop.send('查一下');

    expect(loop.state, AgentLoopState.failed);
    expect(loop.stopReason, AgentStopReason.error);
    expect(provider.seen.length, 3,
        reason: '首发 + 2 次重试 = 3 次请求，第 3 次的 429 不再重试');
    expect(loop.errorMessage, contains('限流三'),
        reason: '报出去的应当是最后一次的错误');
  });

  test('退避等待期间 Stop 立刻生效 —— 不等满那几秒', () async {
    final provider = FakeProvider([
      // 60 秒：如果 Stop 不生效，这条测试会挂到超时
      const RateLimitedException('429：限流', retryAfter: Duration(seconds: 60)),
      const AIResponse(text: '不该走到这里'),
    ]);
    final loop = makeLoop(provider: provider);

    final done = loop.send('查一下');
    await waitUntil(() => loop.state == AgentLoopState.rateLimited);
    expect(loop.state, AgentLoopState.rateLimited,
        reason: '撞上 429 之后应当进入退避状态，而不是继续显示「思考中」');

    final sw = Stopwatch()..start();
    loop.cancel();
    await done;
    sw.stop();

    expect(loop.stopReason, AgentStopReason.userCancelled);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'Stop 必须立刻中断退避，而不是等满 Retry-After 的 60 秒');
    expect(provider.seen.length, 1, reason: '取消之后不该再发第二次请求');
  });

  test('退避期间 isRunning 为真 —— 面板要显示运行条与 Stop 按钮', () async {
    final provider = FakeProvider([
      const RateLimitedException('429：限流', retryAfter: Duration(seconds: 60)),
      const AIResponse(text: 'x'),
    ]);
    final loop = makeLoop(provider: provider);

    final done = loop.send('查一下');
    await waitUntil(() => loop.state == AgentLoopState.rateLimited);

    expect(loop.isRunning, isTrue,
        reason: 'isRunning 控制着运行条和那颗 Stop 按钮 —— '
            '退避期间正是最需要能按 Stop 的时候');
    expect(loop.rateLimitRemaining, isNotNull);
    expect(loop.rateLimitReason, contains('限流'));

    loop.cancel();
    await done;
    expect(loop.rateLimitRemaining, isNull, reason: '退出退避后要清干净');
  });

  test('没有 Retry-After 时用内置退避阶梯', () async {
    final provider = FakeProvider([
      const RateLimitedException('429：限流'), // retryAfter 为 null
      const AIResponse(text: 'x'),
    ]);
    final loop = makeLoop(provider: provider);

    final done = loop.send('查一下');
    await waitUntil(() => loop.state == AgentLoopState.rateLimited);

    final left = loop.rateLimitRemaining;
    expect(left, isNotNull);
    // 阶梯第一档是 5 秒。
    expect(left!.inMilliseconds, greaterThan(3000));
    expect(left.inMilliseconds, lessThanOrEqualTo(5000));

    loop.cancel();
    await done;
  });

  test('普通错误不重试 —— 只有 429 走这条路', () async {
    final provider = FakeProvider([
      Exception('401：API Key 无效或已过期'),
      const AIResponse(text: '不该走到这里'),
    ]);
    final loop = makeLoop(provider: provider);

    await loop.send('查一下');

    expect(loop.state, AgentLoopState.failed);
    expect(provider.seen.length, 1, reason: '401 重试毫无意义，不该再发');
    expect(loop.errorMessage, contains('401'));
  });

  test('额度按「每次用户提问」重置，不是这条 loop 一辈子只有两次', () async {
    // 两次提问，每次都先撞一次 429 再成功。做成实例字段的话，第二次提问
    // 会因为额度已经用掉而直接失败 —— 而 AgentLoop 按 serverId 长期复用、
    // 跨多次面板开关，那意味着用两次之后这条 loop 就永久失去重试能力。
    final provider = FakeProvider([
      const RateLimitedException('429：一', retryAfter: Duration(seconds: 1)),
      const AIResponse(text: '第一次查完了'),
      const RateLimitedException('429：二', retryAfter: Duration(seconds: 1)),
      const AIResponse(text: '第二次查完了'),
    ]);
    final loop = makeLoop(provider: provider);

    await loop.send('第一个问题');
    expect(loop.stopReason, AgentStopReason.completed);

    await loop.send('第二个问题');
    expect(loop.stopReason, AgentStopReason.completed,
        reason: '新的一次提问应当重新拿到完整的重试额度');
    expect(provider.seen.length, 4);
  });

  test('重试次数跨轮累计，不因中间某轮成功而清零', () async {
    // 轮 1：限流一次后成功（用掉 1 次重试额度）
    // 轮 2：模型又发工具调用，再撞两次限流 —— 第 2 次就该到顶
    final provider = FakeProvider([
      const RateLimitedException('429：一', retryAfter: Duration(seconds: 1)),
      AIResponse(toolCalls: [
        ToolCall(id: 'a', name: 'bash', args: {
          'command': 'ps aux',
          'description': 'why',
        })
      ]),
      const RateLimitedException('429：二', retryAfter: Duration(seconds: 1)),
      const RateLimitedException('429：三', retryAfter: Duration(seconds: 1)),
      const AIResponse(text: '不该走到这里'),
    ]);
    final loop = makeLoop(provider: provider);

    await loop.send('查一下');

    expect(loop.state, AgentLoopState.failed);
    // 每轮重置的话，轮 2 还能再撞 2 次，第 5 项才会被消费。
    expect(provider.seen.length, 4,
        reason: '额度跨轮累计：轮 1 用掉 1 次，轮 2 只剩 1 次');
    expect(loop.errorMessage, contains('三'));
  });
}
