// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../local_shell.dart';
import 'remote_transport.dart';

class LocalTransport implements RemoteTransport {
  final LocalShell _shell;
  final StreamController<TransportState> _stateCtrl =
      StreamController.broadcast();
  final Completer<void> _done = Completer();
  TransportState _state = TransportState.idle;

  LocalTransport(this._shell) {
    _shell.onDead = () {
      if (_state != TransportState.closed) {
        _setState(TransportState.failed);
        if (!_done.isCompleted) _done.complete();
      }
    };
    _setState(TransportState.connected);
  }

  void _setState(TransportState s) {
    if (_state == s) return;
    _state = s;
    _stateCtrl.add(s);
  }

  @override
  TransportKind get kind => TransportKind.local;

  @override
  Set<TransportCapability> get capabilities => const {};

  @override
  TransportState get currentState => _state;

  @override
  Stream<TransportState> get stateStream => _stateCtrl.stream;

  @override
  TransportMetrics get metrics => TransportMetrics.empty;

  @override
  Stream<Uint8List> get output => _shell.stdout;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) => _shell.write(String.fromCharCodes(data));

  @override
  void resize(int cols, int rows) => _shell.resizeTerminal(cols, rows);

  @override
  Future<void> close() async {
    _shell.close();
    _setState(TransportState.closed);
    if (!_done.isCompleted) _done.complete();
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
}
