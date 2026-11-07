import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_route.dart';
import 'package:flyterm/ssh/aqt/aqt_session_state.dart';
import 'package:flyterm/ssh/aqt/aqt_ssh_relay.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';
import 'package:flyterm/ssh/transport/transport_factory.dart';

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
  final spki = Uint8List.fromList([1, 2, 3]);
  final token = Uint8List(32);
  late List<(String, int)> endpointCalls;
  late AqtResumeResult Function(String host, int port) endpointResult;

  setUp(() {
    endpointCalls = [];
    endpointResult = (_, port) => AqtResumeSuccess(AqtTransport.testStub(port: port));
    AqtTransportFactory.resumeEndpointOverride = ({
      required String host,
      required int port,
      required Uint8List spki,
      required Uint8List sessionToken,
      required int tabId,
      required Duration budget,
    }) async {
      endpointCalls.add((host, port));
      return endpointResult(host, port);
    };
  });
  tearDown(() => AqtTransportFactory.resumeEndpointOverride = null);

  test('resume_viaSsh_uses_relay_port', () async {
    final relay = await AqtSshRelay.attach(_Exec());
    addTearDown(relay.close);
    final r = await AqtTransportFactory.tryResumeWithInfoDetailed(
      host: 'srv.example.com',
      port: 61005,
      spki: spki,
      sessionToken: token,
      tabId: 1,
      route: AqtRoute.viaSsh,
      openRelay: (daemonPort) async {
        expect(daemonPort, 61005);
        return relay;
      },
    );
    expect(endpointCalls, [('127.0.0.1', relay.localPort)]);
    final t = (r as AqtResumeSuccess).transport;
    expect(t.route, AqtRoute.viaSsh);
    expect(t.lastPort, 61005, reason: '持久化的是守护进程端口');
  });

  test('resume_viaSsh_opener_failure_returns_failure', () async {
    final r = await AqtTransportFactory.tryResumeWithInfoDetailed(
      host: 'srv.example.com',
      port: 61005,
      spki: spki,
      sessionToken: token,
      tabId: 1,
      route: AqtRoute.viaSsh,
      openRelay: (_) async => throw StateError('aux ssh not ready'),
    );
    expect(r, isA<AqtResumeFailed>());
    expect(endpointCalls, isEmpty);
  });

  test('resume_failure_closes_relay', () async {
    final relay = await AqtSshRelay.attach(_Exec());
    endpointResult = (_, __) =>
        const AqtResumeFailed(AqtResumeFailReason.networkTimeout, detail: 'x');
    final r = await AqtTransportFactory.tryResumeWithInfoDetailed(
      host: 'srv.example.com',
      port: 61005,
      spki: spki,
      sessionToken: token,
      tabId: 1,
      route: AqtRoute.viaSsh,
      openRelay: (_) async => relay,
    );
    expect(r, isA<AqtResumeFailed>());
    await relay.done.timeout(const Duration(seconds: 1));
  });

  test('resume_viaSsh_late_opener_relay_is_closed', () async {
    // The opener outlives the relay budget: RESUME has already failed, so
    // nobody owns the relay it eventually returns — it must be closed, or
    // its `--relay` process lives on the server until SSH drops.
    final relay = await AqtSshRelay.attach(_Exec());
    final pending = Completer<AqtSshRelay>();
    final r = await AqtTransportFactory.tryResumeWithInfoDetailed(
      host: 'srv.example.com',
      port: 61005,
      spki: spki,
      sessionToken: token,
      tabId: 1,
      route: AqtRoute.viaSsh,
      openRelay: (_) => pending.future,
      relayBudget: const Duration(milliseconds: 20),
    );
    expect(r, isA<AqtResumeFailed>());
    pending.complete(relay);
    await relay.done.timeout(const Duration(seconds: 1));
    expect(endpointCalls, isEmpty);
  });

  test('direct_route_never_opens_relay', () async {
    var opened = 0;
    await AqtTransportFactory.tryResumeWithInfoDetailed(
      host: 'srv.example.com',
      port: 61005,
      spki: spki,
      sessionToken: token,
      tabId: 1,
      openRelay: (_) async {
        opened++;
        throw StateError('must not be called');
      },
    );
    expect(opened, 0);
    expect(endpointCalls, [('srv.example.com', 61005)]);
  });

  test('viaSsh_session_state_saves_daemon_port', () async {
    final relay = await AqtSshRelay.attach(_Exec());
    addTearDown(relay.close);
    final t = AqtTransport.testStub(
        port: relay.localPort, spki: spki, token: token, tabId: 3);
    t.attachRelay(route: AqtRoute.viaSsh, relay: relay, daemonPort: 61005);
    final s = sessionStateFor(t, tabId: 'tab-1', existing: null, ttlSecs: 0)!;
    expect(s.port, 61005);
    expect(s.route, AqtRoute.viaSsh);
    expect(s.aqtTabId, 3);
  });

  group('relayFailureOf', () {
    test('finds the relay failure through every wrapper', () {
      expect(AqtTransportFactory.relayFailureOf(const AqtRelayUnsupportedException()),
          isA<AqtRelayUnsupportedException>());
      final routed = AqtRouteException(
          TimeoutException('udp'), const AqtRelayStartException('denied'));
      expect(AqtTransportFactory.relayFailureOf(routed), isA<AqtRelayStartException>());
      expect(
        AqtTransportFactory.relayFailureOf(TransportConnectException(
            'AQT connect failed',
            AqtRouteException(
                TimeoutException('udp'), const AqtRelayUnsupportedException()))),
        isA<AqtRelayUnsupportedException>(),
      );
    });

    test('is null when the relay is not what failed', () {
      expect(AqtTransportFactory.relayFailureOf(TimeoutException('udp')), isNull);
      expect(
        AqtTransportFactory.relayFailureOf(
            AqtRouteException(TimeoutException('udp'), TimeoutException('relay'))),
        isNull,
      );
      expect(
        AqtTransportFactory.relayFailureOf(
            const TransportConnectException('AQT connect failed')),
        isNull,
      );
    });
  });
}
