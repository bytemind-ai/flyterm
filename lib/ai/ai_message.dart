// SPDX-License-Identifier: GPL-3.0-or-later
import 'agent/tool_models.dart';
import 'attachment.dart';

enum AIMessageType {
  chat,       // normal user/assistant turn
  toolResult, // legacy auto-execute output (read-only compat, no longer produced)
}

class AIMessage {
  final String role; // 'system' | 'user' | 'assistant' | 'tool'
  final String content;
  final AIMessageType type;

  /// For legacy toolResult messages: the command that produced this output.
  /// Display-only — not sent to the AI provider.
  final String? command;

  /// When set, the chat UI shows this text instead of [content].
  /// Display-only — not persisted.
  final String? displayText;

  /// Agent 模式：assistant 消息请求的工具调用。
  final List<ToolCall>? toolCalls;

  /// Agent 模式：`role == 'tool'` 消息携带的一组执行结果。
  ///
  /// 是**列表**而非单个 —— 模型一轮可能返回多个 tool call，Anthropic 要求
  /// 它们的结果合并在同一个 user turn 的多个 content block 里。
  final List<ToolResult>? toolResults;

  /// 用户随这一轮发出的附件。
  ///
  /// 图片走这里（provider 各自拼成自己的 image block）；**文本文件不走**——
  /// 它的正文已经在 [content] 里，这里只留一条记录供 UI 显示。
  final List<Attachment>? attachments;

  const AIMessage({
    required this.role,
    required this.content,
    this.type = AIMessageType.chat,
    this.command,
    this.displayText,
    this.toolCalls,
    this.toolResults,
    this.attachments,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (type != AIMessageType.chat) 'type': type.name,
        if (command != null) 'command': command,
        // 空列表也省略，与「不让旧格式历史文件膨胀」的目标保持一致
        if (toolCalls != null && toolCalls!.isNotEmpty)
          'toolCalls': toolCalls!.map((t) => t.toJson()).toList(),
        if (toolResults != null && toolResults!.isNotEmpty)
          'toolResults': toolResults!.map((r) => r.toJson()).toList(),
        if (attachments != null && attachments!.isNotEmpty)
          'attachments': attachments!.map((a) => a.toJson()).toList(),
      };

  static AIMessage fromJson(Map<String, dynamic> json) => AIMessage(
        role: json['role'] as String,
        content: json['content'] as String? ?? '',
        type: AIMessageType.values.firstWhere(
          (t) => t.name == (json['type'] as String?),
          orElse: () => AIMessageType.chat,
        ),
        command: json['command'] as String?,
        toolCalls: (json['toolCalls'] as List?)
            ?.map((e) => ToolCall.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        toolResults: (json['toolResults'] as List?)
            ?.map((e) => ToolResult.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        attachments: (json['attachments'] as List?)
            ?.map((e) => Attachment.fromJson((e as Map).cast<String, dynamic>()))
            .whereType<Attachment>()
            .toList(),
      );
}
