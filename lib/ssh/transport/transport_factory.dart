// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dartssh2/dartssh2.dart' show SSHKeyPair, SSHClient;
import 'package:flutter/widgets.dart' show BuildContext;

import '../../data/models/server.dart';
import 'remote_transport.dart';

export 'transport.dart';

/// Credentials injected by ReconnectService for hard reconnect.
/// Keeps credentials out of transport classes (single-responsibility).
class ReconnectCredentials {
  final String? password;
  final String? privateKeyPem;
  final List<SSHKeyPair> keyPairs;
  /// Already-authenticated SSH client to reuse (avoids full re-auth).
  final SSHClient? reuseClient;

  const ReconnectCredentials({
    this.password,
    this.privateKeyPem,
    this.keyPairs = const [],
    this.reuseClient,
  });
}

/// Transport creation factory. SessionManager uses this instead of
/// constructing transports directly.
abstract class TransportFactory {
  /// Connect using server.transport. Strict — no fallback chain.
  /// Throws [TransportConnectException] on failure.
  ///
  /// [dialogContext] (optional) lets the QUIC path show the first-time install
  /// dialog. If null, install prompts are skipped.
  Future<RemoteTransport> connect(
    Server server, {
    BuildContext? dialogContext,
  });

  /// Hard reconnect: create a new transport, reusing session state where possible.
  /// [previous] is the old transport — implementations may extract resume tokens.
  /// [onPurgeSession] (optional) is invoked when the implementation detects the
  /// server has lost the session token (e.g. QUIC RESUME → sessionNotFound after
  /// a server restart). Callers (ReconnectService) pass a callback that removes
  /// the stale token from persistent storage so cold restarts don't burn an RTT
  /// retrying a token that can never succeed again.
  /// Throws [TransportConnectException] on failure.
  /// [resumeLastOutOff] / [resumeRingTailHash] are the client's acknowledged
  /// position in the server's output ring, forwarded to any RESUME the
  /// implementation attempts. Leaving them at 0 forces a COLD resume: the
  /// server replays its whole authoritative history (up to 256 KiB) instead of
  /// the delta since the last ack — slower, and the caller then has to reconcile
  /// that history against what the terminal already shows. Non-QUIC
  /// implementations ignore both.
  Future<RemoteTransport> reconnect({
    required Server server,
    required ReconnectCredentials creds,
    RemoteTransport? previous,
    BuildContext? dialogContext,
    Future<void> Function()? onPurgeSession,
  });
}

class TransportConnectException implements Exception {
  final String message;
  final Object? cause;
  const TransportConnectException(this.message, [this.cause]);
  @override
  String toString() => 'TransportConnectException: $message';
}
