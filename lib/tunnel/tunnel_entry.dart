// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:uuid/uuid.dart';
import '../data/models/server.dart';

enum TunnelDirection { local, remote, socks5 }

enum TunnelStatus { connecting, active, error, stopped }

class TunnelEntry {
  final String id;
  final Server server;
  final TunnelDirection direction;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final String label;
  TunnelStatus status;
  String? errorMessage;
  bool autoStart;
  bool saved;
  int retryCount;

  static const maxRetries = 5;

  TunnelEntry({
    String? id,
    required this.server,
    required this.direction,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.label,
    this.status = TunnelStatus.connecting,
    this.errorMessage,
    this.autoStart = false,
    this.saved = false,
    this.retryCount = 0,
  }) : id = id ?? const Uuid().v4();

  /// Human-readable port mapping string.
  String get displayPorts => switch (direction) {
        TunnelDirection.local =>
          'localhost:$localPort → $remoteHost:$remotePort',
        TunnelDirection.remote =>
          '$remoteHost:$remotePort → localhost:$localPort',
        TunnelDirection.socks5 => 'SOCKS5 :$localPort',
      };
}
