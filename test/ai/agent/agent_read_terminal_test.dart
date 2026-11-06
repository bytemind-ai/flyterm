// read_terminal：让 agent 自己去要「用户此刻屏幕上有什么」。
//
// 存在的理由：system prompt 里那份终端内容是 **loop 创建时的一次性快照**（刻意
// 放在 systemPromptProvider 闭包之外，见 terminal_screen.dart 的说明——它是
// Anthropic prompt cache 的断点，每轮变一次等于每轮全价重算）。而 loop 按
// serverId 复用、寿命跨多次面板开关，那份快照可能已经是几十条命令之前的。
//
// 以前唯一能把当前屏幕喂进去的途径是面板头部的「分析错误」/「会话总结」两个
// 按钮——也就是说正确性依赖「用户记得点按钮而不是直接打字」。现在模型自己能要。
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

AIResponse _readCall() =>
    AIResponse(toolCalls: [ToolCall(id: 'r1', name: 'read_terminal', args: {})]);

String _toolContent(FakeProvider p) => p.seen[1]
    .lastWhere((m) => m.role == 'tool')
    .toolResults!
    .single
    .content;

void main() {
  test('lean 与 full 两档都有 —— 看屏幕是排查的基础能力，不是高级功能', () {
    expect(leanToolSpecs.map((t) => t.name), contains('read_terminal'));
    expect(fullToolSpecs.map((t) => t.name), contains('read_terminal'));
  });

  test('无参数 —— 小模型没有可写坏的形状', () {
    final spec = leanToolSpecs.firstWhere((t) => t.name == 'read_terminal');
    final props = spec.parameters['properties'] as Map;
    expect(props, isEmpty);
    expect(spec.parameters.containsKey('required'), isFalse);
  });

  test('返回当前屏幕内容', () async {
    final provider = FakeProvider([_readCall(), const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: provider,
      terminalTextProvider: () => 'nginx: [emerg] bind() failed (98)',
    );

    await loop.send('屏幕上报的什么错');

    expect(_toolContent(provider), contains('bind() failed (98)'));
  });

  test('ask 档下也不走审批 —— 它只读手机上已经显示着的字，不碰远端', () async {
    final provider = FakeProvider([_readCall(), const AIResponse(text: 'ok')]);
    final loop = makeLoop(
      provider: provider,
      mode: PermissionMode.ask,
      terminalTextProvider: () => 'some output',
    );

    // 若它要审批，这次 send 会挂在等 respondApproval 上、走不到第二轮。
    await loop.send('看下屏幕');

    expect(_toolContent(provider), contains('some output'));
    expect(
      loop.events.whereType<ToolCallEvent>().where(
            (e) => e.status == ToolCallStatus.awaitingApproval,
          ),
      isEmpty,
      reason: '不该出现审批卡',
    );
  });

  test('屏幕是空的时候说清楚，不返回空字符串', () async {
    final provider = FakeProvider([_readCall(), const AIResponse(text: 'ok')]);
    final loop = makeLoop(provider: provider, terminalTextProvider: () => '');

    await loop.send('看下屏幕');

    // 空字符串会被模型读成「工具坏了」或者干脆忽略；说明白它是空的。
    expect(_toolContent(provider), isNotEmpty);
    expect(_toolContent(provider).toLowerCase(), contains('empty'));
  });

  test('没有可读的终端时返回可理解的说明，不抛', () async {
    final provider = FakeProvider([_readCall(), const AIResponse(text: 'ok')]);
    // 不传 terminalTextProvider —— 生产环境总有，但没有时不该崩。
    final loop = makeLoop(provider: provider);

    await loop.send('看下屏幕');

    expect(_toolContent(provider), isNotEmpty);
  });
}
