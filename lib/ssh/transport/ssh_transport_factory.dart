// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dartssh2/dartssh2.dart' show SSHPtyConfig;
import 'package:flutter/widgets.dart' show BuildContext;

import '../../data/models/server.dart';
import 'remote_transport.dart';
import 'ssh_transport.dart';
import 'transport_factory.dart';

/// Placeholder factory for SSH transport.
/// Full bootstrap (credentials, jump host, key pairs) will be wired in
/// when CompositeTransportFactory is built and has access to
/// SecureStorageService.
class SshTransportFactory implements TransportFactory {
  @override
  Future<RemoteTransport> connect(
    Server server, {
    BuildContext? dialogContext,
  }) async {
    throw TransportConnectException(
      'SshTransportFactory.connect not yet wired — '
      'use CompositeTransportFactory',
    );
  }

  @override
  Future<RemoteTransport> reconnect({
    required Server server,
    required ReconnectCredentials creds,
    RemoteTransport? previous,
    BuildContext? dialogContext,
    Future<void> Function()? onPurgeSession,
  }) async {
    // Reuse already-authenticated client when available (saves ~5-8 RTTs).
    final reuseClient = creds.reuseClient;
    if (reuseClient != null && !reuseClient.isClosed) {
      try {
        final session = await reuseClient.shell(
          pty: const SSHPtyConfig(type: 'xterm-256color'),
        );
        return SshTransport(reuseClient, session);
      } catch (_) {
        // Fall through to full reconnect below.
      }
    }
    // Full reconnect — not yet wired in this placeholder factory.
    return connect(server);
  }
}
