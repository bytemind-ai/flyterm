// SPDX-License-Identifier: GPL-3.0-or-later
/// 一段已归档的 agent 会话。
///
/// [archive] 是 `AgentLoop.toArchive()` 的 JSON 字符串，**原样存取、不解析**。
/// 这个类只负责行的读写，不认识里面的事件结构 —— 归档格式的演进由
/// `agentEventsFromJson` 的「未识别类型跳过」策略兜住，与存储层无关。
class AgentSession {
  /// null = 还没写进库。
  final int? id;

  final String serverId;

  /// 列表显示用。null = 这段会话没有可用标题。
  final String? title;

  final String archive;

  /// 归档时的事件数。纯展示，让用户判断「这段有多长」。
  final int eventCount;

  final bool starred;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AgentSession({
    this.id,
    required this.serverId,
    this.title,
    required this.archive,
    required this.eventCount,
    this.starred = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'server_id': serverId,
        'title': title,
        'archive': archive,
        'event_count': eventCount,
        'starred': starred ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static AgentSession fromMap(Map<String, Object?> m) => AgentSession(
        id: m['id'] as int?,
        serverId: m['server_id'] as String,
        title: m['title'] as String?,
        archive: m['archive'] as String,
        eventCount: (m['event_count'] as int?) ?? 0,
        starred: (m['starred'] as int? ?? 0) != 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (m['created_at'] as int?) ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (m['updated_at'] as int?) ?? 0),
      );
}
