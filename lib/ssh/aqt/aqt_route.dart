// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

/// How an AQT session reaches its daemon.
///
/// - [direct]: QUIC over UDP straight to the daemon's port.
/// - [viaSsh]: QUIC over an SSH exec channel (`flyterm-server --relay`), for
///   when UDP is blocked. See `aqt_ssh_relay.dart`.
///
/// Probed once, on a server's first connection in this app run; persisted
/// per session so every reconnect / RESUME (including after a cold start)
/// takes the same route without probing again.
enum AqtRoute { direct, viaSsh }

/// Per-server route probed in this app run (not persisted: a new run may be
/// on a different network). Sessions persist their own route separately.
class AqtRouteCache {
  static final AqtRouteCache instance = AqtRouteCache();

  final Map<String, AqtRoute> _routes = {};

  AqtRoute? get(String serverId) => _routes[serverId];

  void set(String serverId, AqtRoute route) => _routes[serverId] = route;
}

class AqtRouteOutcome<T> {
  final T value;
  final AqtRoute route;

  const AqtRouteOutcome(this.value, this.route);
}

/// Both routes failed; carries both reasons.
class AqtRouteException implements Exception {
  final Object direct;
  final Object viaSsh;
  const AqtRouteException(this.direct, this.viaSsh);

  @override
  String toString() => 'UDP: $direct | SSH relay: $viaSsh';
}

/// Picks the route. [forceViaSsh] goes straight to [viaSsh]. Otherwise the
/// two routes race: [direct] starts first and [viaSsh] starts once
/// [relayHeadStart] passes without a direct success (or as soon as direct
/// fails); with [cached] == viaSsh both start at once. The first success
/// wins; a value that arrives from the other route afterwards goes to
/// [discard]. Both failing throws [AqtRouteException]. Each route carries
/// its own timeout.
Future<AqtRouteOutcome<T>> connectWithRoute<T>({
  required bool forceViaSsh,
  required AqtRoute? cached,
  required Future<T> Function() direct,
  required Future<T> Function() viaSsh,
  required Future<void> Function(T loser) discard,
  Duration relayHeadStart = const Duration(milliseconds: 300),
}) {
  if (forceViaSsh) {
    return viaSsh().then((v) => AqtRouteOutcome(v, AqtRoute.viaSsh));
  }
  final result = Completer<AqtRouteOutcome<T>>();
  Object? directErr;
  Object? relayErr;
  var directFailed = false;
  var relayFailed = false;
  var relayStarted = false;
  Timer? headStart;

  void settle(T v, AqtRoute route) {
    if (result.isCompleted) {
      discard(v).catchError((Object _) {});
    } else {
      headStart?.cancel();
      result.complete(AqtRouteOutcome(v, route));
    }
  }

  void maybeFail() {
    if (directFailed && relayFailed && !result.isCompleted) {
      result.completeError(AqtRouteException(directErr!, relayErr!));
    }
  }

  void startRelay() {
    if (relayStarted) return;
    relayStarted = true;
    headStart?.cancel();
    Future<T> f;
    try {
      f = viaSsh();
    } catch (e) {
      f = Future<T>.error(e);
    }
    f.then((v) => settle(v, AqtRoute.viaSsh), onError: (Object e) {
      relayErr = e;
      relayFailed = true;
      maybeFail();
    });
  }

  Future<T> d;
  try {
    d = direct();
  } catch (e) {
    d = Future<T>.error(e);
  }
  d.then((v) => settle(v, AqtRoute.direct), onError: (Object e) {
    directErr = e;
    directFailed = true;
    startRelay();
    maybeFail();
  });

  if (cached == AqtRoute.viaSsh || relayHeadStart <= Duration.zero) {
    startRelay();
  } else {
    headStart = Timer(relayHeadStart, startRelay);
  }
  return result.future;
}

/// [future] with a [timeout]; if it still completes afterwards, [onLate]
/// disposes of the value. Needed because a connection that succeeds just
/// after we gave up would otherwise stay open with no owner.
Future<T> closeIfLate<T>(
  Future<T> future,
  Duration timeout, {
  required Future<void> Function(T value) onLate,
  required String timeoutMessage,
}) {
  var timedOut = false;
  future.then((v) {
    if (timedOut) onLate(v);
  }, onError: (Object _) {});
  return future.timeout(timeout, onTimeout: () {
    timedOut = true;
    throw TimeoutException(timeoutMessage, timeout);
  });
}
