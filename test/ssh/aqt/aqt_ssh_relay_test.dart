import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_ssh_relay.dart';

/// An in-memory exec channel: what the relay writes to "stdin" is captured,
/// and the test pushes "stdout" bytes as the remote --relay would.
class FakeExec implements AqtRelayExec {
  final _stdin = StreamController<Uint8List>();
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();
  final written = <int>[];
  bool closed = false;

  FakeExec() {
    _stdin.stream.listen(written.addAll);
  }

  @override
  StreamSink<Uint8List> get stdin => _stdin.sink;
  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _done.future;

  void pushStdout(List<int> bytes) => _stdout.add(Uint8List.fromList(bytes));

  /// What the support probe prints before exiting.
  void answer(String text) {
    _stdout.add(Uint8List.fromList(text.codeUnits));
    _stdout.close();
  }
  void exitWithStderr(String msg) {
    _stderr.add(Uint8List.fromList(msg.codeUnits));
    _stderr.close();
    _stdout.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void close() {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

void main() {
  group('relay frames', () {
    test('encode_then_decode_roundtrip', () {
      final f = encodeRelayFrame(Uint8List.fromList([1, 2, 3]));
      expect(f, [0, 3, 1, 2, 3]);
      expect(RelayFrameDecoder().add(f), [
        [1, 2, 3]
      ]);
    });

    test('decoder_split_and_coalesced', () {
      final both = [
        ...encodeRelayFrame(Uint8List.fromList('first'.codeUnits)),
        ...encodeRelayFrame(Uint8List.fromList('second-packet'.codeUnits)),
      ];
      for (var cut = 0; cut <= both.length; cut++) {
        final d = RelayFrameDecoder();
        final got = [
          ...d.add(Uint8List.fromList(both.sublist(0, cut))),
          ...d.add(Uint8List.fromList(both.sublist(cut))),
        ].map(String.fromCharCodes).toList();
        expect(got, ['first', 'second-packet'], reason: 'cut=$cut');
      }
    });

    test('decoder_rejects_zero_length', () {
      expect(() => RelayFrameDecoder().add(Uint8List.fromList([0, 0])),
          throwsFormatException);
    });
  });

  test('attach_forwards_both_directions', () async {
    final exec = FakeExec();
    final relay = await AqtSshRelay.attach(exec);
    addTearDown(relay.close);

    final app = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(app.close);
    final fromRelay = <List<int>>[];
    app.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = app.receive();
        if (d != null) fromRelay.add(d.data);
      }
    });

    // App → relay → exec stdin, framed.
    app.send([9, 9], InternetAddress.loopbackIPv4, relay.localPort);
    await _until(() => exec.written.length >= 4);
    expect(exec.written, [0, 2, 9, 9]);

    // exec stdout (framed) → relay → App as a datagram.
    exec.pushStdout([0, 1, 7]);
    await _until(() => fromRelay.isNotEmpty);
    expect(fromRelay.single, [7]);
  });

  test('close_closes_exec_and_socket', () async {
    final exec = FakeExec();
    final relay = await AqtSshRelay.attach(exec);
    await relay.close();
    expect(exec.closed, isTrue);
    await relay.done.timeout(const Duration(seconds: 1));
  });

  test('exec_early_exit_with_stderr_throws_start_exception', () async {
    final exec = FakeExec()..exitWithStderr('not allowed');
    await expectLater(
      AqtSshRelay.startOnExec(exec),
      throwsA(isA<AqtRelayStartException>()
          .having((e) => e.stderr, 'stderr', contains('not allowed'))),
    );
  });

  group('startVia', () {
    const step = Duration(milliseconds: 50);

    test('probe_that_never_answers_times_out_and_is_closed', () async {
      final probe = FakeExec();
      await expectLater(
        AqtSshRelay.startVia((_) async => probe, daemonPort: 1, step: step),
        throwsA(isA<TimeoutException>()),
      );
      expect(probe.closed, isTrue);
    });

    test('channel_that_opens_late_is_closed', () async {
      final late = Completer<AqtRelayExec>();
      await expectLater(
        AqtSshRelay.startVia((_) => late.future, daemonPort: 1, step: step),
        throwsA(isA<TimeoutException>()),
      );
      final exec = FakeExec();
      late.complete(exec);
      await exec.done.timeout(const Duration(seconds: 1));
      expect(exec.closed, isTrue);
    });

    test('unsupported_binary_throws_and_closes_probe', () async {
      final probe = FakeExec()..answer('no\n');
      await expectLater(
        AqtSshRelay.startVia((_) async => probe, daemonPort: 1, step: step),
        throwsA(isA<AqtRelayUnsupportedException>()),
      );
      expect(probe.closed, isTrue);
    });

    test('starts_and_close_runs_onClose', () async {
      final probe = FakeExec()..answer('yes\n');
      final exec = FakeExec();
      final commands = <String>[];
      var onCloseRan = false;
      final relay = await AqtSshRelay.startVia(
        (cmd) async {
          commands.add(cmd);
          return commands.length == 1 ? probe : exec;
        },
        daemonPort: 61005,
        step: step,
        onClose: () => onCloseRan = true,
      );
      expect(commands.last, relayExecCommand(61005));
      expect(probe.closed, isTrue);
      await relay.close();
      expect(exec.closed, isTrue);
      expect(onCloseRan, isTrue);
    });
  });

  test('commands_reference_binary_and_port', () {
    expect(relayExecCommand(61005), contains('--relay 61005'));
    expect(relayExecCommand(61005), contains('flyterm-server'));
    expect(relaySupportProbeCommand(), contains("grep -q -- '--relay'"));
  });
}

Future<void> _until(bool Function() cond) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in 2s');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
