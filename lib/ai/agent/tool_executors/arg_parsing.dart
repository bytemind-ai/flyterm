// SPDX-License-Identifier: GPL-3.0-or-later
/// executor 共用的参数解析。
///
/// 模型给的 JSON 参数没法当类型安全的输入用：数字可能是字符串、可能带小数点、
/// 可能是负数。这里的函数把「宽容地解析」和「解析不了就退回默认值」这两件事
/// 收在一处，免得每个 executor 各写一版判断。
library;

import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../tool_models.dart';

/// 把模型给的参数转成正整数（[allowZero] 时含 0）。
///
/// **必须同时吃 `num` 和 `String`。** 这些值来自模型，而模型（以及中间的
/// OpenAI 兼容代理）把数字序列化成字符串 `"10"` 非常常见 —— `tool_models
/// .dart` 的 `asTokenCount` 上方专门为同一件事写过一段说明。只认 `num`
/// 的话，`offset: "10"` 会**静默退化成默认值**：不报错、不提示，模型以为
/// 自己从第 10 行开始读，实际读的是第 1 行。
///
/// 吃 `num` 而不只是 `int`：模型偶尔给 `10.0`（JSON 里没有整数类型这回事）。
int asPositiveInt(dynamic v, int fallback,
    {bool allowZero = false}) {
  int? n;
  if (v is num) {
    n = v.toInt();
  } else if (v is String) {
    n = int.tryParse(v) ?? double.tryParse(v)?.toInt();
  }
  if (n == null) return fallback;
  if (allowZero) return n < 0 ? fallback : n;
  return n <= 0 ? fallback : n;
}

/// 必填参数缺失 / 类型不对时的统一错误文案。
///
/// **两套措辞曾经并存**：app / sftp 侧写 `Missing required argument \`X\`.`，
/// file / job / web / skill 侧写 `Invalid arguments: \`X\` is required.`。
/// 它们描述的是同一件事，模型却收到两种格式 —— 而前者不说「这是参数问题」，
/// 模型容易把它当成执行期失败去排查，而不是回头补参数。
///
/// 统一到 `Invalid arguments:` 前缀，是因为它多一层信息（错误归属在参数），
/// 且现有变体（`is required and must be a string` 之类）本来就在用它。
///
/// [what] 是参数名，或一句更具体的描述（`\`old_string\` and \`new_string\``）。
String missingArgMessage(String what) =>
    'Invalid arguments: `$what` is required.';

/// executor 失败回填的两种形状，收在一处。
///
/// 拆成 extension 而不加进 `AgentToolContext`：那个接口已经有四十多个成员，
/// 而这两个方法**完全可以用已有成员表达**（`noteInvalidArgs` /
/// `finishToolCall` / `notifyChanged`）——放进接口只是把实现细节挪个位置，
/// 每个实现者还得各写一遍。extension 让它对任何 context 都成立。
extension ToolFailures on AgentToolContext {
  /// 参数错误，且**已经有一张事件卡**：记失败、把 msg 写到卡上、刷 UI，
  /// 返回给模型的错误结果。
  ///
  /// 这五行此前在 `skill_executors.dart` 里逐字重复了 3 遍（`invalid` 的
  /// 三个副本），`ask_executors.dart` 的 `_fail` 是第 4 遍，`agent_loop`
  /// 里另有一份内联。
  ///
  /// **`noteInvalidArgs` 必须在里面。** 连续多次参数错会触发 loop 熔断 ——
  /// 模型在原地打转时不能无限烧 token。漏掉它等于把熔断保护漏掉。
  ///
  /// （反过来说：调用这个方法的 executor 就是「参数错该计入熔断」的；
  /// 不想计入的用 [failToolBare]，别在这里动手脚。）
  ToolResult failTool(ToolCallEvent ev, ToolCall call, String msg) {
    noteInvalidArgs();
    finishToolCall(ev, ToolCallStatus.failed);
    ev.output = msg;
    notifyChanged();
    return ToolResult(callId: call.id, content: msg, isError: true);
  }

  /// 参数错误，但**还没有事件卡**，不应该为此发一张。
  ///
  /// 与 [failTool] 的分工就是「有没有卡」。没有卡的场合（如 `install_skill_assets`
  /// 在参数校验阶段就失败）发一张卡只会让面板多一条噪音。
  ///
  /// **不在这里调 `noteInvalidArgs`。** 是否计入连续无效计数是有意的语义
  /// 分野，不是可以“统一顺手”的东西：`more_tools` 猜错组名就**刻意不调**
  /// （见那里的注释），而 app / sftp 两个 executor 历史上也从不调。把它们
  /// 一把抬高成会熔断，是修复还是回归得单独判，不该搭在重构里。
  ToolResult failToolBare(ToolCall call, String msg) {
    return ToolResult(callId: call.id, content: msg, isError: true);
  }
}
