// SPDX-License-Identifier: GPL-3.0-or-later
import 'agent_loop.dart';
import 'output_sanitizer.dart';

/// 会话事件流 → markdown。
///
/// **纯函数，不依赖 BuildContext**：它要能在单测里直接跑，也要能在预览页和
/// 分享两处复用同一份产物。文案硬编码中文而不走 l10n —— 导出的文件是给人
/// 转发的，它的语言应当跟随内容而不是跟随 app 的界面语言设置。
String renderSessionMarkdown(List<AgentEvent> events) {
  final b = StringBuffer();
  for (final e in events) {
    switch (e) {
      case UserTurnEvent ev:
        b.writeln('### 你');
        if (ev.supersededByEdit) b.writeln('*（此轮已被重发取代）*');
        b.writeln();
        b.writeln(ev.text);
        b.writeln();
      case AssistantTextEvent ev:
        b.writeln('### AI');
        b.writeln();
        b.writeln(ev.text);
        b.writeln();
      case ToolCallEvent ev:
        final where =
            ev.targetServerName != null ? ' @${ev.targetServerName}' : '';
        b.writeln('#### `${ev.displayCommand}`$where');
        if (ev.description.isNotEmpty) b.writeln(ev.description);
        final out = ev.output;
        if (out != null && out.isNotEmpty) {
          b.writeln();
          b.writeln('```');
          b.writeln(out);
          b.writeln('```');
        }
        if (ev.exitCode != null && ev.exitCode != 0) {
          b.writeln('退出码 ${ev.exitCode}');
        }
        b.writeln();
      case CompactedEvent ev:
        b.writeln('> 此处折叠了 ${ev.droppedMessages} 条消息');
        b.writeln('> ${ev.summary}');
        b.writeln();
      // 措辞与 TruncatedEvent 的 dartdoc 一致：这部分是真的丢了，
      // 不能写成「可展开」。
      case TruncatedEvent ev:
        b.writeln('> 更早的 ${ev.droppedEvents} 条已省略');
        b.writeln();
      case StoppedEvent ev:
        b.writeln('> 会话结束：${ev.reason.name}');
        b.writeln();
      default:
        // 其余事件类型（提案、后台任务、传输……）不进导出正文：它们是
        // 交互控件的载体，脱离 app 之后没有意义。
        break;
    }
  }
  return b.toString();
}

/// 渲染 + 脱敏。[RedactionResult.count] 直接用于预览页顶部的「已脱敏 N 处」，
/// 不另造计数器。
RedactionResult renderSessionMarkdownRedacted(List<AgentEvent> events) =>
    redactSecrets(renderSessionMarkdown(events));
