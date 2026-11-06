// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'aqt_transport.dart';

/// C4 — Holds AqtTransport instances that were preemptively connected
/// during app startup, before the user navigated to the terminal screen.
/// When the terminal opens its tab, it calls [take] to adopt a ready
/// transport, skipping the usual RESUME + bootstrap path entirely.
///
/// Lifecycle:
///   - `main.dart::_prewarmAqtSession` calls [store] after a background
///     RESUME completes.
///   - `terminal_screen.dart::_connectServer` calls [take] when entering
///     a tab whose id matches.
///   - A 30s timer in `_prewarmAqtSession` calls [evictAndClose] if the
///     user never opens the tab — bounds wasted-transport window.
///
/// Not thread-safe — Dart is single-threaded by default and all callers
/// run on the main isolate.
class PrewarmPool {
  final _entries = <String, AqtTransport>{};

  /// Stash [t] under [tabId]. If something was already there, close it
  /// off-band (fire-and-forget) so the new entry is immediately usable.
  void store(String tabId, AqtTransport t) {
    final old = _entries[tabId];
    _entries[tabId] = t;
    if (old != null && !identical(old, t)) {
      // Best-effort close; do NOT await inside store.
      old.close().catchError((_) {});
    }
  }

  /// Remove and return the transport for [tabId], or null if absent.
  AqtTransport? take(String tabId) => _entries.remove(tabId);

  /// Whether [tabId] has a stashed transport.
  bool has(String tabId) => _entries.containsKey(tabId);

  /// Remove the entry for [tabId] and close its transport. Best-effort
  /// on the close — never throws. No-op if absent.
  ///
  /// The close is fire-and-forget: the entry is removed immediately and the
  /// returned Future completes right away, so callers are not blocked waiting
  /// for the underlying QUIC teardown to finish.
  Future<void> evictAndClose(String tabId) async {
    final t = _entries.remove(tabId);
    if (t != null) {
      t.close().catchError((_) {});
    }
  }

  /// Clear all entries and close their transports. Used during teardown.
  ///
  /// Like [evictAndClose], closes are fire-and-forget so this returns
  /// promptly even when many transports are being torn down.
  Future<void> evictAll() async {
    final ts = _entries.values.toList();
    _entries.clear();
    for (final t in ts) {
      t.close().catchError((_) {});
    }
  }

  // ── Cold-RESUME in-flight guard ──────────────────────────────────────
  //
  // Root cause (production log analysis, /root/.flyterm-server/state/daemon.log):
  // `main.dart::_prewarmAqtSession` (fired for the last-active restored tab,
  // BEFORE ReconnectService is even constructed) and
  // `ReconnectService._reconnect()`'s `isQuicHydrate && tab.transport == null`
  // cold-hydrate branch (fired moments later via `reconnectAll()`) each
  // independently load the SAME on-disk `AqtSessionInfo` for the SAME tabId
  // and each send their own RESUME to the server with the same session
  // token. Neither call site knew about the other:
  // `_reconnecting`/`_retrying`/`_proactiveResuming`/`_proactiveResumeCompleters`
  // all live inside the `ReconnectService` instance, which the prewarm call
  // predates. This is the same race documented on
  // `ReconnectService._proactiveResumeCompleters` ("both can get RESUME_ACK
  // ... the DISCARD-swap close() may kill the server session, leaving the
  // survivor as a phantom-connected transport") via a second, previously
  // unguarded call site — see the production log's 23 same-second
  // double-connect events, several of which are exactly this pair.
  //
  // [PrewarmPool] is the one object both call sites already share (main.dart
  // passes `sessionManager.prewarmPool` into `_prewarmAqtSession`;
  // `ReconnectService` holds the same `SessionManager` and can reach
  // `_sessionManager.prewarmPool`), so the mutex lives here rather than on
  // `ReconnectService`, whose lifecycle starts too late to guard the prewarm
  // call.
  //
  // Usage (mirrored on both call sites):
  //   if (pool.claimColdResume(tabId)) {
  //     try {
  //       // ... perform the RESUME; pool.store(tabId, transport) on success ...
  //     } finally {
  //       pool.releaseColdResumeClaim(tabId);
  //     }
  //   } else {
  //     await pool.coldResumeFuture(tabId); // wait for the claim holder
  //     final adopted = pool.take(tabId); // null if the winner's RESUME failed
  //   }
  final _coldResumeClaims = <String, Completer<void>>{};

  /// Attempt to become the sole cold-RESUME performer for [tabId]. Returns
  /// `true` if the caller now owns the claim (it MUST call
  /// [releaseColdResumeClaim] for this tabId, typically in a `finally`
  /// block, or every future caller will wait forever). Returns `false` if
  /// another caller already holds the claim — the caller should await
  /// [coldResumeFuture] instead of starting its own RESUME.
  bool claimColdResume(String tabId) {
    if (_coldResumeClaims.containsKey(tabId)) return false;
    _coldResumeClaims[tabId] = Completer<void>();
    return true;
  }

  /// Future that completes once the current cold-RESUME claim holder for
  /// [tabId] calls [releaseColdResumeClaim]. Returns `null` if nobody holds
  /// the claim right now (nothing to wait for).
  Future<void>? coldResumeFuture(String tabId) =>
      _coldResumeClaims[tabId]?.future;

  /// Release the claim taken via [claimColdResume], unblocking anyone
  /// awaiting [coldResumeFuture] for the same [tabId]. No-op if [tabId]
  /// holds no claim.
  void releaseColdResumeClaim(String tabId) {
    _coldResumeClaims.remove(tabId)?.complete();
  }
}
