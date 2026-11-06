// SPDX-License-Identifier: GPL-3.0-or-later
import 'agent_loop.dart';

/// 够格提议所需的最少**成功**工具调用数。
///
/// 3 是拍出来的，但方向是明确的：门槛太低会让「问了句 df -h 就走」这类
/// 会话每次都花一次提炼调用，而它们本来就没什么可沉淀的。
const int kMinToolCallsForProposal = 3;

/// 算作「实际动作」的工具。
///
/// 纯读的会话不提议：「我看了三个文件」不是知识。要求至少有一次改动或
/// 执行，才说明这次排查真的做了什么。
///
/// 刻意**不含** `run_saved_command`：那条命令本来就是用户自己存下来的，
/// 跑一遍它不产生新知识。
const Set<String> kActionToolNames = {'bash', 'edit_file', 'write_file'};

/// 这次收工够不够格提议沉淀。
///
/// **纯函数、零 IO、零成本** —— 它跑在 `_stop(completed)` 之前的热路径上，
/// 不通过就直接返回，一分钱不花。真正花钱的提炼调用在它之后。
///
/// 开关（用户在设置里关掉这个功能）**不在这里判**：那放在装配处的闭包里，
/// 关闭时连提炼调用都不发起，省得更早。
bool shouldProposeKnowledge({
  required AgentStopReason reason,
  required List<AgentEvent> events,
  required bool alreadyProposed,
}) {
  // 一次会话最多一张卡。用户忽略过一次说明他当下不想做沉淀这件事，同一
  // 会话里再弹就是打扰；已存过一次说明价值已经落袋。保守的默认，放宽很
  // 容易（把标志换成计数）。
  if (alreadyProposed) return false;

  // 半截的排查沉淀下来就是错误知识，而错误知识比没有知识贵 —— 它每轮花
  // 30 token 把模型往沟里带。
  if (reason != AgentStopReason.completed) return false;

  var done = 0;
  var hasAction = false;
  for (final e in events) {
    if (e is! ToolCallEvent) continue;
    if (e.status != ToolCallStatus.done) continue;
    done++;
    if (kActionToolNames.contains(e.toolName)) hasAction = true;
  }
  return done >= kMinToolCallsForProposal && hasAction;
}
