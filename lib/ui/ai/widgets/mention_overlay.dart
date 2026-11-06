// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../mention.dart';

/// file 分组的三种非常态。常态（有候选）不需要单独的值 —— 有候选就画候选。
enum MentionFileState { idle, loading, unavailable }

/// `@` 候选浮层。**无状态**：所有判断都在 `MentionField` 里做完，这里只画。
///
/// 高度上限 240：再高就会把消息列表挤得只剩一两行，而浮层的作用是「挑一个」
/// 不是「浏览」。超出部分内部滚动。
class MentionOverlay extends StatelessWidget {
  final List<MentionCandidate> candidates;
  final ValueChanged<MentionCandidate> onPick;
  final MentionFileState fileState;

  /// 已本地化好的错误文案。null = 没有错误。
  final String? errorText;

  /// 被渲染上限截掉的条数。0 = 没截。
  final int moreCount;

  /// 列表上方的一行提示。null = 不显示。
  ///
  /// 目前只有一个用途：选中服务器之后告诉用户「还能打冒号」。没有这行，
  /// 「不补空格」的设计对用户就是纯粹的困惑——他会以为补全坏了。
  final String? hintText;

  const MentionOverlay({
    super.key,
    required this.candidates,
    required this.onPick,
    this.fileState = MentionFileState.idle,
    this.errorText,
    this.moreCount = 0,
    this.hintText,
  });

  /// 渲染顺序。**只用来排序，不再画分组标题**（2026-09-12）。
  ///
  /// 标题与每条左侧的类型图标说的是同一件事，而触发符拆分之后这个冗余更贵：
  /// `/` 下只可能有技能与命令两类，两行标题却要吃掉 52px —— 240px 上限的
  /// 五分之一，够放一条候选了。同类靠顺序聚在一起，靠图标区分。
  static const _order = [
    MentionKind.file,
    MentionKind.server,
    MentionKind.skill,
    MentionKind.command,
  ];

  IconData _icon(MentionCandidate c) => switch (c.kind) {
        MentionKind.file =>
          c.isDir ? Icons.folder_outlined : Icons.description_outlined,
        MentionKind.server => Icons.dns_outlined,
        MentionKind.skill => Icons.school_outlined,
        MentionKind.command => Icons.bolt_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[];

    if (hintText != null) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        child: Text(
          hintText!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ));
    }
    if (fileState == MentionFileState.loading) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: LinearProgressIndicator(minHeight: 2),
      ));
    }
    if (fileState == MentionFileState.unavailable) {
      rows.add(_note(theme, context.l10n.mentionFilesUnavailable));
    }
    if (errorText != null) {
      rows.add(_note(theme, errorText!, error: true));
    }

    for (final kind in _order) {
      final items = candidates.where((c) => c.kind == kind).toList();
      if (items.isEmpty) continue;
      for (final c in items) {
        rows.add(InkWell(
          onTap: () => onPick(c),
          child: Padding(
            // 纵向 6 而不是 8：一条从 52px 降到 48px。热区仍有 48px，远高于
            // `ask_user_list.dart` 那边权衡出来的 30px —— 这里不必再让步。
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(_icon(c), size: 16),
                // 16 + 6 = 22，与 `DenseEventRow` 的图标列一致，两种列表混在
                // 同一块屏幕上时文字左缘对得上。
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium),
                      if (c.subtitle != null && c.subtitle!.isNotEmpty)
                        Text(c.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (c.isDir) const Icon(Icons.chevron_right, size: 16),
              ],
            ),
          ),
        ));
      }
    }

    if (moreCount > 0) {
      rows.add(_note(theme, context.l10n.mentionMoreEntries(moreCount)));
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }

  Widget _note(ThemeData theme, String text, {bool error = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: error
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
