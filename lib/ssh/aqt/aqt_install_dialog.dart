// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// User's response to the install prompt.
enum AqtInstallChoice {
  /// Proceed with install.
  install,
  /// Skip this time; will re-prompt next connect if binary still missing.
  postpone,
}

/// Show the first-time install confirmation dialog.
/// Returns the user's choice. If the dialog is dismissed without an action
/// (e.g. back button on Android), returns [AqtInstallChoice.postpone] —
/// the safe default that doesn't take any action.
///
/// [archInfo] optional friendly arch label like "x86_64" — shown in the
/// dialog body so user sees exactly what will be uploaded for their server.
/// [packageBytes] optional precise binary size in bytes for accurate sizing
/// in the dialog (formatted to MB).
Future<AqtInstallChoice> showAqtInstallDialog(
  BuildContext context, {
  String? archInfo,
  int? packageBytes,
}) async {
  final choice = await showDialog<AqtInstallChoice>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _AqtInstallDialog(
      archInfo: archInfo,
      packageBytes: packageBytes,
    ),
  );
  return choice ?? AqtInstallChoice.postpone;
}

class _AqtInstallDialog extends StatelessWidget {
  final String? archInfo;
  final int? packageBytes;
  const _AqtInstallDialog({this.archInfo, this.packageBytes});

  String _formatSize() {
    final bytes = packageBytes;
    if (bytes == null) return '~5 MB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final size = _formatSize();
    final archLine = archInfo != null
        ? '检测到远端架构: $archInfo ($size)'
        : 'QUIC 模式需在远端安装 flyterm-server ($size)';

    return AlertDialog(
      title: const Text('安装 FlyTerm Server?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(archLine),
          const SizedBox(height: 8),
          const Text('• 装到 ~/.flyterm-server/，不需要 root'),
          const Text('• 不会修改 PATH 或系统配置'),
          const SelectableText('• 卸载: rm -rf ~/.flyterm-server'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(AqtInstallChoice.postpone),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(AqtInstallChoice.install),
          child: const Text('安装'),
        ),
      ],
    );
  }
}
