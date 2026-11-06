// SPDX-License-Identifier: GPL-3.0-or-later
import '../../data/models/server.dart';
import '../../tunnel/tunnel_entry.dart';

/// 一台服务器 + 它名下的隧道。隧道总览按此分组渲染。
class ServerTunnelGroup {
  final Server server;
  final List<TunnelEntry> tunnels;

  const ServerTunnelGroup({required this.server, required this.tunnels});
}

/// serverId → 隧道条数。
///
/// 计数口径：`tunnels` 里的**全部条目**（已保存 + 临时新建都在内）。
/// 服务器行徽标回答的是「这台配了几条隧道」，不区分 `saved`。
Map<String, int> tunnelCountsByServer(List<TunnelEntry> tunnels) {
  final counts = <String, int>{};
  for (final t in tunnels) {
    counts[t.server.id] = (counts[t.server.id] ?? 0) + 1;
  }
  return counts;
}

/// 按服务器分组，供隧道总览渲染。
///
/// - 组按 `server.name` 升序
/// - 组内：`active` / `connecting` 在前，`error` / `stopped` 在后；
///   同状态按 `label` 升序
/// - [query] 非空时按 `label` / `displayPorts` / `server.name`（均忽略大小写）过滤
List<ServerTunnelGroup> groupTunnelsByServer(
  List<TunnelEntry> tunnels, {
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  final filtered = q.isEmpty
      ? tunnels
      : tunnels
          .where((t) =>
              t.label.toLowerCase().contains(q) ||
              t.displayPorts.toLowerCase().contains(q) ||
              t.server.name.toLowerCase().contains(q))
          .toList();

  final byServer = <String, List<TunnelEntry>>{};
  final serverById = <String, Server>{};
  for (final t in filtered) {
    (byServer[t.server.id] ??= []).add(t);
    serverById[t.server.id] = t.server;
  }

  int rank(TunnelStatus s) => switch (s) {
        TunnelStatus.active => 0,
        TunnelStatus.connecting => 1,
        TunnelStatus.error => 2,
        TunnelStatus.stopped => 3,
      };

  final groups = byServer.entries.map((e) {
    final list = e.value
      ..sort((a, b) {
        final r = rank(a.status).compareTo(rank(b.status));
        if (r != 0) return r;
        return a.label.compareTo(b.label);
      });
    return ServerTunnelGroup(server: serverById[e.key]!, tunnels: list);
  }).toList()
    ..sort((a, b) => a.server.name.compareTo(b.server.name));

  return groups;
}
