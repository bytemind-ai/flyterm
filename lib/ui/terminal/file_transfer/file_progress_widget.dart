// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../../l10n/l10n.dart';
import '../../../ssh/transport/remote_transport.dart';

class FileProgressWidget extends StatelessWidget {
  final String filename;
  final Stream<FileTransferProgress> progress;
  final int totalBytes;
  final VoidCallback onCancel;

  const FileProgressWidget({
    super.key,
    required this.filename,
    required this.progress,
    required this.totalBytes,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FileTransferProgress>(
      stream: progress,
      builder: (ctx, snap) {
        final p = snap.data;
        final pct = (p == null || totalBytes == 0)
            ? 0.0
            : (p.bytesDone / totalBytes).clamp(0.0, 1.0);
        final isDone = p?.state == FileTransferState.completed;
        final isFailed = p?.state == FileTransferState.failed;
        final isCancelled = p?.state == FileTransferState.cancelled;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      filename,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (!isDone && !isFailed && !isCancelled)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onCancel,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ]),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: isDone ? 1.0 : (isFailed || isCancelled ? null : pct),
                  color: isFailed
                      ? Colors.red
                      : (isCancelled ? Colors.orange : null),
                ),
                const SizedBox(height: 4),
                Text(
                  _statusText(context.l10n, p, pct),
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _statusText(AppLocalizations l, FileTransferProgress? p, double pct) {
    if (p == null) return l.transferWaiting;
    switch (p.state) {
      case FileTransferState.completed:
        return l.transferDone;
      case FileTransferState.failed:
        return l.transferFailedWithReason(
            p.errorMessage ?? l.transferUnknownError);
      case FileTransferState.cancelled:
        return l.transferCancelled;
      case FileTransferState.running:
      case FileTransferState.paused:
        final pctStr = '${(pct * 100).toStringAsFixed(1)}%';
        if (p.throughputBps != null) {
          return '$pctStr  ${_fmtSpeed(p.throughputBps!)}';
        }
        return pctStr;
    }
  }

  static String _fmtSpeed(int bps) {
    if (bps < 1024) return '$bps B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
}
