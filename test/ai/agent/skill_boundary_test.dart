import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/skill_search.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

/// 覆盖两个在实现「技能」功能过程中发现的真实缺陷：
///
/// 1. `_restore` 不重建 `_loadedSkills` —— 从归档恢复的会话会把已经 load
///    过的技能正文重发一遍，白白多花一次 8 KiB。
/// 2. `save_skill` 没被排除出聚合审批批次 —— 聚合卡的 `_detail` 只认
///    `command`/`path`，`save_skill` 用的是 `name`/`description`/`body`，
///    三个全对不上会 fallback 成裸的 `save_skill` 字符串，批准之后连它
///    自己的单张审批卡都被跳过。
void main() {
  ToolCall loadCall(String name, {required String id}) =>
      ToolCall(id: id, name: 'load_skill', args: {'name': name});

  List<ToolSpec> withSkills() =>
      agentToolSpecsFor(AgentToolTier.full, hasSkills: true);

  test('恢复一段已 load 过技能的会话后，再 load 同一个技能不重发正文', () async {
    var bodyReads = 0;
    Future<String?> body(String n, {Set<String> alsoAllow = const {}}) async {
      bodyReads++;
      return 'SKILL_BODY_MARK';
    }

    final loop1 = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: body,
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx', id: 'c1')]),
        const AIResponse(text: 'first done'),
      ]),
    );
    await loop1.send('go');
    expect(bodyReads, equals(1));

    // 归档里带着上次会话已经发过的技能正文（[skill: nginx]\n... 这一条
    // tool 消息）。恢复出来的新实例如果不重建 `_loadedSkills`，它会以为
    // 「从没 load 过 nginx」，模型再问一次就会被再读一遍库、再发一遍正文。
    final archive = loop1.toArchive();

    final loop2 = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: body,
      restoreFrom: archive,
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx', id: 'c2')]),
        const AIResponse(text: 'second done'),
      ]),
    );
    await loop2.send('again');

    expect(bodyReads, equals(1),
        reason: '恢复出来的会话应该记得 nginx 已经 load 过，不该再读库');
    // .last 而不是 .single —— events 里还有一条恢复进来的旧 ToolCallEvent
    // （loop1 那次 load_skill 留下的），这里只关心新发起的这一条。
    final ev = loop2.events.whereType<ToolCallEvent>().last;
    expect(ev.status, equals(ToolCallStatus.done));
    expect(ev.output, isNot(contains('SKILL_BODY_MARK')));
    expect(ev.output, contains('already loaded'));
  });

  test('归档里那条技能正文已经被 drop 成 marker——恢复后再 load 要重新发', () async {
    var bodyReads = 0;
    Future<String?> body(String n, {Set<String> alsoAllow = const {}}) async {
      bodyReads++;
      return 'SKILL_BODY_MARK';
    }

    final loop1 = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: body,
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx', id: 'c1')]),
        const AIResponse(text: 'first done'),
      ]),
    );
    await loop1.send('go');
    expect(bodyReads, equals(1));

    // 手动触发一次丢弃：正文所在的那条 tool 消息被替换成
    // `[output dropped: ...]` marker，正文本身已经不在历史里了。
    expect(loop1.debugDropOldestOutput(), isTrue);

    final archive = loop1.toArchive();
    // marker 不是 `kSkillBodyPrefix` 开头，`_restore` 扫描历史时必须认出
    // 这一条**不该**被记成「已加载」——否则模型下次 load 会被回一句
    // 「already loaded, its full text is above」，而上文只剩一条 marker，
    // 模型拿不到正文又不该重试，直接走进死路。
    final loop2 = makeLoop(
      toolSpecs: withSkills,
      skillNamesProvider: () => ['nginx'],
      skillBodyProvider: body,
      restoreFrom: archive,
      provider: FakeProvider([
        AIResponse(toolCalls: [loadCall('nginx', id: 'c2')]),
        const AIResponse(text: 'second done'),
      ]),
    );
    await loop2.send('again');

    expect(bodyReads, equals(2),
        reason: '正文已经被丢弃，恢复后必须能重新真的读一遍库');
    // .last 而不是 .single —— events 里还有一条恢复进来的旧 ToolCallEvent。
    final ev = loop2.events.whereType<ToolCallEvent>().last;
    expect(ev.status, equals(ToolCallStatus.done));
    expect(ev.output, contains('SKILL_BODY_MARK'));
  });

  test('一轮 1 个 save_skill + 1 个需审批的 bash 不聚合——save_skill 走自己的单张卡', () async {
    final saved = <String>[];
    final runner = FakeRunner();
    final provider = FakeProvider([
      AIResponse(toolCalls: [
        const ToolCall(id: 's1', name: 'save_skill', args: {
          'name': 'nginx',
          'description': '排查 502',
          'body': 'BODY',
        }),
        const ToolCall(id: 'b1', name: 'bash', args: {
          'command': 'systemctl restart nginx',
          'description': 'x',
        }),
      ]),
      const AIResponse(text: 'ok'),
    ]);
    final loop = makeLoop(
      provider: provider,
      runner: runner,
      mode: PermissionMode.ask,
      toolSpecs: withSkills,
      skillNamesProvider: () => const [],
      skillSaver: (n, d, b, a) async => saved.add(n),
    );

    // 改之前：save_skill 没被排除出聚合名单，串行桶里两条都「需审批」，
    // 会攒成一张 BatchApprovalEvent，`gate.future` 在等一个这个测试从不
    // 会去点的 approveBatch/discardBatch —— 挂死在这里，而不是断言失败。
    // 把关键断言放在 `await f` 之前，能让这种情况读成一次清晰的失败
    // （BatchApprovalEvent 不是空的），而不是测试跑到超时。
    final f = loop.send('go');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(loop.events.whereType<BatchApprovalEvent>(), isEmpty,
        reason: '聚合卡显示不出 save_skill 的 description/body，'
            '批准后会跳过它自己的审批');
    expect(loop.pendingApprovals, hasLength(1));
    final first = loop.pendingApprovals.single;
    expect(first.toolName, equals('save_skill'));
    expect(saved, isEmpty, reason: '批准前不能落库');

    loop.respondApproval(first.seq, ApprovalDecision.allowOnce);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(saved, equals(['nginx']), reason: '走了自己的审批之后才该落库');
    expect(loop.pendingApprovals, hasLength(1));
    final second = loop.pendingApprovals.single;
    expect(second.toolName, equals('bash'));
    loop.respondApproval(second.seq, ApprovalDecision.allowOnce);

    await f.timeout(const Duration(seconds: 5));

    expect(runner.ran, contains('systemctl restart nginx'));
  });

  test('长尾技能的正文被 drop 后恢复会话，仍能重新 load —— 不撞「它不存在」', () async {
    // 索引里一条都没有（模拟全部被挤出去），长尾靠 search 才能找到。
    var bodyReads = 0;
    Future<String?> body(String n, {Set<String> alsoAllow = const {}}) async {
      bodyReads++;
      return 'TAIL_BODY';
    }

    final loop1 = makeLoop(
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full,
          hasSkills: true, hasSkillOverflow: true),
      skillNamesProvider: () => const [],
      skillSearchProvider: (query, {int limit = 5}) => const [
        SkillSearchHit(name: 'tail', description: 'd', score: 3),
      ],
      skillBodyProvider: body,
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c1', name: 'search_skills', args: {'query': 'tail'}),
        ]),
        AIResponse(toolCalls: [
          ToolCall(id: 'c2', name: 'load_skill', args: {'name': 'tail'}),
        ]),
        const AIResponse(text: 'done'),
      ]),
    );
    await loop1.send('go');
    expect(bodyReads, equals(1));

    // 把正文丢成 marker，然后归档。这段历史里最早的可丢结果其实是
    // `search_skills` 那条（同样不带 `_kDroppedPrefix`），要丢两次才轮到
    // `load_skill` 的正文那条。
    expect(loop1.debugDropOldestOutput(), isTrue);
    expect(loop1.debugDropOldestOutput(), isTrue);
    final archive = loop1.toArchive();

    // 恢复出来的新实例：白名单必须从 marker 里重建，否则下面那次 load 会被
    // 回一句「No skill named tail」——而 marker 自己写着「call load_skill
    // again」。
    final loop2 = makeLoop(
      toolSpecs: () => agentToolSpecsFor(AgentToolTier.full,
          hasSkills: true, hasSkillOverflow: true),
      // 索引里有别的 30 条（这里用两条代表），就是没有 tail——重现真实场景
      // 里「另外 30 个」那句 available 提示。
      skillNamesProvider: () => const ['other1', 'other2'],
      skillSearchProvider: (query, {int limit = 5}) => const [],
      skillBodyProvider: body,
      restoreFrom: archive,
      provider: FakeProvider([
        AIResponse(toolCalls: [
          ToolCall(id: 'c3', name: 'load_skill', args: {'name': 'tail'}),
        ]),
        const AIResponse(text: 'done again'),
      ]),
    );
    await loop2.send('again');

    expect(bodyReads, equals(2), reason: '正文该被重新读一次');
    expect(loop2.isSkillSearched('tail'), isTrue);
  });
}
