import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/skill_search.dart';

/// 造一条 skill。`id` 用 name 的 hashCode 保证唯一但稳定。
AgentSkill sk(String name, String description, {bool enabled = true}) =>
    AgentSkill(
      id: name.hashCode,
      name: name,
      description: description,
      body: 'BODY of $name',
      enabled: enabled,
      source: SkillSource.ai,
      updatedAt: DateTime(2026, 1, 1),
      lastUsedAt: null,
      hitCount: 0,
    );

void main() {
  test('英文多 term 命中越多分越高', () {
    final all = [
      sk('nginx-502', 'fix nginx bad gateway'),
      sk('nginx-tls', 'renew tls cert'),
    ];
    final hits = searchSkills(all, 'nginx gateway');
    expect(hits.first.name, 'nginx-502');
    expect(hits, hasLength(2));
  });

  test('大小写折叠', () {
    final hits = searchSkills([sk('Nginx-502', 'Fix Bad Gateway')], 'NGINX');
    expect(hits, hasLength(1));
  });

  test('中文按 2-gram 切，子串查询能命中', () {
    // 「延迟」是「主从延迟」的 2-gram 之一，所以能命中。这正是不按整串
    // 匹配的理由。
    final all = [sk('mysql-replica', 'MySQL 主从延迟排查')];
    expect(searchSkills(all, '延迟'), hasLength(1));
  });

  test('中英混合查询', () {
    final all = [sk('mysql-replica', 'MySQL 主从延迟排查')];
    expect(searchSkills(all, 'mysql 延迟'), hasLength(1));
  });

  test('name 权重高于 description', () {
    final all = [
      sk('redis', 'something unrelated'),
      sk('unrelated-name', 'about redis memory'),
    ];
    final hits = searchSkills(all, 'redis');
    expect(hits.first.name, 'redis',
        reason: 'name 命中权重 3，description 命中权重 1');
  });

  test('零命中返回空列表，不抛', () {
    expect(searchSkills([sk('a', 'b')], 'zzzz'), isEmpty);
  });

  test('空 query 与纯空白 query 都返回空', () {
    final all = [sk('a', 'b')];
    expect(searchSkills(all, ''), isEmpty);
    expect(searchSkills(all, '   '), isEmpty);
  });

  test('limit 截断，且禁用的不参与', () {
    final all = [
      for (var i = 0; i < 8; i++) sk('nginx-$i', 'nginx note $i'),
      sk('nginx-off', 'nginx disabled one', enabled: false),
    ];
    final hits = searchSkills(all, 'nginx', limit: 3);
    expect(hits, hasLength(3));
    expect(hits.map((h) => h.name), isNot(contains('nginx-off')));
  });
}
