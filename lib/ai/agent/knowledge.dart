// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'agent_instructions.dart' show clipToBytes;
import 'skill.dart';

/// 一条候选知识该存到哪。
///
/// 只有两个去向。用户偏好（「回答简短点」）两边都不属于——它归 app 设置，
/// 模型写不了，`agent_prompt.dart` 里那段三选一已经把这条讲清楚了。
enum KnowledgeTarget {
  /// 跨机可复用的**套路**，进 `agent_skills`。
  skill,

  /// 单台机器的**事实**，进那台机器的 `server_notes` 行。
  serverNote,
}

/// 提炼出来的一条候选，等用户在卡片上拍板。
class KnowledgeCandidate {
  final KnowledgeTarget target;

  /// skill 的匹配名；[KnowledgeTarget.serverNote] 时用作正文的小标题。
  final String name;

  /// 只对 skill 有意义（它是索引里那一行）。serverNote 时为空串。
  final String description;

  final String body;

  /// 命中的已有 skill 原名。非 null 时卡片显示「更新 xxx」而不是「存入」。
  ///
  /// **由解析阶段比对索引算出，不是模型自己声明的字段** —— 让模型声明
  /// 「我要更新哪条」等于把撞名的准确性交给它，而这正是要修的问题。
  final String? updatesExisting;

  const KnowledgeCandidate({
    required this.target,
    required this.name,
    required this.description,
    required this.body,
    this.updatesExisting,
  });

  KnowledgeCandidate copyWith({KnowledgeTarget? target}) => KnowledgeCandidate(
        target: target ?? this.target,
        name: name,
        description: description,
        body: body,
        updatesExisting: updatesExisting,
      );
}

/// 剥掉模型有时会加的 markdown 代码围栏。
///
/// 小模型（尤其 Ollama 上那些）经常无视「只输出 JSON」的指示包一层围栏。
/// 为这一种极其常见的偏差写三行，比让整次提炼白花掉划算。
String _stripFence(String s) {
  var t = s.trim();
  if (!t.startsWith('```')) return t;
  final firstNewline = t.indexOf('\n');
  if (firstNewline < 0) return t;
  t = t.substring(firstNewline + 1);
  final lastFence = t.lastIndexOf('```');
  return (lastFence < 0 ? t : t.substring(0, lastFence)).trim();
}

/// 单行裸截断，不加标记 —— 与 `parseSkillMarkdown` 里的 `_clipLine` 同理由：
/// description 是**一行**，末尾挂标记会把它撑得更长。
String _clipLine(String s, int maxBytes) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return s;
  return utf8
      .decode(bytes.sublist(0, maxBytes), allowMalformed: true)
      .replaceAll('\u{FFFD}', '');
}

/// 解析提炼调用的返回。
///
/// **任何异常都不向外抛**：这是锦上添花的功能，一次解析失败应当表现为
/// 「这次没有提议」，而不是给用户弹一个他无法理解也无需处理的错误。
///
/// [existingSkillNames] 用来回填 [KnowledgeCandidate.updatesExisting]。
List<KnowledgeCandidate> parseDistillCandidates(
  String raw, {
  required List<String> existingSkillNames,
}) {
  final text = _stripFence(raw);
  if (text.isEmpty) return const [];

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];

  final byName = {
    for (final n in existingSkillNames) n.toLowerCase(): n,
  };

  final out = <KnowledgeCandidate>[];
  final seenTargets = <KnowledgeTarget>{};

  for (final item in decoded) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();

    final target = switch (j['target']) {
      'skill' => KnowledgeTarget.skill,
      'server_note' => KnowledgeTarget.serverNote,
      _ => null,
    };
    if (target == null) continue;
    // 每个去向至多一条。多的丢弃而不是全收：一次排查产出三条 skill 说明
    // 模型在拆得过细，收下来只会更快撑爆索引。
    if (!seenTargets.add(target)) continue;

    final name = (j['name'] as String? ?? '').trim();
    final body = (j['body'] as String? ?? '').trim();
    // 正文为空的不是知识；skill 没有 name 就没法被 load_skill 匹配。
    if (body.isEmpty) continue;
    if (target == KnowledgeTarget.skill && name.isEmpty) continue;

    out.add(KnowledgeCandidate(
      target: target,
      name: name,
      description: target == KnowledgeTarget.skill
          ? _clipLine((j['description'] as String? ?? '').trim(),
              kMaxSkillDescriptionBytes)
          : '',
      body: clipToBytes(body, kMaxSkillBodyBytes),
      updatesExisting:
          target == KnowledgeTarget.skill ? byName[name.toLowerCase()] : null,
    ));
  }
  return out;
}

/// 喂给提炼调用的全部素材。
///
/// **刻意不含命令输出** —— 那是整个会话里最贵的部分，且对提炼几乎无用：
/// 提炼要的是「做了什么、结论是什么」，不是 `systemctl status` 的 80 行
/// 原文。一次典型排查压下来几百 token。
class KnowledgeDistillInput {
  /// 用户的第一句话。
  final String userGoal;

  /// 每次成功调用的 `description :: displayCommand`，无输出。
  final List<String> actions;

  /// 模型的最终结论。
  final String conclusion;

  /// 当前索引里的技能，用于防重（重叠时让模型返回原名走更新）。
  final List<SkillIndexEntry> existingSkills;

  /// 本机笔记现有内容。null = 这台机器还没有笔记。
  final String? currentMachineNotes;

  /// 本机笔记还能再写多少字节。已超额时为 0，不为负。
  final int machineNotesRemainingBytes;

  const KnowledgeDistillInput({
    required this.userGoal,
    required this.actions,
    required this.conclusion,
    required this.existingSkills,
    required this.currentMachineNotes,
    required this.machineNotesRemainingBytes,
  });
}
