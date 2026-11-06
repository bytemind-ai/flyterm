// SPDX-License-Identifier: GPL-3.0-or-later
import 'skill.dart';

/// 把内置技能索引拼成能直接塞进 system prompt 的一段。
///
/// 返回 null 表示一条都没启用 —— 调用方据此完全跳过这一段，而不是往 prompt
/// 里塞一个空标题（与 `composeSkillIndex` / `composeInstructions` 同一约定）。
///
/// ## 为什么铁律写在这里而不是 `agent_prompt.dart`
///
/// 铁律与索引是同一件东西的两半：没有条目时铁律不能出现（它会指向一个空
/// 列表），有条目时必须出现。放在一起，两者不可能失配。
String? composeBuiltinSkillIndex(List<SkillIndexEntry> entries) {
  if (entries.isEmpty) return null;
  final buf = StringBuffer();
  buf.writeln('--- built-in skills (call `load_skill` for the full text) ---');
  for (final e in entries) {
    buf.writeln('${e.name}: ${e.description}');
  }
  buf.writeln();
  // 「不准自我说服太简单」这一句防的不是"模型不知道有技能"，而是"模型知道
  // 却觉得这次用不上" —— 后者才是实际的失败模式。
  buf.writeln('If there is even a small chance one of these applies, call '
      '`load_skill` FIRST and then follow it. Do not decide the task is too '
      'simple to need one.');
  buf.writeln();
  // 冲突边界必须写死。前半句让 `plan-change` 里的"问到清楚为止"能压过
  // 通用引导里的"能查就别问 / 每轮最多问一次"；后半句划死安全边界，否则
  // 模型有可能把"skill 优先"推广到审批环节 —— 那是 bug 不是功能。
  buf.writeln('A built-in skill overrides the general guidance above on WHEN '
      'to ask the user and how many questions per turn. It never overrides '
      'approval requirements or the rules about destructive commands.');
  return buf.toString().trimRight();
}
