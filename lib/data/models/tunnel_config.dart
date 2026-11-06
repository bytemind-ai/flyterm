// SPDX-License-Identifier: GPL-3.0-or-later
import '../../tunnel/tunnel_entry.dart';

class TunnelConfig {
  final String id;
  final String serverId;
  final TunnelDirection direction;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final String label;
  final bool autoStart;

  const TunnelConfig({
    required this.id,
    required this.serverId,
    required this.direction,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.label,
    required this.autoStart,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'server_id': serverId,
        'direction': direction.name,
        'local_port': localPort,
        'remote_host': remoteHost,
        'remote_port': remotePort,
        'label': label,
        'auto_start': autoStart ? 1 : 0,
      };

  factory TunnelConfig.fromMap(Map<String, dynamic> map) => TunnelConfig(
        id: map['id'] as String,
        serverId: map['server_id'] as String,
        direction: TunnelDirection.values.byName(map['direction'] as String),
        localPort: map['local_port'] as int,
        remoteHost: map['remote_host'] as String,
        remotePort: map['remote_port'] as int,
        label: map['label'] as String,
        autoStart: (map['auto_start'] as int) == 1,
      );
}
