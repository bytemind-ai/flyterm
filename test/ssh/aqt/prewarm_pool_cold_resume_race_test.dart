// Reproduction + regression test for root-cause (A) from the production log
// analysis (/root/.flyterm-server/state/daemon.log, 296 connections / 7
// sessions, 23 same-second double-connects):
//
//   main.dart::_prewarmAqtSession (fired for the last-active tab, BEFORE
//   ReconnectService even exists) and ReconnectService._reconnect()'s
//   `isQuicHydrate && tab.transport == null` cold-hydrate branch (fired
//   moments later via reconnectAll()) each independently load the same
//   on-disk AqtSessionInfo for the same tabId and each send their own
//   RESUME to the server with the same session token. Neither knows about
//   the other — ReconnectService's `_reconnecting` / `_retrying` /
//   `_proactiveResuming` / `_proactiveResumeCompleters` guards all live
//   inside the ReconnectService instance, which the prewarm call predates.
//
// This is exactly the documented race in reconnect_service.dart's
// `_proactiveResumeCompleters` comment ("both can get RESUME_ACK ... the
// DISCARD-swap close() may kill the server session, leaving the survivor
// as a phantom-connected transport") — just via a second, entirely
// unguarded call site.
//
// `PrewarmPool` is the one object both call sites already share (main.dart
// passes `sessionManager.prewarmPool` into `_prewarmAqtSession`;
// ReconnectService holds the same `SessionManager` and can reach
// `_sessionManager.prewarmPool`). This test drives the fix's guard API
// directly against a fake "cold RESUME" network call to prove: (1) the
// guard collapses two concurrent claims for the same tabId into a single
// network attempt, (2) the loser waits for the winner and adopts its
// result, (3) a THIRD caller for a *different* tabId is never blocked by
// the first tab's claim.
import 'dart:async';
import 'dart:typed_data';

import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/prewarm_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrewarmPool cold-RESUME claim guard', () {
    test('claimColdResume: first caller wins, second is refused until release', () {
      final pool = PrewarmPool();
      expect(pool.claimColdResume('tab-a'), isTrue);
      expect(pool.claimColdResume('tab-a'), isFalse,
          reason: 'a second claim for the same tab while the first is '
              'still in flight must be refused — that is the whole point '
              'of the guard');
      // A different tab is never blocked by tab-a's claim.
      expect(pool.claimColdResume('tab-b'), isTrue);

      pool.releaseColdResumeClaim('tab-a');
      // Released — a fresh claim can now succeed again.
      expect(pool.claimColdResume('tab-a'), isTrue);
    });

    test('coldResumeFuture is null with no claim held, and completes when released', () async {
      final pool = PrewarmPool();
      expect(pool.coldResumeFuture('tab-a'), isNull);

      expect(pool.claimColdResume('tab-a'), isTrue);
      final future = pool.coldResumeFuture('tab-a');
      expect(future, isNotNull);

      var completed = false;
      future!.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse, reason: 'must not complete before release');

      pool.releaseColdResumeClaim('tab-a');
      await future;
      expect(completed, isTrue);
    });

    test(
        'concurrent cold-RESUME race for the same tab: exactly one network '
        'call fires; the loser waits and adopts the winner\'s transport',
        () async {
      final pool = PrewarmPool();
      var networkCalls = 0;
      const tabId = 'tab-active';

      // Hand-replicates the intended call-site shape for BOTH racing
      // callers (main.dart::_prewarmAqtSession and ReconnectService's
      // cold-hydrate branch) once wired through the shared PrewarmPool
      // guard — same claim/resume/store/release skeleton on both sides.
      Future<AqtTransport?> attemptColdResume() async {
        if (pool.claimColdResume(tabId)) {
          try {
            networkCalls++;
            // Simulate the RESUME round-trip (SecureStorage read + QUIC
            // handshake) taking long enough for the other caller to have
            // already reached its own claim attempt and lost.
            await Future<void>.delayed(const Duration(milliseconds: 20));
            final t = _stub();
            pool.store(tabId, t);
            return t;
          } finally {
            pool.releaseColdResumeClaim(tabId);
          }
        }
        // Lost the claim — wait for the winner, then adopt whatever it left
        // in the pool (may be null if the winner's RESUME failed).
        await pool.coldResumeFuture(tabId);
        return pool.take(tabId);
      }

      final results = await Future.wait([
        attemptColdResume(), // simulates main.dart's prewarm
        attemptColdResume(), // simulates reconnectAll()'s cold-hydrate branch
      ]);

      expect(networkCalls, 1,
          reason: 'root cause A: without the guard both callers fire their '
              'own RESUME for the same tab/session-token — exactly the '
              '23 same-second double-connect events in the production log');
      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
      expect(identical(results[0], results[1]), isTrue,
          reason: 'the loser must adopt the SAME transport the winner '
              'installed, not create its own');
    });

    test(
        'concurrent cold-RESUME for two DIFFERENT tabs both proceed '
        '(guard is per-tab, not global)', () async {
      final pool = PrewarmPool();
      var networkCalls = 0;

      Future<void> attempt(String tabId) async {
        if (pool.claimColdResume(tabId)) {
          try {
            networkCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          } finally {
            pool.releaseColdResumeClaim(tabId);
          }
        }
      }

      await Future.wait([attempt('tab-1'), attempt('tab-2')]);
      expect(networkCalls, 2,
          reason: 'the guard must not serialise unrelated tabs');
    });
  });
}

AqtTransport _stub() => AqtTransport.testStub(
      port: 12345,
      spki: Uint8List(32),
      token: Uint8List(32),
      tabId: 1,
    );
