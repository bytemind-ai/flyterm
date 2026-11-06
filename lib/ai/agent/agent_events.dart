// SPDX-License-Identifier: GPL-3.0-or-later
/// aipanel 的事件模型：面板渲染与 SQLite 归档共用的那一层。
///
/// 从 `agent_loop.dart` 拆出来（原先它们和 5000 行的 `AgentLoop` 挤在同一个
/// 文件里）。拆的理由不是行数，是**改一个事件字段会牵动归档序列化**——
/// `agentEventToJson` / `agentEventsFromJson` 这一对必须成对修改，而它们此前
/// 埋在执行逻辑中间，UI 侧改渲染时看不见这条约束。
///
/// `agent_loop.dart` 用 `export` 重新导出本文件，所以 94 个既有引用方
/// 不需要改 import。新代码建议直接 import 这里。
library;

import '../attachment.dart';
import 'ask_option.dart';
import 'knowledge.dart';
import 'tool_models.dart';
import 'tool_registry.dart';

/// loop 的运行状态。
///
/// 与事件放在同一个文件里是**被循环 import 逼出来的**，不是分类上的判断：
/// `agent_tool_context.dart` 的接口签名要用到它，而那个文件被
/// `agent_loop.dart` import —— 状态枚举留在 loop 里就成环了。这一层是
/// 「谁都能依赖、自己不依赖任何人」的共享模型层，状态枚举属于它。
enum AgentLoopState {
  idle,
  thinking,
  executing,
  awaitingApproval,

  /// 正等用户回答一个 `ask_user`——点一个选项，或者自己打字（`✎ 其他…`）。
  ///
  /// 与 [awaitingApproval] 分开，只因为面板顶部的状态文案不同：「等你回答」
  /// 和「等你确认」对用户是两件事。挂起机制、`ToolCallStatus`、归档行为全部
  /// 与审批共用。
  awaitingAnswer,

  /// 撞上 429，正在退避等待下一次重试。
  ///
  /// 单独成一个状态而不是复用 `thinking`：那会让面板在几十秒里显示「思考
  /// 中…」而其实什么都没发生，用户只会以为卡死了然后去杀进程。这个状态带
  /// 倒计时（`AgentLoop.rateLimitRemaining`），并且 Stop 按钮照常可用。
  rateLimited,
  done,
  cancelled,
  failed,
}

enum ApprovalDecision {
  allowOnce,
  reject,

  /// 「加入方案」：不现在跑，攒进队列。
  addToPlan,
}

/// 一次审批的结果：用户点了什么。
///
/// 从 `AgentLoop._ApprovalOutcome` 转公开——executor 搬到
/// `tool_executors/` 之后要在签名里出现它，私有类跨不了文件。
///
/// **曾有一个 `reason` 字段**（拒绝理由，拼进回填给模型的 tool_result）。
/// 2026-10-13 删除：那条链路一直是活的，但 UI 侧从未渲染过输入框
/// （`approval_card.dart` 的 `_reasonCtrl` 定义了没人绑），所以恒为空。
/// 补一个输入框意味着手机键盘上敲一段中文，成本高于它给模型的信息价值。
class ApprovalOutcome {
  final ApprovalDecision decision;
  const ApprovalOutcome(this.decision);
}

enum AgentStopReason {
  completed,
  maxTurns,
  tokenBudget,
  userCancelled,
  invalidArgs,
  error,
}

enum ToolCallStatus {
  awaitingApproval,
  running,
  done,
  failed,
  rejected,

  /// 已加入方案，等用户批准。就这一轮而言是终态——批准后会以队列执行的
  /// 形式重新产生新的事件。
  deferred,
}

/// 这次调用是否已经结束。
///
/// 分档判据**只看状态**，不看工具名、不看有没有按钮、不看写没写文件。
/// `ed7bbe9` 回退的那版拿 `backupPath` 判「重不重要」，而该字段只在
/// `willOverwrite` 分支赋值 —— 结果覆盖已有文件（能撤销）不折叠、往远端
/// 写新文件（撤不回来）反而折叠，越不可逆越被收起来。
///
/// 换成状态之后判据是行为性的（状态机在哪一档），不再需要猜哪个操作重要；
/// 而流水行本身不丢内容，所以也没有「猜错了就丢信息」的风险。
///
/// **住在这里而不是 `tool_call_card.dart`**：它是 [ToolCallStatus] 的谓词，
/// 与那个枚举同生共死。留在卡片文件里的话，`ask_user_list.dart` 要用它就得
/// 反向 import 卡片文件，而卡片文件已经 import 了它——一个纯粹由摆放位置
/// 造出来的循环依赖。
bool isTerminal(ToolCallStatus s) =>
    s == ToolCallStatus.done ||
    s == ToolCallStatus.failed ||
    s == ToolCallStatus.rejected;

/// UI 渲染用的事件流。与发给模型的 `_history` 分开 —— 后者是 wire 格式，
/// 前者是展示格式，混用会让两边互相牵制。
sealed class AgentEvent {}

class UserTurnEvent extends AgentEvent {
  final String text;

  /// 这一轮随消息发出的附件。
  ///
  /// **与 `AIMessage.attachments` 是两份平行数据，不是投影。** `_history` 与
  /// `_events` 本来就并行维护（`_run` 里那两行相邻的 add），前者发给 provider、
  /// 后者供 UI 渲染与归档。少了这一份，气泡里显示不出缩略图。
  final List<Attachment>? attachments;

  /// 这一轮已被「编辑重发」取代。
  ///
  /// **标记而不是删除**，与 [ToolCallEvent.superseded] 同一个理由：这一轮里
  /// 的工具调用确实在远端执行过，而它们身上挂着 `backupPath`——删掉事件就
  /// 等于拿走撤销按钮，而用户想重发的场景很可能恰恰是「agent 改错了文件」。
  bool supersededByEdit = false;

  UserTurnEvent(this.text, {this.attachments});
}

class AssistantTextEvent extends AgentEvent {
  final String text;
  AssistantTextEvent(this.text);
}

class ToolCallEvent extends AgentEvent {
  /// 会话内单调递增，**UI 应当用它而不是 [callId] 做列表 key**。
  ///
  /// [callId] 只在**一轮之内**保证唯一：Ollama 不返回 id，我们按下标合成
  /// `ollama_call_0`、`ollama_call_1`，每轮从头计数；OpenAI 的 `call_1`
  /// 一类短计数器也可能跨轮重复。拿它当 Flutter widget key，重复时直接抛
  /// 异常。
  final int seq;

  final String callId;
  final String toolName;

  /// 展示给用户看的命令（read_file 展示成实际会跑的 sed）。
  final String displayCommand;

  /// 大多数工具上是「模型给的这次调用的人话说明」。
  ///
  /// **`ask_user` 上被复用成分类标签**（渲染在问题行前面的 `[实例]`），不是
  /// 说明文字——那一支不与**渲染**分支冲突（它走 `AskUserList` 专属渲染，不是
  /// `ToolCallCard` 的通用说明行），但改这个字段的人得知道有这个特例。截断
  /// 已经在 `AskExecutors.askUser` 里完成（见 `kMaxAskHeaderChars`），这里
  /// 存的就是最终展示值，不需要再截一遍。
  ///
  /// **非 UI 消费者会看到裸标签，这是已知且判定为可接受的代价**：
  /// - `knowledge_distiller.dart` 拼 actions 摘要时会原样带上 `description`，
  ///   于是知识提炼的 prompt 里会出现 `实例 :: ask: 先处理哪个？` 这种行。
  /// - `session_markdown.dart` 导出会话时，`实例` 会单占一行。
  ///
  /// 两处都不修：影响是「多一行不影响理解的标签文字」，而修它们要么把
  /// `ask_user` 特判撒进两个不相干的文件，要么给 `ToolCallEvent` 加一个新
  /// 字段（当前范围之外）。`lib/main.dart` 的审批通知标题是例外——那里裸标签
  /// 会让通知标题本身失去意义（详见该处 `_approvalNotificationTitle` 的
  /// 注释），所以单独打了补丁。
  final String description;
  final CheckResult check;

  /// 文件写入类工具的展示载荷。`bash` / `read_file` 上为 null。
  final FileEditPreview? preview;

  /// `ask_user` 的候选项。其它工具上为 null。
  ///
  /// 与 [preview] 同一个模式——都是「某类工具专属的展示载荷」。
  ///
  /// **不进归档。** 序列化时挂起态被存成 `rejected`（见本文件里那段「等审批的
  /// 卡片存成已拒绝」的注释），恢复出来的卡片本来就不该渲染按钮，存了也没人用。
  final List<AskOption>? askOptions;

  /// 这次调用打的是哪台服务器。null = 当前会话那台。
  ///
  /// **必须进归档**：撤销按钮要按它路由回目标机取备份。从 [displayCommand]
  /// 里解析机器名是不行的——那个字符串是给人看的，格式会变。
  final String? targetServerName;

  ToolCallStatus status;
  String? output;
  int? exitCode;

  /// 这次写入生成的备份文件路径。null = 不是写文件工具，或写入没成功。
  ///
  /// 存在事件上（而不是每次撤销时重算）是因为它要进归档：关掉面板再打开，
  /// 撤销按钮必须还知道该拷哪个文件回来。
  String? backupPath;

  /// 已经撤销过了。撤销按钮据此变成不可点的「已撤销」。
  bool undone = false;

  /// 撤销时发现备份文件已不存在。按钮永久置灰 + 一行说明。
  ///
  /// 与 [undone] 分开：前者是「回退成功了」，这个是「回退不了了」，UI 上是
  /// 两种不同的呈现，合成一个 bool 会分不清。
  bool backupMissing = false;

  /// 这张卡是一次**抢跑**的产物，而抢跑落空了（判据在 StreamDone 时已变），
  /// 结果被丢弃、命令按正常路径重跑了一遍。
  ///
  /// 不删掉这张卡而是标记它：那条命令**确实在远端执行过**，抹掉它会让
  /// 时间线与真实发生的事对不上。抢跑的按定义是只读命令，所以「跑了两次」
  /// 无副作用，但它仍然是一个用户有权看到的事实。
  bool superseded = false;

  /// 开始执行的时刻。null = 还没开始跑（等审批中，或已从归档恢复）。
  ///
  /// **不进归档**（见 `agentEventToJson`）：恢复出来的卡片是只读终态，
  /// 「上次那条跑了多久」没人看，写进去只是白占存档体积。
  DateTime? startedAt;

  /// 从开始执行到终态的毫秒数。null = 还没跑完，或从归档恢复的旧存档。
  ///
  /// **进归档**，与 [startedAt] 相反。那条注释拒绝 `startedAt` 入档的理由是
  /// 「恢复出来的卡片是只读终态，『上次那条跑了多久』没人看」——前半句现在
  /// 不成立了（卡片上要显示它），后半句仍然成立，所以存一个算好的 int 而不是
  /// 把 DateTime 写进去：体积更小，也不必在 `_restore` 里处理「有起点无终点」
  /// 的中间状态。
  int? durationMs;

  ToolCallEvent({
    required this.seq,
    required this.callId,
    required this.toolName,
    required this.displayCommand,
    required this.description,
    required this.check,
    this.preview,
    this.askOptions,
    this.targetServerName,
    this.status = ToolCallStatus.running,
  });
}

class StoppedEvent extends AgentEvent {
  final AgentStopReason reason;
  StoppedEvent(this.reason);
}

/// 模型更新了步骤列表。
///
/// 事件流里保留每一次更新（而不是只在 loop 上存一份状态），是为了让
/// checklist 出现在时间线的正确位置 —— 「它当时打算做什么」和「它随后做了
/// 什么」挨在一起才读得懂。
class PlanUpdatedEvent extends AgentEvent {
  final List<String> steps;
  final int? current;
  PlanUpdatedEvent(this.steps, this.current);
}

/// 队列里攒了若干待执行的调用，等用户整批批准。
///
/// 与 [PlanUpdatedEvent] 完全是两回事：那个是模型自己报的进度清单（`set_plan`
/// 工具），纯展示；这个是**我们拦下来的真实调用**，批准后会真的执行。
class PlanProposalEvent extends AgentEvent {
  final List<ToolCall> calls;
  PlanProposalEvent(this.calls);
}

/// 收尾时提炼出的候选知识，等用户拍板。
///
/// 与 [PlanProposalEvent] 形状相似而语义完全不同：那个是「已入队的调用等你
/// 批准执行」，这个是「排查完了，要不要把学到的存下来」。前者不存就丢了
/// 一次执行，后者不存只是少一条知识——所以这张卡的默认动作是**忽略**。
///
/// [candidates] 至多 2 条（最多一条 skill + 最多一条 server_note），上限在
/// `parseDistillCandidates` 里就已经收好。
class KnowledgeProposalEvent extends AgentEvent {
  final List<KnowledgeCandidate> candidates;

  /// 已经处理过（存入或忽略）的下标。卡片据此把那一条压暗。
  ///
  /// 可变且进归档：不进的话，关掉面板再打开，已经存过的条目会变回「待
  /// 决定」，用户第二次点存入就把同一条知识又写了一遍。
  final Set<int> resolved;

  KnowledgeProposalEvent(this.candidates, {Set<int>? resolved})
      : resolved = resolved ?? <int>{};
}

/// 一轮里若干需审批的调用，攒成一张卡等用户整批批准。
///
/// 与 [PlanProposalEvent] 形状相似而语义不同，**不要合并**：那个是 plan 模式
/// 的攒批，语义是「已入队、还没执行、你先忙别的」，回填给模型的是
/// `[deferred]`；这个是**这一轮的调用正挂起等你点**，批准后立刻执行，模型那
/// 边还在等 tool_result。合并会让「已经回过 deferred」与「还欠一个 result」
/// 这两种状态混在一个类型里。
///
/// 它存在的理由是跨机：三台机器上跑同一条需审批的命令，逐张弹卡要点三次，
/// 而并行弹三张卡用户根本分不清哪张对应哪台。
class BatchApprovalEvent extends AgentEvent {
  final List<ToolCall> calls;

  /// 每条调用的目标机器名，与 [calls] 一一对应。null = 当前会话那台。
  final List<String?> targets;

  BatchApprovalEvent(this.calls, this.targets);
}

/// 一个后台任务的卡片状态。
///
/// 与 [ToolCallEvent] 分开的理由：那个是「一次调用、一次输出、可能要审批」
/// 的形状，生命周期在一轮之内结束；这个的生命周期跨轮、跨面板开关、甚至
/// 跨 app 重启，字段要能被后续的 `check_job` 反复更新。
/// AI 改了 app 设置。**卡片内容不存在这里，只存批次 id。**
///
/// 真相来源是 `AppControlService.changeLog` 里那个批次：它持有每项变更的
/// 旧值与 undo 闭包，而闭包序列化不了。事件只负责「事件流的这个位置有一张
/// 卡」，渲染时拿 id 回查。
///
/// 这也意味着会话归档恢复之后卡片会查不到批次（撤销栈不落盘，见
/// `AppChangeLog` 的类文档）——那时卡片降级成一行历史记录，不再提供撤销。
/// 这是刻意的：进程重启后用户可能已手动改过，回滚到旧值反而是破坏。
class AppChangeEvent extends AgentEvent {
  final String batchId;
  AppChangeEvent(this.batchId);
}

class BackgroundJobEvent extends AgentEvent {
  /// 会话内唯一，UI 拿它做列表 key（理由同 [ToolCallEvent.seq]）。
  final int seq;
  final String jobId;
  final String command;
  final String description;

  /// 起始时刻（epoch ms）。**要进归档** —— 与 `ToolCallEvent.startedAt`
  /// 相反，这里的运行时长有意义：任务可能真的还在跑，用户需要知道跑了多久。
  final int startedAtMs;

  /// 已读到日志的第几行。下次 `check_job` 的 `since_line` 从这里来。
  int lineCursor;

  /// 最近的日志尾巴，仅供展示。
  ///
  /// **限长**（[kJobTailLimit]）：归档进 `shared_preferences`，一个跑了
  /// 半小时的 `docker build` 能吐几百 KiB，全存会把整份存档撑爆。
  String tail;

  /// 最后一次**确认过**它状态的时刻（epoch ms）。
  ///
  /// 与 [startedAtMs] 是两件事：那个是「什么时候起的」，这个是「我们最后
  /// 一次知道它怎么样了是什么时候」。
  ///
  /// 存在的理由是 [running] 的判据 —— `exitCode == null` —— 只有在模型调
  /// `check_job` 时才会被推翻。模型不去查，这个标志就永远是 true，而 UI
  /// 上那个数字会一直涨下去。把「多久没核实」摆出来，比让用户误以为我们
  /// 在实时监控要诚实。
  int lastCheckedAtMs;

  /// null = 还在跑。
  int? exitCode;

  /// 用户点过「终止」。与 `exitCode != null` 分开：终止请求发出后到进程真的
  /// 死掉之间有一段时间，UI 要在这段时间里显示「正在终止」而不是「已完成」。
  bool killed;

  /// 这个 job 跑在哪台机器上。null = 当前会话那台（与 `ServerTarget.serverId`
  /// 同一约定）。
  ///
  /// **必须记在事件上，不能让模型每次 check/kill 时重报。** 模型很容易漏掉
  /// `server` 参数 —— 起任务时的回填文案根本没提机器名 —— 一漏就会去轮询/
  /// 终止错误的机器。而终止错机器的表现是「命令成功执行了」，于是 killJob
  /// 里那段「杀不掉就把标记退回去」的兜底被静默绕过，UI 显示已终止而任务
  /// 还在目标机器上烧 CPU。
  final String? serverId;

  /// 展示用名字（任务卡上可显示「web-2 上正在跑」）。null = 当前会话那台。
  final String? serverName;

  BackgroundJobEvent({
    required this.seq,
    required this.jobId,
    required this.command,
    required this.description,
    required this.startedAtMs,
    this.lineCursor = 0,
    this.tail = '',
    int? lastCheckedAtMs,
    this.exitCode,
    this.killed = false,
    this.serverId,
    this.serverName,
  }) : lastCheckedAtMs = lastCheckedAtMs ?? startedAtMs;

  bool get running => exitCode == null;

  /// 追加日志尾巴并按 [kJobTailLimit] 从头裁掉超出部分。
  void appendTail(String more) {
    if (more.isEmpty) return;
    final joined = tail.isEmpty ? more : '$tail\n$more';
    tail = joined.length <= kJobTailLimit
        ? joined
        : joined.substring(joined.length - kJobTailLimit);
  }
}

/// 任务卡上保留的日志尾巴上限（字符）。
const int kJobTailLimit = 4000;

/// 被硬杀时正在跑的工具卡,恢复后填这个输出。
const String kInterruptedOutputMarker =
    '[interrupted: the app process was killed — the result of this command '
    'is unknown]';

enum TransferDirection {
  download,
  upload,

  /// 服务器 → 手机 → 另一台服务器。两段传输在用户眼里是一件事。
  relay,
}

/// 中转当前处在哪一段。仅 [TransferDirection.relay] 有意义。
enum TransferPhase { downloading, uploading }

enum TransferStatus {
  running,
  done,
  cancelled,
  failed,

  /// 从归档恢复出来的、上次没跑完的传输。
  ///
  /// 与 [failed] 分开：那个是「传的时候出错了」，这个是「app 被杀了，我们
  /// 不知道它当时怎么样」。UI 上前者显示错误原因，后者只能说「已中断」。
  /// 合成一个会让卡片编一个不存在的失败原因。
  interrupted,
}

/// 一次文件传输的卡片状态。
///
/// 与 [ToolCallEvent] 分开的理由与 [BackgroundJobEvent] 完全相同：那个是
/// 「一次调用、一次输出、可能要审批」的形状，生命周期在一轮之内结束；这个
/// 的生命周期跨轮、跨面板开关（用户过一会儿还要点「打开」），而且带一个
/// 会改变本地状态的操作（分享 / 让 AI 读）。
class TransferEvent extends AgentEvent {
  /// 会话内唯一，UI 拿它做列表 key（理由同 [ToolCallEvent.seq]）。
  final int seq;
  final TransferDirection direction;
  final String remotePath;

  /// 展示用文件名。
  final String filename;

  /// 0 = 未知（stat 失败）。UI 据此走不确定进度条。
  final int totalBytes;

  /// 下载：落盘路径。上传：本地源文件路径。null = 还没确定。
  String? localPath;

  int bytesDone;
  TransferStatus status;

  /// 失败原因，展示用。
  String? error;

  /// 命中凭据清单 —— 「让 AI 读完」按钮据此禁用。
  ///
  /// **必须进归档**：关掉面板再打开，那个按钮不能因为忘了这件事而重新可点。
  bool credentialDeny;

  /// 上传覆盖时生成的备份路径。null = 没有发生覆盖。
  String? backupPath;

  /// 中转的源机器名。null = 非中转。
  final String? fromServerName;

  /// 中转的目标机器名。null = 非中转。
  final String? toServerName;

  /// 中转的目标远端路径。null = 非中转。[remotePath] 此时是**源**路径。
  final String? destPath;

  /// 中转当前在哪一段。
  ///
  /// **不进归档**：恢复出来的中转一律是 `interrupted`（没有续传），那时「当初
  /// 卡在哪一段」对用户没有任何可操作性，写进去只是白占存档体积。
  TransferPhase? phase;

  TransferEvent({
    required this.seq,
    required this.direction,
    required this.remotePath,
    required this.filename,
    required this.totalBytes,
    this.localPath,
    this.bytesDone = 0,
    this.status = TransferStatus.running,
    this.error,
    this.credentialDeny = false,
    this.backupPath,
    this.fromServerName,
    this.toServerName,
    this.destPath,
    this.phase,
  });

  bool get running => status == TransferStatus.running;
}

/// 历史被压缩过一次。
///
/// 这张卡是**推翻 `2026-08-21` 那条否决的全部依据** —— 当时否决摘要压缩的
/// 理由是「摘错了没法察觉」。把摘要摊在面板上、可展开核对，就把「没法察觉」
/// 变成了「看得见」。不要为了省一格 UI 把它去掉。
class CompactedEvent extends AgentEvent {
  /// 被折叠掉的消息条数。展示用。
  final int droppedMessages;
  final String summary;

  CompactedEvent({required this.droppedMessages, required this.summary});
}

/// 事件列表撞上 `AgentLoop._kMaxEvents` 时，被丢弃的那部分留下的痕迹。
///
/// 与 [CompactedEvent] 的区别是**能不能找回**：那个是历史被压缩成摘要，摘要还在，
/// 可以展开核对；这个是真的丢了 —— 裁剪发生在 `_events.removeRange`，而归档写入在
/// 终态，所以归档里存的就是已经被裁过的列表。
///
/// 因此它的文案是「已省略」而不是「可展开」。写成后者会承诺一个做不到的动作。
///
/// 计数可变：第二次截断时累加同一条，不插入第二条 —— 时间线上出现两条「更早的 N 条
/// 已省略」只会让人困惑「到底省略了多少」。
class TruncatedEvent extends AgentEvent {
  int droppedEvents;
  TruncatedEvent(this.droppedEvents);
}

/// 上一次会话是被硬杀的(进程被终止、崩溃),不是正常结束。
///
/// 与 [StoppedEvent] 的区别是**有没有终态**:那个是 loop 自己走完某条终止
/// 路径留下的,这个是恢复时从「事件流结尾不是任何终态事件」反推出来的。
///
/// [lastCalls] 是中断那一刻正在跑的工具调用(形如 `bash(systemctl restart
/// nginx)`),用于两件事:UI 上告诉用户中断在哪,以及 `AgentLoop.resume` 把
/// 它写进给模型的中断提示——那段历史已经被归档的安全前缀丢掉了。
class SessionInterruptedEvent extends AgentEvent {
  final List<String> lastCalls;
  SessionInterruptedEvent(this.lastCalls);
}

Map<String, dynamic> agentEventToJson(AgentEvent e) => switch (e) {
      UserTurnEvent(:final text, :final supersededByEdit, :final attachments) => {
          't': 'user',
          'text': text,
          if (supersededByEdit) 'superseded': true,
          if (attachments != null && attachments.isNotEmpty)
            'attachments': attachments.map((a) => a.toJson()).toList(),
        },
      AssistantTextEvent(:final text) => {'t': 'assistant', 'text': text},
      StoppedEvent(:final reason) => {'t': 'stopped', 'reason': reason.name},
      PlanUpdatedEvent ev => {
          't': 'plan',
          'steps': ev.steps,
          if (ev.current != null) 'current': ev.current,
        },
      PlanProposalEvent(:final calls) => {
          't': 'proposal',
          'calls': calls.map((c) => c.toJson()).toList(),
        },
      // 注意 `target.name` 对 `KnowledgeTarget.serverNote` 产出的是字符串
      // `serverNote`（Dart 的 `Enum.name` 用标识符原文），与解析模型返回时
      // 用的 `server_note`（`parseDistillCandidates`）**不是同一个字符串**。
      // 两处刻意分开：一个是我们自己的存档格式，一个是给模型看的 wire
      // 约定，让它们互相牵制没有好处。
      KnowledgeProposalEvent ev => {
          't': 'knowledge',
          'items': ev.candidates
              .map((c) => {
                    'target': c.target.name,
                    'name': c.name,
                    'description': c.description,
                    'body': c.body,
                    if (c.updatesExisting != null) 'updates': c.updatesExisting,
                  })
              .toList(),
          if (ev.resolved.isNotEmpty) 'resolved': ev.resolved.toList(),
        },
      AppChangeEvent(:final batchId) => {
          't': 'app_change',
          'batch': batchId,
        },
      BackgroundJobEvent ev => {
          't': 'job',
          'seq': ev.seq,
          'jobId': ev.jobId,
          'command': ev.command,
          'description': ev.description,
          'startedAtMs': ev.startedAtMs,
          'lineCursor': ev.lineCursor,
          'lastCheckedAtMs': ev.lastCheckedAtMs,
          // 归属必须进归档：恢复后 killJob 要靠它找对机器，丢了就又退化成
          // 打当前会话那台。
          if (ev.serverId != null) 'serverId': ev.serverId,
          if (ev.serverName != null) 'serverName': ev.serverName,
          if (ev.tail.isNotEmpty) 'tail': ev.tail,
          if (ev.exitCode != null) 'exitCode': ev.exitCode,
          if (ev.killed) 'killed': true,
        },
      TransferEvent ev => {
          't': 'transfer',
          'seq': ev.seq,
          'direction': ev.direction.name,
          'remotePath': ev.remotePath,
          'filename': ev.filename,
          'totalBytes': ev.totalBytes,
          // 运行中的传输存成 interrupted：进程一死它就真的停了，留一个
          // running 会让恢复出来的卡片永远转圈。
          'status': (ev.status == TransferStatus.running
                  ? TransferStatus.interrupted
                  : ev.status)
              .name,
          if (ev.localPath != null) 'localPath': ev.localPath,
          if (ev.bytesDone > 0) 'bytesDone': ev.bytesDone,
          if (ev.error != null) 'error': ev.error,
          if (ev.credentialDeny) 'credentialDeny': true,
          if (ev.backupPath != null) 'backupPath': ev.backupPath,
          if (ev.fromServerName != null) 'fromServerName': ev.fromServerName,
          if (ev.toServerName != null) 'toServerName': ev.toServerName,
          if (ev.destPath != null) 'destPath': ev.destPath,
        },
      ToolCallEvent ev => {
          't': 'tool',
          'seq': ev.seq,
          'callId': ev.callId,
          'toolName': ev.toolName,
          'displayCommand': ev.displayCommand,
          'description': ev.description,
          // 等审批的卡片存成已拒绝：重启后没人能再应答它，留个悬挂的
          // 审批按钮只会骗用户点。
          'status': ev.status == ToolCallStatus.awaitingApproval
              ? ToolCallStatus.rejected.name
              : ev.status.name,
          if (ev.output != null) 'output': ev.output,
          if (ev.exitCode != null) 'exitCode': ev.exitCode,
          if (ev.preview != null) 'preview': ev.preview!.toJson(),
          if (ev.targetServerName != null)
            'targetServerName': ev.targetServerName,
          if (ev.backupPath != null) 'backupPath': ev.backupPath,
          if (ev.undone) 'undone': true,
          if (ev.backupMissing) 'backupMissing': true,
          if (ev.superseded) 'superseded': true,
          if (ev.durationMs != null) 'durationMs': ev.durationMs,
        },
      CompactedEvent ev => {
          't': 'compacted',
          'droppedMessages': ev.droppedMessages,
          'summary': ev.summary,
        },
      TruncatedEvent ev => {
          't': 'truncated',
          'droppedEvents': ev.droppedEvents,
        },
      SessionInterruptedEvent ev => {
          't': 'interrupted',
          'calls': ev.lastCalls,
        },
      // 等待中的批次不进归档：重启后没人能再应答它，恢复成一张卡片只会骗
      // 用户去点。与 `ToolCallEvent` 把 awaitingApproval 存成 rejected 是
      // 同一个道理，只是这里连事件本身都不必留。
      BatchApprovalEvent _ => const {'t': 'batch_dropped'},
    };

/// 未识别的事件类型被**跳过**，不抛异常 —— 存档可能来自更新的版本。
List<AgentEvent> agentEventsFromJson(List<dynamic> raw) {
  final out = <AgentEvent>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    switch (j['t']) {
      case 'app_change':
        final b = j['batch'];
        if (b is String) out.add(AppChangeEvent(b));
      case 'user':
        out.add(UserTurnEvent(
          j['text'] as String? ?? '',
          attachments: (j['attachments'] as List?)
              ?.map((e) =>
                  Attachment.fromJson((e as Map).cast<String, dynamic>()))
              .whereType<Attachment>()
              .toList(),
        )..supersededByEdit = j['superseded'] == true);
      case 'assistant':
        out.add(AssistantTextEvent(j['text'] as String? ?? ''));
      case 'stopped':
        out.add(StoppedEvent(AgentStopReason.values.firstWhere(
          (r) => r.name == j['reason'],
          orElse: () => AgentStopReason.completed,
        )));
      case 'plan':
        out.add(PlanUpdatedEvent(
          (j['steps'] as List?)?.map((e) => '$e').toList() ?? const [],
          (j['current'] as num?)?.toInt(),
        ));
      case 'proposal':
        final raw = j['calls'];
        final calls = <ToolCall>[];
        if (raw is List) {
          for (final m in raw) {
            if (m is! Map) continue;
            try {
              calls.add(ToolCall.fromJson(m.cast<String, dynamic>()));
            } catch (_) {
              // 单条坏记录跳过
            }
          }
        }
        out.add(PlanProposalEvent(calls));
      case 'knowledge':
        final items = j['items'];
        final cands = <KnowledgeCandidate>[];
        if (items is List) {
          for (final m in items) {
            if (m is! Map) continue;
            final e = m.cast<String, dynamic>();
            final target = switch (e['target']) {
              'skill' => KnowledgeTarget.skill,
              'serverNote' => KnowledgeTarget.serverNote,
              // 2026-10 改名前的 wire 值。老存档里是 agentsMd，不认的话会被
              // continue 跳过 —— 而下面的 resolved 是裸索引，少一条就整体
              // 错位，把用户从没存过的候选标成「已处理」。
              'agentsMd' => KnowledgeTarget.serverNote,
              _ => null,
            };
            // 未知去向跳过而不是回落到 skill：把一条本该写进某台机器的
            // 事实存成跨机技能，在别的机器上就是误导。
            if (target == null) continue;
            cands.add(KnowledgeCandidate(
              target: target,
              name: e['name'] as String? ?? '',
              description: e['description'] as String? ?? '',
              body: e['body'] as String? ?? '',
              updatesExisting: e['updates'] as String?,
            ));
          }
        }
        out.add(KnowledgeProposalEvent(
          cands,
          resolved: (j['resolved'] as List?)
                  ?.map((e) => (e as num).toInt())
                  .toSet() ??
              <int>{},
        ));
      case 'job':
        out.add(BackgroundJobEvent(
          seq: j['seq'] as int? ?? out.length,
          jobId: j['jobId'] as String? ?? '',
          command: j['command'] as String? ?? '',
          description: j['description'] as String? ?? '',
          startedAtMs: (j['startedAtMs'] as num?)?.toInt() ?? 0,
          lineCursor: (j['lineCursor'] as num?)?.toInt() ?? 0,
          tail: j['tail'] as String? ?? '',
          lastCheckedAtMs: (j['lastCheckedAtMs'] as num?)?.toInt(),
          exitCode: (j['exitCode'] as num?)?.toInt(),
          killed: j['killed'] as bool? ?? false,
          serverId: j['serverId'] as String?,
          serverName: j['serverName'] as String?,
        ));
      case 'transfer':
        out.add(TransferEvent(
          seq: j['seq'] as int? ?? out.length,
          direction: TransferDirection.values.firstWhere(
            (d) => d.name == j['direction'],
            orElse: () => TransferDirection.download,
          ),
          remotePath: j['remotePath'] as String? ?? '',
          filename: j['filename'] as String? ?? '',
          totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
          localPath: j['localPath'] as String?,
          bytesDone: (j['bytesDone'] as num?)?.toInt() ?? 0,
          // 未知值兜 failed 而不是 done：把一个我们读不懂的状态说成
          // 「成功了」是最坏的猜法。
          status: TransferStatus.values.firstWhere(
            (s) => s.name == j['status'],
            orElse: () => TransferStatus.failed,
          ),
          error: j['error'] as String?,
          credentialDeny: j['credentialDeny'] as bool? ?? false,
          backupPath: j['backupPath'] as String?,
          fromServerName: j['fromServerName'] as String?,
          toServerName: j['toServerName'] as String?,
          destPath: j['destPath'] as String?,
        ));
      case 'tool':
        out.add(ToolCallEvent(
          // 旧存档没有 seq，用下标兜底 —— 它只需要在这一份列表里唯一。
          seq: j['seq'] as int? ?? out.length,
          callId: j['callId'] as String? ?? '',
          toolName: j['toolName'] as String? ?? 'bash',
          displayCommand: j['displayCommand'] as String? ?? '',
          description: j['description'] as String? ?? '',
          // 恢复的卡片是只读的，check 只用于渲染，给一个放行值即可。
          check: const CheckResult(decision: ToolDecision.allow),
          status: ToolCallStatus.values.firstWhere(
            (s) => s.name == j['status'],
            orElse: () => ToolCallStatus.done,
          ),
          preview: j['preview'] is Map
              ? FileEditPreview.fromJson(
                  (j['preview'] as Map).cast<String, dynamic>())
              : null,
          targetServerName: j['targetServerName'] as String?,
        )
          ..output = j['output'] as String?
          ..exitCode = j['exitCode'] as int?
          ..backupPath = j['backupPath'] as String?
          ..undone = j['undone'] as bool? ?? false
          ..backupMissing = j['backupMissing'] as bool? ?? false
          ..superseded = j['superseded'] == true
          ..durationMs = (j['durationMs'] as num?)?.toInt());
      case 'compacted':
        out.add(CompactedEvent(
          droppedMessages: (j['droppedMessages'] as num?)?.toInt() ?? 0,
          summary: j['summary'] as String? ?? '',
        ));
      case 'truncated':
        out.add(TruncatedEvent((j['droppedEvents'] as num?)?.toInt() ?? 0));
      case 'interrupted':
        out.add(SessionInterruptedEvent(
          (j['calls'] as List?)?.map((e) => '$e').toList() ?? const [],
        ));
    }
  }
  return out;
}

/// 给 `AgentLoop.resume` 用的中断提示，注入历史让模型知道自己是被续上的。
///
/// 用英文——system prompt 和工具描述都是英文，混一句中文进去容易让模型
/// 误以为是用户原话。
///
/// 三件事都得说，缺一个都会出问题：
/// 1. 报中断在哪：[calls] 非空时把命令列出来——那段历史已经被归档的安全
///    前缀丢掉了（见 `_history` 归档时的处理），模型看不到自己刚才在干嘛。
/// 2. 说结果未知：只说「中断了」不够，模型会默认当成「大概率没做完」。
/// 3. **同时**禁止两个方向的假设：模型面对不确定性的默认倾向是重跑一遍
///    求稳，而写操作重跑是真实伤害；反过来只说「不要重跑」又会让它直接
///    假设已完成去继续下一步。两句缺一句都会把它推向其中一个坏结果，
///    所以这里显式把两个方向都堵上。
String buildInterruptNotice(List<String> calls) {
  final b = StringBuffer(
      '[The session was interrupted here — the app process was killed.');
  if (calls.isNotEmpty) {
    b.write(' At the moment of interruption you were running: ');
    b.write(calls.join(', '));
    b.write('.');
  }
  b.write(' The result is unknown: those commands may have completed, or '
      'they may not have. Verify the current state before continuing. '
      'Do not assume either outcome.]');
  return b.toString();
}
