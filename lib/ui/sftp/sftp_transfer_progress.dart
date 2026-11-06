// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../sftp/sftp_service.dart';

/// 传输进度条。**无状态、无自己的生命周期** —— 纯展示，所有状态来自
/// [TransferState]。从 `sftp_inline_view.dart` 拆出来是因为那个文件被
/// 6 个任务同时改，拆开能让每个改动落在独立文件里。
class SftpTransferProgress extends StatelessWidget {
  const SftpTransferProgress({
    super.key,
    required this.state,
    required this.onCancel,
  });

  final TransferState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    Widget cancelBtn() => IconButton(
      icon: const Icon(Icons.close, size: 18),
      tooltip: context.l10n.cancel,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onCancel,
    );

    if (state.isScanning) {
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    context.l10n.sftpScanningFiles(state.filesCompleted),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          cancelBtn(),
        ],
      );
    }
    if (state.filesTotal != null) {
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: state.progressValue),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${state.filesCompleted}/${state.filesTotal}  ${state.filename}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${_fmtBytes(state.bytesTransferred)} / ${_fmtBytes(state.totalBytes)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          cancelBtn(),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: state.progressValue),
              if (state.totalBytes > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.isSending
                              ? context.l10n.sftpUploading(state.filename)
                              : state.filename,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${_fmtBytes(state.bytesTransferred)} / ${_fmtBytes(state.totalBytes)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        cancelBtn(),
      ],
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
