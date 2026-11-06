import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_partition.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/skill_search.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import '_fakes.dart';

void main() {
  List<String> namesOf(List<dynamic> specs) =>
      specs.map((s) => s.name as String).toList();

  test('没有长尾时不声明 search_skills', () {
    final specs = agentToolSpecsFor(AgentToolTier.full, hasSkills: true);
    expect(namesOf(specs), isNot(contains('search_skills')),
        reason: 'hasSkillOverflow 默认 false —— 漏传的后果应该是少一个工具，'
            '而不是给模型一个用不了的工具');
  });

  test('有长尾时声明 search_skills', () {
    final specs = agentToolSpecsFor(AgentToolTier.full,
        hasSkills: true, hasSkillOverflow: true);
    expect(namesOf(specs), contains('search_skills'));
  });

  test('lean 档同样声明（小模型也会被挤出索引）', () {
    final specs = agentToolSpecsFor(AgentToolTier.lean,
        hasSkills: true, hasSkillOverflow: true);
    expect(namesOf(specs), contains('search_skills'));
  });

  test('search_skills 进本地工具桶 —— 纯内存查询，不碰 SSH、不需审批', () {
    expect(kLocalToolNames, contains('search_skills'));
  });

  test('search 之后能 load 索引外的技能，白名单被传给 bodyOf', () async {
    // 索引里只有 indexed；long-tail 是被挤出去的那条。
    final calls = <String>[];
    final loop = makeLoop(
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full,
          hasSkills: true, hasSkillOverflow: true),
      skillNamesProvider: () => ['indexed'],
      skillSearchProvider: (query, {int limit = 5}) => const [
        SkillSearchHit(
            name: 'long-tail', description: 'the tail one', score: 3),
      ],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async {
        calls.add('$n|${alsoAllow.join(",")}');
        // 模拟 AgentSkillManager.bodyOf 的放行规则。
        if (n == 'indexed' || alsoAllow.contains(n.toLowerCase())) {
          return 'BODY of $n';
        }
        return null;
      },
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'search_skills', args: {'query': 'tail'}),
        ]),
        AIResponse(toolCalls: [
          ToolCall(id: 'c2', name: 'load_skill', args: {'name': 'long-tail'}),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop.send('go');

    // 白名单确实被传下去了
    expect(calls, contains('long-tail|long-tail'));
    // 正文进了历史。测试入口是 debugHistory（agent_loop.dart:998），不是 history。
    // role == 'tool' 的消息 content 恒为空串，真正的数据在 toolResults 里
    // （见 skill_compaction_test.dart 的 histLastToolContent 用的同一模式）。
    expect(
        loop.debugHistory.any((m) =>
            m.role == 'tool' &&
            (m.toolResults ?? const <ToolResult>[])
                .any((r) => r.content.contains('BODY of long-tail'))),
        isTrue);
  });

  test('只有搜到过的名字进白名单', () async {
    final loop = makeLoop(
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full,
          hasSkills: true, hasSkillOverflow: true),
      skillNamesProvider: () => const [],
      skillSearchProvider: (query, {int limit = 5}) => const [
        SkillSearchHit(name: 'tail', description: 'd', score: 3),
      ],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'B',
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'search_skills', args: {'query': 'tail'}),
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(loop.isSkillSearched('tail'), isTrue);
    expect(loop.isSkillSearched('never-searched'), isFalse);
  });

  test('空 query 返回错误，不当成「列出全部」', () async {
    var searchCalls = 0;
    final loop = makeLoop(
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full,
          hasSkills: true, hasSkillOverflow: true),
      skillNamesProvider: () => const [],
      skillSearchProvider: (query, {int limit = 5}) {
        searchCalls++;
        return const [SkillSearchHit(name: 'x', description: 'd', score: 1)];
      },
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'B',
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'search_skills', args: {'query': '   '}),
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    expect(searchCalls, equals(0),
        reason: '空 query 必须在调检索之前就被拒 —— 否则是绕过索引上限的后门');
    expect(loop.isSkillSearched('x'), isFalse);
  });

  test('零命中时不进白名单，且文案明说「这就是全部」', () async {
    final loop = makeLoop(
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full,
          hasSkills: true, hasSkillOverflow: true),
      skillNamesProvider: () => const [],
      skillSearchProvider: (query, {int limit = 5}) => const [],
      skillBodyProvider: (n, {alsoAllow = const <String>{}}) async => 'B',
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'search_skills', args: {'query': 'zzz'}),
        ]),
        const AIResponse(text: 'ok'),
      ]),
    );
    await loop.send('go');
    final toolMsgs = loop.debugHistory.where((m) => m.role == 'tool');
    expect(
        toolMsgs.any((m) => m.toolResults!
            .any((r) => r.content.contains('are all you have'))),
        isTrue);
  });
}
