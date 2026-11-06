// Integration test against the real mosh-server binary on the host.
//
// What it proves end-to-end:
//   * v2 wire layout (8-byte nonce, OCB tag, zlib-wrapped Instruction)
//     is byte-for-byte compatible with reference mosh-server 1.4.0.
//   * v2 protobuf framing (UserMessage out, HostMessage in) matches.
//   * The client receives the welcome banner the spawned child emits
//     on stdout.
//
// Skipped automatically if `mosh-server` is not on PATH (CI image).
//
// Run with:
//   flutter test --platform vm \
//     test/ssh/ssp_v2/integration/real_mosh_server_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/network/udp_socket.dart';
import 'package:flyterm/ssh/ssp_v2/transport/connection.dart';

void main() {
  final moshServer = _findMoshServer();
  if (moshServer == null) {
    test('mosh-server not installed — integration test skipped', () {});
    return;
  }

  test('v2 client talks to real mosh-server and receives welcome bytes',
      () async {
    // Long-running child so the server stays alive while we drive the
    // handshake. The child prints a unique sentinel we then look for in
    // the client's hostBytes stream.
    final sentinel = 'FLYTERM_V2_HELLO_${DateTime.now().microsecondsSinceEpoch}';
    final spawn = await Process.run(
      moshServer,
      [
        'new',
        '-i',
        '127.0.0.1',
        '--',
        '/bin/sh',
        '-c',
        'echo "$sentinel"; sleep 5',
      ],
      stdoutEncoding: utf8,
    );
    expect(spawn.exitCode, 0,
        reason: 'mosh-server failed to start: ${spawn.stderr}');

    final line = (spawn.stdout as String)
        .split('\n')
        .firstWhere((l) => l.startsWith('MOSH CONNECT '),
            orElse: () => '');
    expect(line, isNotEmpty,
        reason: 'no MOSH CONNECT line; got: ${spawn.stdout}');
    final parts = line.split(' ');
    final port = int.parse(parts[2]);
    final keyB64 = parts[3];
    // mosh prints key without trailing '=' padding; restore it for base64.
    final padded = keyB64 + '=' * ((4 - keyB64.length % 4) % 4);
    final sessionKey = Uint8List.fromList(base64.decode(padded));
    expect(sessionKey.length, 16);

    final udp = await MoshUdpSocket.bind(host: '127.0.0.1', port: port);
    final client = MoshV2Connection(
      udp: udp,
      sessionKey: sessionKey,
      installLifecycleHook: false,
    );

    final hostBuf = <int>[];
    final sub = client.hostBytes.listen(hostBuf.addAll);

    // Send a resize so mosh-server initialises the terminal.
    client.resize(80, 24);
    // mosh-server emits the welcome banner once the first authenticated
    // client packet completes the handshake. Give it ~2 s of tick cycles.
    final ok = await _waitFor(
      () => utf8.decode(hostBuf, allowMalformed: true).contains(sentinel),
      const Duration(seconds: 4),
    );

    await sub.cancel();
    await client.close();

    expect(ok, isTrue,
        reason:
            'sentinel "$sentinel" not seen in hostBytes after 4 s; got: '
            '${utf8.decode(hostBuf, allowMalformed: true)}');
  }, timeout: const Timeout(Duration(seconds: 15)));
}

String? _findMoshServer() {
  for (final p in const ['/usr/bin/mosh-server', '/usr/local/bin/mosh-server']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

Future<bool> _waitFor(bool Function() pred, Duration max) async {
  final deadline = DateTime.now().add(max);
  while (DateTime.now().isBefore(deadline)) {
    if (pred()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return pred();
}
