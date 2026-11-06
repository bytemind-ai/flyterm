// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/known_host.dart';
import '../../data/repositories/known_host_repository.dart';
import '../../l10n/l10n.dart';

class KnownHostsScreen extends StatefulWidget {
  const KnownHostsScreen({super.key});

  @override
  State<KnownHostsScreen> createState() => _KnownHostsScreenState();
}

class _KnownHostsScreenState extends State<KnownHostsScreen> {
  late Future<List<KnownHost>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _future = context.read<KnownHostRepository>().findAll();
  }

  Future<void> _delete(KnownHost h) async {
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.knownHostDeleteTitle),
        content: Text(l.knownHostDeleteBody('${h.host}:${h.port}')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.hostKeyReject),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(l.knownHostDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<KnownHostRepository>().delete(
          host: h.host,
          port: h.port,
          keyType: h.keyType,
        );
    if (!mounted) return;
    setState(_refresh);
  }

  /// 相对时间：今天/昨天/N天前/具体日期
  String _relativeTime(DateTime dt) {
    final l = context.l10n;
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return l.timeToday;
    if (diff.inDays == 1) return l.timeYesterday;
    if (diff.inDays < 30) return l.timeDaysAgo(diff.inDays);
    if (diff.inDays < 365) return l.timeMonthsAgo((diff.inDays / 30).floor());
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  Widget _buildRow(KnownHost h, ColorScheme cs) {
    const accent = Color(0xFF00C896);
    final l = context.l10n;
    final keyTypeUpper = h.keyType.toUpperCase();

    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: h.fingerprintMd5));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.fingerprintCopied),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 左侧 icon box
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: cs.surfaceVariant.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: cs.onSurface.withValues(alpha: 0.08),
                  width: 0.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.shield_outlined,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 12),
            // 中间两行
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 行 1：hostname
                  Text(
                    '${h.host}:${h.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  // 行 2：fingerprint mono
                  Text(
                    h.fingerprintMd5,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: 0.6),
                      height: 1.25,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 3),
                  // 行 3：时间信息
                  Text(
                    context.l10n.knownHostFirstSeen(
                      _formatDate(h.firstSeen),
                      _relativeTime(h.lastSeen),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: cs.onSurface.withValues(alpha: 0.5),
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 右侧 key type chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                border: Border.all(color: accent, width: 0.8),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                keyTypeUpper,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: accent,
                  height: 1.0,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            // 删除按钮
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                size: 20,
                color: cs.error.withValues(alpha: 0.65),
              ),
              onPressed: () => _delete(h),
              tooltip: l.knownHostDelete,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.knownHostsTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: FutureBuilder<List<KnownHost>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 48,
                    color: cs.onSurface.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l.knownHostsEmpty,
                    style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.6)),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 64,
              color: cs.onSurface.withValues(alpha: 0.08),
            ),
            itemBuilder: (_, i) => _buildRow(items[i], cs),
          );
        },
      ),
    );
  }
}
