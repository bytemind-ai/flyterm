// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/commerce/update_prompt_dialog.dart
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../update/update_checker.dart';

class UpdatePromptDialog extends StatelessWidget {
  const UpdatePromptDialog({
    super.key,
    required this.info,
    required this.checker,
  });

  final UpdateInfo info;
  final UpdateChecker checker;

  static const _accent = Color(0xFF00C896);

  static Future<void> show(BuildContext context,
      {required UpdateInfo info, required UpdateChecker checker}) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: !info.isMandatory,
      builder: (_) => UpdatePromptDialog(info: info, checker: checker),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return WillPopScope(
      onWillPop: () async => !info.isMandatory,
      child: AlertDialog(
        title: Text(
          info.isMandatory
              ? l.updatePromptTitleMandatory
              : l.updatePromptTitleOptional,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.updatePromptBody(
                      info.latestVersion, info.currentVersion),
                  style: TextStyle(
                      fontSize: 13.5,
                      color: cs.onSurface.withOpacity(0.85),
                      height: 1.4),
                ),
                if ((info.releaseNotes ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(l.updatePromptReleaseNotes,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurface.withOpacity(0.55),
                          letterSpacing: 1.2)),
                  const SizedBox(height: 4),
                  Text(info.releaseNotes!,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurface.withOpacity(0.75),
                          height: 1.4)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (!info.isMandatory)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l.updatePromptLater),
            ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              await checker.launchUpdateFlow();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(l.updatePromptUpdate),
          ),
        ],
      ),
    );
  }
}
