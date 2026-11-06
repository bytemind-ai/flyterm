import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/network/udp_socket.dart';

void main() {
  test('client socket sends and receives via loopback', () async {
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = <Uint8List>[];
    server.listen((e) {
      if (e == RawSocketEvent.read) {
        final dg = server.receive();
        if (dg != null) {
          got.add(Uint8List.fromList(dg.data));
          server.send(Uint8List.fromList([42]), dg.address, dg.port);
        }
      }
    });

    final client = await MoshUdpSocket.bind(host: '127.0.0.1', port: server.port);
    final replies = <Uint8List>[];
    final sub = client.incoming.listen(replies.add);
    client.send(Uint8List.fromList([1, 2, 3]));

    await Future.delayed(const Duration(milliseconds: 200));
    expect(got, hasLength(1));
    expect(got.first, Uint8List.fromList([1, 2, 3]));
    expect(replies, hasLength(1));
    expect(replies.first, Uint8List.fromList([42]));

    await sub.cancel();
    await client.close();
    server.close();
  });

  test('localPort is non-zero after bind', () async {
    final s = await MoshUdpSocket.bind(host: '127.0.0.1', port: 1);
    expect(s.localPort, greaterThan(0));
    await s.close();
  });
}
