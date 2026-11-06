// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../data/models/server.dart';
import '../data/repositories/server_repository.dart';
import '../data/secure_storage.dart';

/// Adapts [SSHForwardChannel] to the [SSHSocket] interface required by
/// [SSHClient]. Bridges stream/sink and tracks the done state.
class SshChannelTransport implements SSHSocket {
  final SSHForwardChannel _ch;
  final _doneCompleter = Completer<void>();
  late final StreamController<Uint8List> _controller;

  SshChannelTransport(this._ch) {
    _controller = StreamController<Uint8List>(onCancel: close);
    _ch.stream.listen(
      _controller.add,
      onError: _controller.addError,
      onDone: () {
        _controller.close();
        if (!_doneCompleter.isCompleted) _doneCompleter.complete();
      },
      cancelOnError: false,
    );
  }

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  StreamSink<List<int>> get sink => _ch.sink;

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> close() async {
    if (!_controller.isClosed) _controller.close();
    await _ch.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  @override
  void destroy() {
    if (!_controller.isClosed) _controller.close();
    _ch.destroy();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

/// Resolved credentials for a jump host server.
class JumpHostParams {
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPem;

  const JumpHostParams({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPem,
  });
}

/// Resolves jump host credentials for [server].
///
/// Returns [JumpHostParams] when [server.jumpHostId] references an existing
/// server record; returns `null` when jump is not configured or the referenced
/// server no longer exists (caller falls back to direct connection).
Future<JumpHostParams?> resolveJumpParams(
  Server server,
  ServerRepository serverRepo,
  SecureStorageService storage,
) async {
  final jumpHostId = server.jumpHostId;
  if (jumpHostId == null) return null;

  final jump = await serverRepo.findById(jumpHostId);
  if (jump == null) return null; // stale reference — degrade gracefully

  String? password;
  String? privateKeyPem;
  if (jump.authType == 'password') {
    password = await storage.loadPassword(jump.id);
  } else if (jump.authType == 'key' && jump.keyId != null) {
    privateKeyPem = await storage.loadPrivateKey(jump.keyId!);
  }

  return JumpHostParams(
    host: jump.host,
    port: jump.port,
    username: jump.username,
    password: password,
    privateKeyPem: privateKeyPem,
  );
}
