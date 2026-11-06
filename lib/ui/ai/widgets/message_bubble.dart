// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../ai/ai_engine.dart';
import '../../../l10n/l10n.dart';
import '../../design/fly_tokens.dart';
import 'code_block.dart';
import 'message_copy_button.dart';
import 'panel_chrome.dart';

// ---------------------------------------------------------------------------
// Message bubble with code block parsing
// ---------------------------------------------------------------------------

class MessageBubble extends StatelessWidget {
  final AIMessage message;
  final bool isStreaming;
  final bool isErrorDiagnosis;
  final void Function(String)? onRunCommand;
  final void Function(String)? onSaveCommand;
  final void Function(String)? onExplainCommand;

  /// 重跑这条助手回答。null = 不显示重试按钮。
  ///
  /// 由调用方决定给哪一条：它只该出现在最后一条消息上（回退中间某条会
  /// 静默丢掉后面的对话，见 `AIEngine.popLastTurn` 的说明）。这个 widget
  /// 不认识「最后一条」这个概念，也不需要认识 —— 拿到回调就画按钮。
  final VoidCallback? onRetry;

  /// 把这条用户提问载回输入框重新编辑。null = 不显示编辑按钮。
  final VoidCallback? onEdit;

  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.isErrorDiagnosis = false,
    this.onRunCommand,
    this.onSaveCommand,
    this.onExplainCommand,
    this.onRetry,
    this.onEdit,
  });

  // Extracts the first fenced code block; returns (cmd, prose, language).
  static (String, String, String)? _extractCommand(String content) {
    final m = RegExp(r'```(\w*)\n?([\s\S]+?)```').firstMatch(content);
    if (m == null) return null;
    final lang = m.group(1) ?? '';
    final cmd = m.group(2)!.trimRight();
    final prose = (content.substring(0, m.start) + content.substring(m.end))
        .trim();
    return (cmd, prose, lang);
  }

  @override
  Widget build(BuildContext context) {
    // ── Tool result: compact execution card ──────────────────────────────────
    if (message.type == AIMessageType.toolResult) {
      return ToolResultCard(
        rawContent: message.content,
        command: message.command,
      );
    }

    // ── Normal user bubble ───────────────────────────────────────────────────
    if (message.role == 'user') {
      // 复制的是 content 而不是 displayText：displayText 是展示用的改写
      // （比如把长上下文折成一句话），复制出来粘回输入框应该得到原文。
      final shown = message.displayText ?? message.content;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: FlyColors.userBubbleFill,
              border: Border.all(
                color: FlyColors.userBubbleBorder,
                width: kHairline,
              ),
              borderRadius: FlyRadius.bubbleRadius,
            ),
            child: SelectableText(shown, style: const TextStyle(fontSize: 13)),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onEdit != null)
                MessageActionIcon(
                  icon: Icons.edit_outlined,
                  onTap: onEdit!,
                  semanticLabel: context.l10n.aiEditAction,
                ),
              MessageCopyButton(text: message.content),
            ],
          ),
        ],
      );
    }

    // ── Assistant: command-first layout ──────────────────────────────────────
    const amber = Color(0xFFFFA726);
    final extracted = _extractCommand(message.content);
    Widget content;
    if (extracted != null) {
      final (cmd, prose, lang) = extracted;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBlock(
            code: cmd,
            language: lang,
            onRun: onRunCommand,
            onSave: onSaveCommand,
            onExplain: onExplainCommand,
          ),
          if (prose.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: MarkdownBody(
                data: prose,
                selectable: true,
                styleSheet: aiProseStyle(context),
                builders: aiMarkdownBuilders(
                  onRun: onRunCommand,
                  onSave: onSaveCommand,
                  onExplain: onExplainCommand,
                ),
              ),
            ),
          if (isStreaming) const BlinkingCursor(),
        ],
      );
    } else {
      // Fallback: pure prose, no code block
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(
            data: message.content,
            selectable: true,
            styleSheet: aiProseStyle(context),
            builders: aiMarkdownBuilders(
              onRun: onRunCommand,
              onSave: onSaveCommand,
              onExplain: onExplainCommand,
            ),
          ),
          if (isStreaming) const BlinkingCursor(),
        ],
      );
    }

    // 流式输出到一半时不挂复制按钮：那时复制到的是半句话，而用户要的几乎
    // 总是完整回答。等定稿再出现 —— 按钮在光标停止闪烁的同时出现，本身就
    // 是「说完了」的信号。
    if (!isStreaming) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          content,
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onRetry != null)
                MessageActionIcon(
                  icon: Icons.refresh,
                  onTap: onRetry!,
                  semanticLabel: context.l10n.aiRetryAction,
                ),
              MessageCopyButton(text: message.content),
            ],
          ),
        ],
      );
    }

    // Wrap with amber left border for error-diagnosis responses
    if (isErrorDiagnosis) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 2.5,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(child: content),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: content,
    );
  }
}

// ---------------------------------------------------------------------------
// Tool result card — error execution record, expandable output
// ---------------------------------------------------------------------------

/// 渲染历史记录里遗留的 auto-execute 输出条目。
/// auto-execute 已于 2026-08-21 移除，此组件仅用于向后兼容，不再产生新条目。
class ToolResultCard extends StatefulWidget {
  final String rawContent; // '命令失败（exit N）：\n<output>'
  final String? command;

  const ToolResultCard({super.key, required this.rawContent, this.command});

  @override
  State<ToolResultCard> createState() => ToolResultCardState();
}

class ToolResultCardState extends State<ToolResultCard> {
  bool _expanded = false;

  static final _errorRe = RegExp(r'^命令失败（exit (\d+)）：\n');

  int? get _exitCode {
    final m = _errorRe.firstMatch(widget.rawContent);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  String get _output => widget.rawContent
      .replaceFirst(_errorRe, '')
      .replaceFirst(RegExp(r'^命令输出：\n'), '')
      .replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '')
      .trim();

  int get _lineCount =>
      _output.split('\n').where((l) => l.trim().isNotEmpty).length;

  @override
  Widget build(BuildContext context) {
    const errorRed = Color(0xFFFF5252);
    final exitCode = _exitCode;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: FlyRadius.cardRadius,
        border: Border.all(color: errorRed.withValues(alpha: 0.35)),
      ),
      child: ClipRRect(
        borderRadius: FlyRadius.cardRadius,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Red left accent bar
              Container(width: 3, color: errorRed.withValues(alpha: 0.7)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Header row ─────────────────────────────────────────
                    InkWell(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              size: 14,
                              color: errorRed,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                widget.command ?? context.l10n.aiCommandFailed,
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (exitCode != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: errorRed.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'exit $exitCode',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: errorRed,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 6),
                            Text(
                              context.l10n.aiOutputLines(_lineCount),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white30,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              _expanded ? Icons.expand_less : Icons.expand_more,
                              size: 16,
                              color: Colors.white30,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ── Expandable output ───────────────────────────────────
                    if (_expanded)
                      Container(
                        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          _output,
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11.5,
                            color: Colors.white54,
                            height: 1.4,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
