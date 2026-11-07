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
  test('transport_close_closes_relay', () async {
    final relay = await AqtSshRelay.attach(_Exec());
    final t = AqtTransport.testStub(port: relay.localPort);
    t.attachRelay(route: AqtRoute.viaSsh, relay: relay, daemonPort: 61005);
    expect(t.route, AqtRoute.viaSsh);
    await t.close();
    await relay.done.timeout(const Duration(seconds: 1));
  });

  test('lastPort_is_daemon_port_when_relayed', () async {
    final relay = await AqtSshRelay.attach(_Exec());
    addTearDown(relay.close);
    final t = AqtTransport.testStub(port: relay.localPort);
    t.attachRelay(route: AqtRoute.viaSsh, relay: relay, daemonPort: 61005);
    expect(t.lastPort, 61005,
        reason: '会话状态要存守护进程端口，不能存 relay 的本机端口');
  });

  test('direct transport defaults to direct route', () {
    expect(AqtTransport.testStub(port: 61005).route, AqtRoute.direct);
  });
}
