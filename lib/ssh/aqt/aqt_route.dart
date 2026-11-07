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
  final Set<String> _fallbackNotified = {};

  AqtRoute? get(String serverId) => _routes[serverId];

  void set(String serverId, AqtRoute route) => _routes[serverId] = route;

  /// True the first time per server: the "UDP unavailable, using the SSH
  /// channel" notice is shown once per run, not on every reconnect.
  bool markFallbackNotified(String serverId) => _fallbackNotified.add(serverId);
}

class AqtRouteOutcome<T> {
  final T value;
  final AqtRoute route;

  /// The SSH channel was used because the direct attempt failed (as opposed
  /// to the user's "always use the SSH channel" or a cached decision).
  final bool autoFellBack;

  const AqtRouteOutcome(this.value, this.route, {this.autoFellBack = false});
}

/// Both routes failed; carries both reasons.
class AqtRouteException implements Exception {
  final Object direct;
  final Object viaSsh;
  const AqtRouteException(this.direct, this.viaSsh);

  @override
  String toString() => 'UDP: $direct | SSH relay: $viaSsh';
}

/// Picks the route: the SSH channel straight away when forced or already
/// known for this server, otherwise [direct] first and [viaSsh] if it
/// fails. [direct] carries its own timeout.
Future<AqtRouteOutcome<T>> connectWithRoute<T>({
  required bool forceViaSsh,
  required AqtRoute? cached,
  required Future<T> Function() direct,
  required Future<T> Function() viaSsh,
}) async {
  if (forceViaSsh || cached == AqtRoute.viaSsh) {
    return AqtRouteOutcome(await viaSsh(), AqtRoute.viaSsh);
  }
  final Object directError;
  try {
    return AqtRouteOutcome(await direct(), AqtRoute.direct);
  } catch (e) {
    directError = e;
  }
  try {
    return AqtRouteOutcome(await viaSsh(), AqtRoute.viaSsh, autoFellBack: true);
  } catch (e) {
    throw AqtRouteException(directError, e);
  }
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
