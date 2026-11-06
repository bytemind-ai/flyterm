// SPDX-License-Identifier: GPL-3.0-or-later
import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../tool_groups.dart';
import '../tool_models.dart';
import '../tool_registry.dart';

/// `more_tools` 的执行：把一组低频工具加进本会话的工具清单。
///
/// **不碰权限系统**：它什么都不执行、什么都不写，只改本会话的一个 Set ——
/// 与 `load_skill` / `set_plan` 同类。
class MoreToolsExecutors {
  final AgentToolContext ctx;

  MoreToolsExecutors(this.ctx);

  Future<ToolResult> moreTools(ToolCall call) async {
    final raw = call.args['group'];
    final asked = raw is String ? raw.trim().toLowerCase() : '';

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand:
          asked.isEmpty ? 'activate tools' : 'activate tools: $asked',
      description: '',
      check: const CheckResult(decision: ToolDecision.allow),
    );
    ctx.addEvent(ev);

    if (!kToolGroups.containsKey(asked)) {
      // **刻意不调 noteInvalidArgs**：猜错组名是合理尝试，把它计入连续无效
      // 参数会让模型在第 N 次之后被熔断掉，而它其实只差一个正确的组名。
      final msg = 'No tool group named `$asked`. '
          'Available groups: ${kToolGroups.keys.join(', ')}.';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg, isError: true);
    }

    // 幂等：已解锁时照样回成功。报错会让模型以为出了问题而改道。
    final already = ctx.unlockedToolGroups.contains(asked);
    ctx.unlockToolGroup(asked);

    final names = kToolGroups[asked]!.join(', ');
    final msg = already
        ? 'Group `$asked` is already active ($names).'
        : 'Activated `$asked`: $names. They are available from the next '
            'step onward.';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg);
  }
}
