// SPDX-License-Identifier: GPL-3.0-or-later
import '../../../data/models/agent_session.dart';

/// 历史会话列表的搜索过滤。
///
/// ## 为什么只搜标题
///
/// 1. `AgentSession.archive` 是整段会话的 JSON（可能几百 KB）。每敲一个字符
///    解析一遍太贵，而这个列表是每帧重建的。
/// 2. 标题是模型总结出来的，信息密度最高 —— 用户记得住的通常就是那个词。
///
/// ## 为什么不做跨库 SQL 搜索
///
/// 历史本来就只保留最近 `kSessionsPerServer` 条（见
/// `AgentSessionRepository.pruneNonStarred`）。**能被搜到的数据当前列表里
/// 全都有** —— 已删除的更搜不到。为一批不存在的数据建索引是徒劳。
///
/// ## 无标题的行
///
/// `title == null` 时**不参与匹配**。不用列表里那个显示文案（「(无标题)」）
/// 当匹配目标：那会引入一个假命中 —— 用户搜「无标题」不该搜出所有空会话。
/// 但它们仍然在没有查询词时正常显示。
List<AgentSession> filterSessions(List<AgentSession> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return [
    for (final s in all)
      if (s.title != null && s.title!.toLowerCase().contains(q)) s,
  ];
}
