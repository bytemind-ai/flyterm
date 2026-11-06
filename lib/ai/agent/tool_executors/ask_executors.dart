// SPDX-License-Identifier: GPL-3.0-or-later
import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../ask_option.dart';
import '../tool_models.dart';
import '../tool_registry.dart';
import 'arg_parsing.dart';

/// `ask_user` 的执行。
///
/// 形状照 `SkillExecutors.loadSkill`：建事件 → 校验 → 挂起 → 收尾。
class AskExecutors {
  final AgentToolContext ctx;

  AskExecutors(this.ctx);

  Future<ToolResult> askUser(ToolCall call) async {
    final rawQ = call.args['question'];
    final question = rawQ is String ? rawQ.trim() : '';

    // **先解析再建事件**，与 `loadSkill` 的「先建事件再校验」刻意不同。
    //
    // 那边先建事件是因为面板要立刻显示「模型确实发起了这次调用」，参数非法
    // 只是它的一种终态。这里不能照搬：`ToolCallEvent.askOptions` 是 final，
    // 而选项要等解析完才知道。解析是纯函数、无副作用，提前跑没有代价。
    final rawOpts = call.args['options'];
    final parsed = rawOpts is List
        ? parseAskOptions(rawOpts)
        : const AskOptionsParse([],
            error: 'Invalid arguments: `options` must be an array.');

    // 分类标签。**截断在 executor 而不是 UI**：归档里存的就该是最终值，
    // 否则同一个事件在两个版本的 UI 下会显示不同长度。截断逻辑见
    // `truncateAskHeader`（按码点数，不切碎 emoji 一类的代理对）。
    final rawHeader = call.args['header'];
    final header = rawHeader is String ? truncateAskHeader(rawHeader) : '';

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: question.isEmpty ? 'ask user' : 'ask: $question',
      description: header,
      // 不参与权限判定，但事件结构要求一个 CheckResult。给 allow——它如实
      // 描述了发生的事：这次调用没有被任何规则拦过。
      check: const CheckResult(decision: ToolDecision.allow),
      askOptions: parsed.error == null ? parsed.options : null,
    );
    ctx.addEvent(ev);

    if (question.isEmpty) {
      return _fail(ev, call, 'Invalid arguments: `question` is required.');
    }
    if (parsed.error != null) {
      return _fail(ev, call, parsed.error!);
    }

    // 一轮一次。**返回 isError 而不是静默丢弃**：模型看得到反馈才会学会这条
    // 约束；静默成功会让它等一个永远不会来的答案。
    if (ctx.hasAskedThisTurn) {
      return _fail(
          ev,
          call,
          'You already asked once this turn. Handle that answer before '
          'asking anything else.');
    }
    ctx.markAskedThisTurn();
    ctx.resetInvalidArgs();

    ev.status = ToolCallStatus.awaitingApproval;
    ctx.notifyChanged();

    final choice = await ctx.awaitAnswer(ev, parsed.options);
    if (choice == null || choice.isEmpty) {
      const msg = 'The user did not answer (session cancelled).';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg, isError: true);
    }

    // 自由输入的标注 + 截断说明的拼接，逻辑在 `formatAskAnswerContent`
    // 里——纯字符串拼接，抽出去之后能直接单测，不必装配 loop。
    final content = formatAskAnswerContent(choice, parsed);
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = choice;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: content);
  }

  ToolResult _fail(ToolCallEvent ev, ToolCall call, String msg) =>
      ctx.failTool(ev, call, msg);
}
