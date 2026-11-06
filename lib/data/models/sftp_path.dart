// SPDX-License-Identifier: GPL-3.0-or-later
/// 一条 SFTP 目录历史/书签。
class SftpPath {
  final String serverId;
  final String path;
  final DateTime lastUsedAt;
  final bool pinned;

  const SftpPath({
    required this.serverId,
    required this.path,
    required this.lastUsedAt,
    required this.pinned,
  });

  factory SftpPath.fromMap(Map<String, Object?> m) => SftpPath(
        serverId: m['server_id'] as String,
        path: m['path'] as String,
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(
            (m['last_used_at'] as int?) ?? 0),
        pinned: ((m['pinned'] as int?) ?? 0) != 0,
      );

  Map<String, Object?> toMap() => {
        'server_id': serverId,
        'path': path,
        'last_used_at': lastUsedAt.millisecondsSinceEpoch,
        'pinned': pinned ? 1 : 0,
      };
}
