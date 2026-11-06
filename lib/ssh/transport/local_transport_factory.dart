// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/widgets.dart' show BuildContext;

import '../../data/models/server.dart';
import '../local_shell.dart';
import 'local_transport.dart';
import 'remote_transport.dart';
import 'transport_factory.dart';

class LocalTransportFactory implements TransportFactory {
  @override
  Future<RemoteTransport> connect(
    Server server, {
    BuildContext? dialogContext,
  }) async {
    final shell = LocalShell();
    await shell.start();
    return LocalTransport(shell);
  }

  @override
  Future<RemoteTransport> reconnect({
    required Server server,
    required ReconnectCredentials creds,
    RemoteTransport? previous,
    BuildContext? dialogContext,
    Future<void> Function()? onPurgeSession,
  }) => connect(server);
}
