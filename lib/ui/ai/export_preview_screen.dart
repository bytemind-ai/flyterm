// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/agent/agent_loop.dart';
import '../../ai/agent/session_markdown.dart';
import '../../l10n/l10n.dart';

/// 导出前的预览。
///
/// **强制经过这一步，不提供「直接分享」的快捷路径。** 导出的内容会离开设备，
/// 用户有权在它离开之前看到全文——这条约束来自 09-02 的能力缺口评估。
class ExportPreviewScreen extends StatelessWidget {
  final List<AgentEvent> events;

  /// 分享出去的文件名前缀，用会话标题或服务器名，避免一堆同名文件。
  final String filenameHint;

  const ExportPreviewScreen({
    super.key,
    required this.events,
    required this.filenameHint,
  });

  /// 走文件而不是纯文本分享 —— 与 `_exportMetrics` 同一个理由：几十轮的内容
  /// 会超过多数 IM 的单条粘贴上限。
  Future<void> _share(BuildContext context, String text) async {
    final dir = await getTemporaryDirectory();
    final safe = filenameHint.replaceAll(RegExp(r'[^\w\-]'), '_');
    final path =
        '${dir.path}/flyterm_${safe}_${DateTime.now().millisecondsSinceEpoch}.md';
    final file = await File(path).writeAsString(text);
    if (!context.mounted) return;
    await Share.shareXFiles([XFile(file.path)]);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final result = renderSessionMarkdownRedacted(events);
    final empty = result.text.trim().isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.aiExportPreviewTitle),
        actions: [
          if (!empty)
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: l.aiExportShare,
              onPressed: () => _share(context, result.text),
            ),
        ],
      ),
      body: empty
          ? Center(
              child: Text(
                l.aiExportEmpty,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Column(
              children: [
                if (result.count > 0)
                  Container(
                    width: double.infinity,
                    color: theme.colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.shield_outlined,
                            size: 14, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          l.aiExportRedacted(result.count),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      result.text,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
