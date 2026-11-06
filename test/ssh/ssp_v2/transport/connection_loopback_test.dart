// Smoke test for MoshV2Connection: verifies the tick loop produces packets
// that decode cleanly using the same session key, and that ack-driven
// sentStates trimming works end-to-end through the UDP loopback path.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/network/nonce.dart';
import 'package:flyterm/ssh/ssp_v2/network/ocb_cipher.dart';
import 'package:flyterm/ssh/ssp_v2/network/packet.dart';
import 'package:flyterm/ssh/ssp_v2/network/udp_socket.dart';
import 'package:flyterm/ssh/ssp_v2/state_machine/transport_instruction.dart';
import 'package:flyterm/ssh/ssp_v2/transport/connection.dart';

final _zlib = ZLibCodec(level: 1);

Uint8List _wrap(TransportInstruction inst) {
  final compressed = _zlib.encode(inst.encode());
  final out = Uint8List(14 + compressed.length);
  final bd = ByteData.sublistView(out);
  bd.setUint16(0, 0, Endian.big);
  bd.setUint16(2, 0, Endian.big);
  bd.setUint64(4, 0, Endian.big);
  bd.setUint16(12, 0x8000, Endian.big);
  out.setRange(14, out.length, compressed);
  return out;
}

TransportInstruction _unwrap(Uint8List plain) {
  final compressed = Uint8List.sublistView(plain, 14);
  return TransportInstruction.decode(Uint8List.fromList(_zlib.decode(compressed)));
}

void main() {
  test('client sends decryptable packets and acks trim sentStates', () async {
    final sessionKey = Uint8List.fromList(List.generate(16, (i) => i + 1));

    // Fake mosh-server: bind a UDP socket, decrypt incoming packets, and
    // immediately echo back an ack of the most recent newNum.
    final serverSock =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverCipher = OcbCipher(sessionKey);
    final serverNonce = NonceGenerator(direction: NonceDirection.server);
    int latestSeen = 0;
    final received = <TransportInstruction>[];

    serverSock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = serverSock.receive();
      if (dg == null) return;
      try {
        final p = MoshPacket.decode(
          Uint8List.fromList(dg.data),
          cipher: serverCipher,
        );
        final inst = _unwrap(p.plaintext);
        received.add(inst);
        if (inst.newNum > latestSeen) latestSeen = inst.newNum;
        // Echo an empty diff with ack = latestSeen to advance the client.
        final reply = TransportInstruction(
          oldNum: 0,
          newNum: 0,
          ackNum: latestSeen,
          throwawayNum: 0,
        );
        final wire = MoshPacket.encode(
          nonce: serverNonce.next(),
          plaintext: _wrap(reply),
          cipher: serverCipher,
        );
        serverSock.send(wire, dg.address, dg.port);
      } catch (_) {
        // ignore malformed
      }
    });

    final clientUdp = await MoshUdpSocket.bind(
      host: '127.0.0.1',
      port: serverSock.port,
    );
    final client = MoshV2Connection(
      udp: clientUdp,
      sessionKey: sessionKey,
      installLifecycleHook: false,
    );

    // Push a few user inputs.
    client.write(Uint8List.fromList('abc'.codeUnits));
    client.write(Uint8List.fromList('def'.codeUnits));

    // Allow several tick cycles + acks to flow.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(received, isNotEmpty,
        reason: 'server should have received at least one client packet');
    expect(latestSeen, greaterThan(0),
        reason: 'newNum must advance once user input is appended');
    // After acks, sentStates should be trimmed back to the most recent state.
    expect(client.pendingStateCount, lessThanOrEqualTo(2));

    await client.close();
    serverSock.close();
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('client decodes server HostMessage and emits hoststring on hostBytes',
      () async {
    final sessionKey = Uint8List.fromList(List.generate(16, (i) => i + 2));

    final serverSock =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverCipher = OcbCipher(sessionKey);
    final serverNonce = NonceGenerator(direction: NonceDirection.server);

    // The VT bytes the fake server wants to push to the client.
    final hoststring = Uint8List.fromList('hello\r\n'.codeUnits);
    // Build a HostMessage{Instruction{HostBytes{hoststring}}} protobuf.
    // Wire format mirrors v1's encoder for client→server keystrokes; we
    // reuse its building blocks via field numbers documented in
    // hostinput.proto: HostBytes field number = 2 in the Instruction
    // extension, hoststring tag inside HostBytes = field 4.
    Uint8List buildHostMessage(Uint8List bytes) {
      // HostBytes { hoststring = bytes (field 4) }
      final hostBytes = BytesBuilder(copy: false);
      hostBytes.addByte((4 << 3) | 2); // tag: field 4, wire 2
      _writeVarint(hostBytes, bytes.length);
      hostBytes.add(bytes);
      // Instruction { hostbytes = HostBytes (field 2, extension) }
      final inst = BytesBuilder(copy: false);
      inst.addByte((2 << 3) | 2);
      _writeVarint(inst, hostBytes.length);
      inst.add(hostBytes.takeBytes());
      // HostMessage { instruction = Instruction (field 1) }
      final msg = BytesBuilder(copy: false);
      msg.addByte((1 << 3) | 2);
      _writeVarint(msg, inst.length);
      msg.add(inst.takeBytes());
      return msg.takeBytes();
    }

    bool firstReply = true;
    serverSock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = serverSock.receive();
      if (dg == null) return;
      try {
        final p = MoshPacket.decode(
          Uint8List.fromList(dg.data),
          cipher: serverCipher,
        );
        _unwrap(p.plaintext);
        // First server packet bumps newNum to 1 and carries hoststring.
        final reply = TransportInstruction(
          oldNum: 0,
          newNum: firstReply ? 1 : 0,
          ackNum: 0,
          throwawayNum: 0,
          diff: firstReply ? buildHostMessage(hoststring) : Uint8List(0),
        );
        firstReply = false;
        final wire = MoshPacket.encode(
          nonce: serverNonce.next(),
          plaintext: _wrap(reply),
          cipher: serverCipher,
        );
        serverSock.send(wire, dg.address, dg.port);
      } catch (_) {}
    });

    final clientUdp = await MoshUdpSocket.bind(
      host: '127.0.0.1',
      port: serverSock.port,
    );
    final client = MoshV2Connection(
      udp: clientUdp,
      sessionKey: sessionKey,
      installLifecycleHook: false,
    );

    // Collect everything the client surfaces on its hostBytes stream.
    final received = <int>[];
    final sub = client.hostBytes.listen(received.addAll);

    // v2 no longer sends 50pps empty heartbeats — trigger a client packet so
    // the fake server has something to reply to within the test window.
    client.write(Uint8List.fromList([0x20]));

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(received, equals(hoststring),
        reason:
            'client must decode HostMessage and emit hoststring on hostBytes');

    // write() should not emit raw bytes — it must wrap them in UserMessage.
    // Verifying by inspecting the wire is unnecessary here; the previous
    // test already confirms TransportInstruction decoding works.

    await sub.cancel();
    await client.close();
    serverSock.close();
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('client reassembles fragmented server diff (>500B)', () async {
    // Regression for the "frozen terminal on TUI refresh" bug: mosh-server
    // splits any diff >~500B across multiple UDP packets with the same
    // instrId; v2 used to drop every non-final fragment outright.
    final sessionKey = Uint8List.fromList(List.generate(16, (i) => i + 3));

    final serverSock =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverCipher = OcbCipher(sessionKey);
    final serverNonce = NonceGenerator(direction: NonceDirection.server);

    // 1200B of host bytes — guaranteed to fragment at the 14B-header + 500B
    // MTU boundary the client expects (see connection.dart fragment layout).
    final hoststring = Uint8List.fromList(List.generate(1200, (i) => 0x41 + (i % 26)));

    Uint8List buildHostMessage(Uint8List bytes) {
      final hostBytes = BytesBuilder(copy: false);
      hostBytes.addByte((4 << 3) | 2);
      _writeVarint(hostBytes, bytes.length);
      hostBytes.add(bytes);
      final inst = BytesBuilder(copy: false);
      inst.addByte((2 << 3) | 2);
      _writeVarint(inst, hostBytes.length);
      inst.add(hostBytes.takeBytes());
      final msg = BytesBuilder(copy: false);
      msg.addByte((1 << 3) | 2);
      _writeVarint(msg, inst.length);
      msg.add(inst.takeBytes());
      return msg.takeBytes();
    }

    bool sentOnce = false;
    serverSock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = serverSock.receive();
      if (dg == null) return;
      if (sentOnce) return;
      sentOnce = true;
      try {
        MoshPacket.decode(Uint8List.fromList(dg.data), cipher: serverCipher);
      } catch (_) { return; }
      // Build the inner instruction and zlib-compress it the same way the
      // client expects, then split the resulting plaintext payload across
      // two fragments sharing the same instrId.
      final inst = TransportInstruction(
        oldNum: 0,
        newNum: 1,
        ackNum: 0,
        throwawayNum: 0,
        diff: buildHostMessage(hoststring),
      );
      final compressed = _zlib.encode(inst.encode());
      // Split compressed payload into 2 fragments under the same instrId=42.
      final mid = compressed.length ~/ 2;
      final part1 = Uint8List.fromList(compressed.sublist(0, mid));
      final part2 = Uint8List.fromList(compressed.sublist(mid));

      for (var i = 0; i < 2; i++) {
        final body = i == 0 ? part1 : part2;
        final plain = Uint8List(14 + body.length);
        final bd = ByteData.sublistView(plain);
        bd.setUint16(0, 0, Endian.big);
        bd.setUint16(2, 0, Endian.big);
        bd.setUint64(4, 42, Endian.big);
        // index=0 normal, index=1 final.
        final rawIndex = i == 0 ? 0 : (1 | 0x8000);
        bd.setUint16(12, rawIndex, Endian.big);
        plain.setRange(14, plain.length, body);
        final wire = MoshPacket.encode(
          nonce: serverNonce.next(),
          plaintext: plain,
          cipher: serverCipher,
        );
        serverSock.send(wire, dg.address, dg.port);
      }
    });

    final clientUdp = await MoshUdpSocket.bind(
      host: '127.0.0.1',
      port: serverSock.port,
    );
    final client = MoshV2Connection(
      udp: clientUdp,
      sessionKey: sessionKey,
      installLifecycleHook: false,
    );

    final received = <int>[];
    final sub = client.hostBytes.listen(received.addAll);

    // Kick the server with one packet so it sends the fragmented reply.
    client.write(Uint8List.fromList([0x20]));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(received, equals(hoststring),
        reason: 'fragmented diff must be reassembled before HostMessage decode');

    await sub.cancel();
    await client.close();
    serverSock.close();
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('idle cadence: no diff -> <= ~5 packets in 500ms (was 25 at 50pps)',
      () async {
    // Regression: v2 used to run a 20ms periodic tick that sent an empty
    // diff packet every wake-up — 50pps of pure heartbeats that wasted
    // battery and crowded out real retransmits. Real mosh sends ack
    // heartbeats every 3000ms when idle.
    final sessionKey = Uint8List.fromList(List.generate(16, (i) => i + 4));

    final serverSock =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    int count = 0;
    serverSock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = serverSock.receive();
      if (dg == null) return;
      count++;
    });

    final clientUdp = await MoshUdpSocket.bind(
      host: '127.0.0.1',
      port: serverSock.port,
    );
    final client = MoshV2Connection(
      udp: clientUdp,
      sessionKey: sessionKey,
      installLifecycleHook: false,
    );

    // Strictly idle: no client.write() in this window.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(count, lessThanOrEqualTo(5),
        reason: 'idle client must not emit >5 packets in 500ms');

    await client.close();
    serverSock.close();
  }, timeout: const Timeout(Duration(seconds: 5)));
}

void _writeVarint(BytesBuilder bb, int v) {
  while (v >= 0x80) {
    bb.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  bb.addByte(v & 0x7f);
}
