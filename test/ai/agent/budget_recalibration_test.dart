// `tokenBudget` 的重标定 —— 以及它保持行为不变的锁。
//
// 估算器改完之后同一段历史的返回值大约翻倍。`tokenBudget` 若不同步重标，
// 压缩会在真实 96k 而不是原来的真实约 200k 触发 —— 每个会话的可用长度
// 直接砍半，这是用户能感觉到的回归。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/token_estimate.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_message.dart';

/// 旧估算器的拷贝。**保留它是为了能证明行为没变**，不是为了还在用它。
int legacyEstimate(List<AIMessage> history) {
  var chars = 0;
  for (final m in history) {
    chars += m.content.length;
    for (final r in m.toolResults ?? const <ToolResult>[]) {
      chars += r.content.length;
    }
    for (final t in m.toolCalls ?? const <ToolCall>[]) {
      chars += t.name.length;
      t.args.forEach((k, v) => chars += k.length + '$v'.length);
    }
  }
  return (chars / 3.5).round();
}

/// 一条形状有代表性的排查历史：命令输出占大头，掺中文回复。
List<AIMessage> buildHistory(int rounds) {
  final log = 'Sep 14 11:20:01 host nginx[1234]: 127.0.0.1 - - '
      '"GET /api/v1/items?page=3 HTTP/1.1" 200 4213\n' * 20;
  return [
    const AIMessage(
        role: 'system', content: 'You are a hands-on ops assistant.'),
    for (var i = 0; i < rounds; i++) ...[
      AIMessage(role: 'assistant', content: '我看一下 nginx 的日志。', toolCalls: [
        ToolCall(id: 'c$i', name: 'bash', args: {'command': 'journalctl -u nginx'}),
      ]),
      AIMessage(role: 'tool', content: '', toolResults: [
        ToolResult(callId: 'c$i', content: log),
      ]),
    ],
  ];
}

void main() {
  test('量出 N：旧估算器首次越过 120000 时，新估算器返回多少', () {
    var rounds = 1;
    while (legacyEstimate(buildHistory(rounds)) <= 120000 && rounds < 5000) {
      rounds++;
    }
    final h = buildHistory(rounds);
    final oldEst = legacyEstimate(h);
    final newEst = h.fold<int>(0, (a, m) => a + estimateMessageTokens(m));
    // ignore: avoid_print
    print('RECALIBRATION rounds=$rounds old=$oldEst new=$newEst '
        'ratio=${(newEst / oldEst).toStringAsFixed(2)}');
    expect(oldEst, greaterThan(120000));
    // 这条是给实施者读数用的，不是判据；真正的判据是下面那条。
    expect(newEst, greaterThan(oldEst),
        reason: '新估算器必须比旧的大，否则重标定的前提就不成立');
  });

  test('行为不变：新旧两套在同一条历史上同时跨过压缩阈值', () {
    const oldBudget = 120000;
    const oldThreshold = oldBudget * 0.8;
    final newThreshold = kDefaultTokenBudget * 0.8;

    // 逐轮加长，找出各自首次越过 0.8 阈值的轮数。
    int firstCrossing(bool Function(List<AIMessage>) over) {
      var r = 1;
      while (!over(buildHistory(r)) && r < 5000) {
        r++;
      }
      return r;
    }

    final oldAt = firstCrossing((h) => legacyEstimate(h) > oldThreshold);
    final newAt = firstCrossing((h) =>
        h.fold<int>(0, (a, m) => a + estimateMessageTokens(m)) > newThreshold);

    expect((oldAt - newAt).abs(), lessThanOrEqualTo(1),
        reason: '重标定没做对：新旧两套在第 $oldAt / 第 $newAt 轮才触发压缩，'
            '差了不止一轮 —— 会话的可用长度被改了');
  });
}
