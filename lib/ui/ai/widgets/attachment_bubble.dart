// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../ai/attachment.dart';
import '../../../l10n/l10n.dart';
import 'attachment_bar.dart' show AttachmentBar;
import 'image_viewer_sheet.dart';

/// 气泡里的一条附件。
///
/// [fileFor] 注入而不是内部算路径：这一层不该知道 `AttachmentStore` 的存在，
/// 而测试也不必造真文件。
class AttachmentBubble extends StatelessWidget {
  final Attachment attachment;
  final File? Function(Attachment) fileFor;

  const AttachmentBubble({
    super.key,
    required this.attachment,
    required this.fileFor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (attachment.kind == AttachmentKind.text) {
      // 正文已经在 content 里由 markdown 渲染过了，这里只显示文件名与大小，
      // 不重复渲染一遍。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.description_outlined, size: 14),
            const SizedBox(width: 6),
            Text(attachment.name ?? '', style: theme.textTheme.bodySmall),
            const SizedBox(width: 6),
            Text(AttachmentBar.formatBytes(attachment.bytes),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    final file = fileFor(attachment);
    if (file == null || !file.existsSync()) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(context.l10n.attachMissing,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: GestureDetector(
        onTap: () => showImageViewer(context, file),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: Image.file(file,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Text(context.l10n.attachMissing)),
          ),
        ),
      ),
    );
  }
}
