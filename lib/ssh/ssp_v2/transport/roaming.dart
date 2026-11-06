// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors the roaming path in mosh::Connection in src/network/network.cc:
// when the OS source-port mapping is broken (NAT timeout, network change,
// suspend/resume), the client rebinds to a fresh ephemeral port. The mosh
// server already accepts packets from any source address as long as the
// OCB tag authenticates, so the rebind is invisible to the protocol layer.
import 'dart:io' show InternetAddress;
import '../network/udp_socket.dart';

class Roamer {
  // Store the already-resolved InternetAddress rather than a hostname string
  // to avoid InternetAddress.lookup() on every roam — on some Android/VPN
  // configurations DNS lookup blocks until a system timeout even for IP strings.
  final InternetAddress _peerAddr;
  final int peerPort;
  MoshUdpSocket _current;

  Roamer({
    required InternetAddress peerAddr,
    required this.peerPort,
    required MoshUdpSocket initial,
  }) : _peerAddr = peerAddr,
       _current = initial;

  MoshUdpSocket get socket => _current;

  Future<void> roam() async {
    final old = _current;
    _current = await MoshUdpSocket.bindAddress(addr: _peerAddr, port: peerPort);
    await old.close();
  }
}
