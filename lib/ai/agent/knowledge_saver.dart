// SPDX-License-Identifier: GPL-3.0-or-later
import 'knowledge.dart';

/// 把一条候选存成 skill。
///
/// **异常原样抛出**，与提炼路径的「一律静默」相反：那边失败了用户不该知道
/// （他没要求过什么），这边是他刚点了「存入」，静默失败等于骗他。
Future<void> saveKnowledgeSkill(
  KnowledgeCandidate c, {
  required Future<void> Function(String name, String description, String body)
      saver,
}) =>
    saver(c.name, c.description, c.body);
