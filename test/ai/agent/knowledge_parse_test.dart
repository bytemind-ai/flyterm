import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/knowledge.dart';
import 'package:flyterm/ai/agent/skill.dart';

String jsonOf(List<Map<String, dynamic>> items) => jsonEncode(items);

void main() {
  const existing = ['nginx-502', 'deploy-cli'];

  test('解析一条 skill 候选', () {
    final r = parseDistillCandidates(
      jsonOf([
        {
          'target': 'skill',
          'name': 'redis-oom',
          'description': 'redis 被 OOM kill 时的排查顺序',
          'body': '1. dmesg\n2. maxmemory',
        }
      ]),
      existingSkillNames: existing,
    );
    expect(r, hasLength(1));
    expect(r.single.target, equals(KnowledgeTarget.skill));
    expect(r.single.name, equals('redis-oom'));
    expect(r.single.updatesExisting, isNull);
  });

  test('解析一条 server_note 候选', () {
    final r = parseDistillCandidates(
      jsonOf([
        {
          'target': 'server_note',
          'name': 'nginx 配置位置',
          'description': '',
          'body': '这台的 nginx 配置在 /data/etc，不在 /etc',
        }
      ]),
      existingSkillNames: existing,
    );
    expect(r.single.target, equals(KnowledgeTarget.serverNote));
  });

  // 撞名撞不上正是 upsert 按 name 覆盖时的老问题：模型这次叫 nginx-502、
  // 下次叫 nginx-upstream-timeout，于是索引里两条并存互相矛盾。
  test('命中已有 skill 名时标记为更新（大小写不敏感）', () {
    final r = parseDistillCandidates(
      jsonOf([
        {
          'target': 'skill',
          'name': 'NGINX-502',
          'description': 'd',
          'body': 'b',
        }
      ]),
      existingSkillNames: existing,
    );
    expect(r.single.updatesExisting, equals('nginx-502'),
        reason: '要回填索引里的原名，不是模型写的大小写');
  });

  test('空数组 = 没什么可沉淀，合法', () {
    expect(parseDistillCandidates('[]', existingSkillNames: existing), isEmpty);
  });

  test('坏 JSON 返回空，不抛', () {
    expect(parseDistillCandidates('这不是 JSON', existingSkillNames: existing),
        isEmpty);
  });

  test('空字符串返回空，不抛', () {
    expect(parseDistillCandidates('', existingSkillNames: existing), isEmpty);
  });

  test('顶层不是数组返回空', () {
    expect(
        parseDistillCandidates('{"target":"skill"}', existingSkillNames: existing),
        isEmpty);
  });

  // 小模型（尤其 Ollama 上的）经常把 JSON 包在 markdown 围栏里
  test('剥掉 ```json 围栏', () {
    final r = parseDistillCandidates(
      '```json\n${jsonOf([
            {'target': 'skill', 'name': 'x', 'description': 'd', 'body': 'b'}
          ])}\n```',
      existingSkillNames: existing,
    );
    expect(r, hasLength(1));
  });

  test('剥掉无语言标注的 ``` 围栏', () {
    final r = parseDistillCandidates(
      '```\n[{"target":"skill","name":"x","description":"d","body":"b"}]\n```',
      existingSkillNames: existing,
    );
    expect(r, hasLength(1));
  });

  test('每个 target 至多一条，多的丢弃', () {
    final r = parseDistillCandidates(
      jsonOf([
        {'target': 'skill', 'name': 'a', 'description': 'd', 'body': 'b'},
        {'target': 'skill', 'name': 'b', 'description': 'd', 'body': 'b'},
        {'target': 'server_note', 'name': 'c', 'description': '', 'body': 'b'},
        {'target': 'server_note', 'name': 'd', 'description': '', 'body': 'b'},
      ]),
      existingSkillNames: existing,
    );
    expect(r, hasLength(2));
    expect(r.map((c) => c.name), equals(['a', 'c']));
  });

  test('未知 target 跳过', () {
    expect(
      parseDistillCandidates(
        jsonOf([
          {'target': 'instructions', 'name': 'x', 'description': 'd', 'body': 'b'}
        ]),
        existingSkillNames: existing,
      ),
      isEmpty,
    );
  });

  test('正文为空的条目跳过 —— 没有正文的知识不是知识', () {
    expect(
      parseDistillCandidates(
        jsonOf([
          {'target': 'skill', 'name': 'x', 'description': 'd', 'body': '   '}
        ]),
        existingSkillNames: existing,
      ),
      isEmpty,
    );
  });

  test('name 为空的 skill 跳过 —— load_skill 靠它匹配', () {
    expect(
      parseDistillCandidates(
        jsonOf([
          {'target': 'skill', 'name': '', 'description': 'd', 'body': 'b'}
        ]),
        existingSkillNames: existing,
      ),
      isEmpty,
    );
  });

  test('单条坏记录不影响其余条目', () {
    final r = parseDistillCandidates(
      '[{"target":"skill","name":"ok","description":"d","body":"b"},"垃圾"]',
      existingSkillNames: existing,
    );
    expect(r, hasLength(1));
    expect(r.single.name, equals('ok'));
  });

  test('description 超 200 字节被裸截断（不加标记）', () {
    final long = 'x' * 500;
    final r = parseDistillCandidates(
      jsonOf([
        {'target': 'skill', 'name': 'n', 'description': long, 'body': 'b'}
      ]),
      existingSkillNames: existing,
    );
    expect(utf8.encode(r.single.description).length,
        lessThanOrEqualTo(kMaxSkillDescriptionBytes));
    expect(r.single.description, isNot(contains('truncated')),
        reason: '标记会把这一行撑得更长，正好与限制它的目的相反');
  });

  test('body 超 8 KiB 被截断', () {
    final long = 'y' * (kMaxSkillBodyBytes + 1000);
    final r = parseDistillCandidates(
      jsonOf([
        {'target': 'skill', 'name': 'n', 'description': 'd', 'body': long}
      ]),
      existingSkillNames: existing,
    );
    expect(utf8.encode(r.single.body).length,
        lessThanOrEqualTo(kMaxSkillBodyBytes + 64),
        reason: 'clipToBytes 会在末尾挂一个截断标记，允许它的长度');
  });

  test('多字节字符不被截断成半个', () {
    final long = '排' * 200; // 每个 3 字节
    final r = parseDistillCandidates(
      jsonOf([
        {'target': 'skill', 'name': 'n', 'description': long, 'body': 'b'}
      ]),
      existingSkillNames: existing,
    );
    expect(r.single.description, isNot(contains('\u{FFFD}')));
  });
}
