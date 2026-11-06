// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/secure_storage.dart';
import '../../l10n/l10n.dart';
import '../../tunnel/tunnel_entry.dart';
import '../../tunnel/tunnel_manager.dart';
import '../design/fly_tokens.dart';
import 'tunnel_form_screen.dart';
import 'tunnel_grouping.dart';
import 'tunnel_status.dart';

/// 隧道列表体：可嵌入首页「隧道」分段，也可被 [TunnelListScreen]
/// 包在 Scaffold 里（`/tunnels` 深链）。
class TunnelListView extends StatelessWidget {
  const TunnelListView({super.key, this.query = ''});

  /// 非空时按 label / 端口映射 / 服务器名过滤。
  final String query;

  // ── Status helpers ─────────────────────────────────────────────────────

  IconData _directionIcon(TunnelDirection dir) => switch (dir) {
        TunnelDirection.local => Icons.arrow_forward,
        TunnelDirection.remote => Icons.arrow_back,
        TunnelDirection.socks5 => Icons.public,
      };

  Future<bool?> _confirmDelete(BuildContext context, TunnelEntry t) {
    final l = context.l10n;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.deleteTunnelTitle),
        content: Text(l.confirmDeleteTunnel(t.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.delete,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
  }

  // ── 长按动作面板 ──────────────────────────────────────────────────────

  /// 长按隧道行弹出的动作面板。结构与首页 `_showContextMenu`（服务器长按）
  /// 同构：头部信息 + Divider + ListTile 列表。
  ///
  /// 未保存（`saved == false`）的临时隧道没有可编辑/删除的存档，只给"停止"。
  Future<void> _showTunnelActions(
    BuildContext context,
    TunnelManager mgr,
    TunnelEntry t,
  ) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final isStopped = t.saved && t.status == TunnelStatus.stopped;

    return showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.cable, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.displayPorts,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontFamily: 'JetBrainsMono', fontSize: 11.5),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.dns_outlined,
                                size: 11,
                                color: cs.onSurface.withValues(alpha: 0.4)),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                t.server.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 10.5,
                                  color: cs.onSurface.withValues(alpha: 0.4),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(isStopped ? Icons.play_arrow : Icons.stop),
              title: Text(isStopped ? l.startTunnel : l.stopTunnel),
              onTap: () {
                Navigator.pop(ctx);
                if (isStopped) {
                  final storage = context.read<SecureStorageService>();
                  mgr.reactivate(t.id, storage);
                } else {
                  mgr.stopTunnel(t.id);
                }
              },
            ),
            if (t.saved)
              ListTile(
                leading: Icon(
                  t.autoStart ? Icons.alarm_off : Icons.alarm_on,
                  color: t.autoStart ? Colors.grey : const Color(0xFFFFB300),
                ),
                title: Text(
                    t.autoStart ? l.disableAutoConnect : l.enableAutoConnect),
                onTap: () {
                  Navigator.pop(ctx);
                  mgr.setAutoStart(t.id, !t.autoStart);
                },
              ),
            if (t.saved)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l.edit),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).pushNamed(
                    '/tunnels/form',
                    arguments: TunnelFormArgs(server: t.server),
                  );
                },
              ),
            if (t.saved)
              ListTile(
                leading: Icon(Icons.delete_outline, color: cs.error),
                title: Text(l.delete, style: TextStyle(color: cs.error)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await _confirmDelete(context, t);
                  if (ok == true) mgr.removeSaved(t.id);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Tunnel row ──────────────────────────────────────────────────────────

  Widget _buildTile(BuildContext context, TunnelManager mgr, TunnelEntry t) {
    final statusColor = tunnelStatusColor(t.status);
    final isStopped = t.saved && t.status == TunnelStatus.stopped;
    final isLive = !isStopped;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () {
            if (isStopped) {
              final storage = context.read<SecureStorageService>();
              mgr.reactivate(t.id, storage);
            } else {
              mgr.stopTunnel(t.id);
            }
          },
          // 与首页服务器行一致：长按弹动作面板。单击保留为启停（对应服务器
          // 的"单击=连接"）。
          onLongPress: () => _showTunnelActions(context, mgr, t),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                FlySpace.md, 10, FlySpace.sm, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 形状 = 方向，颜色 = 状态：方向图标不再吃 mint。
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: isLive
                        ? statusColor.withValues(alpha: 0.14)
                        : FlyColors.panelElevated,
                    borderRadius: FlyRadius.controlRadius,
                    border: Border.all(
                      color: isLive
                          ? statusColor.withValues(alpha: 0.5)
                          : FlyColors.divider,
                      width: kHairline,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    _directionIcon(t.direction),
                    size: 17,
                    color: isLive ? statusColor : FlyColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 首行只放 label：给最重要的字段拉满宽度（AUTO 下沉到
                      // 第三行，状态在右列，都不与它争宽）。
                      Text(
                        t.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FlyText.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isLive
                              ? FlyColors.textPrimary
                              : FlyColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        t.displayPorts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FlyText.secondary.copyWith(
                          fontFamily: FlyText.monoFamily,
                          color: FlyColors.textSecondary,
                          letterSpacing: 0,
                        ),
                      ),
                      if (t.errorMessage != null &&
                          t.status == TunnelStatus.error) ...[
                        const SizedBox(height: 2),
                        Text(
                          t.errorMessage!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FlyText.secondary.copyWith(
                            fontFamily: FlyText.monoFamily,
                            fontSize: 10.5,
                            color: FlyColors.danger,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.dns_outlined,
                              size: 11, color: FlyColors.textTertiary),
                          const SizedBox(width: FlySpace.xs),
                          Flexible(
                            child: Text(
                              t.server.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: FlyText.secondary.copyWith(
                                fontFamily: FlyText.monoFamily,
                                fontSize: 10.5,
                                color: FlyColors.textTertiary,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                          if (t.autoStart) ...[
                            const SizedBox(width: FlySpace.sm),
                            const _AutoChip(),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: FlySpace.sm),
                TunnelStatusLabel(
                  color: statusColor,
                  label: tunnelStatusLabel(t),
                  breathing: t.status == TunnelStatus.connecting,
                ),
              ],
            ),
          ),
        ),
        const Divider(
          height: kHairline,
          thickness: kHairline,
          indent: 54, // 12 左内边距 + 32 图标 + 10 间距，与首页 _RowDivider 对齐
          color: FlyColors.divider,
        ),
      ],
    );
  }

  // ── Empty state ─────────────────────────────────────────────────────────

  Widget _buildEmptyState(BuildContext context) {
    final l = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cable_outlined,
              size: 48, color: FlyColors.textTertiary),
          const SizedBox(height: 14),
          Text(
            l.noTunnels,
            style: FlyText.body.copyWith(
              fontWeight: FontWeight.w500,
              color: FlyColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l.tapPlusToAdd,
            style: FlyText.secondary.copyWith(
              fontFamily: FlyText.monoFamily,
              color: FlyColors.textTertiary,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: FlyColors.brand,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pushNamed(
              '/tunnels/form',
              arguments: const TunnelFormArgs(),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: Text(l.newTunnel),
          ),
        ],
      ),
    );
  }

  // ── Group header ────────────────────────────────────────────────────────

  Widget _groupHeader(BuildContext context, String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          FlySpace.lg, FlySpace.lg, FlySpace.lg, 6),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: FlyText.micro.copyWith(
              fontSize: 11,
              letterSpacing: 1.2,
              color: FlyColors.textTertiary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: FlyText.micro.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
              color: FlyColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // 可空读取：首页把本 widget 常驻在 IndexedStack 里，最小 provider 树的
    // 既有测试（job 徽标等）不会挂 TunnelManager，读到 null 时按空列表渲染。
    final mgr = context.watch<TunnelManager?>();
    final tunnels = mgr?.tunnels ?? const <TunnelEntry>[];
    if (tunnels.isEmpty) return _buildEmptyState(context);

    final groups = groupTunnelsByServer(tunnels, query: query);
    if (groups.isEmpty) {
      return Center(
        child: Text(
          context.l10n.noSearchResults,
          style: FlyText.body.copyWith(color: FlyColors.textSecondary),
        ),
      );
    }

    final rows = <Widget>[];
    for (final g in groups) {
      rows.add(_groupHeader(context, g.server.name, g.tunnels.length));
      for (final t in g.tunnels) {
        rows.add(_buildTile(context, mgr!, t));
      }
    }

    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 80),
      children: rows,
    );
  }
}

/// `/tunnels` 路由的薄壳（AI 导航深链）。列表体见 [TunnelListView]。
class TunnelListScreen extends StatelessWidget {
  const TunnelListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.tunnels),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: const TunnelListView(),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00C896),
        foregroundColor: Colors.black,
        onPressed: () => Navigator.of(context).pushNamed(
          '/tunnels/form',
          arguments: const TunnelFormArgs(),
        ),
        icon: const Icon(Icons.add),
        label: Text(l.newTunnel),
      ),
    );
  }
}

/// `AUTO`（自动连接）微标签。与 SSH/QUIC 同类的等宽大写 chip。
class _AutoChip extends StatelessWidget {
  const _AutoChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
      decoration: BoxDecoration(
        border: Border.all(color: FlyColors.divider, width: 0.8),
        borderRadius: FlyRadius.chipRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.alarm, size: 9, color: FlyColors.textTertiary),
          const SizedBox(width: 3),
          Text(
            'AUTO',
            style: FlyText.micro.copyWith(
              fontSize: 9.5,
              color: FlyColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
