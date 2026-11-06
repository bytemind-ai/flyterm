// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/agent_loop.dart';
import '../../../l10n/l10n.dart';
import 'dense_event_row.dart';
import '../../design/fly_tokens.dart';

/// 文件传输卡。
///
/// 与 [JobCard] 分开而不是加分支：那张卡的生命周期由远端进程决定、操作是
/// 「终止」；这张卡传完之后还长期留着，操作是三个作用于**本地**文件的动作。
///
/// 与 `ToolCallCard` 也分开：审批那一步用的是 `ToolCallEvent`，这张卡渲染的
/// 是批准之后的 [TransferEvent]。一次传输在时间线上确实是两张卡 —— 与
/// `run_background` 的「调用卡 + 任务卡」同构。
class TransferCard extends StatelessWidget {
  final TransferEvent event;

  /// 传输进行中时的取消。null = 不提供。
  final VoidCallback? onCancel;

  final VoidCallback? onOpen;

  /// 把已落盘的本地内容注入会话。[TransferEvent.credentialDeny] 为真时
  /// 这个按钮会被强制禁用，**不管调用方传了什么** —— 那是数据边界，不能
  /// 依赖每个调用点都记得判断。
  final VoidCallback? onLetAiRead;

  final VoidCallback? onShare;

  const TransferCard({
    super.key,
    required this.event,
    this.onCancel,
    this.onOpen,
    this.onLetAiRead,
    this.onShare,
  });

  static String formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _statusText(BuildContext context) {
    final l = context.l10n;
    return switch (event.status) {
      TransferStatus.running => switch (event.direction) {
        TransferDirection.download => l.transferDownloading,
        TransferDirection.upload => l.transferUploading,
        TransferDirection.relay =>
          event.phase == TransferPhase.uploading
              ? l.transferRelayUploading(event.toServerName ?? '')
              : l.transferRelayDownloading(event.fromServerName ?? ''),
      },
      TransferStatus.done => l.transferDone,
      TransferStatus.cancelled => l.transferCancelled,
      TransferStatus.failed => l.transferFailed,
      TransferStatus.interrupted => l.transferInterrupted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final done = event.status == TransferStatus.done;

    if (!event.running) {
      final dim = theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
      return DenseEventRow(
        leading: Icon(
          switch (event.direction) {
            TransferDirection.download => Icons.download,
            TransferDirection.upload => Icons.upload,
            TransferDirection.relay => Icons.swap_horiz,
          },
          size: 16,
          color: event.status == TransferStatus.done
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
        ),
        spans: [
          TextSpan(
            text: event.filename,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          TextSpan(text: ' · ${_statusText(context)}', style: dim),
          if (event.error != null)
            TextSpan(
              text: ' · ${event.error}',
              style: dim?.copyWith(color: theme.colorScheme.error),
            ),
          // 凭据警告留在行上而不是进展开区：它是数据边界的提示，藏在一次
          // 点击后面等于没提示。展开区里「让 AI 读完」按钮另有强制禁用
          // （见字段文档），两道并存，不合并成一道。
          if (event.credentialDeny)
            TextSpan(
              text: ' · ${l.transferCredentialWarning}',
              style: dim?.copyWith(color: theme.colorScheme.error),
            ),
        ],
        trailingLabel: event.totalBytes > 0
            ? formatBytes(event.totalBytes)
            : null,
        expanded: (ctx) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              switch (event.direction) {
                TransferDirection.download => event.remotePath,
                TransferDirection.upload => '→ ${event.remotePath}',
                TransferDirection.relay =>
                  '${event.fromServerName}:${event.remotePath}\n'
                      '→ ${event.toServerName}:'
                      '${event.destPath ?? event.remotePath}',
              },
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (event.backupPath != null)
              Text(
                l.transferBackupKept(event.backupPath!),
                style: theme.textTheme.bodySmall,
              ),
            // 中转不显示这三个：临时文件在拷贝结束时就删了，没有本地对象
            // 可操作。
            if (done && event.direction == TransferDirection.download)
              Row(
                children: [
                  TextButton(onPressed: onOpen, child: Text(l.transferOpen)),
                  TextButton(
                    // 凭据文件强制禁用 —— 见字段文档。
                    onPressed: event.credentialDeny ? null : onLetAiRead,
                    child: Text(l.transferLetAiRead),
                  ),
                  TextButton(onPressed: onShare, child: Text(l.transferShare)),
                ],
              ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        // 第一层·角色：中性底。
        //
        // **描边保留 running 语义** —— 同 job_card。
        color: FlyColors.roleToolFill,
        borderRadius: FlyRadius.cardRadius,
        border: Border.all(
          color: event.running
              ? theme.colorScheme.primary.withValues(alpha: 0.4)
              : FlyColors.tintBorder(FlyColors.tintSky),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                switch (event.direction) {
                  TransferDirection.download => Icons.download,
                  TransferDirection.upload => Icons.upload,
                  TransferDirection.relay => Icons.swap_horiz,
                },
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  event.filename,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(_statusText(context), style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            switch (event.direction) {
              TransferDirection.download => event.remotePath,
              TransferDirection.upload => '→ ${event.remotePath}',
              // 中转要说清两端，否则用户看不出这是从哪搬到哪。
              TransferDirection.relay =>
                '${event.fromServerName}:${event.remotePath}\n'
                    '→ ${event.toServerName}:${event.destPath ?? event.remotePath}',
            },
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (event.running) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              // totalBytes 为 0（stat 失败）时给 null → 不确定进度条。
              value: event.totalBytes > 0
                  ? (event.bytesDone / event.totalBytes).clamp(0.0, 1.0)
                  : null,
              minHeight: 3,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${formatBytes(event.bytesDone)}'
                  '${event.totalBytes > 0 ? ' / ${formatBytes(event.totalBytes)}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                if (onCancel != null)
                  TextButton(
                    onPressed: onCancel,
                    child: Text(l.transferCancel),
                  ),
              ],
            ),
          ],
          if (event.error != null) ...[
            const SizedBox(height: 6),
            Text(
              event.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (event.backupPath != null) ...[
            const SizedBox(height: 6),
            Text(
              l.transferBackupKept(event.backupPath!),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (event.credentialDeny) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.warning_amber,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    l.transferCredentialWarning,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          // 中转不显示这三个：临时文件在拷贝结束时就删了，没有本地对象可操作。
          if (done && event.direction == TransferDirection.download) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(onPressed: onOpen, child: Text(l.transferOpen)),
                TextButton(
                  // 凭据文件强制禁用 —— 见字段文档。
                  onPressed: event.credentialDeny ? null : onLetAiRead,
                  child: Text(l.transferLetAiRead),
                ),
                TextButton(onPressed: onShare, child: Text(l.transferShare)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
