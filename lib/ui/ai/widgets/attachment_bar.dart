// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../ai/attachment.dart';
import '../../../l10n/l10n.dart';

/// 待发送附件的预览条。放在输入框上方，**与 `@` 引用浮层共用那个位置**
/// —— 两者不会同时出现（浮层只在光标处于 `@` 上下文时才弹）。
class AttachmentBar extends StatelessWidget {
  final Attachment attachment;

  /// 缩略图文件。null 或不存在时显示占位图标。
  final File? thumbnailFile;

  final VoidCallback onRemove;

  const AttachmentBar({
    super.key,
    required this.attachment,
    required this.thumbnailFile,
    required this.onRemove,
  });

  static String formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage = attachment.kind == AttachmentKind.image;
    final file = thumbnailFile;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: (isImage && file != null && file.existsSync())
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(file,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.image_outlined, size: 18)),
                  )
                : Icon(
                    isImage ? Icons.image_outlined : Icons.description_outlined,
                    size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(attachment.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
                Text(formatBytes(attachment.bytes),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: context.l10n.attachRemove,
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
