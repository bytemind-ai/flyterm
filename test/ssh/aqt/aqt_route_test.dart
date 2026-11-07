import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_route.dart';

void main() {
  group('connectWithRoute', () {
    test('force_via_ssh_skips_direct', () async {
      var directCalls = 0;
      final r = await connectWithRoute<String>(
        forceViaSsh: true,
        cached: null,
        direct: () async {
          directCalls++;
          return 'direct';
        },
        viaSsh: () async => 'relay',
      );
      expect(directCalls, 0);
      expect(r.value, 'relay');
      expect(r.route, AqtRoute.viaSsh);
      expect(r.autoFellBack, isFalse, reason: '用户手动选择，不算自动降级');
    });

    test('cached_via_ssh_skips_direct', () async {
      var directCalls = 0;
      final r = await connectWithRoute<String>(
        forceViaSsh: false,
        cached: AqtRoute.viaSsh,
        direct: () async {
          directCalls++;
          return 'direct';
        },
        viaSsh: () async => 'relay',
      );
      expect(directCalls, 0);
      expect(r.route, AqtRoute.viaSsh);
      expect(r.autoFellBack, isFalse);
    });

    test('direct_success_never_opens_relay', () async {
      var relayCalls = 0;
      final r = await connectWithRoute<String>(
        forceViaSsh: false,
        cached: null,
        direct: () async => 'direct',
        viaSsh: () async {
          relayCalls++;
          return 'relay';
        },
      );
      expect(relayCalls, 0);
      expect(r.value, 'direct');
      expect(r.route, AqtRoute.direct);
      expect(r.autoFellBack, isFalse);
    });

    test('direct_failure_falls_back', () async {
      final r = await connectWithRoute<String>(
        forceViaSsh: false,
        cached: null,
        direct: () async => throw TimeoutException('udp blocked'),
        viaSsh: () async => 'relay',
      );
      expect(r.value, 'relay');
      expect(r.route, AqtRoute.viaSsh);
      expect(r.autoFellBack, isTrue);
    });

    test('both_fail_reports_both', () async {
      await expectLater(
        connectWithRoute<String>(
          forceViaSsh: false,
          cached: null,
          direct: () async => throw StateError('udp-boom'),
          viaSsh: () async => throw StateError('relay-boom'),
        ),
        throwsA(isA<AqtRouteException>()
            .having((e) => e.toString(), 'message', contains('udp-boom'))
            .having((e) => e.toString(), 'message', contains('relay-boom'))),
      );
    });
  });

  group('AqtRouteCache', () {
    test('remembers per server; fallback notice fires once', () {
      final c = AqtRouteCache();
      expect(c.get('s1'), isNull);
      c.set('s1', AqtRoute.viaSsh);
      expect(c.get('s1'), AqtRoute.viaSsh);
      expect(c.get('s2'), isNull);
      expect(c.markFallbackNotified('s1'), isTrue);
      expect(c.markFallbackNotified('s1'), isFalse);
    });
  });

  test('closeIfLate：超时后才完成的结果会被清理掉', () async {
    final pending = Completer<String>();
    final closed = <String>[];
    await expectLater(
      closeIfLate<String>(pending.future, const Duration(milliseconds: 20),
          onLate: (v) async => closed.add(v), timeoutMessage: 'too slow'),
      throwsA(isA<TimeoutException>()),
    );
    pending.complete('conn');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(closed, ['conn']);
  });
}
