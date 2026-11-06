import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/builtin_skill_merge.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// `AgentLoop` 的必填参数（`rulesProvider` / `toolSpecsProvider` /
/// `onRuleAdded` / `systemPromptProvider` 等）不在 `_fakes.dart` 的
/// `makeLoop` 助手里暴露 `builtinSkillNamesProvider`，所以这里直接调用
/// `AgentLoop(...)` 构造，自己把必填项配平——而不是去改 `makeLoop`（那个
/// 助手被同目录几十个测试 import，改它的风险不该由这个任务承担）。
List<ToolSpec> _fullTools() =>
    agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

AgentLoop _buildLoop({
  required FakeProvider provider,
  PermissionMode mode = PermissionMode.bypass,
  List<String> Function()? builtinSkillNamesProvider,
  List<String> Function()? skillNamesProvider,
  Future<void> Function(String name, String description, String body,
      List<AgentSkillAsset>? assets)? skillSaver,
}) {
  return AgentLoop(
    providerProvider: () => provider,
    runnerProvider: (_) => FakeRunner(),
    rulesProvider: () => const PermissionRuleSet(defaultAllowRules),
    modeProvider: () => mode,
    toolSpecsProvider: _fullTools,
    onRuleAdded: (_) {},
    systemPromptProvider: (_) => 'test prompt',
    skillNamesProvider: skillNamesProvider,
    builtinSkillNamesProvider: builtinSkillNamesProvider,
    skillSaver: skillSaver,
  )
    // `save_skill` 属于 `more_tools` 的 skills 组，默认锁着。这个文件测的
    // 是撞名保护，不是解锁机制 —— 不解锁的话它只会收到「is not active
    // yet」，根本走不到撞名判定那一步。
    ..unlockToolGroup('skills');
}

ToolCall _saveCall({
  String name = 'plan-change',
  String description = '我自己的版本',
  String body = '正文',
}) =>
    ToolCall(id: 'c1', name: 'save_skill', args: {
      'name': name,
      'description': description,
      'body': body,
    });

void main() {
  test('save_skill 用内置技能的名字存 → 报错，且 skillSaver 一次都没被调用',
      () async {
    var saverCalls = 0;
    final loop = _buildLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [_saveCall()]),
        const AIResponse(text: 'done'),
      ]),
      mode: PermissionMode.bypass,
      builtinSkillNamesProvider: () => const ['plan-change'],
      skillNamesProvider: () => const ['plan-change'],
      skillSaver: (n, d, b, a) async => saverCalls++,
    );

    await loop.send('存一条技能');

    expect(saverCalls, 0, reason: '被内置遮住的技能存进去也永远读不到');
    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, ToolCallStatus.failed);
    expect(ev.output, contains('built-in'));
  });

  test('名字不撞内置时照常存', () async {
    var saverCalls = 0;
    final loop = _buildLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          _saveCall(name: 'nginx', description: 'd', body: 'b'),
        ]),
        const AIResponse(text: 'done'),
      ]),
      mode: PermissionMode.bypass,
      builtinSkillNamesProvider: () => const ['plan-change'],
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async => saverCalls++,
    );

    await loop.send('存一条技能');
    expect(saverCalls, 1);
  });

  test('大小写不同也拦 —— 与 load_skill 的匹配规则同源', () async {
    var saverCalls = 0;
    final loop = _buildLoop(
      provider: FakeProvider([
        AIResponse(toolCalls: [
          _saveCall(name: 'Plan-Change', description: 'd', body: 'b'),
        ]),
        const AIResponse(text: 'done'),
      ]),
      mode: PermissionMode.bypass,
      builtinSkillNamesProvider: () => const ['plan-change'],
      skillSaver: (n, d, b, a) async => saverCalls++,
    );

    await loop.send('存一条技能');
    expect(saverCalls, 0);
  });

  group('名字与正文的合并', () {
    test('内置排在用户技能之前', () {
      final merged = mergeSkillNames(
        builtin: const ['plan-change'],
        user: const ['nginx'],
      );
      expect(merged, ['plan-change', 'nginx']);
    });

    test('同名时内置优先，用户那条不出现在合并结果里', () {
      final merged = mergeSkillNames(
        builtin: const ['plan-change'],
        user: const ['Plan-Change', 'nginx'],
      );
      expect(merged, ['plan-change', 'nginx']);
    });

    test('resolveSkillBody 先查内置，命中就不碰数据库', () async {
      var userCalls = 0;
      final body = await resolveSkillBody(
        name: 'plan-change',
        builtinBody: (n) => n == 'plan-change' ? 'BUILTIN_BODY' : null,
        userBody: (n, {Set<String> alsoAllow = const {}}) async {
          userCalls++;
          return 'USER_BODY';
        },
      );
      expect(body, 'BUILTIN_BODY');
      expect(userCalls, 0);
    });

    test('内置没有时落到用户技能', () async {
      final body = await resolveSkillBody(
        name: 'nginx',
        builtinBody: (_) => null,
        userBody: (n, {Set<String> alsoAllow = const {}}) async => 'USER_BODY',
      );
      expect(body, 'USER_BODY');
    });
  });
}
