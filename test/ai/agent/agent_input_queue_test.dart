import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

import '_fakes.dart';

void main() {
  test('运行中 send 进队列，不进 history', () async {
    final provider = FakeProvider([
      bashCall('c1', 'sleep 1'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
    );

    final running = loop.send('查一下 nginx');
    // 让 loop 跑到第一轮的工具执行里（FakeRunner 有 1ms 延迟）
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(loop.isRunning, isTrue, reason: '这一步必须落在运行期间');

    loop.send('顺便看下 disk');
    expect(loop.pendingInputs, ['顺便看下 disk']);
    expect(
      loop.debugHistory.where((m) => m.content.contains('disk')),
      isEmpty,
    );

    await running;
    loop.dispose();
  });

  test('withdrawPendingInput 取回文本并出队', () async {
    final provider = FakeProvider([
      bashCall('c1', 'sleep 1'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
    );

    final running = loop.send('查一下 nginx');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    loop.send('第一句');
    loop.send('第二句');
    expect(loop.pendingInputs, ['第一句', '第二句']);

    expect(loop.withdrawPendingInput(0), '第一句');
    expect(loop.pendingInputs, ['第二句']);
    expect(loop.withdrawPendingInput(9), isNull);
    expect(loop.withdrawPendingInput(-1), isNull);

    await running;
    loop.dispose();
  });

  test('排队的输入在轮末注入 history，且 wire 结构合法', () async {
    final provider = FakeProvider([
      bashCall('c1', 'tail -100 error.log'),
      bashCall('c2', 'df -h'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
    );

    final running = loop.send('查一下 nginx');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    loop.send('顺便看下 disk');
    await running;

    final userTexts = loop.debugHistory
        .where((m) => m.role == 'user')
        .map((m) => m.content)
        .toList();
    expect(userTexts, contains('顺便看下 disk'));
    expect(loop.pendingInputs, isEmpty);

    // wire 结构:每条带 toolCalls 的 assistant 后面必须紧跟 tool 消息,
    // 且 toolResults 数量与 toolCalls 相等
    final h = loop.debugHistory;
    for (var i = 0; i < h.length; i++) {
      final calls = h[i].toolCalls;
      if (calls == null || calls.isEmpty) continue;
      expect(i + 1, lessThan(h.length),
          reason: '带 toolCalls 的 assistant 是历史最后一条 = 孤儿 tool_use');
      expect(h[i + 1].role, 'tool');
      expect(h[i + 1].toolResults?.length, calls.length);
    }

    loop.dispose();
  });

  test('多条排队合并成一条 user 消息', () async {
    final provider = FakeProvider([
      bashCall('c1', 'tail -100 error.log'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
    );

    final running = loop.send('查一下 nginx');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    loop.send('第一句');
    loop.send('第二句');
    await running;

    final merged = loop.debugHistory
        .where((m) => m.role == 'user' && m.content.contains('第一句'))
        .toList();
    expect(merged, hasLength(1), reason: '两条排队必须合并成一条,不是两条');
    expect(merged.single.content, '第一句\n第二句');

    loop.dispose();
  });

  test('模型这轮没有工具调用但有排队 → 继续跑而不是结束', () async {
    // 第 1 轮:一次工具调用（跑完，此时队列为空，点 A 是空操作）
    // 第 2 轮:纯文本，模型想收工——排队恰好在这一轮的模型调用期间发生
    // 第 3 轮:纯文本，回应排队的那句话
    //
    // 排队时机用 `onCall` 精确命中「第 2 轮模型调用期间」，而不是赌一个
    // `Future.delayed(1ms)`——FakeRunner 的工具执行本身也有 1ms 延迟，
    // 两个定时器几乎同时到期时，测试自己注册的那个总是先注册、先到期，
    // 排队反而会落进第 1 轮（工具执行中）的窗口，在那一轮末尾就被注入点
    // A 吃掉，测不出注入点 B 的效果（实测：跑出来是 2 轮，不是 3 轮）。
    var calls = 0;
    late final AgentLoop loop;
    final provider = FakeProvider(
      [
        bashCall('c1', 'tail -100 error.log'),
        const AIResponse(text: '看完了，nginx 配置有误'),
        const AIResponse(text: 'disk 也满了'),
      ],
      onCall: (_) {
        calls++;
        if (calls == 2) loop.send('顺便看下 disk');
      },
    );
    loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
    );

    await loop.send('查一下 nginx');

    expect(provider.seen, hasLength(3), reason: '有排队时不能在第 2 轮收工');
    expect(
      provider.seen.last.where((m) => m.content.contains('disk')),
      isNotEmpty,
    );
    expect(loop.stopReason, AgentStopReason.completed);
    expect(loop.pendingInputs, isEmpty);

    loop.dispose();
  });

  test('没有排队时照常在无工具调用那轮结束', () async {
    final provider = FakeProvider([
      const AIResponse(text: '不用查，配置就是错的'),
    ]);
    final loop = makeLoop(provider: provider, mode: PermissionMode.bypass);

    await loop.send('查一下 nginx');

    expect(provider.seen, hasLength(1));
    expect(loop.stopReason, AgentStopReason.completed);

    loop.dispose();
  });

  test('cancel 时排队文本退回，不自动发出', () async {
    final provider = FakeProvider([
      bashCall('c1', 'sleep 1'),
      const AIResponse(text: 'done'),
    ]);
    String? returned;
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
      onPendingReturned: (t) => returned = t,
    );

    final running = loop.send('查一下 nginx');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    loop.send('第一句');
    loop.send('第二句');
    loop.cancel();
    await running;

    expect(returned, '第一句\n第二句');
    expect(loop.pendingInputs, isEmpty);
    expect(
      loop.debugHistory.where((m) => m.content.contains('第一句')),
      isEmpty,
      reason: '用户点了停止,排队的话不该在他没看见时自动执行',
    );

    loop.dispose();
  });

  test('completed 终态下队列必为空，退回回调不触发', () async {
    // 排队时机用 `onCall` 精确命中「第 2 轮模型调用期间」，理由同上面
    // 「模型这轮没有工具调用但有排队」那个测试的注释：`Future.delayed(1ms)`
    // 的赛跑会落进第 1 轮（工具执行中），在那一轮末尾就被注入点 A 吃掉，
    // 测不出「正常走完时退回回调不触发」这件事——因为队列在第 2 轮开始前
    // 就已经空了，等于没排过队。
    var calls = 0;
    var returnedCount = 0;
    late final AgentLoop loop;
    final provider = FakeProvider(
      [
        bashCall('c1', 'tail error.log'),
        const AIResponse(text: '查完了'),
        const AIResponse(text: 'disk 也看了'),
      ],
      onCall: (_) {
        calls++;
        if (calls == 2) loop.send('顺便看下 disk');
      },
    );
    loop = makeLoop(
      provider: provider,
      mode: PermissionMode.bypass,
      runner: FakeRunner(),
      onPendingReturned: (_) => returnedCount++,
    );

    await loop.send('查一下 nginx');

    expect(loop.stopReason, AgentStopReason.completed);
    expect(returnedCount, 0, reason: '排队消息已在终态前被注入续跑，不该再有退回');

    loop.dispose();
  });
}
