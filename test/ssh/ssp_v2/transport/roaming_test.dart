import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/network/udp_socket.dart';
import 'package:flyterm/ssh/ssp_v2/transport/roaming.dart';

void main() {
  test('roam binds a new ephemeral source port', () async {
    // Bind a placeholder server socket so peerPort is reachable on this host.
    final server =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final init =
        await MoshUdpSocket.bind(host: '127.0.0.1', port: server.port);
    final r = Roamer(
      peerAddr: InternetAddress.loopbackIPv4,
      peerPort: server.port,
      initial: init,
    );
    final p1 = r.socket.localPort;
    await r.roam();
    final p2 = r.socket.localPort;
    expect(p1, isNot(equals(p2)));
    await r.socket.close();
    server.close();
  });
}
