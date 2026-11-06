import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/tunnel/socks5_handler.dart';

void main() {
  group('socks5Handshake', () {
    test('IPv4 target: parses host and port correctly', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;

      // Send full SOCKS5 handshake: negotiation + CONNECT IPv4 93.184.216.34:80
      clientSocket.add([
        0x05, 0x01, 0x00,                         // version, 1 method: NO AUTH
        0x05, 0x01, 0x00, 0x01,                   // ver, CONNECT, RSV, atyp=IPv4
        93, 184, 216, 34,                         // dst_addr
        0x00, 0x50,                               // dst_port = 80
      ]);

      final conn = await socks5Handshake(serverSocket);

      expect(conn.host, '93.184.216.34');
      expect(conn.port, 80);

      conn.cancel();
      await clientSocket.close();
      await server.close();
    });

    test('domain name target: parses host and port correctly', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;

      const domain = 'example.com';
      clientSocket.add([
        0x05, 0x01, 0x00,                         // negotiation
        0x05, 0x01, 0x00, 0x03,                   // CONNECT, atyp=domain
        domain.length, ...domain.codeUnits,        // domain bytes
        0x01, 0xBB,                               // dst_port = 443
      ]);

      final conn = await socks5Handshake(serverSocket);

      expect(conn.host, 'example.com');
      expect(conn.port, 443);

      conn.cancel();
      await clientSocket.close();
      await server.close();
    });

    test('invalid SOCKS version throws FormatException', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;

      clientSocket.add([0x04, 0x01, 0x00]); // SOCKS4 version

      await expectLater(
        socks5Handshake(serverSocket),
        throwsA(isA<FormatException>()),
      );

      await clientSocket.close();
      await server.close();
    });

    test('no acceptable auth method throws FormatException', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;

      clientSocket.add([0x05, 0x01, 0x02]); // only GSSAPI, not NO AUTH

      await expectLater(
        socks5Handshake(serverSocket),
        throwsA(isA<FormatException>()),
      );

      await clientSocket.close();
      await server.close();
    });

    test('IPv6 atyp parses 16 bytes into colon-separated groups', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;

      clientSocket.add([
        0x05, 0x01, 0x00,
        0x05, 0x01, 0x00, 0x04,           // atyp = IPv6
        0x20, 0x01, 0x0d, 0xb8,           // 2001:0db8:...
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0x01,                     // ...::1 (rest)
        0x00, 0x50,                        // port 80
      ]);

      final conn = await socks5Handshake(serverSocket);
      // 16-byte literal `2001:0db8:0000:0000:0000:0000:0000:0001`
      // is rendered without leading-zero compaction — Socket.connect
      // and InternetAddress accept the long form.
      expect(conn.host, '2001:db8:0:0:0:0:0:1');
      expect(conn.port, 80);
      conn.cancel();

      await clientSocket.close();
      await server.close();
    });
  });
}
