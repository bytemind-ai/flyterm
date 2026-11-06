// SPDX-License-Identifier: GPL-3.0-or-later
/// 一台机器的 agent 笔记。
///
/// 与 `AgentSkill` 的分工：skill 是**跨机可复用的套路**，这个是**单台机器
/// 的事实**（它用 podman 不用 docker、日志在 /data）。两者都在 app 端落库，
/// 但索引方式完全不同 —— skill 靠 name 匹配按需加载，笔记按当前会话的
/// serverId 每轮无条件进 prompt。
class ServerNote {
  final String serverId;
  final String body;
  final DateTime updatedAt;

  const ServerNote({
    required this.serverId,
    required this.body,
    required this.updatedAt,
  });
}
