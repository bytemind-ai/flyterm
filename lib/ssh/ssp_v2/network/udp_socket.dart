// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::Connection::recv / Connection::send in src/network/network.cc
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class MoshUdpSocket {
  final RawDatagramSocket _sock;
  final InternetAddress _peerAddr;
  final int _peerPort;
  final _incomingCtrl = StreamController<Uint8List>.broadcast();

  MoshUdpSocket._(this._sock, this._peerAddr, this._peerPort) {
    _sock.listen(_onEvent);
  }

  static Future<MoshUdpSocket> bind({
    required String host,
    required int port,
    int localPort = 0,
  }) async {
    final addr = (await InternetAddress.lookup(host)).first;
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, localPort);
    return MoshUdpSocket._(sock, addr, port);
  }

  /// Bind using an already-resolved [InternetAddress] — skips DNS lookup.
  /// Prefer this over [bind] when the peer address is already known (roaming).
  static Future<MoshUdpSocket> bindAddress({
    required InternetAddress addr,
    required int port,
  }) async {
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    return MoshUdpSocket._(sock, addr, port);
  }

  Stream<Uint8List> get incoming => _incomingCtrl.stream;
  int get localPort => _sock.port;
  InternetAddress get peerAddress => _peerAddr;
  int get peerPort => _peerPort;

  void send(Uint8List bytes) => _sock.send(bytes, _peerAddr, _peerPort);

  Future<void> close() async {
    _sock.close();
    await _incomingCtrl.close();
  }

  void _onEvent(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final dg = _sock.receive();
    if (dg == null) return;
    _incomingCtrl.add(Uint8List.fromList(dg.data));
  }
}
