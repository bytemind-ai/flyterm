import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_path_controller.dart';
import 'package:flyterm/ssh/aqt/aqt_route.dart';
import 'package:flyterm/ssh/aqt/aqt_ssh_relay.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

const _daemonPort = 61005;
const _serverIp = '203.0.113.5';

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

  /// SSH 通道自己断了（不是谁调了 close）。
  void end() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void close() => end();
}

/// 一个假会话：testStub transport + 计数用的各个回调，全部跑在 [fa] 里。
class _H {
  final FakeAsync fa = FakeAsync();
  int recvAge = 9000;

  /// 模拟 Rust `rx_from_current`：每次 setPath 归零。
  int pathRx = 0;
  bool fg = true;
  final setPaths = <(String, int)>[];
  bool setPathOk = true;
  void Function(String ip, int port)? onSetPath;
  int probeCalls = 0;
  bool probeOk = false;
  bool probePending = false;
  int resolveCalls = 0;
  bool directAllowed = true;

  /// 非 null 时替代默认解析（用于模拟 DNS 抛错）。
  Future<({String ip, int port})?> Function()? resolveImpl;
  final events = <Event>[];
  int routeChanged = 0;
  final openPorts = <int>[];
  Future<AqtSshRelay> Function(int port) openRelay =
      (_) => Future.error(StateError('no relay in this test'));
  late final AqtTransport transport;
  late final AqtPathController c;
  final _relays = <AqtSshRelay>[];

  _H() {
    transport = AqtTransport.testStub(
      port: _daemonPort,
      spki: Uint8List.fromList([1, 2, 3]),
      recvAgeImpl: () => recvAge,
      pathRxImpl: () => pathRx,
      setPathImpl: (ip, port) {
        setPaths.add((ip, port));
        pathRx = 0;
        onSetPath?.call(ip, port);
        return setPathOk;
      },
      probeImpl: (ip, port, spki, timeoutMs) {
        probeCalls++;
        return () => probePending ? -1 : (probeOk ? 1 : 0);
      },
    );
    fa.run((_) {
      c = AqtPathController(
        transport: transport,
        openRelay: (port) {
          openPorts.add(port);
          return openRelay(port);
        },
        resolveDirect: () async {
          resolveCalls++;
          final impl = resolveImpl;
          if (impl != null) return impl();
          return (ip: _serverIp, port: _daemonPort);
        },
        directAllowed: () => directAllowed,
        feed: events.add,
        onRouteChanged: () => routeChanged++,
        isForeground: () => fg,
      );
    });
  }

  /// 真 relay 要绑真 UDP socket：在假 zone 里发起，再用真时间推 IO、
  /// 用 flushMicrotasks 推假 zone 里的回调。这样 relay 的 done / exec.done
  /// 的监听都落在假 zone，测试里能同步观察到。
  Future<(AqtSshRelay, _Exec)> relay() async {
    late _Exec exec;
    AqtSshRelay? r;
    Object? err;
    fa.run((_) {
      exec = _Exec();
      AqtSshRelay.attach(exec).then((v) {
        r = v;
      }, onError: (Object e) {
        err = e;
      });
    });
    for (var i = 0; r == null && err == null && i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      fa.flushMicrotasks();
    }
    if (err != null) throw err!;
    _relays.add(r!);
    return (r!, exec);
  }

  void onRelay(AqtSshRelay r) =>
      transport.attachRelay(route: AqtRoute.viaSsh, relay: r, daemonPort: _daemonPort);

  void dispose() {
    fa.run((_) {
      c.dispose();
      for (final r in _relays) {
        r.close();
      }
    });
    fa.flushMicrotasks();
  }
}

class _DnsError implements Exception {
  const _DnsError(this.message);
  final String message;
}

bool _closed(FakeAsync async, AqtSshRelay r) {
  var closed = false;
  r.done.then((_) => closed = true);
  async.flushMicrotasks();
  return closed;
}

void main() {
  test('direct to relay on StartPathSwitch', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.openRelay = (_) => Future.value(relay);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.flushMicrotasks();
      expect(h.openPorts, [_daemonPort]);
      expect(h.setPaths, [('127.0.0.1', relay.localPort)]);
      expect(h.transport.route, AqtRoute.viaSsh);
      expect(identical(h.transport.relay, relay), isTrue);
      expect(h.events, [isA<PathSwitched>()]);
      expect(h.routeChanged, 1);
      expect(_closed(async, relay), isFalse);
    });
  });

  test('direct recovers while relay opens', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.openRelay =
        (_) => Future.delayed(const Duration(seconds: 1), () => relay);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.elapse(const Duration(milliseconds: 500));
      h.recvAge = 500;
      async.elapse(const Duration(milliseconds: 600));
      expect(h.setPaths, isEmpty);
      expect(_closed(async, relay), isTrue);
      expect(h.events, [isA<PathSwitchFailed>()]);
      expect(h.transport.route, AqtRoute.direct);
      expect(h.routeChanged, 0);
    });
  });

  // 请求后 500 ms 直连来过包，中继 2 s 后落地 → 直连已恢复，不切。
  test('inbound since the request means direct recovered', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.openRelay =
        (_) => Future.delayed(const Duration(seconds: 2), () => relay);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.elapse(const Duration(milliseconds: 500));
      h.recvAge = 1500; // 请求后 500 ms 来过一个包
      async.elapse(const Duration(milliseconds: 1500));
      expect(h.setPaths, isEmpty);
      expect(_closed(async, relay), isTrue);
      expect(h.events, [isA<PathSwitchFailed>()]);
      expect(h.transport.route, AqtRoute.direct);
    });
  });

  test('inbound since the request rejects even when older than 3 s', () async {
    // 短暂丢包：请求后 1 s 直连恢复过（之后又静了），中继 5 s 才落地。
    // 落地时 lastRecvAgeMs = 4000：旧判据（< 3000）会切，但请求之后确实收到过
    // 直连的包 —— 直连是通的，切过去是误切。
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.openRelay =
        (_) => Future.delayed(const Duration(seconds: 5), () => relay);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.elapse(const Duration(seconds: 1));
      h.recvAge = 4000; // 落地时（t+5 s）看到的值：t+1 s 来过包
      async.elapse(const Duration(seconds: 4));
      expect(h.setPaths, isEmpty);
      expect(_closed(async, relay), isTrue);
      expect(h.events, [isA<PathSwitchFailed>()]);
      expect(h.transport.route, AqtRoute.direct);
    });
  });

  test('no inbound since the request switches', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.recvAge = 9000;
    h.openRelay =
        (_) => Future.delayed(const Duration(seconds: 2), () => relay);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.elapse(const Duration(seconds: 2));
      expect(h.setPaths, [('127.0.0.1', relay.localPort)]);
      expect(h.events, [isA<PathSwitched>()]);
      expect(h.transport.route, AqtRoute.viaSsh);
      expect(_closed(async, relay), isFalse);
    });
  });

  test('relay open failure reports failed', () async {
    final h = _H();
    addTearDown(h.dispose);
    h.openRelay = (_) => Future.error(StateError('ssh down'));
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.flushMicrotasks();
      expect(h.events, [isA<PathSwitchFailed>()]);
      expect(h.setPaths, isEmpty);
      expect(h.transport.route, AqtRoute.direct);
    });
  });

  test('relay open past budget is closed when it lands', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.openRelay =
        (_) => Future.delayed(const Duration(seconds: 9), () => relay);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.elapse(const Duration(milliseconds: 7900));
      expect(h.events, isEmpty);
      async.elapse(const Duration(milliseconds: 200));
      expect(h.events, [isA<PathSwitchFailed>()]);
      expect(_closed(async, relay), isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(_closed(async, relay), isTrue);
      expect(h.setPaths, isEmpty);
      expect(h.events, hasLength(1));
    });
  });

  test('probe success switches back to direct', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.probeOk = true;
    h.fa.run((async) {
      h.c.start();
      async.elapse(const Duration(seconds: 59));
      expect(h.probeCalls, 0);
      async.elapse(const Duration(seconds: 1));
      expect(h.probeCalls, 1);
      expect(h.setPaths, [(_serverIp, _daemonPort)]);
      async.elapse(const Duration(milliseconds: 500));
      h.pathRx = 2; // 新路径（当前目的地）上来了包
      async.elapse(const Duration(seconds: 2));
      expect(h.transport.route, AqtRoute.direct);
      expect(h.transport.relay, isNull);
      expect(_closed(async, relay), isTrue);
      expect(h.routeChanged, 1);
      expect(h.setPaths, hasLength(1));
      expect(h.events, isEmpty, reason: 'probes never feed the state machine');
      // 已经直连：不再探测。
      async.elapse(const Duration(minutes: 10));
      expect(h.probeCalls, 1);
    });
  });

  test('probe ok but no traffic reverts to relay', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.probeOk = true;
    h.fa.run((async) {
      h.c.start();
      async.elapse(const Duration(seconds: 60));
      async.elapse(const Duration(seconds: 2, milliseconds: 100));
      expect(h.setPaths, [
        (_serverIp, _daemonPort),
        ('127.0.0.1', relay.localPort),
      ]);
      expect(h.transport.route, AqtRoute.viaSsh);
      expect(identical(h.transport.relay, relay), isTrue);
      expect(_closed(async, relay), isFalse);
      expect(h.routeChanged, 0);
      // 失败一次 → 下一次间隔 120 s。
      async.elapse(const Duration(seconds: 119));
      expect(h.probeCalls, 1);
      async.elapse(const Duration(seconds: 1));
      expect(h.probeCalls, 2);
    });
  });

  test('fresh lastRecvAgeMs without traffic from direct still reverts',
      () async {
    // 中继还在送在途包、1 Hz 采样也会把切换前的包算成「新鲜」：
    // lastRecvAgeMs 一直很小，但当前目的地（直连）一个包都没来。
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.probeOk = true;
    h.recvAge = 50;
    final relayPort = relay.localPort;
    h.fa.run((async) {
      h.c.start();
      async.elapse(const Duration(seconds: 60));
      async.elapse(const Duration(seconds: 2, milliseconds: 100));
      expect(h.transport.route, AqtRoute.viaSsh,
          reason: 'no datagram from direct: must not switch');
      expect(h.setPaths, [
        (_serverIp, _daemonPort),
        ('127.0.0.1', relayPort),
      ]);
      expect(h.transport.route, AqtRoute.viaSsh);
      expect(_closed(async, relay), isFalse);
      expect(h.routeChanged, 0);
    });
  });

  test('probe backoff and reset on network change', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.fa.run((async) {
      h.c.start();
      var expected = 0;
      for (final s in [60, 120, 300, 300]) {
        async.elapse(Duration(seconds: s - 1));
        expect(h.probeCalls, expected, reason: 'before the ${s}s mark');
        async.elapse(const Duration(seconds: 1));
        expect(h.probeCalls, ++expected, reason: 'at the ${s}s mark');
      }
      expect(h.setPaths, isEmpty);
      final resolvesBefore = h.resolveCalls;
      h.c.onNetworkChanged();
      async.flushMicrotasks();
      expect(h.probeCalls, ++expected, reason: 'network change probes now');
      expect(h.resolveCalls, resolvesBefore + 1,
          reason: 'the direct address is resolved again after a network change');
      async.elapse(const Duration(seconds: 59));
      expect(h.probeCalls, expected);
      async.elapse(const Duration(seconds: 1));
      expect(h.probeCalls, ++expected, reason: 'interval reset to 60 s');
    });
  });

  test('a failed timer probe escalates even with a re-probe queued', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, exec) = await h.relay();
    h.onRelay(relay);
    h.probePending = true;
    h.fa.run((async) {
      h.c.start();
      async.elapse(const Duration(seconds: 60));
      expect(h.probeCalls, 1);
      exec.end(); // 中继断了：想再探一次，但上一次还在途 → 排队
      async.flushMicrotasks();
      expect(h.probeCalls, 1);
      h.probePending = false; // 两次都失败
      async.elapse(const Duration(milliseconds: 300));
      expect(h.probeCalls, 2);
      async.elapse(const Duration(seconds: 119));
      expect(h.probeCalls, 2, reason: 'the timer probe failure escalated');
      async.elapse(const Duration(seconds: 1));
      expect(h.probeCalls, 3);
    });
  });

  test('no probing in background', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.fg = false;
    h.fa.run((async) {
      h.c.start();
      async.elapse(const Duration(minutes: 10));
      expect(h.probeCalls, 0);
      h.c.onNetworkChanged();
      async.elapse(const Duration(seconds: 1));
      expect(h.probeCalls, 0);
      expect(h.openPorts, isEmpty, reason: 'no relay rebuild in background');
      h.fg = true;
      async.elapse(const Duration(seconds: 60));
      expect(h.probeCalls, 1, reason: 'background ticks do not escalate');
    });
  });

  test('relay dropping while on relay rebuilds', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (r1, exec1) = await h.relay();
    final (r2, _) = await h.relay();
    h.onRelay(r1);
    h.openRelay = (_) => Future.value(r2);
    h.fa.run((async) {
      h.c.start();
      async.flushMicrotasks();
      expect(h.openPorts, isEmpty);
      exec1.end();
      async.flushMicrotasks();
      expect(h.openPorts, [_daemonPort]);
      expect(h.setPaths, [('127.0.0.1', r2.localPort)]);
      expect(identical(h.transport.relay, r2), isTrue);
      expect(h.transport.route, AqtRoute.viaSsh);
      expect(h.probeCalls, 1, reason: 'a direct probe also starts');
      expect(h.events, isEmpty);
      // 新 relay 也受监视：它再断也会重建。
      h.openRelay = (_) => Future.error(StateError('gone'));
      r2.close();
      async.flushMicrotasks();
      expect(h.openPorts, hasLength(2));
    });
  });

  test('directAllowed false: never probes, relay drop still rebuilds', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (r1, exec1) = await h.relay();
    final (r2, _) = await h.relay();
    h.onRelay(r1);
    h.directAllowed = false;
    h.probeOk = true;
    h.openRelay = (_) => Future.value(r2);
    h.fa.run((async) {
      h.c.start();
      async.elapse(const Duration(seconds: 700));
      expect(h.probeCalls, 0);
      h.c.onNetworkChanged();
      exec1.end();
      async.flushMicrotasks();
      expect(h.openPorts, [_daemonPort]);
      expect(identical(h.transport.relay, r2), isTrue);
      expect(h.transport.route, AqtRoute.viaSsh);
      async.elapse(const Duration(seconds: 700));
      expect(h.probeCalls, 0, reason: '强制 SSH 通道的会话绝不切回直连');
      expect(h.resolveCalls, 0);
      expect(h.routeChanged, 0);
    });
  });

  test('resolveDirect throwing once does not poison later probes', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.probeOk = true;
    var fail = true;
    h.resolveImpl = () async {
      if (fail) {
        fail = false;
        throw const _DnsError('dns not ready');
      }
      return (ip: _serverIp, port: _daemonPort);
    };
    h.fa.run((async) {
      h.c.start();
      async.elapse(const Duration(seconds: 60));
      expect(h.resolveCalls, 1);
      expect(h.probeCalls, 0);
      // 第一次失败后升一级：120 s 后再探，这次要重新解析。
      async.elapse(const Duration(seconds: 120));
      expect(h.resolveCalls, 2);
      expect(h.probeCalls, 1);
      expect(h.setPaths, [(_serverIp, _daemonPort)]);
      h.pathRx = 1;
      async.elapse(const Duration(seconds: 2));
      expect(h.transport.route, AqtRoute.direct);
    });
  });

  test('relay dropping while direct only cleans up', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (r1, exec1) = await h.relay();
    h.openRelay = (_) => Future.value(r1);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.flushMicrotasks();
      // 手动模拟已切回直连
      h.transport.replaceRelay(AqtRoute.direct, null);
      exec1.end();
      async.flushMicrotasks();
      expect(h.openPorts, hasLength(1));
    });
  });

  test('network change on relay: probe and rebuild race, probe wins', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (r1, _) = await h.relay();
    final (r2, _) = await h.relay();
    h.onRelay(r1);
    h.probeOk = true;
    h.openRelay = (_) => Future.delayed(const Duration(seconds: 1), () => r2);
    h.onSetPath = (ip, _) {
      if (ip == _serverIp) h.pathRx = 1;
    };
    h.fa.run((async) {
      h.c.start();
      h.c.onNetworkChanged();
      async.elapse(const Duration(seconds: 3));
      expect(h.openPorts, [_daemonPort]);
      expect(h.transport.route, AqtRoute.direct);
      expect(h.setPaths, [(_serverIp, _daemonPort)]);
      expect(_closed(async, r1), isTrue);
      expect(_closed(async, r2), isTrue, reason: 'the losing relay is closed');
    });
  });

  test('network change on relay: rebuild wins when probe fails', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (r1, _) = await h.relay();
    final (r2, _) = await h.relay();
    h.onRelay(r1);
    h.openRelay = (_) => Future.delayed(const Duration(seconds: 1), () => r2);
    h.fa.run((async) {
      h.c.start();
      h.c.onNetworkChanged();
      async.elapse(const Duration(seconds: 2));
      expect(h.probeCalls, 1);
      expect(h.setPaths, [('127.0.0.1', r2.localPort)]);
      expect(identical(h.transport.relay, r2), isTrue);
      expect(_closed(async, r1), isTrue);
      expect(_closed(async, r2), isFalse);
    });
  });

  test('never two direct probes at once', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.probePending = true;
    h.fa.run((async) {
      h.c.start();
      h.c.onNetworkChanged();
      async.elapse(const Duration(milliseconds: 300));
      h.c.onNetworkChanged();
      h.c.onNetworkChanged();
      async.elapse(const Duration(milliseconds: 300));
      expect(h.probeCalls, 1);
      h.probePending = false; // 第一次探测结束（失败）
      async.elapse(const Duration(milliseconds: 300));
      expect(h.probeCalls, 2, reason: 'one queued re-probe, run after');
      async.elapse(const Duration(seconds: 1));
      expect(h.probeCalls, 2);
    });
  });

  test('unsupported relay stops further attempts', () async {
    final h = _H();
    addTearDown(h.dispose);
    h.openRelay = (_) => Future.error(const AqtRelayUnsupportedException());
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.flushMicrotasks();
      expect(h.events, [isA<PathSwitchFailed>()]);
      h.c.onStartPathSwitch();
      async.flushMicrotasks();
      expect(h.openPorts, hasLength(1));
      expect(h.events, [isA<PathSwitchFailed>(), isA<PathSwitchFailed>()]);
    });
  });

  test('dispose cancels and closes', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.openRelay =
        (_) => Future.delayed(const Duration(seconds: 1), () => relay);
    h.fa.run((async) {
      h.c.onStartPathSwitch();
      async.elapse(const Duration(milliseconds: 300));
      h.c.dispose();
      async.flushMicrotasks();
      expect(h.events, [isA<PathSwitchFailed>()],
          reason: 'an in-flight switch still reports back');
      async.elapse(const Duration(seconds: 1));
      expect(_closed(async, relay), isTrue);
      expect(h.setPaths, isEmpty);
      expect(h.transport.route, AqtRoute.direct);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('dispose while on relay cancels the probe timer', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (relay, _) = await h.relay();
    h.onRelay(relay);
    h.fa.run((async) {
      h.c.start();
      h.c.dispose();
      async.elapse(const Duration(minutes: 10));
      expect(h.probeCalls, 0);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('every onStartPathSwitch ends in exactly one completion event', () async {
    final h = _H();
    addTearDown(h.dispose);
    final (r1, _) = await h.relay();
    final (r2, _) = await h.relay();
    h.fa.run((async) {
      final perCall = <int>[];
      void call() {
        final before = h.events.length;
        var done = false;
        h.c.onStartPathSwitch().then((_) => done = true);
        async.elapse(const Duration(seconds: 10));
        expect(done, isTrue);
        perCall.add(h.events.length - before);
      }

      // openRelay throws synchronously
      h.openRelay = (_) => throw StateError('sync throw');
      call();
      // setPath refused → relay closed, failed
      h.openRelay = (_) => Future.value(r1);
      h.setPathOk = false;
      call();
      expect(_closed(async, r1), isTrue);
      expect(h.transport.route, AqtRoute.direct);
      h.setPathOk = true;

      // onRouteChanged throwing does not swallow / duplicate the event
      final c2 = AqtPathController(
        transport: h.transport,
        openRelay: (_) => Future.value(r2),
        resolveDirect: () async => null,
        feed: h.events.add,
        onRouteChanged: () => throw StateError('persist failed'),
        isForeground: () => true,
      );
      final before = h.events.length;
      c2.onStartPathSwitch();
      async.flushMicrotasks();
      expect(h.events.length - before, 1);
      expect(h.events.last, isA<PathSwitched>());
      c2.dispose();
      h.transport.replaceRelay(AqtRoute.direct, null);

      // two concurrent calls (second while the first is in flight)
      final pending = Completer<AqtSshRelay>();
      h.openRelay = (_) => pending.future;
      final b2 = h.events.length;
      final opens = h.openPorts.length;
      h.c.onStartPathSwitch();
      async.elapse(const Duration(milliseconds: 100));
      h.c.onStartPathSwitch();
      async.elapse(const Duration(milliseconds: 100));
      expect(h.openPorts.length, opens + 1,
          reason: 'the second call joins the switch in flight');
      pending.complete(r2);
      async.flushMicrotasks();
      expect(h.events.length - b2, 2, reason: 'one event per call');

      // disposed mid-flight, then a call after dispose
      h.transport.replaceRelay(AqtRoute.direct, null);
      h.openRelay = (_) => Completer<AqtSshRelay>().future;
      final b3 = h.events.length;
      h.c.onStartPathSwitch();
      async.elapse(const Duration(milliseconds: 100));
      h.c.dispose();
      async.flushMicrotasks();
      h.c.onStartPathSwitch();
      async.flushMicrotasks();
      expect(h.events.length - b3, 2);
      expect(h.events.sublist(b3), everyElement(isA<PathSwitchFailed>()));
      async.elapse(const Duration(seconds: 10));
      expect(h.events.length - b3, 2, reason: 'no late duplicates');

      expect(perCall, [1, 1]);
    });
  });
}
