// SPDX-License-Identifier: GPL-3.0-or-later
import 'skill.dart';

/// 把技能索引拼成能直接塞进 system prompt 的一段。
///
/// 返回 null 表示一条都没有 —— 调用方据此完全跳过这一段，而不是往 prompt
/// 里塞一个空标题（与 `composeInstructions` 同一约定）。
///
/// ## 只有摘要进这里，正文永远不进
///
/// 这是整个 skill 设计的核心：这一段**每一轮都随 system prompt 重发**，
/// 所以只能放每条一行的摘要。正文由 `load_skill` 取回、作为 tool result
/// 追加在对话尾部 —— 那里不破坏 prompt cache 的公共前缀，而且能被
/// `compaction` / `_dropOldestOutput` 当普通工具输出回收。
///
/// ## 排序与条数由调用方负责
///
/// 这个函数原样输出传进来的顺序，不做截断。取前 N 条是
/// `AgentSkillManager.indexEntries` 的事 —— 那里才知道 `updatedAt`。
String? composeSkillIndex(List<SkillIndexEntry> entries) {
  if (entries.isEmpty) return null;
  final buf = StringBuffer();
  buf.writeln(
      '--- your skills (call `load_skill` for the full text of one) ---');
  for (final e in entries) {
    buf.writeln('${e.name}: ${e.description}');
  }
  return buf.toString().trimRight();
}
