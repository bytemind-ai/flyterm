// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io' show Directory;

import '../../app_control/app_control_service.dart';
import '../../sftp/sftp_service.dart' show SftpOps;
import '../../sftp/sftp_transfer_task.dart' show TransferCancelToken;
import 'agent_events.dart';
import 'ask_option.dart';
import 'command_runner.dart';
import 'permission_rules.dart';
import 'server_notes_manager.dart' show ServerNoteSaveResult;
import 'server_targets.dart';
import 'skill.dart';
import 'skill_search.dart';
import 'tool_models.dart';
import 'tool_registry.dart';
import 'turn_metrics.dart';
import 'web_fetch.dart';

/// 一次工具执行需要向 loop 借用的全部能力。
///
/// ## 它为什么存在
///
/// 17 个 `_executeXxx` 曾经全部长在 `AgentLoop` 上，直接读写它的私有字段。
/// 代价不是行数，是**没有第二份内核可开**：子 agent / 并行看板要的是能实例化
/// 多个可重入的执行环境，而 executor 和 loop 共享同一个对象的 83 个字段时，
/// 谁都拆不出来。
///
/// 抽这层接口的依据是一次实测：download / upload / copy_between_servers 三个
/// executor 用到的私有成员**完全相同**（11 个，无一独有），而全局统计里被 3 个
/// 以上 executor 共用的也正是同一批。依赖是收敛的，所以一个统一的 context
/// 成立 —— 不需要每个域各配一套窄接口。
///
/// ## 边界
///
/// 这里**只有 executor 真正用得到的**。loop 自己的东西（`_history`、
/// `providerProvider`、`systemPromptProvider`、turn 计数、compaction 触发）
/// 一概不进来 —— 那些是「怎么驱动一轮对话」，不是「怎么执行一次调用」。
/// 后续把 file / job / web 各域搬进 `tool_executors/` 时，在下面对应的分组里
/// 追加，不要图省事把 loop 的字段整体暴露出来。
///
/// `AgentLoop` 用 `implements` 满足它。环境回调那一组是 `final` 字段，
/// 同名即自动实现 getter，无需写转发代码。
abstract class AgentToolContext {
  // ───────── 事件流 ─────────

  /// 取下一个会话内单调递增的事件序号。
  ///
  /// UI 拿它做列表 key（`callId` 只在一轮内唯一，见 `ToolCallEvent.seq`），
  /// 所以必须从同一个计数器出，不能各域自己维护。
  int nextSeq();

  /// 把事件追加到面板的事件流。
  ///
  /// 语义就是 `_events.add` —— **不触发裁剪**。裁剪由 loop 在轮次边界统一做，
  /// 在这里顺手 trim 会让 executor 手上刚拿到的事件引用可能已经被移出列表。
  void addEvent(AgentEvent e);

  /// 事件流的只读视图。
  ///
  /// 给 `check_job` 那种「回头找之前那张卡」的回溯用。`AgentLoop` 侧返回的
  /// 是 `List.unmodifiable` 副本 —— executor 拿不到可变引用，改事件流只能走
  /// [addEvent]。
  List<AgentEvent> get events;

  /// 通知 UI 重绘。dispose 之后静默丢弃（原 `_safeNotify`）。
  void notifyChanged();

  /// 切换 loop 状态并刷新阶段起点（原 `_setState`）。
  void enterState(AgentLoopState s);

  /// 给工具卡打终态：状态 + 耗时。
  void finishToolCall(ToolCallEvent ev, ToolCallStatus status);

  // ───────── 审批 ─────────

  /// 挂起等用户在审批卡上应答。
  ///
  /// 会话已取消或已 dispose 时立即返回 reject，不会永久挂着 —— 那道防线在
  /// 实现里只有一处，别在调用点各自重复判断。
  Future<ApprovalOutcome> awaitApproval(ToolCallEvent ev);

  /// [awaitApproval] 的计时版本：把等人类反应的时长累加进 `tm.waitApprovalMs`。
  ///
  /// **累加（`+=`）而不是覆盖（`=`）。** 一次工具调用可能弹两张卡（`edit_file`
  /// 的读阶段与写阶段就是），覆盖会让前一张卡的等待时长凭空消失。
  ///
  /// 这个惯用法此前在 11 处逐字重复（transfer / file / skill / job 四个
  /// executor），其中每处都自带一个 `try { ... } catch (_) {}` —— 计时段
  /// 出错绝不能反过来把工具调用弄挂。收在这里之后，「只量等审批那一段」
  /// 这条语义只有一份实现，改计时口径不会再漏掉几个点。

  /// 这两条合并成一个方法，而不是让调用点自己量，理由与上面的累加说明同：
  /// 11 处逐字重复的 Stopwatch 样板是同一个语义被抄了 11 遍。
  Future<ApprovalOutcome> timedAwaitApproval(
      ToolCallEvent ev, ToolMetrics? tm);

  /// 用户点了拒绝之后的标准回填（原 `_rejectedResult`）。
  ToolResult rejectedResult(ToolCallEvent ev, ApprovalOutcome outcome);

  /// 传输类调用被点了「加入方案」时的回落。
  ///
  /// 传输不能进批量方案：上传的 picker 是交互式的，两个方向都占带宽，都需要
  /// 用户在场。
  ToolResult transferNotQueueable(ToolCallEvent ev);

  /// 用户在审批卡上点了「加入方案」之后的落点。
  ///
  /// 绝大多数时候是入队。唯一的例外是凭据边界命中 —— 那种调用不进队列，按
  /// 拒绝处理。这个分叉判断只有实现里一份，别在 executor 侧重写。
  ToolResult deferOrRejectFromApproval(
      ToolCallEvent ev, ToolCall call, CheckResult check);

  /// 审批闸门：需要审批就弹卡并等应答，不需要就放行。
  ///
  /// 返回非 null 表示**这次调用已经有结论了**（被拒、被推迟），executor 应当
  /// 直接把它当成自己的返回值；返回 null 才继续往下执行。
  ///
  /// **返回类型必须是 `FutureOr`，实现与转发都不能写成 `async`。** 不需要审批
  /// 时这条路径同步返回 null，而把它包成 `async` 会强制让出一次 microtask ——
  /// 那一跳足以让并发配额的测试稳定挂死（`agent_loop.dart` 里 `_executeOneInner`
  /// 调用处还留着一段更详细的说明）。
  FutureOr<ToolResult?> gateOnApproval(
      ToolCall call, ToolCallEvent ev, String checkTarget, CheckResult check,
      {bool preApproved, ToolMetrics? tm});

  /// 把一次**写文件**调用推迟进方案，并给模型一个立刻可用的 tool_result。
  ///
  /// 不收 message 参数：写文件那条回填的措辞（「文件还没改，别跑依赖这次改动
  /// 的命令」）与 bash 那条是刻意分开的两份文案，而 executor 没有理由知道
  /// 文案内容 —— 让它传字符串就等于把这个区分泄漏成调用方的责任。
  ToolResult deferWrite(ToolCallEvent ev, ToolCall call);

  // ───────── 生命周期 ─────────

  /// 用户按过停止。长任务应在检查点主动退出。
  bool get cancelRequested;

  /// loop 已 dispose。
  bool get disposed;

  // ───────── 计数与诊断 ─────────

  /// 记一次参数错误。连续多次会让 loop 熔断 —— 模型在原地打转时不能无限烧
  /// token（原 `_consecutiveInvalidArgs++`）。
  void noteInvalidArgs();

  /// 参数正确，清零上面那个计数器。
  void resetInvalidArgs();

  /// 记下异常栈，供开发者模式的诊断面板定位（原 `_errorStack = st`）。
  void noteToolError(StackTrace st);

  // ───────── 传输取消令牌 ─────────

  /// 登记一个可取消的传输，让卡片上的「取消」按钮找得到它。
  void registerTransfer(int transferSeq, TransferCancelToken token);

  /// 传输结束（成功、失败、取消都算）后摘掉令牌。
  void unregisterTransfer(int transferSeq);

  // ───────── 取消唤醒 ─────────

  /// 登记一个「等用户按停止」的唤醒点，用于 `check_job` 那种能阻塞几十秒的
  /// 等待。
  ///
  /// **必须在发起阻塞调用之前登记。** 同步回调（以及现实里几乎同时发生的
  /// 用户点击取消）可能在阻塞的 Future 完成之前就跑到 `cancel()`；晚一步
  /// 登记，那次唤醒就找不到人接，等待会挂满整个超时。
  void registerCancelWaiter(Completer<void> waiter);

  /// 等待结束后摘掉唤醒点。
  void unregisterCancelWaiter();

  // ───────── 已装载的技能 ─────────

  /// 这个技能的全文是否已经发给模型过。
  ///
  /// 重复 load 只回一句「已经装过了」而不重发全文 —— 一份技能正文动辄上千
  /// token，模型忘了自己load过就会反复要。
  bool isSkillLoaded(String key);

  /// 记下「这份技能的全文已经进过历史」。
  void markSkillLoaded(String key);

  /// 这个名字在本会话被 `search_skills` 返回过吗？（key 为小写）
  ///
  /// 与 [isSkillLoaded] 的区别：那个记「正文已发给模型」，这个记「确认过它
  /// 存在」。前者在压缩时要清（正文被摘要抹掉了），后者不清——见
  /// `agent_loop.dart` 的 `_searchedSkills` 字段注释。
  bool isSkillSearched(String key);

  /// 记下「这个名字本会话搜到过」。
  void markSkillSearched(String key);

  /// 挂起等用户点一个选项，返回他选中的 label。
  ///
  /// 返回 null = 会话已取消/关闭，调用方回一条 isError。实现必须与
  /// `_awaitApproval` 走同一个取消闸门——理由见那边的注释：cancel()/dispose()
  /// 只叫醒它们被调用那一刻已注册的等待者，之后注册的没人会完成它，loop 会
  /// 永久挂起并把整段历史一起泄漏。
  Future<String?> awaitAnswer(ToolCallEvent ev, List<AskOption> options);

  /// 本轮是否已经问过一次。
  bool get hasAskedThisTurn;

  /// 记下「本轮问过了」。
  void markAskedThisTurn();

  /// 本会话搜到过的全部名字（小写），传给 [skillBodyProvider] 做放行。
  Set<String> get searchedSkillNames;

  /// 本会话已解锁的工具组。
  Set<String> get unlockedToolGroups;

  /// 解锁一组。已解锁时是 no-op（幂等）。
  void unlockToolGroup(String group);

  // ───────── 环境 ─────────
  //
  // 以下是 `AgentLoop` 构造时注入的回调，同名 `final` 字段自动满足。
  // 按域逐步追加：transfer 6 个、skill 4 个。

  /// 开一个 SFTP 通道。null = 这个会话不支持传输（本地 shell）。
  Future<SftpOps> Function(String? serverId)? get sftpOpsProvider;

  /// 下载落盘目录。
  Future<Directory> Function()? get downloadDirProvider;

  /// 跨服务器中转的临时目录。
  Future<Directory> Function()? get relayTempDirProvider;

  /// 弹系统文件选择器。null = 不支持上传。
  Future<String?> Function()? get pickLocalFile;

  /// 下载完是否再发布到系统媒体库（Android MediaStore）。
  bool Function()? get publishToPublicStore;

  /// 当前可用的服务器清单，用于把 `to_server` 之类的名字解析成 id。
  Future<List<ServerListEntry>> Function()? get serverListProvider;

  /// 当前信任档（plan / ask / bypass）。
  PermissionMode Function() get modeProvider;

  /// 按名字取一份技能的正文。null = 这个会话没有技能库。
  ///
  /// [alsoAllow] 是本会话通过 `search_skills` 确认存在过的名字（小写）。
  /// 实现方（`AgentSkillManager.bodyOf`）默认只放行进了索引的条目，这个参数
  /// 是第二个放行来源——凭更早对话的记忆猜名字照旧被拦。
  Future<String?> Function(String name, {Set<String> alsoAllow})?
      get skillBodyProvider;

  /// 技能库里有哪些名字，用于「没找到」时提示最接近的。
  List<String> Function()? get skillNamesProvider;

  /// 内置技能的名字，`save_skill` 据此拒绝撞名。
  List<String> Function()? get builtinSkillNamesProvider;

  /// 按关键词检索技能。null = 这个会话没有技能库或没有长尾。
  ///
  /// 同步返回：实现方读的是 `AgentSkillManager` 那份全量内存列表。
  List<SkillSearchHit> Function(String query, {int limit})?
      get skillSearchProvider;

  /// 落盘一份新技能。null = 这个会话不允许保存。
  ///
  /// [assets] 是这条技能的附件（脚本 / 模板 / 参考文档）。可空 —— 不传的
  /// 调用点产出的是无附件技能（如远端 `.md` 导入），与改造前行为一致。
  Future<void> Function(String name, String description, String body,
      List<AgentSkillAsset>? assets)?
      get skillSaver;

  /// 按名字读一份技能的附件清单（含正文）。
  ///
  /// 白名单（[alsoAllow]）语义与 `skillBodyProvider` 完全一致，两条路径共享
  /// 同一套「模型只能用它真看见过的技能」。null = 这个会话没有技能库。
  Future<List<AgentSkillAsset>> Function(String name,
      {Set<String> alsoAllow})? get skillAssetProvider;

  /// 追加一段机器笔记。null = 这个会话不允许写。
  ///
  /// [serverId] 为 null 表示「当前会话那台」；全局会话里必须由调用方给出
  /// 具体的 id，拿不到就该让工具报错而不是猜 —— 猜错会把一台机器的事实
  /// 写进另一台的笔记，而且没人会发现。
  ///
  /// 返回 [ServerNoteSaveResult] 而不是抛：超限是可预期的正常路径，要把
  /// 「超了多少字节」原样告诉模型，它才知道该精简多少。
  Future<ServerNoteSaveResult> Function(
          String? serverId, String heading, String body)?
      get serverNoteSaver;

  /// 当前的放行规则集。
  PermissionRuleSet Function() get rulesProvider;

  /// 取一个能在指定服务器上跑命令的 runner。null = 当前会话那台。
  CommandRunner Function(String? serverId) get runnerProvider;

  /// 当前工作目录，用于把相对路径讲清楚。
  String? Function()? get cwdProvider;

  /// 抓网页的实现。null = 这个会话没配 web_fetch。
  WebFetcher? get webFetcher;

  // ───────── app 自身控制 ─────────

  /// app 控制门面。**可选** —— null 时 app 工具整体不声明
  /// （`agentToolSpecsFor(hasAppControl: false)`），其余功能照常。
  ///
  /// 做成可选与 [archive] 同理：那十几个只关心远端行为的 executor 测试
  /// 不该被迫构造一整套 provider。
  AppControlService? get appControl;

  /// 当前用户放行规则集（`freezeCommand` 要用）。
  ///
  /// 可选：null 时当作空规则集（即「没有任何预放行」）—— 这只会让冻结更
  /// 严格，不会更宽松，是安全的降级方向。
  PermissionRuleSet Function()? get permissionRulesProvider;

  /// 把工具参数的 `server` 名字解析成 serverId。
  ///
  /// 返回 null = 名字不认 / 没有目标机器。**复用 loop 的解析**而不是在
  /// executor 里重写一遍：那一层要处理「省略 server 时用当前会话那台」
  /// （见 `resolveServerTarget`），本机会话下这个逻辑不平凡。
  Future<String?> Function(String? name)? get serverIdResolver;
}
