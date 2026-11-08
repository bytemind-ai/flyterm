import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_route.dart';

void main() {
  group('connectWithRoute', () {
    Future<void> noDiscard(String _) async {}

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
        discard: noDiscard,
      );
      expect(directCalls, 0);
      expect(r.value, 'relay');
      expect(r.route, AqtRoute.viaSsh);
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
        discard: noDiscard,
      );
      expect(relayCalls, 0);
      expect(r.value, 'direct');
      expect(r.route, AqtRoute.direct);
    });

    test('relay starts after head start and wins', () async {
      final never = Completer<String>();
      final r = await connectWithRoute<String>(
        forceViaSsh: false,
        cached: null,
        direct: () => never.future,
        viaSsh: () async => 'relay',
        discard: noDiscard,
        relayHeadStart: const Duration(milliseconds: 20),
      );
      expect(r.value, 'relay');
      expect(r.route, AqtRoute.viaSsh);
    });

    test('direct failure starts relay immediately', () async {
      var relayCalls = 0;
      final sw = Stopwatch()..start();
      final r = await connectWithRoute<String>(
        forceViaSsh: false,
        cached: null,
        direct: () async => throw TimeoutException('udp blocked'),
        viaSsh: () async {
          relayCalls++;
          return 'relay';
        },
        discard: noDiscard,
        relayHeadStart: const Duration(seconds: 5),
      );
      expect(relayCalls, 1);
      expect(r.route, AqtRoute.viaSsh);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('cached via ssh races both', () async {
      var directCalls = 0;
      var relayCalls = 0;
      final r = await connectWithRoute<String>(
        forceViaSsh: false,
        cached: AqtRoute.viaSsh,
        direct: () async {
          directCalls++;
          return 'direct';
        },
        viaSsh: () async {
          relayCalls++;
          return 'relay';
        },
        discard: noDiscard,
      );
      expect(directCalls, 1);
      expect(relayCalls, 1);
      expect(r.value, isNotEmpty);
    });

    test('loser completing later is discarded', () async {
      final discarded = <String>[];
      final r = await connectWithRoute<String>(
        forceViaSsh: false,
        cached: null,
        direct: () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 'direct';
        },
        viaSsh: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'relay';
        },
        discard: (v) async => discarded.add(v),
        relayHeadStart: Duration.zero,
      );
      expect(r.value, 'relay');
      expect(r.route, AqtRoute.viaSsh);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(discarded, ['direct']);
    });

    test('both_fail_reports_both', () async {
      await expectLater(
        connectWithRoute<String>(
          forceViaSsh: false,
          cached: null,
          direct: () async => throw StateError('udp-boom'),
          viaSsh: () async => throw StateError('relay-boom'),
          discard: (_) async {},
        ),
        throwsA(isA<AqtRouteException>()
            .having((e) => e.toString(), 'message', contains('udp-boom'))
            .having((e) => e.toString(), 'message', contains('relay-boom'))),
      );
    });
  });

  group('AqtRouteCache', () {
    test('remembers per server', () {
      final c = AqtRouteCache();
      expect(c.get('s1'), isNull);
      c.set('s1', AqtRoute.viaSsh);
      expect(c.get('s1'), AqtRoute.viaSsh);
      expect(c.get('s2'), isNull);
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
