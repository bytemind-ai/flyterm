import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/knowledge.dart';

KnowledgeCandidate cand({
  KnowledgeTarget target = KnowledgeTarget.skill,
  String name = 'nginx-502',
  String description = '排查 502',
  String body = 'BODY',
  String? updates,
}) =>
    KnowledgeCandidate(
      target: target,
      name: name,
      description: description,
      body: body,
      updatesExisting: updates,
    );

void main() {
  test('归档往返保住全部字段', () {
    final ev = KnowledgeProposalEvent([
      cand(),
      cand(
          target: KnowledgeTarget.serverNote,
          name: '配置位置',
          description: '',
          body: '配置在 /data/etc'),
    ]);
    final restored = agentEventsFromJson([agentEventToJson(ev)]).single;

    expect(restored, isA<KnowledgeProposalEvent>());
    final k = restored as KnowledgeProposalEvent;
    expect(k.candidates, hasLength(2));
    expect(k.candidates[0].target, equals(KnowledgeTarget.skill));
    expect(k.candidates[0].name, equals('nginx-502'));
    expect(k.candidates[0].body, equals('BODY'));
    expect(k.candidates[1].target, equals(KnowledgeTarget.serverNote));
  });

  test('updatesExisting 进归档', () {
    final ev = KnowledgeProposalEvent([cand(updates: 'nginx-502')]);
    final k = agentEventsFromJson([agentEventToJson(ev)]).single
        as KnowledgeProposalEvent;
    expect(k.candidates.single.updatesExisting, equals('nginx-502'));
  });

  // 已经存过/忽略过的条目不能在恢复后变回「待决定」——那会让用户第二次
  // 点存入，把同一条知识再写一遍。
  test('已处理的下标进归档', () {
    final ev = KnowledgeProposalEvent([cand(), cand(name: 'other')])
      ..resolved.add(0);
    final k = agentEventsFromJson([agentEventToJson(ev)]).single
        as KnowledgeProposalEvent;
    expect(k.resolved, equals({0}));
  });

  test('候选为空时往返不炸', () {
    final k = agentEventsFromJson(
            [agentEventToJson(KnowledgeProposalEvent(const []))])
        .single as KnowledgeProposalEvent;
    expect(k.candidates, isEmpty);
  });

  // I1：改名前（agentsMd → serverNote）的旧归档必须认得出来，否则候选数会
  // 比 resolved 记的下标集合少一条，后面的候选顶替被丢弃那条的位置，
  // 被误标成「已处理」。
  test('旧存档的 agentsMd 识别为 serverNote，不被丢弃导致 resolved 错位', () {
    // 下标 0 是已经存过的机器笔记（老 wire 值 agentsMd），下标 1 是还没
    // 处理的 skill。
    final restored = agentEventsFromJson([
      {
        't': 'knowledge',
        'items': [
          {
            'target': 'agentsMd',
            'name': '配置位置',
            'description': '',
            'body': '配置在 /data/etc',
          },
          {'target': 'skill', 'name': 'nginx-502', 'description': 'd', 'body': 'b'},
        ],
        'resolved': [0],
      }
    ]).single as KnowledgeProposalEvent;

    expect(restored.candidates, hasLength(2),
        reason: 'agentsMd 被当成未知去向 continue 跳过的话这里只剩 1 条');
    expect(restored.candidates[0].target, equals(KnowledgeTarget.serverNote));
    expect(restored.candidates[0].name, equals('配置位置'));
    expect(restored.candidates[1].target, equals(KnowledgeTarget.skill));
    expect(restored.resolved, equals({0}));
    // resolved 指向的必须真的是那条已经存过的机器笔记，而不是因为错位
    // 误伤了后面还没处理的 skill。
    expect(restored.candidates[restored.resolved.single].name, equals('配置位置'));
  });

  test('归档里的坏条目被跳过，其余保住', () {
    final restored = agentEventsFromJson([
      {
        't': 'knowledge',
        'items': [
          {'target': 'skill', 'name': 'ok', 'description': 'd', 'body': 'b'},
          '垃圾',
          {'target': '不认识的去向', 'name': 'x', 'description': 'd', 'body': 'b'},
        ],
      }
    ]).single as KnowledgeProposalEvent;
    expect(restored.candidates, hasLength(1));
    expect(restored.candidates.single.name, equals('ok'));
  });
}
