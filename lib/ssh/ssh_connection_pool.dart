// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../util/dlog.dart';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// Shared `SSHClient` cache for ControlMaster-style multiplexing.
///
/// When multiple [SessionTab]s connect to the same `(host, port, user,
/// keyId)` tuple, the second tab onwards skips the full TCP + KEX +
/// auth handshake and just opens a new shell channel on the existing
/// client. Saves roughly 200–500 ms per subsequent tab depending on
/// network RTT and key algorithm.
///
/// v1 scope (matches `docs/ssh-protocol-roadmap.md` P1-7 Phase 1):
///   • Direct connections only — jump-host paths get unique keys so
///     they effectively bypass pooling.
///   • Public-key auth only — password auth is not pooled. Sharing
///     a client across password-auth tabs would require us to keep
///     credentials around for re-auth on death, which is out of scope.
///   • Refcount-based lifecycle: last tab to release a client closes
///     it.
///   • Concurrent acquires for the same key share the in-flight build
///     future via [_pending] so we never build the same client twice
///     during simultaneous tab opens.
///
/// v2 follow-ups (deferred):
///   • Jump-host pooling (jump-client + target-client both shared).
///   • Coordinated reconnect when a pooled client dies — all dependent
///     tabs share the next-rebuilt client instead of each retrying
///     independently and racing to repopulate the pool.
class SshConnectionPool {
  final Map<String, _PooledClient> _alive = {};
  final Map<String, List<_PooledClient>> _retired = {};
  final Map<String, Future<_PooledClient>> _pending = {};

  /// How long to keep a client warm after the last reference is
  /// released. New tabs to the same target within this window reuse
  /// the existing SSH client (saves ~200–500 ms of TCP+KEX+auth).
  /// Set to [Duration.zero] to close immediately on refcount=0.
  static const _idleRetention = Duration(seconds: 30);

  /// Build a key for a direct (no-jump) public-key auth connection.
  /// Anything that doesn't match these conditions returns a unique
  /// key — those connections effectively bypass pooling.
  static String? keyFor({
    required String host,
    required int port,
    required String username,
    required String authType,
    String? keyId,
    String? jumpHostId,
  }) {
    if (jumpHostId != null) return null; // jump-host: not pooled in v1
    if (authType != 'key' || keyId == null) return null; // password: not pooled
    return 'd:$host:$port:$username:$keyId';
  }

  /// Acquire a client for [key]. If a healthy client already exists,
  /// returns it with a bumped refcount. If a build is already in
  /// flight for the same [key], awaits that. Otherwise calls [build]
  /// to construct a fresh client.
  ///
  /// Caller must invoke [release] exactly once when done with the
  /// returned client (typically from `SSHConnection.close()`).
  Future<SSHClient> acquire(
    String key,
    Future<SSHClient> Function() build,
  ) async {
    final existing = _alive[key];
    if (existing != null && !existing.isClosed) {
      // Cancel any pending idle-shutdown timer — we're back in use.
      existing.idleTimer?.cancel();
      existing.idleTimer = null;
      existing.refCount++;
      dlog('SshPool', 'reuse key=$key refcount=${existing.refCount}');
      return existing.sshClient;
    }
    // Build dropped this entry but didn't remove it yet — clean up.
    if (existing != null && existing.isClosed) {
      _alive.remove(key);
    }
    final inFlight = _pending[key];
    if (inFlight != null) {
      final pc = await inFlight;
      pc.refCount++;
      dlog('SshPool',
        'joined in-flight build key=$key refcount=${pc.refCount}',
      );
      return pc.sshClient;
    }
    final fut = _build(key, build);
    _pending[key] = fut;
    final pc = await fut;
    return pc.sshClient;
  }

  Future<_PooledClient> _build(
    String key,
    Future<SSHClient> Function() build,
  ) async {
    try {
      final client = await build();
      final pc = _PooledClient.ssh(key: key, client: client, refCount: 1);
      _alive[key] = pc;
      // Auto-evict from the pool if the underlying client closes
      // unexpectedly (idle timeout, server reboot, network drop).
      // Refcount stays where it was — each owner will independently
      // hit acquire() again on its own reconnect path and trigger
      // a fresh build.
      client.done.whenComplete(() {
        if (_alive[key] == pc) _alive.remove(key);
        dlog('SshPool', 'client died, evicted key=$key');
      });
      dlog('SshPool', 'built fresh client key=$key');
      return pc;
    } finally {
      _pending.remove(key);
    }
  }

  /// Decrement the refcount for [key]. When the count drops to
  /// zero the entry is **kept warm** for [_idleRetention] seconds —
  /// during that window a fresh acquire for the same key reuses
  /// the still-authenticated client (the common "close tab → open
  /// new tab to same host" pattern). After the timer fires the
  /// client is closed and the entry removed.
  void release(String key, [SSHClient? client]) {
    _release(key, client);
  }

  void _release(String key, Object? client) {
    final pc = _findClient(key, client);
    if (pc == null) return;
    pc.refCount--;
    dlog('SshPool', 'release key=$key refcount=${pc.refCount}');
    if (pc.refCount <= 0) {
      if (pc.retired) {
        _removeRetired(key, pc);
        _evictAndClose(key, pc);
        return;
      }
      if (_idleRetention == Duration.zero) {
        _evictAndClose(key, pc);
        return;
      }
      // Schedule lazy close. acquire() cancels this timer if the
      // entry is reused within the window.
      pc.idleTimer?.cancel();
      pc.idleTimer = Timer(_idleRetention, () {
        // Re-check refcount in case a race re-bumped it (idleTimer
        // is canceled in the synchronous part of acquire(), but
        // belt-and-suspenders).
        if (pc.refCount <= 0 && _alive[key] == pc) {
          _evictAndClose(key, pc);
        }
      });
      dlog('SshPool',
        'idle hold key=$key for ${_idleRetention.inSeconds}s',
      );
    }
  }

  /// Forcefully remove a pooled client when it is no longer safe to reuse.
  ///
  /// This is intentionally stronger than [release]: a TCP/SSH transport can
  /// still report `isClosed == false` after Android background/network changes,
  /// while the server refuses new channels on it. Keeping such a half-dead
  /// client warm makes every new tab fail with `SSHChannelOpenError` until the
  /// app process is restarted.
  void invalidate(String key, SSHClient client) {
    _invalidate(key, client);
  }

  void _invalidate(String key, Object client) {
    final pc = _alive[key];
    if (pc == null || !pc.matches(client)) return;
    _alive.remove(key);
    pc.idleTimer?.cancel();
    pc.idleTimer = null;
    if (pc.refCount <= 1) {
      _evictAndClose(key, pc);
      dlog('SshPool', 'invalidated key=$key');
      return;
    }
    // Existing tabs may still have live channels on this transport. Do not
    // close it under them; just retire it from future acquire() calls. Each
    // owner releases by exact client identity, and the last release closes it.
    pc.retired = true;
    (_retired[key] ??= <_PooledClient>[]).add(pc);
    dlog('SshPool', 'invalidated key=$key');
  }

  _PooledClient? _findClient(String key, Object? client) {
    final alive = _alive[key];
    if (client == null) return alive;
    if (alive != null && alive.matches(client)) return alive;
    final retired = _retired[key];
    if (retired == null) return null;
    for (final pc in retired) {
      if (pc.matches(client)) return pc;
    }
    return null;
  }

  void _removeRetired(String key, _PooledClient pc) {
    final retired = _retired[key];
    if (retired == null) return;
    retired.remove(pc);
    if (retired.isEmpty) _retired.remove(key);
  }

  void _evictAndClose(String key, _PooledClient pc) {
    pc.idleTimer?.cancel();
    pc.idleTimer = null;
    if (_alive[key] == pc) _alive.remove(key);
    try {
      pc.close();
    } catch (_) {
      /* already closed */
    }
    dlog('SshPool', 'evicted + closed key=$key');
  }

  /// True if [key] currently has a healthy pooled client. Test-only
  /// convenience; production code should call [acquire] instead.
  @visibleForTesting
  bool isHealthy(String key) {
    final pc = _alive[key];
    return pc != null && !pc.isClosed;
  }

  @visibleForTesting
  int refCountOf(String key) => _alive[key]?.refCount ?? 0;

  @visibleForTesting
  int get aliveCount => _alive.length;

  @visibleForTesting
  int retiredCountOf(String key) => _retired[key]?.length ?? 0;

  /// Inserts a pure-Dart test double into the pool without constructing a real
  /// [SSHClient]. Keeps production API paths typed to [SSHClient] while letting
  /// tests exercise refcount/retirement lifecycle by object identity.
  @visibleForTesting
  void addClientForTesting(
    String key,
    Object client, {
    required int refCount,
    bool isClosed = false,
    void Function()? onClose,
  }) {
    _alive[key] = _PooledClient.testing(
      key: key,
      client: client,
      refCount: refCount,
      isClosed: isClosed,
      onClose: onClose,
    );
  }

  @visibleForTesting
  void invalidateForTesting(String key, Object client) =>
      _invalidate(key, client);

  @visibleForTesting
  void releaseForTesting(String key, [Object? client]) => _release(key, client);
}

class _PooledClient {
  final String key;
  final Object client;
  final bool Function() _isClosed;
  final void Function() _close;
  int refCount;
  bool retired = false;

  /// Timer scheduled when refCount drops to 0 — closes the client
  /// after [SshConnectionPool._idleRetention]. Cancelled if the
  /// entry is reused (acquire) before it fires.
  Timer? idleTimer;

  _PooledClient._({
    required this.key,
    required this.client,
    required this.refCount,
    required bool Function() isClosed,
    required void Function() close,
  }) : _isClosed = isClosed,
       _close = close;

  factory _PooledClient.ssh({
    required String key,
    required SSHClient client,
    required int refCount,
  }) {
    return _PooledClient._(
      key: key,
      client: client,
      refCount: refCount,
      isClosed: () => client.isClosed,
      close: client.close,
    );
  }

  factory _PooledClient.testing({
    required String key,
    required Object client,
    required int refCount,
    required bool isClosed,
    void Function()? onClose,
  }) {
    var closed = isClosed;
    return _PooledClient._(
      key: key,
      client: client,
      refCount: refCount,
      isClosed: () => closed,
      close: () {
        closed = true;
        onClose?.call();
      },
    );
  }

  bool get isClosed => _isClosed();

  SSHClient get sshClient => client as SSHClient;

  bool matches(Object other) => identical(client, other);

  void close() => _close();
}
