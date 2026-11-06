// SPDX-License-Identifier: GPL-3.0-or-later
class MoshProcess {
  final String id;
  final String serverId;
  final String? tabId;
  final String? tmuxKey;
  final int pid;
  final int? udpPort;
  final String host;
  final int sshPort;
  final String username;
  final String? portRange;
  final String state; // starting | active | pending_kill | killed
  final DateTime createdAt;
  final DateTime updatedAt;

  const MoshProcess({
    required this.id,
    required this.serverId,
    this.tabId,
    this.tmuxKey,
    required this.pid,
    this.udpPort,
    required this.host,
    required this.sshPort,
    required this.username,
    this.portRange,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'server_id': serverId,
    'tab_id': tabId,
    'tmux_key': tmuxKey,
    'pid': pid,
    'udp_port': udpPort,
    'host': host,
    'ssh_port': sshPort,
    'username': username,
    'port_range': portRange,
    'state': state,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory MoshProcess.fromMap(Map<String, dynamic> map) => MoshProcess(
    id: map['id'] as String,
    serverId: map['server_id'] as String,
    tabId: map['tab_id'] as String?,
    tmuxKey: map['tmux_key'] as String?,
    pid: map['pid'] as int,
    udpPort: map['udp_port'] as int?,
    host: map['host'] as String,
    sshPort: map['ssh_port'] as int,
    username: map['username'] as String,
    portRange: map['port_range'] as String?,
    state: map['state'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
  );
}
