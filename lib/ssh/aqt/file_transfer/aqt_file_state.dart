// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

enum AqtFileMode { upload, download, uploadResume, downloadResume }
enum AqtFileStatus { pending, running, paused, completed, failed }

class AqtFileTransferState {
  final int? id;
  final int serverId;
  final int requestId;
  final AqtFileMode mode;
  final String localPath;
  final String remotePath;
  final int totalSize;
  final int bytesDone;
  final Uint8List sha256Full;
  final AqtFileStatus status;
  final DateTime updatedAt;

  const AqtFileTransferState({
    this.id,
    required this.serverId,
    required this.requestId,
    required this.mode,
    required this.localPath,
    required this.remotePath,
    required this.totalSize,
    required this.bytesDone,
    required this.sha256Full,
    required this.status,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'server_id': serverId,
    'request_id': requestId,
    'mode': mode.index + 1,
    'local_path': localPath,
    'remote_path': remotePath,
    'total_size': totalSize,
    'bytes_done': bytesDone,
    'sha256_full': sha256Full,
    'status': status.index,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory AqtFileTransferState.fromMap(Map<String, Object?> m) =>
      AqtFileTransferState(
        id: m['id'] as int?,
        serverId: m['server_id'] as int,
        requestId: m['request_id'] as int,
        mode: AqtFileMode.values[(m['mode'] as int) - 1],
        localPath: m['local_path'] as String,
        remotePath: m['remote_path'] as String,
        totalSize: m['total_size'] as int,
        bytesDone: m['bytes_done'] as int,
        sha256Full: m['sha256_full'] as Uint8List,
        status: AqtFileStatus.values[m['status'] as int],
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );

  AqtFileTransferState copyWith({
    int? bytesDone,
    AqtFileStatus? status,
    DateTime? updatedAt,
  }) =>
      AqtFileTransferState(
        id: id,
        serverId: serverId,
        requestId: requestId,
        mode: mode,
        localPath: localPath,
        remotePath: remotePath,
        totalSize: totalSize,
        sha256Full: sha256Full,
        bytesDone: bytesDone ?? this.bytesDone,
        status: status ?? this.status,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
