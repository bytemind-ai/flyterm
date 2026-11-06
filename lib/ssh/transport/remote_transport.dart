// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Transport type identifier — for UI/debug display only.
/// Use capabilities for branching logic, not kind.
enum TransportKind { ssh, mosh, aqt, local }

/// Transport lifecycle state.
enum TransportState {
  idle,
  connecting,
  connected,
  reconnecting,
  closed,
  failed,
}

/// Capability flags. Each transport exposes the subset it supports.
enum TransportCapability {
  /// Client-side local echo prediction (mosh / aqt)
  localEchoPrediction,
  /// Network switch/roaming handling (mosh / aqt)
  roaming,
  /// Server-side scrollback replay on reconnect (aqt only)
  scrollbackReplay,
  /// File upload/download via transport's own stream (aqt only; ssh uses SFTP separately)
  fileTransfer,
  /// Reverse port forwarding (ssh only)
  reverseForward,
  /// Suspend/resume reconnect (mosh / aqt)
  suspendResume,
  /// Rich metrics: cwnd, inFlight, pending diffs, etc. (mosh / aqt)
  metricsRich,
}

/// Observable metrics snapshot. Fields unsupported by a transport return null/0.
class TransportMetrics {
  final Duration? rtt;
  final int? cwnd;
  final int? inFlight;
  final int pendingBytes;
  final int secondsSinceLastRx;
  /// Transport-specific debug fields (only DebugOverlay should consume these)
  final Map<String, Object?> extra;

  const TransportMetrics({
    this.rtt,
    this.cwnd,
    this.inFlight,
    this.pendingBytes = 0,
    this.secondsSinceLastRx = 0,
    this.extra = const {},
  });

  static const TransportMetrics empty = TransportMetrics();
}

/// File transfer handle (aqt capability: fileTransfer).
abstract class FileTransferHandle {
  int get totalBytes;
  Stream<FileTransferProgress> get progress;
  Future<void> cancel();
}

class FileTransferProgress {
  final int bytesDone;
  final int? throughputBps;
  final FileTransferState state;
  final String? errorMessage;
  const FileTransferProgress({
    required this.bytesDone,
    required this.state,
    this.throughputBps,
    this.errorMessage,
  });
}

enum FileTransferState { running, paused, completed, failed, cancelled }

/// Unified remote transport interface.
/// All concrete types (SshTransport / MoshTransport / AqtTransport / LocalTransport)
/// implement this interface.
abstract class RemoteTransport {
  TransportKind get kind;
  Set<TransportCapability> get capabilities;

  TransportState get currentState;
  Stream<TransportState> get stateStream;

  TransportMetrics get metrics;

  Stream<Uint8List> get output;
  Stream<Uint8List> get stderr;
  Future<void> get done;

  void write(Uint8List data);
  void resize(int cols, int rows);
  Future<void> close();

  void setForeground(bool active);
  void heartbeat();
  void roam();

  /// Soft reconnect: protocol-internal self-healing (path migration, heartbeat).
  /// Called by ReconnectService on short network blips before attempting hard reconnect.
  /// Returns true if the transport handled it (QUIC path migration, Mosh roam).
  /// Returns false if the protocol doesn't support soft reconnect (SSH, Local).
  Future<bool> softReconnect();

  void suppressLocalEcho();
  void suppressNextLocalEcho();

  Future<FileTransferHandle> upload(File local, String remotePath);
  Future<FileTransferHandle> download(String remotePath, File local);

  Future<void> requestScrollbackReplay(int fromOffset);
}

/// Helper: checks capability and throws UnsupportedError if missing.
/// Each transport calls this at the start of capability-gated methods.
void assertCapability(RemoteTransport t, TransportCapability cap) {
  if (!t.capabilities.contains(cap)) {
    throw UnsupportedError(
      '${t.kind.name} transport does not support $cap. '
      'Callers must check transport.capabilities.contains($cap) first.',
    );
  }
}
