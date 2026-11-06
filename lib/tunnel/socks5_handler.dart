// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

/// Result of a completed SOCKS5 server-side handshake.
/// [host] and [port] are the target the client wants to reach.
/// Call [pipeSocketTo] to forward remaining buffered bytes and future socket
/// data to the SSH channel sink. Call [cancel] on error before piping.
class Socks5Connection {
  final String host;
  final int port;
  final _Socks5Reader _reader;

  Socks5Connection._(this.host, this.port, this._reader);

  /// Forward socket data (buffered + future) to [sink].
  /// After this call, the [sink] owns the socket data stream.
  void pipeSocketTo(StreamSink<List<int>> sink) => _reader.forwardTo(sink);

  /// Cancel the socket subscription. Call on error, before piping.
  void cancel() => _reader.cancel();
}

/// Performs a SOCKS5 server-side handshake on [socket] (RFC 1928).
///
/// Supported:
///   - Auth method: NO AUTH (0x00) only
///   - Address type: IPv4 (0x01), IPv6 (0x04), and domain name (0x03)
///
/// Any protocol violation throws [FormatException]; the caller is
/// expected to close the socket on error.
///
/// Returns a [Socks5Connection] after sending the success reply.
/// The caller should then call [Socks5Connection.pipeSocketTo] to forward
/// data to the SSH channel, and listen to the channel stream back to the socket.
Future<Socks5Connection> socks5Handshake(Socket socket) async {
  final reader = _Socks5Reader(socket);
  try {
    // Step 1: version negotiation
    final ver = await reader.readByte();
    if (ver != 5) throw FormatException('Not SOCKS5 (version byte: $ver)');

    final nMethods = await reader.readByte();
    final methods = await reader.readN(nMethods);
    if (!methods.contains(0x00)) {
      socket.add([0x05, 0xFF]); // no acceptable method
      throw const FormatException('No acceptable auth method (NO AUTH required)');
    }
    socket.add([0x05, 0x00]); // select NO AUTH

    // Step 2: CONNECT request
    final ver2 = await reader.readByte();
    if (ver2 != 5) throw const FormatException('Bad SOCKS5 request version');
    final cmd = await reader.readByte();
    if (cmd != 0x01) {
      throw FormatException('Only CONNECT (0x01) supported, got $cmd');
    }
    await reader.readByte(); // RSV — reserved, ignored

    final atyp = await reader.readByte();
    final String host;
    switch (atyp) {
      case 0x01: // IPv4
        final b = await reader.readN(4);
        host = '${b[0]}.${b[1]}.${b[2]}.${b[3]}';
        break;
      case 0x03: // domain name
        final len = await reader.readByte();
        final domainBytes = await reader.readN(len);
        host = String.fromCharCodes(domainBytes);
        break;
      case 0x04: // IPv6 — 16 bytes, formatted as 8 colon-separated groups
        final b = await reader.readN(16);
        final groups = <String>[];
        for (int i = 0; i < 16; i += 2) {
          groups.add(((b[i] << 8) | b[i + 1]).toRadixString(16));
        }
        host = groups.join(':');
        break;
      default:
        throw FormatException('Unknown SOCKS5 address type: $atyp');
    }

    final portBytes = await reader.readN(2);
    final port = (portBytes[0] << 8) | portBytes[1];

    // Success reply: VER REP RSV ATYP BND.ADDR BND.PORT
    // BND.ADDR = 0.0.0.0, BND.PORT = 0 (we don't bind a specific address)
    socket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

    return Socks5Connection._(host, port, reader);
  } catch (_) {
    reader.cancel();
    rethrow;
  }
}

/// Buffers incoming [Socket] data byte-by-byte during the handshake.
/// Uses a single [StreamSubscription] that can be repurposed for forwarding
/// after the handshake completes, preserving any already-received bytes.
class _Socks5Reader {
  final List<int> _buf = [];
  Completer<void>? _waiter;
  bool _done = false;
  Object? _doneError;
  late final StreamSubscription<List<int>> _sub;

  _Socks5Reader(Socket socket) {
    _sub = socket.listen(
      (data) {
        _buf.addAll(data);
        final w = _waiter;
        if (w != null && !w.isCompleted) {
          _waiter = null;
          w.complete();
        }
      },
      onError: (Object e) {
        _doneError = e;
        _done = true;
        final w = _waiter;
        if (w != null && !w.isCompleted) {
          _waiter = null;
          w.completeError(e);
        }
      },
      onDone: () {
        _done = true;
        final w = _waiter;
        if (w != null && !w.isCompleted) {
          _waiter = null;
          w.completeError(
            const SocketException('Socket closed during SOCKS5 handshake'),
          );
        }
      },
      cancelOnError: false,
    );
  }

  Future<int> readByte() async {
    while (_buf.isEmpty) {
      if (_done) throw _doneError ?? const SocketException('Connection closed');
      assert(_waiter == null, 'Concurrent reads on _Socks5Reader are not supported');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    return _buf.removeAt(0);
  }

  Future<List<int>> readN(int n) async {
    while (_buf.length < n) {
      if (_done) throw _doneError ?? const SocketException('Connection closed');
      assert(_waiter == null, 'Concurrent reads on _Socks5Reader are not supported');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  /// Flush any buffered bytes to [sink], then reroute future socket data
  /// directly to [sink]. The subscription stays active — only its callbacks
  /// are replaced. This ensures no bytes are lost between handshake completion
  /// and data forwarding.
  void forwardTo(StreamSink<List<int>> sink) {
    if (_buf.isNotEmpty) {
      sink.add(List<int>.from(_buf));
      _buf.clear();
    }
    _sub.onData((data) => sink.add(data));
    _sub.onDone(() => sink.close());
    _sub.onError((Object e, StackTrace st) => sink.addError(e, st));
  }

  void cancel() => _sub.cancel();
}
