import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_route.dart';
import 'package:flyterm/ssh/aqt/aqt_ssh_relay.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';

class _Exec implements AqtRelayExec {
  final _in = StreamController<Uint8List>();
  final _out = StreamController<Uint8List>();
  final _err = StreamController<Uint8List>();
  final _done = Completer<void>();
  _Exec() {
    _in.stream.listen((_) {});
  }
  @override
  StreamSink<Uint8List> get stdin => _in.sink;
  @override
  Stream<Uint8List> get stdout => _out.stream;
  @override
  Stream<Uint8List> get stderr => _err.stream;
  @override
  Future<void> get done => _done.future;
  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}

void main() {
  test('replaceRelay returns the previous relay and sets route', () async {
    final r1 = await AqtSshRelay.attach(_Exec());
    addTearDown(r1.close);
    final t = AqtTransport.testStub(port: r1.localPort);
    t.attachRelay(route: AqtRoute.viaSsh, relay: r1, daemonPort: 61005);

    final old = t.replaceRelay(AqtRoute.direct, null);

    expect(identical(old, r1), isTrue);
    expect(t.route, AqtRoute.direct);
    expect(t.lastPort, 61005);
    var closed = false;
    unawaited(r1.done.then((_) => closed = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse, reason: 'replaceRelay must not close the old relay');
  });

  test('setPath uses the injected impl', () {
    String? gotIp;
    int? gotPort;
    final t = AqtTransport.testStub(
      port: 1,
      setPathImpl: (ip, port) {
        gotIp = ip;
        gotPort = port;
        return true;
      },
    );
    expect(t.setPath('127.0.0.1', 61005), isTrue);
    expect([gotIp, gotPort], ['127.0.0.1', 61005]);
  });

  test('probeDirect polls probeImpl until a verdict', () async {
    var polls = 0;
    final t = AqtTransport.testStub(
      port: 1,
      spki: Uint8List(32),
      probeImpl: (ip, port, spki, timeoutMs) => () => ++polls < 3 ? -1 : 1,
    );
    expect(await t.probeDirect('10.0.0.1', 61005), isTrue);
    expect(polls, 3);
  });

  test('probeDirect false on unreachable and on missing spki', () async {
    final t = AqtTransport.testStub(
      port: 1,
      spki: Uint8List(32),
      probeImpl: (ip, port, spki, timeoutMs) => () => 0,
    );
    expect(await t.probeDirect('10.0.0.1', 61005), isFalse);
    expect(await AqtTransport.testStub(port: 1).probeDirect('10.0.0.1', 1),
        isFalse);
  });

  test('probeDirect stops polling once the transport is closed', () async {
    var polls = 0;
    var pollsAfterClose = 0;
    var closed = false;
    final t = AqtTransport.testStub(
      port: 1,
      spki: Uint8List(32),
      probeImpl: (ip, port, spki, timeoutMs) => () {
        polls++;
        if (closed) pollsAfterClose++;
        return -1;
      },
    );
    final verdict = t.probeDirect('10.0.0.1', 61005);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(polls, greaterThan(0));
    unawaited(t.close());
    closed = true;
    expect(await verdict.timeout(const Duration(seconds: 2)), isFalse);
    expect(pollsAfterClose, 0,
        reason: 'the native result slot of a closed handle must not be read');
  });

  test('pathRxImpl drives pathRxFromCurrent; -1 without a handle', () {
    var rx = 0;
    final t = AqtTransport.testStub(port: 1, pathRxImpl: () => rx);
    expect(t.pathRxFromCurrent, 0);
    rx = 3;
    expect(t.pathRxFromCurrent, 3);
    expect(AqtTransport.testStub(port: 1).pathRxFromCurrent, -1);
  });

  test('recvAgeImpl drives lastRecvAgeMs', () {
    final t = AqtTransport.testStub(port: 1, recvAgeImpl: () => 4242);
    expect(t.lastRecvAgeMs, 4242);
  });
}
