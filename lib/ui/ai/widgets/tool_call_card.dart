// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/agent_loop.dart';
import '../../../l10n/l10n.dart';
import 'ask_user_list.dart';
import 'dense_event_row.dart';
import 'skill_save_card.dart';
import '../../design/fly_tokens.dart';

/// 一次工具调用的卡片。
///
/// **输出默认折叠**是硬要求：手机屏幕装不下 `journalctl -n 100`，全展开会把
/// 对话流冲垮。展开后限高 200px，内部可滚。
class ToolCallCard extends StatefulWidget {
  final ToolCallEvent event;

  /// 点撤销时的回调。null = 不提供撤销（非写入卡、或只读场景）。
  final VoidCallback? onUndo;

  /// 点某个 `ask_user` 选项 / 提交自由输入时的回调。参数可能是选中的
  /// label，也可能是用户自己打的任意文本——「其他…」入口走的就是后者，
  /// `formatAskAnswerContent` 存在的全部理由就是它不一定是某个 label。
  ///
  /// null = 不提供（非提问卡、或恢复出来的只读历史）。`seq` 不在参数里——
  /// 调用方在闭包里捕获它，与 [onUndo] 同一个模式。
  final void Function(String choice)? onAnswer;

  const ToolCallCard({
    super.key,
    required this.event,
    this.onUndo,
    this.onAnswer,
  });

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final ev = widget.event;
    final hasOutput = ev.output != null && ev.output!.isNotEmpty;

    // 提问在通用渲染之前分派出去：通用分支会把 `output` 当命令输出铺开，
    // 而这里要的是可点的清单。渲染在 `ask_user_list.dart`——它要管一个
    // TextEditingController 的生命周期，塞在这个文件里会让它更难读。
    if (ev.toolName == 'ask_user') {
      return AskUserList(event: ev, onAnswer: widget.onAnswer);
    }

    // 技能两卡在通用渲染之前分派出去。
    //
    // `load_skill` 绝不能走通用分支：那条路会把 `output`（8 KiB markdown）
    // 铺在手机屏幕上，用户要滚十屏才能看到 AI 接下来说了什么 —— 而那段
    // 文字本来就是他自己写的、是给模型看的。这与 `bash` 的输出卡不同，
    // 那个是新信息。
    if (ev.toolName == 'load_skill') {
      final name = ev.displayCommand.replaceFirst('load skill: ', '');
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Row(
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l.agentSkillLoadedInPanel(name),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }
    if (ev.toolName == 'save_skill') {
      return SkillSaveCard(event: ev);
    }

    if (isTerminal(ev.status)) {
      final row = DenseEventRow(
        leading: _statusIcon(theme, ev.status),
        spans: _denseSpans(context),
        trailingLabel: hasOutput
            ? l.agentToolOutputLines(countLines(ev.output!))
            : null,
        expanded: (hasOutput || _canUndo) ? _denseExpanded : null,
      );
      // superseded 的压暗包住整行。不删卡的理由见 ToolCallEvent.superseded
      // 的 dartdoc；「已被取代」那句话已经并进 spans 尾部，不再单占一行。
      return ev.superseded ? Opacity(opacity: 0.45, child: row) : row;
    }

    final card = Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      decoration: BoxDecoration(
        // 第一层·角色：工具类事件卡用中性底（不带色相）。
        // 第二层·事件：色相只在描边上 —— 见 fly_tokens 的「角色层」注释。
        color: FlyColors.roleToolFill,
        borderRadius: FlyRadius.cardRadius,
        border: Border.all(color: FlyColors.tintBorder(FlyColors.tintBlue)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _statusIcon(theme, ev.status),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (ev.description.isNotEmpty)
                        Text(ev.description, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 4),
                      SelectableText(
                        ev.displayCommand,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (ev.status == ToolCallStatus.running &&
                          ev.startedAt != null)
                        Text(
                          l.agentToolRunningFor(
                            DateTime.now().difference(ev.startedAt!).inSeconds,
                          ),
                          style: theme.textTheme.labelSmall,
                        ),
                      if (ev.status != ToolCallStatus.running)
                        Builder(
                          builder: (_) {
                            final took = formatToolDuration(ev.durationMs);
                            if (took == null) return const SizedBox.shrink();
                            return Text(
                              l.agentToolTook(took),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            );
                          },
                        ),
                      if (ev.exitCode != null && ev.exitCode != 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            l.agentExitCode(ev.exitCode!),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasOutput)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    tooltip: _expanded
                        ? l.agentToolCollapse
                        : l.agentToolExpand,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
              ],
            ),
          ),
          if (ev.backupPath != null && ev.status == ToolCallStatus.done)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 6, 6),
              child: Row(
                children: [
                  // backupMissing 优先于 undone：逻辑上两者不会同时为 true
                  // （undoEdit 里成功才设 undone、备份没了才设 backupMissing），
                  // 但呈现不该依赖那个不变量。
                  if (ev.backupMissing)
                    Expanded(
                      child: Text(
                        l.agentUndoBackupMissing,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else if (ev.undone)
                    Row(
                      children: [
                        Icon(
                          Icons.undo,
                          size: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l.agentUndone,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  else if (widget.onUndo != null)
                    TextButton.icon(
                      onPressed: widget.onUndo,
                      icon: const Icon(Icons.undo, size: 14),
                      label: Text(l.agentUndo),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
          if (_expanded && hasOutput)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  bottom: const Radius.circular(FlyRadius.card),
                ),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  ev.output!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // 抢跑落空的卡片压暗 + 加一行说明。不删卡的理由见 ToolCallEvent
    // .superseded 的 dartdoc：命令确实执行过，抹掉会让时间线失真。
    if (ev.superseded) {
      return Opacity(
        opacity: 0.45,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            card,
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
              child: Text(
                l.agentToolSuperseded,
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
        ),
      );
    }
    return card;
  }

  Widget _statusIcon(ThemeData theme, ToolCallStatus status) =>
      switch (status) {
        ToolCallStatus.running => const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        ToolCallStatus.done => Icon(
          Icons.check_circle_outline,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        ToolCallStatus.failed => Icon(
          Icons.error_outline,
          size: 16,
          color: theme.colorScheme.error,
        ),
        ToolCallStatus.rejected => Icon(
          Icons.block,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        ToolCallStatus.awaitingApproval => Icon(
          Icons.pending_outlined,
          size: 16,
          color: theme.colorScheme.tertiary,
        ),
        ToolCallStatus.deferred => Icon(
          Icons.playlist_add_check,
          size: 16,
          color: theme.colorScheme.tertiary,
        ),
      };

  /// 撤销按钮是否还有意义。已撤销、备份没了、非写入卡都算没有。
  bool get _canUndo =>
      widget.onUndo != null &&
      widget.event.backupPath != null &&
      !widget.event.undone &&
      !widget.event.backupMissing;

  /// 流水行的富文本段。
  ///
  /// 顺序是「描述 · 命令 · 耗时 · 状态后缀」。命令永远完整 —— 描述可以
  /// 没有，命令不能被省略，这是 `ed7bbe9` 那条 revert 的直接结论。
  List<InlineSpan> _denseSpans(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final ev = widget.event;
    final dim = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final err = dim?.copyWith(color: theme.colorScheme.error);
    final took = formatToolDuration(ev.durationMs);

    return [
      if (ev.description.isNotEmpty) ...[
        TextSpan(text: ev.description, style: theme.textTheme.bodySmall),
        TextSpan(
          text: ' · ',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      ],
      TextSpan(
        text: ev.displayCommand,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      if (took != null) TextSpan(text: ' · $took', style: dim),
      if (ev.exitCode != null && ev.exitCode != 0)
        TextSpan(text: ' · ${l.agentExitCode(ev.exitCode!)}', style: err),
      if (ev.undone) TextSpan(text: ' · ${l.agentUndone}', style: dim),
      if (ev.backupMissing)
        TextSpan(text: ' · ${l.agentUndoBackupMissing}', style: err),
      if (ev.superseded)
        TextSpan(text: ' · ${l.agentToolSuperseded}', style: dim),
    ];
  }

  /// 流水行的展开区：输出在上，撤销按钮在下。
  Widget _denseExpanded(BuildContext context) {
    final theme = Theme.of(context);
    final ev = widget.event;
    final hasOutput = ev.output != null && ev.output!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasOutput)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 200),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                ev.output!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        if (_canUndo)
          TextButton.icon(
            onPressed: widget.onUndo,
            icon: const Icon(Icons.undo, size: 14),
            label: Text(context.l10n.agentUndo),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
      ],
    );
  }
}

/// 耗时的人类可读形式。
///
/// 阈值 1s：每张卡都挂个「0.1s」是噪声，用户要找的是慢的那几条。返回 null
/// 表示不显示。
@visibleForTesting
String? formatToolDuration(int? ms) {
  if (ms == null || ms < 1000) return null;
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  return '${m}m${s}s';
}
