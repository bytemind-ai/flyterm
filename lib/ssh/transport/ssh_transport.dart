// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'remote_transport.dart';

/// Wraps dartssh2 SSHSession as RemoteTransport.
/// Capability: {reverseForward}
class SshTransport implements RemoteTransport {
  final SSHClient _client;
  final SSHSession _session;
  final StreamController<TransportState> _stateCtrl =
      StreamController.broadcast();
  TransportState _state = TransportState.connecting;

  SshTransport(this._client, this._session) {
    _setState(TransportState.connected);
    _session.done.then((_) {
      if (_state != TransportState.closed) {
        _setState(TransportState.failed);
      }
    }).catchError((_) {
      if (_state != TransportState.closed) {
        _setState(TransportState.failed);
      }
    });
  }

  void _setState(TransportState s) {
    if (_state == s) return;
    _state = s;
    _stateCtrl.add(s);
  }

  @override
  TransportKind get kind => TransportKind.ssh;

  @override
  Set<TransportCapability> get capabilities =>
      const {TransportCapability.reverseForward};

  @override
  TransportState get currentState => _state;

  @override
  Stream<TransportState> get stateStream => _stateCtrl.stream;

  @override
  TransportMetrics get metrics => TransportMetrics.empty;

  @override
  Stream<Uint8List> get output => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  Future<void> get done => _session.done;

  @override
  void write(Uint8List data) => _session.stdin.add(data);

  @override
  void resize(int cols, int rows) => _session.resizeTerminal(cols, rows);

  @override
  Future<void> close() async {
    _session.close();
    _client.close();
    _setState(TransportState.closed);
    await _stateCtrl.close();
  }

  @override
  void setForeground(bool active) {}

  @override
  void heartbeat() {}

  @override
  void roam() {}

  @override
  Future<bool> softReconnect() async => false;

  @override
  void suppressLocalEcho() =>
      assertCapability(this, TransportCapability.localEchoPrediction);

  @override
  void suppressNextLocalEcho() =>
      assertCapability(this, TransportCapability.localEchoPrediction);

  @override
  Future<FileTransferHandle> upload(File local, String remotePath) async {
    assertCapability(this, TransportCapability.fileTransfer);
    throw StateError('unreachable');
  }

  @override
  Future<FileTransferHandle> download(String remotePath, File local) async {
    assertCapability(this, TransportCapability.fileTransfer);
    throw StateError('unreachable');
  }

  @override
  Future<void> requestScrollbackReplay(int fromOffset) async {
    assertCapability(this, TransportCapability.scrollbackReplay);
  }

  /// Expose underlying SSH objects for reverse forwarding
  /// (TunnelManager casts to SshTransport to use these).
  SSHClient get sshClient => _client;
  SSHSession get sshSession => _session;
}
