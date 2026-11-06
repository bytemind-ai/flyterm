// Regression test for the SECOND (and previously missing) half of root-cause
// A's fix. `test/ssh/aqt/prewarm_pool_cold_resume_race_test.dart` already
// proved `PrewarmPool.claimColdResume`/`coldResumeFuture`/
// `releaseColdResumeClaim` are correct in isolation. This file proves the
// two REAL call sites — main.dart::_prewarmAqtSession and
// ReconnectService._reconnect()'s `isQuicHydrate && tab.transport == null`
// cold-hydrate branch — are actually wired to use that shared guard
// correctly, including the asymmetric shapes each side has:
//
//   - main.dart's prewarm: claim → resume → store on success → release.
//     (It does NOT wait/adopt on a lost claim — it just returns; the
//     terminal screen or reconnectAll() will pick up the stored transport.)
//   - reconnect_service.dart's cold-hydrate branch: claim → resume →
//     release when it WINS; on LOSING, await the winner then `pool.take()`
//     and gate adoption on `currentState == TransportState.connected`
//     (mirroring the existing adopt-gate in
//     terminal_screen.dart::_connectServer) — crucially, NEVER firing a
//     second independent network resume for the same tab/session-token.
//
// `ReconnectService._reconnect()` is private and its cold-hydrate branch
// also drives real SecureStorage + FFI network calls, so — following the
// disclosed-limitation precedent in
// test/ssh/cold_launch_reconnect_sequence_test.dart — both call-site shapes
// are hand-replicated here statement-for-statement against the ACTUAL
// PrewarmPool, ACTUAL AqtTransport (via `.testStub`), and ACTUAL
// TransportState gating, with only the network round-trip itself faked.
import 'dart:async';
import 'dart:typed_data';

import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/prewarm_pool.dart';
import 'package:flyterm/ssh/transport/remote_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Outcome of the reconnect_service-side replica: either it installed a
/// transport (cold RESUME succeeded, either its own or adopted from
/// prewarm), or it fell through to the normal SSH-bootstrap path below the
/// cold-hydrate block — exactly the two exits the real branch has.
class _ColdHydrateOutcome {
  final AqtTransport? installed;
  final bool fellThrough;
  _ColdHydrateOutcome.installed(this.installed) : fellThrough = false;
  _ColdHydrateOutcome.fallThrough()
      : installed = null,
        fellThrough = true;
}

/// Hand-replicates `main.dart::_prewarmAqtSession`'s current (post-fix)
/// guarded body: claim the pool slot; if refused, skip entirely (no
/// wait/adopt on this side — that is intentionally the OTHER call site's
/// job); if claimed, resume, store on success, release in `finally`.
Future<AqtTransport?> _replicatePrewarmAqtSession(
  PrewarmPool pool,
  String tabId,
  Future<AqtTransport?> Function() networkResume,
) async {
  if (!pool.claimColdResume(tabId)) {
    return null; // "cold-resume already claimed — skip" in the real code.
  }
  try {
    final t = await networkResume();
    if (t != null) {
      pool.store(tabId, t);
    }
    return t;
  } finally {
    pool.releaseColdResumeClaim(tabId);
  }
}

/// Hand-replicates `ReconnectService._reconnect()`'s cold-hydrate branch
/// AFTER the fix (reconnect_service.dart, `isQuicHydrate && tab.transport ==
/// null`): claim → resume → release in `finally` when it wins; on losing,
/// await the winner then adopt from the pool ONLY if the adopted transport
/// is actually connected — otherwise fall through, and critically, never
/// fire a second network resume.
Future<_ColdHydrateOutcome> _replicateReconnectColdHydrate(
  PrewarmPool pool,
  String tabId,
  Future<AqtTransport?> Function() networkResume,
) async {
  if (!pool.claimColdResume(tabId)) {
    await pool.coldResumeFuture(tabId);
    final adopted = pool.take(tabId);
    if (adopted != null && adopted.currentState == TransportState.connected) {
      return _ColdHydrateOutcome.installed(adopted);
    }
    return _ColdHydrateOutcome.fallThrough();
  }
  try {
    final t = await networkResume();
    return t != null
        ? _ColdHydrateOutcome.installed(t)
        : _ColdHydrateOutcome.fallThrough();
  } finally {
    pool.releaseColdResumeClaim(tabId);
  }
}

AqtTransport _connectedStub() => AqtTransport.testStub(
      port: 12345,
      spki: Uint8List(32),
      token: Uint8List(32),
      tabId: 1,
      state: TransportState.connected,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('main.dart prewarm vs ReconnectService cold-hydrate — shared guard', () {
    test(
        'prewarm fires first and wins the claim; reconnect side waits and '
        'adopts the SAME transport instance; exactly one network resume '
        'fires in total', () async {
      final pool = PrewarmPool();
      var networkCalls = 0;
      const tabId = 'tab-active';

      Future<AqtTransport?> fakeResume() async {
        networkCalls++;
        // Long enough that the reconnect-service replica (started right
        // after, exactly as reconnectAll() fires moments after the prewarm
        // call in main.dart/_initApp) reaches its own claimColdResume()
        // call and loses.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _connectedStub();
      }

      // Mirrors real startup ordering: prewarm's claim happens synchronously
      // before its first await, so starting this Future first guarantees it
      // wins the race — exactly like main.dart firing before
      // ReconnectService is even constructed.
      final prewarmFuture = _replicatePrewarmAqtSession(pool, tabId, fakeResume);
      final reconnectFuture =
          _replicateReconnectColdHydrate(pool, tabId, fakeResume);

      final prewarmResult = await prewarmFuture;
      final reconnectOutcome = await reconnectFuture;

      expect(networkCalls, 1,
          reason: 'root cause A: without the shared claim, both call sites '
              'would fire their own RESUME for the same tab/session-token — '
              'the 23 same-second double-connect events in the production '
              'log. Only the winner (prewarm here) may touch the network.');
      expect(prewarmResult, isNotNull);
      expect(reconnectOutcome.fellThrough, isFalse,
          reason: 'the loser must adopt prewarm\'s result, not fall through '
              'to a redundant SSH bootstrap when a perfectly good resumed '
              'session is sitting in the pool');
      expect(identical(reconnectOutcome.installed, prewarmResult), isTrue,
          reason: 'the reconnect side must install the EXACT transport '
              'instance prewarm produced, not a second independent one');
    });

    test(
        'reconnect side fires first and wins the claim (rare ordering — no '
        'last-active tab to prewarm); prewarm loses and simply skips '
        '(returns null, does not wait/adopt) — still exactly one network '
        'resume', () async {
      final pool = PrewarmPool();
      var networkCalls = 0;
      const tabId = 'tab-active';

      Future<AqtTransport?> fakeResume() async {
        networkCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _connectedStub();
      }

      final reconnectFuture =
          _replicateReconnectColdHydrate(pool, tabId, fakeResume);
      final prewarmFuture = _replicatePrewarmAqtSession(pool, tabId, fakeResume);

      final reconnectOutcome = await reconnectFuture;
      final prewarmResult = await prewarmFuture;

      expect(networkCalls, 1);
      expect(reconnectOutcome.fellThrough, isFalse);
      expect(reconnectOutcome.installed, isNotNull);
      expect(prewarmResult, isNull,
          reason: 'main.dart\'s guarded prewarm intentionally does NOT wait '
              'on a lost claim — it just skips, per its own doc comment '
              '("its cold-hydrate branch will handle this tab")');
    });

    test(
        'prewarm wins the claim but its RESUME fails (returns null, nothing '
        'stored); reconnect side must fall through to SSH bootstrap, NOT '
        'fire a second cold RESUME with the same stale session info',
        () async {
      final pool = PrewarmPool();
      var networkCalls = 0;
      const tabId = 'tab-active';

      Future<AqtTransport?> failingResume() async {
        networkCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return null; // server said sessionNotFound / handshakeFailed, etc.
      }

      final prewarmFuture =
          _replicatePrewarmAqtSession(pool, tabId, failingResume);
      final reconnectFuture =
          _replicateReconnectColdHydrate(pool, tabId, failingResume);

      final prewarmResult = await prewarmFuture;
      final reconnectOutcome = await reconnectFuture;

      expect(prewarmResult, isNull);
      expect(networkCalls, 1,
          reason: 'the reconnect side losing the claim must NOT retry the '
              'same cold RESUME itself — that would defeat the entire '
              'point of the guard (and hammer a session the server already '
              'said is gone)');
      expect(reconnectOutcome.fellThrough, isTrue,
          reason: 'nothing usable was produced — the branch must fall '
              'through to the normal pre-SSH-RESUME / SSH-bootstrap path, '
              'exactly as when `info == null` today');
      expect(reconnectOutcome.installed, isNull);
    });

    test(
        'prewarm wins the claim, RESUME succeeds, but the stub transport is '
        'still `connecting` (never reached `connected`) — reconnect side '
        'must NOT adopt it and must fall through instead', () async {
      final pool = PrewarmPool();
      const tabId = 'tab-active';

      Future<AqtTransport?> resumeToUnconnectedStub() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return AqtTransport.testStub(
          port: 12345,
          spki: Uint8List(32),
          token: Uint8List(32),
          tabId: 1,
          // default state: connecting — never actually became usable.
        );
      }

      final prewarmFuture =
          _replicatePrewarmAqtSession(pool, tabId, resumeToUnconnectedStub);
      final reconnectFuture =
          _replicateReconnectColdHydrate(pool, tabId, resumeToUnconnectedStub);

      await prewarmFuture;
      final reconnectOutcome = await reconnectFuture;

      expect(reconnectOutcome.fellThrough, isTrue,
          reason: 'adoption is gated on currentState == connected, '
              'mirroring terminal_screen.dart::_connectServer\'s own '
              'C4-adopt gate — a non-connected transport must never be '
              'installed');
    });

    test('two DIFFERENT tabs cold-hydrating concurrently both proceed '
        'independently (guard is per-tab, not global)', () async {
      final pool = PrewarmPool();
      var networkCalls = 0;

      Future<AqtTransport?> fakeResume() async {
        networkCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return _connectedStub();
      }

      final results = await Future.wait([
        _replicatePrewarmAqtSession(pool, 'tab-1', fakeResume),
        _replicatePrewarmAqtSession(pool, 'tab-2', fakeResume),
      ]);

      expect(networkCalls, 2,
          reason: 'the guard must not serialise unrelated tabs');
      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
    });
  });
}
