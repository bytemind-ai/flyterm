import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_events.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/tool_executors/arg_parsing.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import '_fakes.dart';

/// `arg_parsing.dart` 是所有 executor 共用的参数解析，此前**没有直接测试**，
/// 只被各个 executor 的测试间接走到。它承载的恰恰是最容易出错的一件事：
/// 模型给的 JSON 参数类型不受控。
///
/// 这个文件直接测它本身，而不是透过某个 executor。
void main() {
  group('asPositiveInt', () {
    test('吃 num', () {
      expect(asPositiveInt(10, 1), equals(10));
    });

    /// 最关键的一条：模型（以及中间的 OpenAI 兼容代理）把数字序列化成
    /// 字符串非常常见。只认 num 的话 `offset: "10"` 会**静默退化成默认值**
    /// —— 不报错、不提示，模型以为自己从第 10 行开始读，实际读的是第 1 行。
    test('吃数字字符串 —— 退化成默认值是静默错误', () {
      expect(asPositiveInt('10', 1), equals(10));
    });

    test('吃小数（JSON 里没有整数类型这回事）', () {
      expect(asPositiveInt(10.0, 1), equals(10));
      expect(asPositiveInt('10.0', 1), equals(10));
    });

    test('解析不了退回 fallback', () {
      expect(asPositiveInt(null, 42), equals(42));
      expect(asPositiveInt('abc', 42), equals(42));
      expect(asPositiveInt(<int>[], 42), equals(42));
      expect(asPositiveInt(true, 42), equals(42));
    });

    test('默认拒绝 0 与负数', () {
      expect(asPositiveInt(0, 7), equals(7));
      expect(asPositiveInt(-3, 7), equals(7));
      expect(asPositiveInt('-3', 7), equals(7));
    });

    test('allowZero=true 时 0 放行、负数仍拒', () {
      expect(asPositiveInt(0, 7, allowZero: true), equals(0));
      expect(asPositiveInt('0', 7, allowZero: true), equals(0));
      expect(asPositiveInt(-1, 7, allowZero: true), equals(7));
    });
  });

  group('missingArgMessage', () {
    test('统一措辞且点名参数', () {
      expect(missingArgMessage('path'),
          equals('Invalid arguments: `path` is required.'));
    });

    /// 有些调用点传的不是单个参数名，而是一句更具体的描述。措辞函数不该
    /// 对它做任何假设（比如加反引号包裹）。
    test('原样接受描述性短语', () {
      expect(missingArgMessage('`old_string` and `new_string`'),
          contains('`old_string` and `new_string`'));
    });
  });

  group('ToolFailures extension', () {
    late AgentLoop loop;

    setUp(() => loop = makeLoop(provider: FakeProvider([])));

    ToolCallEvent makeEvent(String callId) => ToolCallEvent(
          seq: loop.nextSeq(),
          callId: callId,
          toolName: 'x',
          displayCommand: 'x',
          description: '',
          check: const CheckResult(decision: ToolDecision.allow),
        );

    test('failTool 记失败、写卡、返回错误结果', () {
      final ev = makeEvent('c1');
      loop.debugAddEvent(ev);
      const call = ToolCall(id: 'c1', name: 'x', args: {});

      final r = loop.failTool(ev, call, 'Invalid arguments: `a` is required.');

      expect(r.isError, isTrue);
      expect(r.callId, equals('c1'));
      expect(r.content, contains('Invalid arguments'));
      expect(ev.output, contains('Invalid arguments'));
      expect(ev.status, equals(ToolCallStatus.failed));
      expect(loop.debugConsecutiveInvalidArgs, equals(1),
          reason: '应计入连续无效计数');
    });

    /// `failToolBare` 与 `failTool` 的分工就是「有没有卡」。
    ///
    /// **它刻意不计入连续无效计数。** 是否计入是有意的语义分野：
    /// `more_tools` 猜错组名就刻意不调，app / sftp 两个 executor 历史上
    /// 也从不调。把这一点钉住，防止后人「顺手统一」。
    test('failToolBare 不记无效计数、不碰事件卡', () {
      final ev = makeEvent('c2');
      loop.debugAddEvent(ev);
      const call = ToolCall(id: 'c2', name: 'x', args: {});

      final r = loop.failToolBare(call, 'Invalid arguments: `b` is required.');

      expect(r.isError, isTrue);
      expect(r.callId, equals('c2'));
      expect(loop.debugConsecutiveInvalidArgs, equals(0),
          reason: 'failToolBare 不该计入连续无效计数 —— '
              '那是与 failTool 有意的分野，不是遗漏');
      // 事件卡不该被这次失败改动。
      expect(ev.output, isNull);
      expect(ev.status, isNot(equals(ToolCallStatus.failed)));
    });
  });
}
