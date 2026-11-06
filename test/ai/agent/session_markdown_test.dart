import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/session_markdown.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

void main() {
  test('用户轮与助手轮各自成段', () {
    final md = renderSessionMarkdown([
      UserTurnEvent('重启 nginx'),
      AssistantTextEvent('好的，我先看配置。'),
    ]);
    expect(md, contains('### 你'));
    expect(md, contains('重启 nginx'));
    expect(md, contains('好的，我先看配置。'));
  });

  test('工具调用带命令、输出与目标机器', () {
    final ev = ToolCallEvent(
      seq: 1,
      callId: 'c',
      toolName: 'bash',
      displayCommand: 'nginx -t',
      description: '检查配置',
      check: const CheckResult(decision: ToolDecision.allow),
      status: ToolCallStatus.done,
      targetServerName: 'web-01',
    )..output = 'syntax is ok';

    final md = renderSessionMarkdown([ev]);
    expect(md, contains('nginx -t'));
    expect(md, contains('syntax is ok'));
    expect(md, contains('web-01'));
    expect(md, contains('```'),
        reason: '输出必须进围栏，否则 shell 里的 * 会被当 markdown');
  });

  test('被截断的历史如实说明，不谎称可展开', () {
    final md = renderSessionMarkdown([TruncatedEvent(12)]);
    expect(md, contains('12'));
    expect(md, isNot(contains('展开')),
        reason: 'TruncatedEvent 的内容是真的丢了，承诺展开等于骗人');
  });

  test('被重发取代的那一轮有标注', () {
    final md = renderSessionMarkdown([
      UserTurnEvent('旧问法')..supersededByEdit = true,
      UserTurnEvent('新问法'),
    ]);
    expect(md, contains('旧问法'));
    expect(md, contains('已被重发取代'));
  });

  test('密钥被脱敏且报告条数', () {
    final ev = ToolCallEvent(
      seq: 1,
      callId: 'c',
      toolName: 'bash',
      displayCommand: 'env',
      description: '',
      check: const CheckResult(decision: ToolDecision.allow),
      status: ToolCallStatus.done,
    )..output = 'api_key=sk-abcdef123456';

    final r = renderSessionMarkdownRedacted([ev]);
    expect(r.text, isNot(contains('sk-abcdef123456')));
    expect(r.count, greaterThan(0));
  });
}
