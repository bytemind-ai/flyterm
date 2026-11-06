// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/ai_engine.dart';
import '../../ai/ai_provider_service.dart';
import '../../l10n/l10n.dart';
import 'widgets/message_bubble.dart';
import 'widgets/panel_chrome.dart';

/// The existing "direct chat" surface — AI suggests commands, the user runs
/// them. Moved out of `_AIPanelState` verbatim so `AIPanel` can be
/// a thin shell that also hosts `AgentView`.
///
/// State is exposed publicly (not `_DirectChatViewState`) so the shell can
/// reach `analyzeError()` / `requestSummary()` via a `GlobalKey` — those two
/// actions live on `PanelHeader`, which stays in the shell.
class DirectChatView extends StatefulWidget {
  final AIEngine engine;

  /// Called each time a query is submitted to get the latest terminal snapshot.
  /// Replaces the old fixed-string terminalContext so session summary and error
  /// analysis always see the current terminal output, not a stale open-time copy.
  final String Function()? contextProvider;
  final String? initialQuery;

  /// Called when user taps "执行" on a code block. The command is sent to terminal.
  final void Function(String command)? onRunCommand;

  /// Called when user taps "收藏" on a code block.
  final void Function(String command)? onSaveCommand;
  final void Function(String command)? onExplainCommand;

  /// Scroll controller handed down by the shell's `DraggableScrollableSheet`.
  /// Wiring the message list to it (rather than an internally-owned
  /// controller) is what lets dragging the list itself — not just the
  /// handle — resize the sheet; dropping this would be a UX regression.
  final ScrollController? scrollController;

  /// 消息列表为空时显示在**列表区域**的内容。输入框不受影响，始终在底部。
  ///
  /// 收到的 `send` 回调用来让占位内容里的建议 chip 直接发出那句话 —— 输入框
  /// 的控制器是本类私有的，外部即使拿到 GlobalKey 也填不进去。
  ///
  /// null = 沿用原来那行 `aiEmptyHint` 灰字（终端页 AI 面板走的就是这条路径，
  /// 它的空状态不需要建议 chip）。
  final Widget Function(void Function(String text) send)? emptyBuilder;

  const DirectChatView({
    super.key,
    required this.engine,
    this.contextProvider,
    this.initialQuery,
    this.onRunCommand,
    this.onSaveCommand,
    this.onExplainCommand,
    this.scrollController,
    this.emptyBuilder,
  });

  @override
  State<DirectChatView> createState() => DirectChatViewState();
}

class DirectChatViewState extends State<DirectChatView> {
  late final TextEditingController _ctrl;
  bool _isLoading = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => submit());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 触发「分析错误」——`PanelHeader` 的按钮通过 `GlobalKey` 调它。
  void analyzeError() {
    _ctrl.text = context.l10n.aiAnalyzeError;
    submit();
  }

  /// 触发「会话摘要」——`PanelHeader` 的按钮通过 `GlobalKey` 调它。
  void requestSummary() {
    final termText = widget.contextProvider?.call() ?? '';
    // Send the full terminal content to the AI so it can summarise it, but
    // show only the short label in the chat UI via displayText.
    final fullPrompt = termText.isNotEmpty
        ? '${context.l10n.sessionSummaryPrompt}\n\n$termText'
        : context.l10n.sessionSummaryPrompt;
    _ctrl.text = fullPrompt;
    submit(displayText: context.l10n.sessionSummaryPrompt);
  }

  /// 重跑最后一轮：把它弹掉，用同一条提问再问一次。
  ///
  /// 复用弹出来的 `displayText` 而不是丢掉它 —— 「会话摘要」那类提问的
  /// prompt 里塞着整个终端输出，只带 prompt 重发会让屏幕上突然摊开几百行。
  Future<void> _retryLastTurn() async {
    final t = widget.engine.popLastTurn();
    if (t == null) return;
    _ctrl.text = t.prompt;
    await submit(displayText: t.displayText);
  }

  /// 把最后一轮的提问载回输入框重新编辑。
  ///
  /// 光标落在末尾而不是选中全文：用户来点这个按钮，多半是要在原话上补一句
  /// 或改个词，而不是整条重写 —— 选中全文会让下一次按键把原文清空。
  void _editLastTurn() {
    final t = widget.engine.popLastTurn();
    if (t == null) return;
    _ctrl.text = t.prompt;
    _ctrl.selection = TextSelection.collapsed(offset: t.prompt.length);
  }

  Future<void> submit({String? displayText}) async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    final svc = context.read<AIProviderService>();
    if (!svc.hasProvider) {
      setState(() => _errorMsg = context.l10n.aiNoProvider);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    _ctrl.clear();
    try {
      await widget.engine.query(
        text,
        provider: svc.provider!,
        context: widget.contextProvider?.call(),
        displayText: displayText,
      );
    } catch (e) {
      setState(() => _errorMsg = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.engine,
      builder: (context, _) {
        final engine = widget.engine;
        final messages = engine.history
            .where((m) => m.role != 'system')
            .toList();
        final streaming = engine.streamingContent;

        // Auto-scroll to bottom while streaming
        if (streaming != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final sc = widget.scrollController;
            if (sc?.hasClients == true) {
              final pos = sc!.position;
              if (pos.maxScrollExtent > 0) {
                sc.animateTo(
                  pos.maxScrollExtent,
                  duration: const Duration(milliseconds: 80),
                  curve: Curves.easeOut,
                );
              }
            }
          });
        }

        // 编辑按钮挂在最后一条 user 消息上，而它未必是列表最后一条（后面
        // 通常跟着助手的回答）。在 builder 外算一次，别在每一项里重新扫。
        final lastUserIndex = messages.lastIndexWhere((m) => m.role == 'user');

        final showEmpty = messages.isEmpty && streaming == null;
        return Column(
          children: [
            Expanded(
              child: showEmpty
                  ? (widget.emptyBuilder?.call((t) {
                          _ctrl.text = t;
                          submit();
                        }) ??
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              context.l10n.aiEmptyHint,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ),
                        ))
                  : ListView.builder(
                      controller: widget.scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: messages.length + (streaming != null ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == messages.length && streaming != null) {
                          return MessageBubble(
                            message: AIMessage(
                              role: 'assistant',
                              content: streaming,
                            ),
                            isStreaming: true,
                            onRunCommand: widget.onRunCommand,
                            onSaveCommand: widget.onSaveCommand,
                            onExplainCommand: widget.onExplainCommand,
                          );
                        }
                        final isErrorDiagnosis =
                            i > 0 &&
                            messages[i].role == 'assistant' &&
                            messages[i - 1].type == AIMessageType.toolResult;
                        // 重试与编辑都只给最后一轮 —— 回退中间某条会静默
                        // 丢掉它之后的全部对话，而这里没有撤销路径，engine
                        // 也不保留分支（见 AIEngine.popLastTurn）。
                        //
                        // 出流或已在请求中时一律不给：那时 popLastTurn 会
                        // 和正在写入历史的 query 抢同一个列表。
                        final busy = streaming != null || _isLoading;
                        final isLastMessage = i == messages.length - 1;
                        return MessageBubble(
                          message: messages[i],
                          isErrorDiagnosis: isErrorDiagnosis,
                          onRunCommand: widget.onRunCommand,
                          onSaveCommand: widget.onSaveCommand,
                          onExplainCommand: widget.onExplainCommand,
                          onRetry:
                              !busy &&
                                  isLastMessage &&
                                  messages[i].role == 'assistant'
                              ? _retryLastTurn
                              : null,
                          onEdit: !busy && i == lastUserIndex
                              ? _editLastTurn
                              : null,
                        );
                      },
                    ),
            ),
            if (_errorMsg != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _errorMsg!,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    if (!context.read<AIProviderService>().hasProvider)
                      TextButton(
                        onPressed: () =>
                            Navigator.of(context)
                                .pushNamed('/settings/ai-providers'),
                        child: Text(context.l10n.aiGoConfig),
                      ),
                  ],
                ),
              ),
            if (_isLoading) const LinearProgressIndicator(),
            PanelInputRow(ctrl: _ctrl, onSubmit: submit),
          ],
        );
      },
    );
  }
}
