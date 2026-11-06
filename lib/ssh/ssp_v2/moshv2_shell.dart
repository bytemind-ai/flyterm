// SPDX-License-Identifier: GPL-3.0-or-later
// Factory entry for the v2 mosh transport. Wraps MoshUdpSocket.bind +
// MoshV2Connection so callers don't need to know the network layout.
//
// NOTE: v2 returns the abstract SspTransport interface from
// `lib/ssh/ssp_interface.dart`. The legacy v1 god-object class
// `lib/ssh/ssp/ssp_transport.dart::SspTransport` is *not* the same type;
// TerminalStateSync currently depends on the v1 surface. Wiring v2 into
// MoshShell will be completed once the adapter (P4.2 follow-up) lands.
import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import '../ssp_interface.dart';
import 'network/udp_socket.dart';
import 'transport/connection.dart';

Future<SspTransport> createMoshV2Transport({
  required String host,
  required int port,
  required Uint8List sessionKey,
  int? initialCols,
  int? initialRows,
  // When provided, skips DNS resolution and binds directly to the already-
  // resolved address. Pass [MoshShellV2.resolvedPeerAddress] on soft reconnect
  // so InternetAddress.lookup() is not repeated for the same host.
  InternetAddress? resolvedAddr,
}) async {
  final udp = resolvedAddr != null
      ? await MoshUdpSocket.bindAddress(addr: resolvedAddr, port: port)
      : await MoshUdpSocket.bind(host: host, port: port);
  return MoshV2Connection(
    udp: udp,
    sessionKey: sessionKey,
    initialCols: initialCols,
    initialRows: initialRows,
  );
}
