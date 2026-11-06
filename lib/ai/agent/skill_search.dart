// SPDX-License-Identifier: GPL-3.0-or-later
import 'skill.dart';

/// 一次检索命中。[score] 只用于排序，不给模型看。
class SkillSearchHit {
  final String name;
  final String description;
  final int score;

  const SkillSearchHit({
    required this.name,
    required this.description,
    required this.score,
  });
}

/// 一次 `search_skills` 默认返回几条。
///
/// 5 条是「够模型挑一条」与「别把 context 灌满」之间的折中：每条只有 name +
/// 最多 200 字节描述，5 条约 350 token。
const int kSkillSearchLimit = 5;

/// 命中 `name` 与命中 `description` 的权重。
///
/// name 是用户/模型起的标识，命中它基本等于命中意图；description 是一句话
/// 说明，里面的词更泛。3:1 是让「名字里有 redis」压过「描述里提了 redis」。
const int _kNameWeight = 3;
const int _kDescWeight = 1;

/// 把文本切成检索 term。
///
/// ASCII 按 `[a-z0-9_]+` 切；**CJK 切 2-gram**。
///
/// 2-gram 是必须的：中文没有空格，按整串匹配会让「延迟」这种子串查询漏掉
/// 「MySQL 主从延迟」。而单字 1-gram 噪声太大——「的」「是」会命中一切。
///
/// 已知代价：单字查询（「日志」里查「志」）命中不了，因为被搜文本切出的是
/// `日志` 而不是 `志`。这是刻意的取舍。
Set<String> tokenizeForSearch(String text) {
  final lower = text.toLowerCase();
  final out = <String>{};
  for (final m in RegExp(r'[a-z0-9_]+').allMatches(lower)) {
    out.add(m.group(0)!);
  }
  for (final m in RegExp(r'[一-鿿]+').allMatches(lower)) {
    final s = m.group(0)!;
    if (s.length == 1) {
      out.add(s);
      continue;
    }
    for (var i = 0; i + 1 < s.length; i++) {
      out.add(s.substring(i, i + 2));
    }
  }
  return out;
}

/// 按 [query] 在 [all] 里检索，返回至多 [limit] 条命中，分数高的在前。
///
/// **纯函数、同步、零 IO。** 调用方传的 `all` 是 `AgentSkillManager` 那份
/// 全量内存列表（它之所以全量在内存，是因为 `indexEntries` 必须同步，见
/// 那个类的文档）。
///
/// 禁用的条目不参与——它们连索引都进不了，搜出来只会让模型 load 到一个必然
/// 失败的名字。
List<SkillSearchHit> searchSkills(
  List<AgentSkill> all,
  String query, {
  int limit = kSkillSearchLimit,
}) {
  final terms = tokenizeForSearch(query);
  if (terms.isEmpty) return const [];

  final hits = <SkillSearchHit>[];
  for (final s in all) {
    if (!s.enabled) continue;
    final nameTerms = tokenizeForSearch(s.name);
    final descTerms = tokenizeForSearch(s.description);
    var score = 0;
    for (final t in terms) {
      if (nameTerms.contains(t)) score += _kNameWeight;
      if (descTerms.contains(t)) score += _kDescWeight;
    }
    if (score == 0) continue;
    hits.add(SkillSearchHit(
      name: s.name,
      description: s.description,
      score: score,
    ));
  }

  // 同分按名字排，保证结果稳定 —— 不稳定的顺序会让测试偶发失败，也会让
  // 同一个查询在两轮里给模型不同的排序。
  hits.sort((a, b) {
    final c = b.score.compareTo(a.score);
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  return hits.take(limit).toList(growable: false);
}
