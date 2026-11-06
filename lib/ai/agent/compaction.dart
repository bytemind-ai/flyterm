// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../ai_message.dart';
import 'session_facts.dart';
import 'token_estimate.dart';
import 'tool_models.dart';

/// 压缩至少要省下这么多 **token** 才值得发起。
///
/// 摘要要花一次真实的模型调用。省下几百 token 却付一次调用是净亏 ——
/// 那种情形应该继续让 `_dropOldestOutput` 去处理。
///
/// **4000 是从旧值换算来的，不是重新拍的**：旧值 8000 是**字符**，而本次
/// 之前字符与 token 靠 `/3.5` 换算。按主导内容类型（命令输出，实测
/// 2.0 chars/tok）折算，8000 字符 = 4000 token，于是对命令输出行为不变。
/// 对散文会比以前保守一点（同样 8000 字符只算 2667 token，够不着门槛就
/// 不压），而更保守是安全方向 —— 不压的后果是继续用 `_dropOldestOutput`，
/// 不是出错。
const int kMinCompactionGain = 4000;

/// 算出压缩的切点：`history[1, cut)` 将被一条摘要替换，`history[cut..]` 原样
/// 保留。返回 0 表示**不要压缩**。
///
/// ## 切点必须落在完整轮次边界上——这是最硬的约束
///
/// wire protocol 要求每个 `tool_use` 在紧接的下一个 user turn 里有恰好一个
/// `tool_result`（见 `anthropic_provider.dart` 的 `_buildToolMessages`）。
/// 如果保留段的**第一条**是 `role: 'tool'`，它的 `tool_use` 已经被砍进摘要
/// 里了 —— 那条 `tool_result` 就悬空，请求直接 400。
///
/// 所以切点向**前**推（保留更多）直到不落在 `tool` 消息上。向前而不是向后：
/// 向后推会砍掉超出预期的内容，可能把 [keepTokens] 要求的保留量吃掉。
///
/// ## 为什么按 token 不按轮数
///
/// 一轮可能是 60 token，也可能是三条 8 KiB 的日志。按轮数保留会让「保留
/// 最近 10 轮」在两种会话里意味着完全不同的上下文量。
///
/// ## 已知限制：巨型单条消息会让压缩静默失效
///
/// 下面 `cut <= 1` 的早退不仅覆盖「tool 消息对齐把 cut 推到 1」这一条路径，
/// 还覆盖一种更隐蔽的情形：如果 `history[1]` 本身就是一条超过 [keepTokens]
/// 的巨型消息（比如一段数万字符的 assistant 文本），尾部累计循环走到它时
/// 一次性冲过阈值，`cut` 直接落在 1 退出循环，随后被当成「没什么可砍的」
/// 而返回 0——压缩不会发生。`_dropOldestOutput`（`agent_loop.dart`）也救不了
/// 这种情形，它只丢 `role == 'tool'` 的输出，从不丢 assistant 文本，于是
/// 上下文预算控制在这条路径上整体失效，会话会因超预算硬停。现实概率很低
/// （模型很少一次吐出上万字符的纯文本，而巨型 tool 输出本身是可以被
/// `_dropOldestOutput` 丢掉的），本次不修，只在此处记录。
int findCompactionCut(List<AIMessage> history, {required int keepTokens}) {
  assert(keepTokens >= 0, 'keepTokens 不能是负数：负数会让下面的尾部累计循环'
      '第一次比较就满足 kept >= keepTokens，从而砍掉几乎全部历史。');
  // history[0] 是 system，永不参与。至少要有 system + 若干条才谈得上压缩。
  if (history.length < 4) return 0;

  // 从尾部往前累计，直到保留量够了。
  var kept = 0;
  var cut = history.length;
  while (cut > 1) {
    kept += estimateMessageTokens(history[cut - 1]);
    cut--;
    if (kept >= keepTokens) break;
  }

  // 切点不能落在 tool 消息上 —— 向前推，保留更多。
  while (cut > 1 && history[cut].role == 'tool') {
    cut--;
  }
  // cut 可能被推到 1（system 之后立刻保留），那就没什么可砍的了。
  if (cut <= 1) return 0;
  // 越界保护：cut == history.length 意味着什么都不保留，那不是压缩而是清空。
  if (cut >= history.length) return 0;

  final gain = history
      .sublist(1, cut)
      .fold<int>(0, (a, m) => a + estimateMessageTokens(m));
  if (gain < kMinCompactionGain) return 0;

  return cut;
}

/// 把要被砍掉的那段历史拼成一次摘要请求。
///
/// ## 不带 system 消息
///
/// agent 的 system prompt 讲的是「你有这些工具、要先查再动手」。带着它去
/// 要一份摘要，模型会尝试调工具、或者按排查助手的口吻回话。摘要是一次
/// 独立的、无工具的文本任务。
///
/// ## 改动与 job 不在这里要，由代码提取
///
/// 这份 prompt 原先有第四段，要求模型逐字抄下改过的文件路径和还在跑的
/// job id。那件事现在由 `session_facts.dart` 的 `extractSessionFacts` 用
/// 确定性规则做：模型抄标识符会漏、会错，还要花 output token 复述本来就
/// 躺在 `ToolCall.args` 里的字符串。
///
/// 留在这里的三段都是**代码提取不了的判断**——哪些事实已被确认、哪些假设
/// 已被排除、还有什么没查。
///
/// ## 第二段的措辞要匹配它实际能拿到的证据
///
/// 触发顺序是先 `AgentLoop._dropOldOutputsIfNeeded` / `_dropOldestOutput`
/// 把最早的、尚未丢过的工具输出换成 `[output dropped: N lines, exit N]`
/// 这类 marker，便宜的手段用尽了才轮到这里的摘要压缩（`findCompactionCut`
/// 只在省下的量达到 [kMinCompactionGain] 时才建议压缩）。也就是说传进
/// [dropped] 的 tool 消息内容完全可能已经是 marker 而不是原始日志——
/// 摘要请求能确实拿到的证据是「跑过什么命令、退出码、assistant 自己写下的
/// 判断」，不是保证仍在的原始输出。下面第二段的措辞按这个现实调整过。
List<AIMessage> buildSummaryRequest(List<AIMessage> dropped) {
  final buf = StringBuffer();
  for (final m in dropped) {
    if (m.role == 'system') continue;
    switch (m.role) {
      case 'user':
        if (m.content.trim().isNotEmpty) buf.writeln('USER: ${m.content}');
      case 'assistant':
        if (m.content.trim().isNotEmpty) {
          buf.writeln('ASSISTANT: ${m.content}');
        }
        for (final t in m.toolCalls ?? const <ToolCall>[]) {
          // 展开成可读文本：`AIMessage.content` 在带 toolCalls 时常常是空的，
          // 只拼 content 会让摘要请求里根本看不到跑过什么命令。
          //
          // 带上 `t.id`：并行工具调用是这一期的核心特性，同一条 assistant
          // 消息可能连发多个 TOOL_CALL，紧跟着多条 TOOL_RESULT——没有 id
          // 只能靠先后顺序去猜配对，猜错了会把某个命令的结果安到另一个
          // 命令头上。
          //
          // args 用 `jsonEncode` 而不是 `Map` 的默认 `toString()`：命令参数
          // 里常见的 `,` 或 `}`（比如一条 shell 命令本身）会让 `toString()`
          // 的输出产生歧义（分不清是参数值的一部分还是 Map 的分隔符），
          // `jsonEncode` 没有这个问题。
          buf.writeln(
              'TOOL_CALL ${t.name} (id=${t.id}): ${jsonEncode(t.args)}');
        }
      case 'tool':
        for (final r in m.toolResults ?? const <ToolResult>[]) {
          // 带上 `r.callId`：理由同上——并行调用时结果要能配回它的调用。
          buf.writeln(
              'TOOL_RESULT for ${r.callId} (exit ${r.exitCode ?? '?'}): '
              '${r.content}');
        }
    }
  }

  return [
    AIMessage(role: 'user', content: buf.toString()),
    const AIMessage(
      role: 'user',
      content: 'The text above is the first part of a troubleshooting session '
          'on a remote Linux server. Compress it into a compact handover note '
          'with exactly these three sections:\n'
          '1. CONFIRMED FACTS — what has been established (services, ports, '
          'versions, config values actually observed).\n'
          '2. RULED OUT — hypotheses already checked and eliminated, citing '
          'the commands run, their exit codes, and the reasoning that ruled '
          'them out (the raw command output may no longer be available). Be '
          'thorough here: without it the next steps will re-run checks that '
          'were already done.\n'
          '3. STILL OPEN — leads not yet verified.\n\n'
          'Be dense. Drop pleasantries and raw log dumps, keep numbers, paths '
          'and identifiers. Do not speculate beyond what the transcript says.',
    ),
  ];
}

/// 把摘要文本与事实块包成一条可以塞进 `_history` 的消息。
///
/// **user 角色**，不是 assistant：assistant 消息带不带 `toolCalls` 都要额外
/// 考虑配对，user 没有这个负担。这与 `approvePlan` 把批量执行结果以 user
/// 消息注入的做法一致。
///
/// ## 为什么事实块在这里拼、不让调用方拼好传进来
///
/// 「摘要为空时怎么办」这个降级决策属于这个函数。散到调用方会出现两处不
/// 一致的降级逻辑，而这条路径极少被走到 —— 不一致会藏很久。
///
/// ## 摘要为空 ≠ 没有上下文
///
/// `complete()` **抛异常**时压缩根本不会发生（`agent_loop.dart` 那里
/// `return false`，`_history` 不动）。真正会走到这里的是「调用成功但返回
/// 空字符串」——历史照常被替换掉。事实块由代码生成、不依赖那次调用，所以
/// 这种情形下它仍然完整：故障从「静默丢失改动记录」降级成「丢了叙事，
/// 事实还在」。
AIMessage buildSummaryMessage(String summary, SessionFacts facts) {
  final s = summary.trim();
  final factBlock = formatSessionFacts(facts);
  final buf = StringBuffer();

  buf.writeln('--- summary of the earlier part of this session ---');
  if (s.isNotEmpty) {
    buf.writeln(s);
  } else if (factBlock.isEmpty) {
    buf.writeln('(the summary came back empty; earlier context was dropped '
        'to stay within the context window)');
  } else {
    buf.writeln('(the narrative summary could not be generated; the '
        'confirmed facts below were extracted directly from the dropped '
        'messages)');
  }
  if (factBlock.isNotEmpty) {
    buf.writeln();
    buf.writeln(factBlock);
  }
  buf.write('--- end of summary; the messages after this are verbatim ---');

  return AIMessage(role: 'user', content: buf.toString());
}
