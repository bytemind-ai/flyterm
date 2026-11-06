import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/knowledge.dart';
import 'package:flyterm/ai/agent/knowledge_distiller.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/ai_provider.dart';

import '_fakes.dart';

KnowledgeDistillInput input({
  String goal = '502 怎么回事',
  List<String> actions = const ['查状态 :: systemctl status nginx'],
  String conclusion = 'upstream 挂了',
  List<SkillIndexEntry> skills = const [],
  String? machineNotes,
  int remaining = 4096,
}) =>
    KnowledgeDistillInput(
      userGoal: goal,
      actions: actions,
      conclusion: conclusion,
      existingSkills: skills,
      currentMachineNotes: machineNotes,
      machineNotesRemainingBytes: remaining,
    );

void main() {
  test('正常返回被解析成候选', () async {
    final p = FakeProvider([], completeScript: [
      '[{"target":"skill","name":"nginx-502","description":"d","body":"b"}]'
    ]);
    final d = KnowledgeDistiller(() => p);
    final r = await d.distill(input());
    expect(r, hasLength(1));
    expect(r.single.name, equals('nginx-502'));
  });

  // 任何失败都不能变成用户可见的错误：这是锦上添花的功能，一次失败
  // 应当表现为「这次没有提议」，用户根本不该知道它发生过。
  test('provider 抛异常时静默返回空', () async {
    final p = FakeProvider([],
        completeScript: [const RateLimitedException('429')]);
    final d = KnowledgeDistiller(() => p);
    expect(await d.distill(input()), isEmpty);
  });

  test('provider 抛任意异常时也静默', () async {
    final p = FakeProvider([], completeScript: [StateError('boom')]);
    final d = KnowledgeDistiller(() => p);
    expect(await d.distill(input()), isEmpty);
  });

  test('返回坏 JSON 时静默返回空', () async {
    final p = FakeProvider([], completeScript: ['我觉得没什么可存的']);
    final d = KnowledgeDistiller(() => p);
    expect(await d.distill(input()), isEmpty);
  });

  test('提炼请求里带上了现有 skill 索引 —— 防重靠它', () async {
    final p = FakeProvider([], completeScript: ['[]']);
    final d = KnowledgeDistiller(() => p);
    await d.distill(input(skills: const [
      SkillIndexEntry(name: 'nginx-502', description: '排查 502')
    ]));
    final sent = p.seenComplete.single.map((m) => m.content).join('\n');
    expect(sent, contains('nginx-502'));
  });

  test('提炼请求里带上了意图、动作与结论', () async {
    final p = FakeProvider([], completeScript: ['[]']);
    final d = KnowledgeDistiller(() => p);
    await d.distill(input());
    final sent = p.seenComplete.single.map((m) => m.content).join('\n');
    expect(sent, contains('502 怎么回事'));
    expect(sent, contains('systemctl status nginx'));
    expect(sent, contains('upstream 挂了'));
  });

  test('本机笔记写满时请求里说明不要再产出 server_note 条目', () async {
    final p = FakeProvider([], completeScript: ['[]']);
    final d = KnowledgeDistiller(() => p);
    await d.distill(input(remaining: 0));
    final sent = p.seenComplete.single.map((m) => m.content).join('\n');
    expect(sent.toLowerCase(), contains('full'));
  });

  test('命中已有索引名时回填 updatesExisting', () async {
    final p = FakeProvider([], completeScript: [
      '[{"target":"skill","name":"nginx-502","description":"d2","body":"b2"}]'
    ]);
    final d = KnowledgeDistiller(() => p);
    final r = await d.distill(input(skills: const [
      SkillIndexEntry(name: 'nginx-502', description: '旧的')
    ]));
    expect(r.single.updatesExisting, equals('nginx-502'));
  });
}
