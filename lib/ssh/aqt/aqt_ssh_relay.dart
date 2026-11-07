// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// QUIC over an SSH channel, App side.
///
/// When UDP to the daemon is blocked (only port 22 open, or the phone's
/// network drops UDP), the QUIC client still connects to a UDP port — this
/// one, on 127.0.0.1 — and every datagram is forwarded through an SSH exec
/// channel running `flyterm-server --relay <daemonPort>`, which hands it to
/// the daemon. Each packet travels as one frame, `u16 big-endian length +
/// bytes` (same format as the server's `relay.rs`).
///
/// Nothing above the UDP socket changes: TLS/SPKI pinning, streams, RESUME
/// and Notify run end to end through the tunnel. The cost is QUIC over TCP
/// (head-of-line blocking on lossy links) and, after a network change, a new
/// SSH connection + RESUME instead of QUIC connection migration.

/// Largest packet one frame can carry (the u16 length field).
const int kMaxRelayPacket = 65535;

Uint8List encodeRelayFrame(Uint8List packet) {
  assert(packet.isNotEmpty && packet.length <= kMaxRelayPacket);
  final out = Uint8List(2 + packet.length);
  out[0] = packet.length >> 8;
  out[1] = packet.length & 0xff;
  out.setRange(2, out.length, packet);
  return out;
}

/// Reassembles frames from arbitrarily split / coalesced chunks. Throws
/// [FormatException] on a zero-length frame.
class RelayFrameDecoder {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  List<Uint8List> add(Uint8List chunk) {
    _buf
      ..add(_pending)
      ..add(chunk);
    final data = _buf.takeBytes();
    final out = <Uint8List>[];
    var at = 0;
    while (data.length - at >= 2) {
      final len = (data[at] << 8) | data[at + 1];
      if (len == 0) throw const FormatException('zero-length relay frame');
      if (data.length - at - 2 < len) break;
      out.add(Uint8List.sublistView(data, at + 2, at + 2 + len));
      at += 2 + len;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(data, at));
    return out;
  }
}

/// The exec channel the relay talks through. [SshSessionRelayExec] is the
/// real one; tests inject an in-memory implementation.
abstract class AqtRelayExec {
  StreamSink<Uint8List> get stdin;
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;
  void close();
}

class SshSessionRelayExec implements AqtRelayExec {
  final SSHSession _session;
  SshSessionRelayExec(this._session);

  @override
  StreamSink<Uint8List> get stdin => _session.stdin;
  @override
  Stream<Uint8List> get stdout => _session.stdout;
  @override
  Stream<Uint8List> get stderr => _session.stderr;
  @override
  Future<void> get done => _session.done;
  @override
  void close() => _session.close();
}

/// The remote binary does not know `--relay` (older than flyterm-server
/// 0.4.0, and the upgrade did not happen).
class AqtRelayUnsupportedException implements Exception {
  const AqtRelayUnsupportedException();
  @override
  String toString() => 'AqtRelayUnsupportedException: flyterm-server has no --relay';
}

/// The relay process exited right away (e.g. a `ForceCommand` restriction).
class AqtRelayStartException implements Exception {
  final String stderr;
  const AqtRelayStartException(this.stderr);
  @override
  String toString() => 'AqtRelayStartException: $stderr';
}

const String _bin = r'BIN="$HOME/.flyterm-server/bin/flyterm-server"; '
    r'[ -x "$BIN" ] || BIN=/usr/local/bin/flyterm-server; ';

/// Prints `yes` if the remote binary supports `--relay`, `no` otherwise.
String relaySupportProbeCommand() =>
    '$_bin"\$BIN" --help 2>&1 | grep -q -- \'--relay\' && echo yes || echo no';

/// Runs the relay towards the daemon on [daemonPort]. `exec` so the relay
/// is the channel's own process: closing the channel closes its stdin.
String relayExecCommand(int daemonPort) =>
    '${_bin}exec "\$BIN" --relay $daemonPort';

class AqtSshRelay {
  final AqtRelayExec _exec;
  final RawDatagramSocket _socket;
  final RelayFrameDecoder _decoder = RelayFrameDecoder();
  final Completer<void> _done = Completer<void>();
  SSHClient? _ownedClient;
  InternetAddress? _appAddress;
  int? _appPort;
  StreamSubscription<RawSocketEvent>? _socketSub;
  StreamSubscription<Uint8List>? _stdoutSub;

  AqtSshRelay._(this._exec, this._socket);

  /// The local UDP port the QUIC client should connect to (on 127.0.0.1).
  int get localPort => _socket.port;

  /// Completes once the relay is closed — by [close] or because the exec
  /// channel ended (SSH connection lost, remote relay exited).
  Future<void> get done => _done.future;

  /// Opens the relay over [client] towards the daemon on [daemonPort].
  /// With [ownsClient], [close] also closes [client] (a connection opened
  /// just for this relay).
  static Future<AqtSshRelay> start(
    SSHClient client, {
    required int daemonPort,
    bool ownsClient = false,
  }) async {
    final probe = await client.execute(relaySupportProbeCommand());
    final answer = await probe.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5));
    probe.close();
    if (answer.trim() != 'yes') throw const AqtRelayUnsupportedException();
    final session = await client.execute(relayExecCommand(daemonPort));
    final relay = await startOnExec(SshSessionRelayExec(session));
    if (ownsClient) relay._ownedClient = client;
    return relay;
  }

  /// [start] after the exec channel is open: if the relay process exits
  /// within [earlyExitWindow] it never started (e.g. `ForceCommand`), and
  /// its stderr is surfaced instead of a QUIC timeout 8 s later.
  @visibleForTesting
  static Future<AqtSshRelay> startOnExec(
    AqtRelayExec exec, {
    Duration earlyExitWindow = const Duration(milliseconds: 300),
  }) async {
    final stderr = StringBuffer();
    final stderrSub = exec.stderr
        .listen((b) => stderr.write(utf8.decode(b, allowMalformed: true)));
    final exitedEarly = await Future.any([
      exec.done.then((_) => true),
      Future<bool>.delayed(earlyExitWindow, () => false),
    ]);
    if (exitedEarly) {
      // stderr may still be in flight when `done` fires; let it drain.
      await stderrSub
          .asFuture<void>()
          .timeout(const Duration(milliseconds: 200), onTimeout: () {});
      await stderrSub.cancel();
      exec.close();
      throw AqtRelayStartException(stderr.toString().trim());
    }
    await stderrSub.cancel();
    return attach(exec);
  }

  /// Binds the local UDP socket and starts forwarding in both directions.
  @visibleForTesting
  static Future<AqtSshRelay> attach(AqtRelayExec exec) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = AqtSshRelay._(exec, socket);
    relay._socketSub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null || dg.data.isEmpty) return;
      // The QUIC client is the only sender; remember where to reply.
      relay._appAddress = dg.address;
      relay._appPort = dg.port;
      exec.stdin.add(encodeRelayFrame(dg.data));
    });
    relay._stdoutSub = exec.stdout.listen(
      (chunk) {
        final List<Uint8List> packets;
        try {
          packets = relay._decoder.add(chunk);
        } on FormatException {
          relay.close();
          return;
        }
        final to = relay._appAddress;
        final port = relay._appPort;
        if (to == null || port == null) return;
        for (final p in packets) {
          socket.send(p, to, port);
        }
      },
      onDone: relay.close,
      onError: (Object _) => relay.close(),
    );
    exec.done.then((_) => relay.close());
    return relay;
  }

  /// Closes the exec channel and the UDP socket. Safe to call repeatedly.
  Future<void> close() async {
    if (_done.isCompleted) return;
    _done.complete();
    await _socketSub?.cancel();
    await _stdoutSub?.cancel();
    _socket.close();
    _exec.close();
    _ownedClient?.close();
    _ownedClient = null;
  }
}
