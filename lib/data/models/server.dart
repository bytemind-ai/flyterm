// SPDX-License-Identifier: GPL-3.0-or-later
import '../../ssh/multiplexer/multiplexer_backend.dart';
import '../../ssh/transport/transport.dart';

class Server {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String authType;
  final String? keyId;
  final DateTime? lastConnectedAt;
  final String? startupCommand;
  final String? jumpHostId;
  final String moshPortRange;
  final int? moshPid;
  final String? groupName;
  final bool agentForwarding;
  final String serverType; // 'ssh' | 'local'
  /// IP version policy for resolving [host].
  /// 'auto' | 'ipv4' | 'ipv6'. Ignored for serverType='local'.
  final String addressFamily;

  /// Transport protocol. QUIC is strict — no SSH fallback.
  final Transport transport;

  /// tmux process persistence (master-era source-of-truth).
  /// Orthogonal to transport — applies to all protocols.
  final bool useTmux;

  /// QUIC daemon-strict mode. Only meaningful when [transport] == quic.
  /// When true, connect path runs `flyterm-server --status` first; on miss,
  /// starts daemon via `nohup ... --listen 0 & disown` and polls daemon.info.
  /// Failure does NOT fall back to once — surfaces an explicit error.
  final bool useDaemon;

  /// UDP port or range (`61001-61999`) the AQT daemon listens on. Null/empty
  /// means [AqtPortSpec.defaults]. A fixed range is what lets users open the
  /// server firewall ahead of time; see `aqt_port_spec.dart`.
  final String? aqtPorts;

  /// "Always use the SSH channel": skip the UDP attempt and run QUIC over
  /// an SSH exec channel from the start (see `aqt_ssh_relay.dart`). For
  /// hosts that only expose port 22 or networks that block UDP.
  final bool aqtViaSsh;

  /// Last SFTP path browsed for this server. Written every time the user
  /// navigates within the inline SFTP view; read as the starting directory
  /// on the next SFTP open (including after app restart). Null = use HOME.
  final String? sftpLastPath;

  /// Whether the tab was last closed in SFTP view mode. On cold start the
  /// tab is restored to this mode and _openSftp is triggered automatically
  /// once the SSH connection is established.
  final bool sftpViewMode;

  /// Backend dispatch helper. Derived from [useTmux].
  /// shpool removed in v23; tmux is the only remaining multiplexer.
  MultiplexerType get multiplexerType =>
      useTmux ? MultiplexerType.tmux : MultiplexerType.none;

  static const _absent = Object();

  const Server({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    this.keyId,
    this.lastConnectedAt,
    this.startupCommand,
    this.useTmux = false,
    this.jumpHostId,
    this.moshPortRange = '60000:61000',
    this.moshPid,
    this.groupName,
    this.agentForwarding = false,
    this.serverType = 'ssh',
    this.addressFamily = 'auto',
    this.transport = Transport.quic,
    // Default daemon=true so QUIC sessions survive app restart. Once mode
    // (daemon=false) ties server lifetime to the SSH session — app close
    // closes SSH → SIGHUP → server exits → cold-RESUME has no source to
    // recover from. Daemon mode runs setsid+nohup detached, survives the
    // SSH channel close. Users can opt out via the server form toggle if
    // they explicitly want clean teardown.
    this.useDaemon = true,
    this.aqtPorts,
    this.aqtViaSsh = false,
    this.sftpLastPath,
    this.sftpViewMode = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'auth_type': authType,
        'key_id': keyId,
        'last_connected_at': lastConnectedAt?.millisecondsSinceEpoch,
        'startup_command': startupCommand,
        'use_tmux': useTmux ? 1 : 0,
        'jump_host_id': jumpHostId,
        'mosh_port_range': moshPortRange,
        'mosh_pid': moshPid,
        'group_name': groupName,
        'agent_forwarding': agentForwarding ? 1 : 0,
        'server_type': serverType,
        'address_family': addressFamily,
        'connection_strategy': transport.name,
        'use_daemon': useDaemon ? 1 : 0,
        'aqt_ports': aqtPorts,
        'aqt_via_ssh': aqtViaSsh ? 1 : 0,
      };

  factory Server.fromMap(Map<String, dynamic> map) {
    return Server(
      id: map['id'] as String,
      name: map['name'] as String,
      host: map['host'] as String,
      port: map['port'] as int,
      username: map['username'] as String,
      authType: map['auth_type'] as String,
      keyId: map['key_id'] as String?,
      lastConnectedAt: map['last_connected_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['last_connected_at'] as int)
          : null,
      startupCommand: map['startup_command'] as String?,
      useTmux: (map['use_tmux'] as int? ?? 0) == 1,
      jumpHostId: map['jump_host_id'] as String?,
      moshPortRange: (map['mosh_port_range'] as String?) ?? '60000:61000',
      moshPid: map['mosh_pid'] as int?,
      groupName: map['group_name'] as String?,
      agentForwarding: (map['agent_forwarding'] as int? ?? 0) == 1,
      serverType: (map['server_type'] as String?) ?? 'ssh',
      addressFamily: (map['address_family'] as String?) ?? 'auto',
      // Graceful handling of legacy enum strings from pre-v24 DBs /
      // restored backups: unknown values fall back to Transport.quic.
      transport: Transport.values.firstWhere(
        (t) => t.name == (map['connection_strategy'] as String? ?? 'quic'),
        orElse: () => Transport.quic,
      ),
      // Default true (matches constructor default) so legacy maps without
      // the key inherit the same daemon-on behaviour. DB schema has
      // DEFAULT 1 so this fallback is theoretical for live data.
      useDaemon: (map['use_daemon'] as int? ?? 1) == 1,
      aqtPorts: map['aqt_ports'] as String?,
      aqtViaSsh: (map['aqt_via_ssh'] as int? ?? 0) == 1,
      sftpLastPath: map['sftp_last_path'] as String?,
      sftpViewMode: (map['sftp_view_mode'] as int? ?? 0) == 1,
    );
  }

  Server copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? authType,
    String? keyId,
    DateTime? lastConnectedAt,
    String? startupCommand,
    bool? useTmux,
    Object? jumpHostId = _absent,
    String? moshPortRange,
    Object? moshPid = _absent,
    Object? groupName = _absent,
    bool? agentForwarding,
    String? serverType,
    String? addressFamily,
    Transport? transport,
    bool? useDaemon,
    String? aqtPorts,
    bool? aqtViaSsh,
  }) =>
      Server(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        authType: authType ?? this.authType,
        keyId: keyId ?? this.keyId,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        startupCommand: startupCommand ?? this.startupCommand,
        useTmux: useTmux ?? this.useTmux,
        jumpHostId: identical(jumpHostId, _absent)
            ? this.jumpHostId
            : jumpHostId as String?,
        moshPortRange: moshPortRange ?? this.moshPortRange,
        moshPid: identical(moshPid, _absent) ? this.moshPid : moshPid as int?,
        groupName: identical(groupName, _absent)
            ? this.groupName
            : groupName as String?,
        agentForwarding: agentForwarding ?? this.agentForwarding,
        serverType: serverType ?? this.serverType,
        addressFamily: addressFamily ?? this.addressFamily,
        transport: transport ?? this.transport,
        useDaemon: useDaemon ?? this.useDaemon,
        aqtPorts: aqtPorts ?? this.aqtPorts,
        aqtViaSsh: aqtViaSsh ?? this.aqtViaSsh,
      );
}
