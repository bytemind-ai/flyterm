// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../../util/dlog.dart';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:math';

import 'package:flutter/foundation.dart';

// 不 import '../ai_message.dart' —— ai_provider.dart 已经 export 了它，
// 再引一次是 unnecessary_import。
import '../ai_provider.dart';
import '../attachment.dart';
import '../attachment_materialize.dart';
import '../attachment_store.dart';
import '../providers/provider_http.dart';
import '../../data/models/favorite_command.dart';
import '../../sftp/sftp_service.dart' show SftpOps;
import '../../sftp/sftp_transfer_task.dart';
import 'agent_events.dart';
import 'agent_prompt.dart' show AgentPromptInputs;
import 'agent_tool_context.dart';
import 'ask_option.dart';
import 'output_sanitizer.dart';
import 'server_notes_manager.dart' show ServerNoteSaveResult;
import 'skill.dart';
import 'skill_search.dart';
import '../../app_control/app_control_service.dart';
import 'app_permission.dart';
import 'tool_executors/app_executors.dart';
import 'tool_executors/arg_parsing.dart';
import 'tool_executors/ask_executors.dart';
import 'tool_executors/file_executors.dart';
import 'tool_executors/job_executors.dart';
import 'tool_executors/more_tools_executors.dart';
import 'tool_executors/sftp_executors.dart';
import 'tool_executors/skill_executors.dart';
import 'tool_executors/web_executors.dart';
import 'tool_executors/transfer_executors.dart';
import 'agent_tools.dart' show kSearchResultLimit;
import 'tool_groups.dart';
import 'background_job.dart';
import 'command_runner.dart';
import 'compaction.dart';
import 'concurrency.dart';
import 'error_location.dart';
import 'file_edit.dart';
import 'knowledge.dart';
import 'session_facts.dart';
import 'knowledge_gate.dart';
import 'permission_rules.dart';
import 'saved_command_guard.dart';
import 'server_targets.dart';
import 'shell_guard.dart';
import 'tool_models.dart';
import 'token_estimate.dart';
import 'tool_partition.dart';
import 'tool_registry.dart';
import 'turn_metrics.dart';
import 'usage_totals.dart';
import 'web_fetch.dart';

// 事件模型（`AgentEvent` 那一族 + 两个 JSON 编解码函数）已拆到
// `agent_events.dart`。这里重新导出：拆分是内部整理，不该外溢成一次
// 94 个文件的 import 改动。新代码直接 import `agent_events.dart` 更好。
export 'agent_events.dart';

/// 一次工具调用被解析后的形态。
class _Resolved {
  final String execCommand;
  final String checkTarget;
  final String displayCommand;
  final String description;
  final String? error;

  /// 执行成功后要前置到回填里的提示。null = 没有。
  ///
  /// 目前只有一个来源：`run_saved_command` 收到了模板里没有的参数键。那不是
  /// 错误（多余的键碰不到命令），但静默忽略会让模型以为它生效了。
  final String? warning;

  /// 目标服务器 id。null = 当前会话那台。
  final String? targetServerId;

  /// 目标服务器名，仅用于展示与归档。
  final String? targetServerName;

  /// 这条命令的输出要不要去噪。
  ///
  /// **默认 false。** `read_file` 通过 `sed` 走同一条执行路径，折叠会让行号
  /// 错位，更糟的是模型会从折叠后的输出里抄 `edit_file` 的 `old_string`，
  /// 抄到文件里根本不存在的 `[last message repeated N times]` —— 编辑失败时
  /// 它只看到「old_string not found」，不会想到是输出被改过形状。
  final bool denoise;

  /// 这条命令的输出撞上 8 KiB 时丢哪一段。
  ///
  /// **默认 head。** 只有 `bash` 标 middle：它是运维场景的万能工具，
  /// `journalctl` 的错误在尾、`systemctl status` 的 `Active:` 在头，两端都
  /// 可能是关键。`read_file` 走同一条执行路径（`sed`），但它是按 offset
  /// 连续读的，挖空中间会让内容不连续、模型也无从据此续读 —— 与 [denoise]
  /// 默认 false 是同一个理由：漏传的后果应该是「少省一点」，不是「内容被
  /// 悄悄改了形状」。
  final TruncateMode truncate;

  const _Resolved({
    this.execCommand = '',
    this.checkTarget = '',
    this.displayCommand = '',
    this.description = '',
    this.error,
    this.warning,
    this.targetServerId,
    this.targetServerName,
    this.denoise = false,
    this.truncate = TruncateMode.head,
  });
}


/// 一次抢跑：调用、它的 Future、以及起飞那一刻的判据快照。
///
/// 快照记的是 `rules` / `mode` / `cwd` 三个**值**，落地时按值比较。
///
/// **这里原先比较的是 `rules` 的对象身份（`identical`），那是个真实的
/// bug。** 生产接线 `rulesProvider` = `() => mgr.rules`，而
/// `AgentSessionManager.rules` 在用户动过任何一条权限规则之后就走
/// `PermissionRuleSet.fromJson(...)` 分支，每次读都 new 一个对象 —— 判据
/// 于是**永远**判为「变了」，每一条抢跑过的命令都被丢弃重跑，在远端实际
/// 执行两次。用户的 crontab 里因此出现过两条一模一样的定时任务。
///
/// 修法是给 `PermissionRuleSet` 加值相等（见那个类的 `==` dartdoc），不是
/// 在这里放宽比较 —— 身份比较的另一半毛病是反过来的：同一个对象被原地改了
/// 正文时它会判成「没变」。值比较两头都治。
class _Speculation {
  final ToolCall call;
  final Future<ToolResult> future;
  final PermissionRuleSet rules;
  final PermissionMode mode;
  final String? cwd;
  final ToolMetrics metrics;
  bool consumed = false;

  _Speculation({
    required this.call,
    required this.future,
    required this.rules,
    required this.mode,
    required this.cwd,
    required this.metrics,
  });
}

/// `tokenBudget` 的默认值。见该字段的 dartdoc —— 这个数是量出来的。
///
/// 量法：`test/ai/agent/budget_recalibration_test.dart` 的第一条测试打印
/// `RECALIBRATION ... new=<N>`，取那个 N 向上取整到百位。
const int kDefaultTokenBudget = 210900;

/// 客户端 tool-use 循环。
///
/// **不认识网络，不认识 UI** —— provider 与 runner 都是注入的接口，因此可以
/// 用 fake 完整测出多轮、审批、中断、上限等全部路径。
class AgentLoop extends ChangeNotifier implements AgentToolContext {
  /// 现取，不在构造时定死 —— 换了 provider（换 key、换模型）之后，已存在
  /// 的 loop 也要用新的，风格与 rulesProvider/modeProvider 一致。
  final AIProvider Function() providerProvider;

  /// 现取 —— QUIC 路径的 exec channel 归 [AgentSessionManager] 持有，与
  /// loop 同生命周期；这里不能定死某一个 channel 实例，否则 channel 被
  /// 换掉（重建）之后 runner 还指着孤儿对象。
  ///
  /// [serverId] 为 null 表示**当前会话那台**（现有的、唯一的行为）；非 null
  /// 时表示打另一台已保存的服务器。连接由调用方按 serverId 复用或新建 ——
  /// 这个类不认识连接，只认识「给我一个能跑命令的东西」。
  @override
  final CommandRunner Function(String? serverId) runnerProvider;

  /// 提前把某台机器的执行连接建好。null = 不做预热。
  ///
  /// **只建连接，不发任何命令**，所以它没有安全语义，不需要经过权限判定。
  /// 存在的理由是一段确定空闲的时间窗：需审批的调用要等用户在手机上点批准
  /// （人类反应时间，几秒到几分钟），而连接直到批准之后才开始建。
  ///
  /// 做成 `AgentLoop` 上的一个可空回调、而不是给 `CommandRunner` 加方法：
  /// 那个抽象有 8 个 `implements` 实现（1 个生产 + 7 个测试 fake），
  /// `implements` 要求实现全部成员，加一个方法就要改 7 个测试文件。
  final Future<void> Function(String? serverId)? prewarmProvider;

  /// 当前可见的服务器清单。null = 这个 loop 不支持多机（老测试 / 未来其他
  /// 调用点）——此时 `server` 参数会被拒绝，`list_servers` 返回空。
  ///
  /// 做成「一次给全」而不是让 loop 自己查仓库 + 逐台判凭据：凭据可用性要问
  /// `AgentExecChannel`，那是 UI 层才拿得到的东西。让这个类去碰它等于把连接
  /// 知识漏进执行核心。
  @override
  final Future<List<ServerListEntry>> Function()? serverListProvider;

  /// 手机端取数的实现。null = 手机端路径不可用（只能走远端）。
  ///
  /// 与 `runnerProvider` 同一注入风格：`dio` 因此完全不进这个文件，
  /// loop 层的测试用 fake 就能跑完路由与回退的全部路径。
  @override
  final WebFetcher? webFetcher;

  /// app 控制门面。null = 这个会话不支持 app 工具。
  ///
  /// **默认 null、默认档 off** 是刻意的：漏传的后果应该是「app 工具不可用」，
  /// 而不是「app 工具带着一个没人配过的权限档可用」。
  @override
  final AppControlService? appControl;

  /// 复用的放行规则集（与 [rulesProvider] 同源）。
  ///
  /// 不另加一个 `permissionRulesProvider` 字段：两个字段指向同一个东西，
  /// 就多一个「只改了一个」的可能 —— 而冻结用的规则集与交互式判定用的
  /// 必须一致，否则同一条命令在两边会得到不同结论。
  @override
  PermissionRuleSet Function()? get permissionRulesProvider => rulesProvider;

  /// 把 `server` 名字解析成 serverId（复用 loop 自己的解析）。
  @override
  final Future<String?> Function(String? name)? serverIdResolver;

  @override
  final PermissionRuleSet Function() rulesProvider;
  @override
  final PermissionMode Function() modeProvider;

  /// 现取 —— 用户在设置里改了档不该要求重建 loop，与
  /// providerProvider / rulesProvider / cwdProvider 的风格一致。
  ///
  /// **必填**，不给默认值：上一轮栽过一次「整条链路实现完整却忘了接上」
  /// （`restoreFrom` 当过死代码）。必填能让编译器把每一个构造点都点出来，
  /// 而默认值只会让漏接静默降级成 lean 档。
  final List<ToolSpec> Function() toolSpecsProvider;
  final void Function(PermissionRule) onRuleAdded;

  /// **现取**，每轮开头调一次。
  ///
  /// ## 为什么不是构造时的一个 String
  ///
  /// 曾经是。那时用户在设置里改完自定义说明，回到面板发现 agent 完全不知道
  /// ——`_agentLoopFor` 对已存在的 loop 直接 `return existing`，而 loop 由
  /// `AgentSessionManager` 长期持有，关掉面板它还活着。于是唯一能让新说明
  /// 生效的办法是点「清空对话」，而那会把整段排查历史一起丢掉。
  ///
  /// ## 这不牺牲 prompt cache
  ///
  /// 当初做成快照的理由是「Anthropic 的第一个 cache 断点打在 system 字段上，
  /// 每轮变动会让缓存前缀每轮失效」。那个推理把两件事绑错了：**缓存失效的
  /// 条件是内容变了，不是每轮重新计算**。
  ///
  /// 所以 [_refreshSystemPrompt] 每轮现取、但只在**内容真的不同**时才替换
  /// `_history[0]`。自定义说明只在用户改动的那一刻变，那一次缓存失效正是他
  /// 想要的；其余每一轮内容不变，缓存照常命中。
  ///
  /// 注意 `cwd` 与终端快照仍然是构造时快照（由调用方拼进这个 provider 返回
  /// 的字符串里，见 `terminal_screen.dart` 的 `_agentLoopFor`）——它们真的
  /// 每轮都在变，做成现取会让缓存每轮失效，那才是当初那个理由适用的地方。
  final String Function(AgentPromptInputs inputs) systemPromptProvider;

  /// 现取 —— 用户 `cd` 到别处之后，agent 的 `cd <cwd> && ...` 不该还用
  /// 打开面板那一刻的旧目录。
  @override
  final String? Function()? cwdProvider;

  /// agent 自己那条 SFTP 通道。null = 这个 loop 不支持传输（老测试 /
  /// 未来别的调用点）—— 此时两个传输工具即便被声明了也会回一条错误。
  ///
  /// 现取而非定死：底层 SSH 连接会断会重建，`AgentExecChannel.obtain()`
  /// 每次都给当前那条。
  ///
  /// 取一台服务器的 SFTP 通道。
  ///
  /// [serverId] 为 null 表示**当前会话那台**（`download_file` / `upload_file`
  /// 走这条）；非 null 时表示另一台已保存的服务器（跨服务器拷贝的两端）。
  ///
  /// 与 `runnerProvider` 同构：这个类不认识连接，只认识「给我一个能读写远端
  /// 文件的东西」。
  @override
  final Future<SftpOps> Function(String? serverId)? sftpOpsProvider;

  /// 用户**此刻**屏幕上的内容（已去掉 ANSI），`read_terminal` 的数据源。
  ///
  /// 必须是 provider 而不是构造时的值：system prompt 里那份终端快照就是构造时
  /// 取的一次性值（它是 prompt cache 的断点，不能每轮变），而这条 loop 按
  /// serverId 复用、寿命跨多次面板开关 —— 那份快照可能已经是几十条命令之前的。
  /// 这个 provider 是模型拿到当前屏幕的唯一途径。
  ///
  /// 返回 null = 这台机器现在没有可读的终端（tab 已关）。可空是因为测试与
  /// 直连场景不需要它；生产环境总会注入。
  final String? Function()? terminalTextProvider;

  /// 中转用的临时目录。
  ///
  /// **不复用 `downloadDirProvider`**：那是用户可见的 Download 目录，中转是实现
  /// 细节，在那里留下中间产物会让用户以为「我什么时候下过这个文件」。
  ///
  /// 做成注入而不是直接调 `getTemporaryDirectory()`：那是 `path_provider` 的平台
  /// 调用，在这个类里碰它会让全部中转测试都要跑真机。
  @override
  final Future<Directory> Function()? relayTempDirProvider;

  /// 下载落点。
  @override
  final Future<Directory> Function()? downloadDirProvider;

  /// 是否把下载的文件发布进系统 Downloads 集合。
  @override
  final bool Function()? publishToPublicStore;

  /// 打开系统文件选择器，返回用户选中的本地绝对路径。null / 空 = 取消。
  ///
  /// 做成注入的回调而不是在这里直接调 `FilePicker.platform`：这个类是重
  /// 单测的，直接碰插件会让传输测试要跑真机。
  @override
  final Future<String?> Function()? pickLocalFile;

  /// 按 name 读技能正文。null = 这个 loop 不支持技能。
  ///
  /// 返回 null 表示「拿不到」，含义包括不存在、被禁用、被挤出索引上限 ——
  /// 对模型是同一件事，不需要分。
  @override
  final Future<String?> Function(String name, {Set<String> alsoAllow})?
      skillBodyProvider;

  /// 索引里的技能名。用于大小写不敏感匹配，以及未命中时的错误提示。
  @override
  final List<String> Function()? skillNamesProvider;

  /// 内置技能的名字。`save_skill` 用它拒绝撞名 —— 被内置遮住的用户技能存
  /// 进去也永远读不到，会变成一条列在设置页里却不生效的僵尸。
  @override
  final List<String> Function()? builtinSkillNamesProvider;

  /// 按关键词检索技能。null = 这个会话没有技能库或没有长尾。
  @override
  final List<SkillSearchHit> Function(String query, {int limit})?
      skillSearchProvider;

  /// `save_skill` 的落库回调。
  @override
  final Future<void> Function(String name, String description, String body,
      List<AgentSkillAsset>? assets)? skillSaver;

  /// 按 name 读技能附件。null = 这个会话没有技能库。
  @override
  final Future<List<AgentSkillAsset>> Function(String name,
      {Set<String> alsoAllow})? skillAssetProvider;

  /// `save_note` 的落库回调。null = 这个 loop 不支持机器笔记。
  @override
  final Future<ServerNoteSaveResult> Function(
          String? serverId, String heading, String body)?
      serverNoteSaver;

  /// 收尾时把这一段会话提炼成候选知识。null = 这个 loop 不做自动沉淀。
  ///
  /// 做成注入回调而不是在这里直接持有 `KnowledgeDistiller`：与 `skillSaver`
  /// 同理由，loop 是重单测的，直接碰 provider 会让每个流程测试都要装配一个
  /// 能回 JSON 的假模型。
  ///
  /// **用户的功能开关也在这个闭包里判**（装配处），关掉时它直接返回空列表，
  /// 提炼调用根本不发起。
  final Future<List<KnowledgeCandidate>> Function(List<AgentEvent> events)?
      knowledgeDistiller;

  /// 按名字取一条**可调用**的收藏命令。**同步** —— `_resolve` 不能 await，
  /// 这也是 `AiCommandManager` 把整个对象放内存的原因。
  final FavoriteCommand? Function(String name)? savedCommandProvider;

  /// 索引里的收藏命令名，用于未命中时告诉模型有哪些可用。
  final List<String> Function()? savedCommandNamesProvider;

  /// 附件落地仓库，供发送前把图片物化成 base64（见 [materializeAttachments]）。
  ///
  /// null = 这个 loop 不支持附件（老测试 / 未来其他调用点）—— 此时即便
  /// `_history` 里挂了 attachments 也原样发给 provider，不做任何物化。
  final AttachmentStore? attachmentStore;

  /// 这一段会话里已经发过正文的技能名（小写）。
  ///
  /// 重复 load 只回一行提示，是省 token 的主要手段。但它必须和历史保持
  /// 同步：compaction 整段替换历史时全清、drop 掉某条正文时精确移除，
  /// 否则模型会被告知「正文在上文」而上文里已经没有了 —— 它拿不到，又
  /// 不该重试，直接走进死路。那部分由下一个任务实现。
  final Set<String> _loadedSkills = {};

  /// 本会话被 `search_skills` 返回过的技能名（小写）。
  ///
  /// **压缩时刻意不清，与 `_loadedSkills` 相反。** 两者语义不同：
  /// `_loadedSkills` 记的是「正文已在上文」，摘要把正文抹掉了所以必须清、
  /// 让模型重新 load；这个是「本会话确认过这些名字真实存在」的放行凭证，
  /// 摘要不改变这个事实，清掉只会让模型白搜一遍拿到完全相同的结果。
  ///
  /// `_restore()` 会部分重建它：认历史里出现过的技能名（正文或正文被
  /// `_dropOldestOutput` 换成的 marker），这两者都是「本会话确认过这个
  /// 名字真实存在」的权威证据。凭猜重建才会让拦截失去意义——这里不是猜，
  /// 是读回原本就发生过的事实。被摘要整段替换掉的那部分历史确实拿不到，
  /// 代价仅限于「摘要吞掉的那段搜索」需要重搜一次。
  final Set<String> _searchedSkills = {};

  /// 本会话已解锁的工具组。**不回收** —— 回收等于让用户在同一场对话里付
  /// 两次 prompt cache 重建（断点 2/3 打在工具定义末项，清单一变就失效）。
  ///
  /// 会话恢复时由 `_restore` 从历史里重建，不进归档格式。
  final Set<String> _unlockedToolGroups = {};

  /// 进程内自增，保证同一次运行里两个 loop 的 key 必不相同。
  ///
  /// 不用 `Random()`：测试要断言「两个 loop 的 key 不同」，随机源有非零的
  /// 撞号概率，那会变成一个偶发失败的 flaky 测试。
  static int _sessionKeySeq = 0;

  /// 本会话的缓存亲和 key，发给 provider 当 `prompt_cache_key`。
  ///
  /// **per-loop 而非 per-provider**：provider 实例长存（只在切模型时重建）
  /// 且同时服务多个 tab 的面板。挂成 provider 的可变字段、每轮 set 的话，
  /// 两个并发面板会互相覆盖，结果是两条完全不同的历史共用一个 key ——
  /// 命中率比不发还差。
  ///
  /// **恢复存档时不沿用旧值、直接新生成**：恢复后第一轮本来就是冷的
  /// （服务端缓存早已过期），沿用换不来命中，却要给归档格式加一个字段。
  ///
  /// 形如 `flyterm-m3k2j1x9-0`，约 20 字符，远低于 OpenAI 的 64 上限。
  final String sessionKey =
      'flyterm-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${(_sessionKeySeq++).toRadixString(36)}';

  @override
  // `Set.unmodifiable` 而不是直接返回内部字段：它是可变 Set，调用方拿到
  // 后一句 `.add()` 就能改掉门控状态，而且绕过 `unlockToolGroup()`（那里
  // 还有缓存失效那一行），编译器一句话都不会说。同文件其余 getter 一向
  // 这么做（`events` / `plan` / `debugHistory`），这两个是漏网的。
  Set<String> get unlockedToolGroups => Set.unmodifiable(_unlockedToolGroups);

  @override
  void unlockToolGroup(String group) {
    _unlockedToolGroups.add(group);
    // 解锁改变了工具清单，缓存的 schema 大小作废。这是
    // `_unlockedToolGroups` 唯一的修改点，所以这一行就够。
    _toolSchemaTokensCache = null;
  }

  final int maxTurns;

  /// 上下文预算，单位是**真实 token**。
  ///
  /// 2026-09-14 之前这个数的单位是「`chars / 3.5` 折算出来的量」，与除数
  /// 3.5 配套标定 —— 它不表示 token，谁也无法据它判断「离上下文上限还有
  /// 多远」。估算器改成内容感知之后，这个默认值按**保持行为不变**重标：
  /// 在一段命令输出占大头的代表性历史上，量出「旧估算器首次越过 120000 的
  /// 那一刻，新估算器返回多少」，取那个数。方法与可复现的测试见
  /// `test/ai/agent/budget_recalibration_test.dart`。
  ///
  /// **这个数字是量出来的，不是挑的。** 挑一个好看的圆整数就是在改策略，
  /// 而改策略需要知道 provider 的上下文窗口 —— 各家差几十倍（Anthropic 1M、
  /// 兼容端点 32k–1M、Ollama 本地模型常见 8k–128k），那是另一件事。
  final int tokenBudget;

  /// `run_background` 回填文本的前缀。
  ///
  /// **`_dropOldestOutput` 必须跳过以它开头的工具结果。** job id 只存在于
  /// 这段回填里——它进不了 `ToolCall.args`（id 是调用被受理**之后**才由客户端
  /// 生成的），而 drop 从不碰 `toolCalls`。所以 `write_file` 的 path 能在 drop
  /// 之后存活，job id 不能。
  ///
  /// 丢它省不了钱（就一行），而丢掉的代价是模型再也找不到那个还在跑的任务：
  /// 要么放弃收尾，要么幻觉一个 id（`isValidJobId` 只校验形状）。

  /// 技能正文回填的前缀，`[skill: <name>]\n` 的前半截。
  ///
  /// 存在的唯一理由是让 `_dropOldestOutput` 能从被丢弃的那条结果里认出这是
  /// 哪个技能，从而精确地把它从 `_loadedSkills` 里摘掉。

  /// 丢弃 marker 的**前缀**。判断「这条是否已被丢过」只能用前缀匹配 ——
  /// marker 带上行数之后就不再是一个常量，等值比较会让同一条消息被反复
  /// 丢弃，`_dropOldestOutput` 永远返回 true，调用方的 while 永远退不出去。
  static const String _kDroppedPrefix = '[output dropped';


  /// 丢弃 marker 的正文。
  ///
  /// 旧版是一句零信息量的 `[output dropped — re-run if needed]`：模型只知道
  /// 「这里曾有输出」，不知道那条命令成功没有、输出多少，于是很可能盲目重跑
  /// —— 那就是「原地打转」，只是换了个触发方式。
  ///
  /// 行数与退出码是执行时就有的，写进去零成本，模型据此能判断「查过了、
  /// 成功了、47 行现在不需要」或「那条失败了，也许该再看看」。
  ///
  /// 行数数的是 `formatForModel` 拼装后的**完整回填文本**（含
  /// `--- exit code: N ---` 尾行、可能的 `--- stderr ---` 分隔行、
  /// `(no output)` 占位行、脱敏提示行），所以比命令真实输出行数固定偏高
  /// 至少 1 行（尾行恒在）。这个偏差是系统性、可预测的，不影响模型判断
  /// 「大致多长」，但不能拿这个数字做精确统计。
  ///
  /// `code == -1` 与 `timedOut == true` 都对应「没有真实退出码」，但原因
  /// 不同（前者是拿不到、后者是命令被杀死），拆成两种文案：`-1` 本身不是
  /// 任何真实进程能返回的值（POSIX 是 0–255），原样写成 `exit -1` 模型没有
  /// 先验去理解，容易被当成解析错误；超时又是排查场景里的高频失败模式，
  /// 值得单独标出来而不是淹没在一个负数里。
  /// 从一条 tool result 的内容里取出技能名；不是技能正文就返回 null。
  ///
  /// 正文的形状是 `[skill: nginx]\n<正文>`（见 [kSkillBodyPrefix]）。记账摘除
  /// 与丢弃 marker 的文案都要认这个形状，抽出来共用，免得两处各写一遍偏移量、
  /// 改一处漏一处。
  static String? _skillNameOf(String content) {
    if (!content.startsWith(kSkillBodyPrefix)) return null;
    final close = content.indexOf(']');
    if (close <= kSkillBodyPrefix.length) return null;
    return content.substring(kSkillBodyPrefix.length, close);
  }

  /// 从一条丢弃 marker 里取出技能名；不是「技能正文被丢弃」的 marker 就返回
  /// null。
  ///
  /// 形状由 [_droppedMarker] 生成：
  /// `[output dropped: N lines — was skill \`nginx\`, call load_skill again...]`
  ///
  /// 与 [_skillNameOf] 成对：那个认正文，这个认正文被丢弃后的残留。两者都是
  /// 「这个技能名真实存在过」的证据，区别只在正文还在不在。
  static String? _droppedSkillNameOf(String content) {
    if (!content.startsWith(_kDroppedPrefix)) return null;
    const marker = 'was skill `';
    final start = content.indexOf(marker);
    if (start < 0) return null;
    final from = start + marker.length;
    final close = content.indexOf('`', from);
    if (close <= from) return null;
    return content.substring(from, close);
  }

  /// 从一条 tool result 里认出「某个组被成功解锁」。
  ///
  /// 形状由 `MoreToolsExecutors.moreTools` 的成功分支生成：
  ///   `Activated \`transfer\`: upload_file, ...`
  ///   `Group \`transfer\` is already active (...)`
  ///
  /// 与 `_skillNameOf` 同一个约定：格式归产生它的那一方，这里只做反解析。
  /// 两种成功形状都要认 —— 只认第一种的话，一段「解锁→重复解锁」的历史在
  /// 恢复后会漏掉。失败文案（`No tool group named ...`）不匹配任何前缀，
  /// 天然被排除在外。
  static String? _unlockedGroupOf(String content) {
    for (final p in const ['Activated `', 'Group `']) {
      if (content.startsWith(p)) {
        final close = content.indexOf('`', p.length);
        if (close > p.length) return content.substring(p.length, close);
      }
    }
    return null;
  }

  static String _droppedMarker(ToolResult r) {
    final lines = r.content.isEmpty ? 0 : r.content.split('\n').length;
    // 技能正文单独一种文案。
    //
    // 通用的 `[output dropped: N lines]` 不带任何线索，而 system prompt 要求
    // 「每个技能一次会话只 load 一次」—— 模型看到它既不知道那曾是技能正文，
    // 也就不会重新取，只能凭残留印象往下做。真机表现就是「聊了一阵之后不再
    // 按技能执行」，而且只在对话长到触发丢弃时才出现，所以是「有时候」。
    //
    // 记账那边早就摘干净了（`_dropOldestOutput` 用 [_skillNameOf] 把它从
    // `_loadedSkills` 移除，重新 load 会真的重发全文），缺的只是告诉模型。
    //
    // 前缀必须仍是 `[output dropped` —— 判断「这条已经丢过」靠的是这个前缀
    // （见 [_kDroppedPrefix]），换掉会让同一条被反复丢弃，调用方的 while
    // 永远退不出去。
    final skill = _skillNameOf(r.content);
    if (skill != null) {
      return '[output dropped: $lines lines — was skill `$skill`, '
          'call load_skill again if you still need it]';
    }
    if (r.timedOut) {
      return '[output dropped: $lines lines, timed out]';
    }
    final code = r.exitCode;
    if (code == null) {
      return '[output dropped: $lines lines]';
    }
    if (code == -1) {
      return '[output dropped: $lines lines, no exit code]';
    }
    return '[output dropped: $lines lines, exit $code]';
  }

  /// 写文件被推迟时的回填。
  ///
  /// 两件事都必须说到，缺一件就出错：
  ///
  /// 1. **这不是失败** —— 否则模型重试同一个 edit_file，每次都进队列，
  ///    用户最后看到一份重复 5 遍的方案
  /// 2. **文件此刻还没变** —— 否则模型接着跑 `nginx -t` 去验证一个尚未
  ///    生效的修改，在旧配置上得到误导性的通过，据此给出错误结论
  ///
  /// 第 2 条比第 1 条隐蔽得多也危险得多：它不报错，只是安静地给出错的
  /// 答案。末半句是给模型的出路——验证命令也该进方案。
  static const String kDeferredWriteMessage =
      '[deferred: queued for user approval — the file is NOT modified yet. '
      'Do not run commands that depend on this change; put those in the '
      'plan too.]';

  /// bash 命令被推迟时的回填。措辞与写文件那条平行，但说的是「命令没跑」。
  static const String kDeferredCommandMessage =
      '[deferred: queued for user approval — this command has NOT run yet. '
      'Do not run commands that depend on its effect; put those in the '
      'plan too.]';

  /// 重复入队时的回填。`isError` 为 true 是刻意的——要让模型注意到「这条
  /// 别再来了」，一条 isError=false 的提示很容易被当成成功而继续重试。
  static const String kAlreadyQueuedMessage =
      '[already queued — see the pending plan. Do not repeat this call.]';

  /// 连续多少次非法参数就终止会话。
  ///
  /// **OpenAI 的 strict function calling 不能替代这个熔断。**
  /// （`openai_provider.dart` 的 `_strictDisabled` 一带那套。）
  ///
  /// strict 只保证参数**符合 schema** —— 字段齐全、类型正确。它保证不了
  /// 语义：模型照样可以传一个不存在的路径、一个格式合法但值错的 job_id、
  /// 一个已经被删掉的服务器名。这个计数器挡的正是 strict 覆盖不到的那一半。
  ///
  /// 而且它只在 OpenAI 系 provider 上生效：Anthropic 那条路径上没有 strict，
  /// 不支持 strict 的第三方端点也会被降级关掉。对那些配置来说，这个熔断是
  /// 唯一的防线。
  static const int _kMaxConsecutiveInvalidArgs = 3;

  /// UI 事件流的保留条数上限。超出的从最早的开始丢。
  static const int _kMaxEvents = 500;

  /// 并行桶的并发上限。
  ///
  /// 手机到远端每条命令一个 exec channel，20 条一起打出去会同时压上手机的
  /// 上行、SSH 连接的窗口和远端的负载。3 是「三条独立查询命令一起发」这个
  /// 主要收益场景的自然宽度（`ps` / `ss` / `journalctl`），再往上边际收益
  /// 迅速消失而风险线性增长。
  static const int _kMaxParallel = 3;

  /// 一轮里同时在飞的远端命令总数上限，**跨所有目标机**。
  ///
  /// `_kMaxParallel` 的三条理由里，「SSH 连接的窗口」与「远端的负载」是
  /// per-connection 的 —— 跨机时本就不该共享；只有「手机上行」是全局的，
  /// 这个常量就是它。没有它的话，模型一轮请求 20 台机器会同时发起 20 次
  /// TCP+KEX+auth。
  ///
  /// **8 是拍的，本项目还没有支撑它的数据。** 它只防极端；真正该定它的是
  /// 第一期那把秤导出的 `connMs`。这是已知限制。
  static const int _kMaxGlobalParallel = 8;

  final List<AIMessage> _history = [];
  final List<AgentEvent> _events = [];

  /// 正在流式到达、**尚未定稿**的助手文本。null = 此刻没有在流。
  ///
  /// ## 为什么不做成一条可变的 AssistantTextEvent
  ///
  /// `_events` 是 append-only 的不可变列表，`toArchive()` 直接序列化它。
  /// 一旦事件可变，归档、`_restore`、`_kMaxEvents` 裁剪都要开始考虑
  /// 「半截消息」这种状态 —— 三处各自都可能漏。
  ///
  /// 做成一个独立字段则完全避开：正在流的东西**本来就不该进归档**（app
  /// 被杀时它本来也就没了），UI 在事件列表尾部单独渲染它即可。
  String? _streamingText;

  String? get streamingText => _streamingText;

  /// 这一轮里已经抢跑出去、尚待 `StreamDone` 后核对判据的调用。
  ///
  /// 每轮开始时清空（`_run()` 里 `_speculations.clear()`）——上一轮的抢跑
  /// 不可能跨轮存活：`_executeRound` 会在轮末把它们要么消费掉、要么在
  /// `_discardSpeculations()` 里收尾，不存在「这一轮没处理、留给下一轮」的
  /// 情形。
  final List<_Speculation> _speculations = [];

  /// `resp.text` 里已经落成 `AssistantTextEvent` 的前缀长度。
  ///
  /// 抢跑会在 `StreamDone` **之前**把 `_streamingText` 提前落成事件（见
  /// `_flushStreamedTextSoFar`），如果 `StreamDone` 到达时仍然整段
  /// `resp.text` 原样再落一次，用户会看到重复的文字。这个计数器记的是
  /// 「到目前为止已经落过多少字符」，`StreamDone` 时只需要落**尾巴**。
  ///
  /// 每轮开始时清零，理由与 [_speculations] 一致。
  int _flushedTextLen = 0;

  /// 这一轮是否已经真的调用过 `_compact()`（不论成败）。
  ///
  /// `_maybeCompactConcurrently()` 与轮末兜底的 `_dropOldOutputsIfNeeded()`
  /// 都可能触发一次 `_compact()`，而两者是**互不知情**地各自判断「要不要
  /// 压」——都基于同一个 token 阈值，但阈值判断本身不构成互斥。没有这面
  /// 旗子，压缩失败（最常见的原因是 429 限流）会导致一轮里连发两次真实的
  /// 模型调用：并发那次失败，轮末兜底又压一次，又失败——对本来就在限流的
  /// 请求加倍，是本末倒置。
  ///
  /// 一轮最多一次真实的摘要调用，失败就等下一轮再说：压缩是优化不是命脉，
  /// 为它连发两次请求得不偿失。每轮开头随 [_speculations] / [_flushedTextLen]
  /// 一起清零。
  bool _compactedThisTurn = false;

  /// 这一轮是否已经调过一次 `ask_user`。
  ///
  /// 并行工具调用是本项目的核心特性，不拦的话模型可能同轮发三个 `ask_user`
  /// ——而 `tool_partition.dart` 的注释里已经记着「审批卡同时弹三张，用户
  /// 不知道先点哪个」。轮初清零的位置与 [_compactedThisTurn] 相同。
  bool _askedThisTurn = false;

  /// 按 [ToolCallEvent.seq] 索引，**不按 [ToolCallEvent.callId]**。
  ///
  /// `edit_file` 是「一次调用做两件事」的路径：先为读注册一次审批，读完
  /// 之后再为写注册一次，**两次共用同一个 `callId`**（同一条 tool_use
  /// 消息只有一个 id，模型侧的写法就是如此）。若按 callId 索引，会出现
  /// 这条序列：
  ///
  /// 1. 读审批注册在 `callId="c1"` 下，用户批准 → `remove("c1")`，完成
  /// 2. 读命令执行，`applyEdit` 算出 diff
  /// 3. 写审批**又**注册在 `"c1"` 下（同一个 map key，指向新的 completer）
  /// 4. 用户此刻的第二次点击（通知与面板各点一次、或单纯手滑）如果带的是
  ///    第 1 步那张卡的标识，仍然会命中 `"c1"` —— 因为 map 里现在存的是
  ///    写审批的 completer，这一下会把**写**当成批准，而用户看到的、点的
  ///    是**读**那张卡。
  ///
  /// `seq` 是 [ToolCallEvent] 自带的会话内单调递增计数器（它存在的理由
  /// 与此完全一致 —— UI 拿它做列表 key，也是因为 `callId` 不足以区分
  /// 同一轮甚至同一次调用里的多张卡）。用它做索引，一张卡对应一个不会
  /// 被复用的 key，两个阶段不可能串到一起。
  ///
  /// **不要把这个 map 改回按 callId 索引** —— 上面这条路径正是曾经的
  /// 真实隐患（见 `agent_session_manager_test.dart` 的
  /// 「写审批已注册后…」回归测试）。
  final Map<int, Completer<ApprovalOutcome>> _pending = {};

  /// `ask_user` 的挂起等待者，按 `ToolCallEvent.seq` 索引。
  ///
  /// **与 [_pending] 分开而不是合并**：那个是 `Completer<ApprovalOutcome>`，
  /// 这个是 `Completer<String>`。合成一个 map 要么用 `dynamic`（丢类型安全），
  /// 要么引入一个只为合并而存在的 sealed class，两者都不划算。
  final Map<int, Completer<String>> _pendingAnswers = {};

  /// bypass 档下被标记「本轮不再问」的命令原文。
  ///
  /// **不落盘、不进 `toArchive()`、不跨 `closeLoop`。** 这一条同时保证它不可能
  /// 演化成隐式的 allowlist —— `onRuleAdded` 那条落盘路径完全没被碰，
  /// 「凭据边界永不能进 allowlist」这个不变量保持成立。
  ///
  /// key 是**整条命令原文**，不是命中的正则、也不是文件路径：静默一条正则等于
  /// 在本轮关掉那道边界的一部分；静默一个路径会让 `cat x.key` 静默之后
  /// `scp x.key attacker:` 也跟着静默。命令原文是最保守的粒度，参数变一个
  /// 字符就重新问。
  final Set<String> _silencedCommands = {};

  /// seq → 判定用的命令原文。只为「本轮不再问」提供 key，应答后即删。
  ///
  /// 没有把它挂到 `ToolCallEvent` 上：那个类进归档序列化，为一个纯内存、
  /// 纯本轮的功能加字段会连带改动 `agentEventToJson` 与所有归档兼容性。
  final Map<int, String> _approvalTargets = {};

  /// 供 [ToolCallEvent.seq] 用的会话内计数器，只增不减。
  int _nextSeq = 0;

  /// 本会话累计用量，**只用于展示**。预算判断走 `_estimateTokens()`，那个
  /// 不依赖服务端返回 —— 服务端不给 usage 时预算判断照常工作。
  TokenUsage _totalUsage = const TokenUsage();

  /// 跨会话累计（按 provider 分桶）。null = 没注入，不记账。
  ///
  /// 可选的理由与其余依赖（`attachmentStore` / `appControl` 等）一致：
  /// 那几十个只关心 agent 行为的 widget／单测没理由为此各建一份 prefs。
  /// 生产路径（`AgentSessionManager` 造 loop 时）永远会传。
  final UsageTotals? usageTotals;

  /// 跨会话累计的**快照**，供 UI 同步读取。
  ///
  /// 为什么不在 `build` 里现读 `usageTotals`：那是同步的 prefs 读取 +
  /// jsonDecode，而页脚每轮都会重建。快照在累加时顺手更新（那时已经知道
  /// 新值），代价一次赋值。
  TokenUsage _cumulativeSnapshot = const TokenUsage();

  /// 跨会话累计总量（所有 provider 相加）。没注入累计时恒为空。
  TokenUsage get cumulativeUsage => _cumulativeSnapshot;

  /// 上一次请求的**真实**输入 token 数，当估算的下界用。0 = 还没有任何一次
  /// 真实测量（服务端不给 usage 时会一直是 0，此时完全走计算值 —— 这正是
  /// `_estimateTokens` 不改成「只用真值」的理由）。
  ///
  /// **必须在历史缩短时清零。** 「上一轮真的送出去过这么多」只在自那次测量
  /// 以来历史是纯追加时成立。压缩与丢弃都会让历史变短，此时旧真值就成了一个
  /// 虚高的地板，而 `_dropOldOutputsIfNeeded` 是
  /// `while (_estimateTokens() > threshold)` —— 地板不降，循环永远跨不过
  /// 阈值：把能丢的全丢完，再白发一次 `_compact()` 的真实调用，最后靠那个
  /// guard 熔断器兜住。用户看到的是「上下文被清空了、钱也花了、还是说超
  /// 预算」。
  ///
  /// 清零点有且只有两处：`_dropOldestOutput()` 与 `_compact()` 的成功路径。
  /// 将来若新增第三处改写 `_history` 的地方，必须一并清零。
  int _lastRealInput = 0;

  /// per-turn 计量。**纯展示与离线分析用**，不参与任何判断。
  ///
  /// 与 `_totalUsage` 的分工：那个是整条会话的累计，给面板底部那行用量看的；
  /// 这个是逐轮的时间切片，给「到底慢在哪」这个问题用的。
  final MetricsRecorder _metrics = MetricsRecorder();

  MetricsRecorder get metrics => _metrics;

  /// 所有采集点都走这里。
  ///
  /// **度量绝不能弄坏会话** —— 一个空指针、一次字段访问异常都不该让一次
  /// 正常的排查中断。这里静默吞掉，代价是采集失败时数据缺一格，可接受。
  void _metric(void Function(TurnMetrics t) f) {
    final t = _metrics.current;
    if (t == null) return;
    try {
      f(t);
    } catch (_) {}
  }

  AgentLoopState _state = AgentLoopState.idle;
  AgentStopReason? _stopReason;
  String? _errorMessage;

  /// Stack trace from the most recent caught exception, from *any* of the
  /// catch sites below (model call, command exec, file write, edit-file
  /// read) — not just the one that produced [_errorMessage].
  ///
  /// Kept around (rather than only threading it through the one catch that
  /// stops the loop) so a future diagnostic surface — e.g. the developer
  /// debug overlay — can show "what was the last exception this loop hit"
  /// even for tool-level failures that don't stop the session. Whichever
  /// catch fires last wins; when that's the `_run()` catch (the only one
  /// that sets [_errorMessage]), this is guaranteed to be *that* catch's
  /// stack, since the two are set in the same catch block.
  StackTrace? _errorStack;
  bool _cancelRequested = false;

  /// loop 运行期间用户追加的输入，等下一个轮边界注入 `_history`。
  ///
  /// **不进 `_events`**：它还没生效，进事件流意味着它会被归档成一条正式的
  /// `UserTurnEvent`，而撤回时又得从事件流里摘掉——那是一条只为「可能会被
  /// 撤销」而存在的写入路径。单独一个列表，撤回就是 `removeAt`。
  final List<String> _pendingInputs = [];

  /// 用来打断当前正卡在某次长阻塞远端调用上的等待——目前唯一的使用者是
  /// `_executeCheckJob` 的轮询（最长可阻塞 [kJobPollTimeout]，90 秒）。
  /// null 表示当前没有这样一次等待在进行；有值时 [cancel] 会把它 complete
  /// 掉，让等待方的 `Future.any` 立刻收到「被取消了」而不必等真正的远端
  /// 调用回来。别的取消检查点（`_cancelRequested` 轮询）足够应付那些本来
  /// 就会频繁让出事件循环的路径，只有这种一次 await 就吃满几十秒的调用
  /// 才需要这个额外的唤醒机制。
  Completer<void>? _cancelWaiter;
  bool _disposed = false;
  int _consecutiveInvalidArgs = 0;

  /// 本轮实际发给模型的工具名集合（已过 conditional 与解锁两道筛选）。
  ///
  /// 测试与 `systemPromptProvider` 都要读它：prompt 里那些工具的用法引导
  /// 必须与这份清单同步，否则会出现「引导说你可以 upload_file，但工具清单
  /// 里没有它」。
  Set<String> get activeToolNames =>
      filterByUnlockedGroups(toolSpecsProvider(), _unlockedToolGroups)
          .map((s) => s.name)
          .toSet();

  /// 本会话的用户消息里出现过 `@` 引用吗？给 system prompt 用——没出现过就
  /// 说明这个会话不涉及引用语义，那四条用法引导可以整段不发。
  ///
  /// 只看 `role == 'user'`：`@` 出现在工具结果或 assistant 文本里不代表用户
  /// 用过引用语义，算进去会让这条判据形同虚设（几乎任何会话的工具输出里都
  /// 可能带一个 `@`，比如邮箱地址）。
  bool get hasAtReference =>
      _history.any((m) => m.role == 'user' && m.content.contains('@'));

  /// 只给测试读的连续无效参数计数。
  @visibleForTesting
  int get debugConsecutiveInvalidArgs => _consecutiveInvalidArgs;

  /// 这一段会话已经提议过沉淀了。一次会话最多一张卡，见 `knowledge_gate.dart`。
  bool _knowledgeProposed = false;

  /// 非正常终止时,把排队中的输入退回给 UI(放回输入框)。
  ///
  /// **非 final,由 UI 层在 attach 时设置。** 不做成构造参数是因为 loop 由
  /// `AgentSessionManager` 创建、由 `AgentView` 消费,而输入框属于后者——
  /// 构造参数会逼着 manager 去知道一个纯 UI 的目标。
  void Function(String text)? onPendingReturned;

  AgentLoop({
    required this.providerProvider,
    required this.runnerProvider,
    this.prewarmProvider,
    required this.rulesProvider,
    required this.modeProvider,
    required this.toolSpecsProvider,
    required this.onRuleAdded,
    required this.systemPromptProvider,
    this.cwdProvider,
    this.serverListProvider,
    this.webFetcher,
    this.sftpOpsProvider,
    this.terminalTextProvider,
    this.relayTempDirProvider,
    this.downloadDirProvider,
    this.publishToPublicStore,
    this.pickLocalFile,
    this.skillBodyProvider,
    this.skillNamesProvider,
    this.builtinSkillNamesProvider,
    this.skillSearchProvider,
    this.skillSaver,
    this.skillAssetProvider,
    this.serverNoteSaver,
    this.knowledgeDistiller,
    this.savedCommandProvider,
    this.savedCommandNamesProvider,
    this.attachmentStore,
    this.appControl,
    this.serverIdResolver,
    this.maxTurns = 25,
    this.tokenBudget = kDefaultTokenBudget,
    this.usageTotals,
    Map<String, dynamic>? restoreFrom,
  }) {
    // system prompt 永远用**新的** —— cwd 与终端内容在上次会话之后已经变了，
    // 用存档里那份会让模型基于陈旧的环境描述做判断。
    _history.add(AIMessage(
        role: 'system',
        content: systemPromptProvider(AgentPromptInputs(
          activeToolNames: activeToolNames,
          hasAtReference: hasAtReference,
        ))));
    // 跨会话累计的历史值先装进快照，不然面板底部那一截会从 0 开始 ——
    // 一开面板显示「累计 0」而实际已经用过几十万，比不显示更误导。
    _cumulativeSnapshot = usageTotals?.total ?? const TokenUsage();
    if (restoreFrom != null) _restore(restoreFrom);
  }

  /// 把 `_history[0]` 的 system 消息刷成最新，**只在内容真的变了时才动**。
  ///
  /// 这个「只在变了时才动」是关键：`_history` 的第一条就是 Anthropic 的
  /// prompt-cache 断点所在。无条件替换成一个等值的新对象不影响缓存（缓存看
  /// 的是内容），但保留这个判断让意图明确——我们不是每轮重建 prompt，我们是
  /// 在用户改了设置之后让它生效。
  void _refreshSystemPrompt() {
    final fresh = systemPromptProvider(AgentPromptInputs(
      activeToolNames: activeToolNames,
      hasAtReference: hasAtReference,
    ));
    if (_history.isEmpty || _history.first.role != 'system') {
      // 理论上不可能（构造函数第一件事就是塞它），但恢复存档、上下文丢弃
      // 都动过 `_history`，这里便宜地兜一下比断言更实用。
      _history.insert(0, AIMessage(role: 'system', content: fresh));
      return;
    }
    if (_history.first.content == fresh) return;
    _history[0] = AIMessage(role: 'system', content: fresh);
  }

  AgentLoopState get state => _state;
  AgentStopReason? get stopReason => _stopReason;
  String? get errorMessage => _errorMessage;

  /// Stack trace behind [errorMessage] (or the last tool-level exception,
  /// if none has stopped the loop yet) — see the doc comment on
  /// [_errorStack]. `null` until the first exception is caught.
  StackTrace? get errorStack => _errorStack;
  @override
  List<AgentEvent> get events => List.unmodifiable(_events);
  List<String> get pendingInputs => List.unmodifiable(_pendingInputs);
  bool get isRunning =>
      _state == AgentLoopState.thinking ||
      _state == AgentLoopState.executing ||
      _state == AgentLoopState.awaitingApproval ||
      // 同理必须算「运行中」：`cancel()` 开头就是 `if (!isRunning) return;`，
      // 漏了这一支会让它在 `ask_user` 挂起期间变成空操作——完全复现
      // `_awaitApproval` 注释里警告过的那种永久挂起 + 历史泄漏。
      _state == AgentLoopState.awaitingAnswer ||
      // 必须算「运行中」：面板的运行条（以及那颗 Stop 按钮）由它控制，
      // 退避等待期间正是最需要能按 Stop 的时候。
      _state == AgentLoopState.rateLimited;

  /// 当前阶段的起点。null = 还没进过任何阶段（刚构造）。
  ///
  /// **每次 [_setState] 都会重置**，包括一轮之内反复进入 `executing`
  /// （每个 executor 入口各调一次）。这是刻意的：运行条要回答的是「现在
  /// 这一步等了多久」，不是「这一轮开始多久了」——后者由收工总结回答。
  ///
  /// 用 `DateTime` 而非 `Stopwatch`：读它的是每秒重建一次的 widget，那边
  /// 本来就要拿「现在」去减，持有一个跑着的秒表反而多一份要维护的状态。
  DateTime? _phaseStartedAt;
  DateTime? get phaseStartedAt => _phaseStartedAt;

  /// 此刻正在执行的调用。运行条用它显示「在跑哪条命令」。
  ///
  /// 与 [pendingApprovals] 同形（同样是对事件流的一次筛选，不额外维护
  /// 一份状态）——两者都调用得不频繁，事件流长度受 `_kMaxEvents` 约束。
  List<ToolCallEvent> get runningCalls => _events
      .whereType<ToolCallEvent>()
      .where((e) => e.status == ToolCallStatus.running)
      .toList();

  /// 退避倒计时剩余量。null = 此刻不在退避。
  Duration? _rateLimitRemaining;
  Duration? get rateLimitRemaining => _rateLimitRemaining;

  /// 触发这次退避的那条错误文案（含服务端原话）。null = 此刻不在退避。
  String? _rateLimitReason;
  String? get rateLimitReason => _rateLimitReason;

  /// 退避等待。返回 true = 等满了可以重试，false = 中途被取消 / dispose。
  ///
  /// **必须可中断。** 服务端给的 `Retry-After` 可以是几十秒，把 UI 锁死那么
  /// 久而 Stop 按不动，比直接报错还糟。所以这里按秒切片轮询取消标志，而不是
  /// 一发 `Future.delayed(total)` 睡过去。
  ///
  /// 每秒 notify 一次驱动倒计时：60 秒的等待最多 60 次重建，量级远低于流式
  /// 文本每个 chunk 一次的 notify。
  Future<bool> _waitOutRateLimit(Duration total, String reason) async {
    _rateLimitReason = reason;
    _setState(AgentLoopState.rateLimited);
    final deadline = DateTime.now().add(total);
    while (true) {
      if (_cancelRequested || _disposed) break;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      _rateLimitRemaining = left;
      _safeNotify();
      await Future<void>.delayed(
          left < const Duration(seconds: 1) ? left : const Duration(seconds: 1));
    }
    _rateLimitRemaining = null;
    _rateLimitReason = null;
    return !_cancelRequested && !_disposed;
  }

  /// 是否还有后台任务在跑。
  ///
  /// UI 的 1 秒 tick 要看它：agent 这一轮结束（`isRunning == false`）之后，
  /// 远端那个 `apt` 还在跑，任务卡上的时长必须继续走。
  bool get hasRunningJobs =>
      _events.whereType<BackgroundJobEvent>().any((e) => e.running);

  TokenUsage get totalUsage => _totalUsage;

  /// 当前等待用户应答的审批（面板关闭时用来决定推不推通知）。
  List<ToolCallEvent> get pendingApprovals => _events
      .whereType<ToolCallEvent>()
      .where((e) => e.status == ToolCallStatus.awaitingApproval)
      .toList();

  List<String> _plan = const [];
  int? _planCurrent;

  /// 模型当前的步骤列表。整体替换语义 —— 手机屏幕装不下可增删改的任务管理，
  /// 用户要的只是「它现在到哪一步」。
  List<String> get plan => List.unmodifiable(_plan);
  int? get planCurrent => _planCurrent;

  /// 被推迟的调用，等用户整批批准。
  ///
  /// 存的是**原始 [ToolCall]**，不是加工过的命令：批准后要重新走一遍完整
  /// 执行路径（含参数校验、diff 计算），那条路径的入口就是 ToolCall。
  final List<ToolCall> _planQueue = [];

  /// 已入队的去重键，见 [planDedupKey]。
  final Set<String> _planKeys = {};

  List<ToolCall> get planQueue => List.unmodifiable(_planQueue);

  /// 去重键：工具名 + 三个可能的定位参数。
  ///
  /// 用 NUL 连接而不是空格/逗号：路径和命令里都可能出现后者，
  /// `(bash, "a b")` 与 `(bash, "a", "b")` 不该撞成同一个键。NUL 不可能
  /// 出现在这些字段里（含 NUL 的命令早被 shell_guard 拦掉）。
  static String planDedupKey(ToolCall c) => [
        c.name,
        '${c.args['path'] ?? ''}',
        '${c.args['command'] ?? ''}',
        '${c.args['old_string'] ?? ''}',
      ].join('\x00');

  /// 入队。返回 false 表示这一条已经在队列里了。
  bool _enqueuePlan(ToolCall call) {
    if (!_planKeys.add(planDedupKey(call))) return false;
    _planQueue.add(call);
    return true;
  }

  void _restore(Map<String, dynamic> archive) {
    // 计量先恢复：后面的恢复路径不依赖它，但它与事件流是一对（StoppedEvent
    // 的收工总结要读它）。坏数据降级成空 recorder，不抛 ——
    // 与下面逐项 try/catch 同一个风格。
    final rawMetrics = archive['metrics'];
    if (rawMetrics != null) {
      final restored = MetricsRecorder.fromJson(rawMetrics);
      _metrics.adopt(restored);
    }
    final rawEvents = archive['events'];
    if (rawEvents is List) {
      _events.addAll(agentEventsFromJson(rawEvents));
      // `_nextSeq` 必须接着恢复的最大 seq 往下走，不能留在构造时的初值 0——
      // 否则本次会话新建的 ToolCallEvent 会复用恢复进来的旧 seq。那不会让
      // 审批串走（恢复的卡片一律是终态，见 agentEventToJson 的注释，不会
      // 再进 `_pending`），但会撞上 seq 本身的第一条不变量：「会话内唯一」，
      // 而 UI 拿它当 ValueKey 用——同一次 build 里两个不同的
      // `ToolCallEvent`（一个恢复的、一个新的）共享一个 key，是
      // `ToolCallEvent.seq` 文档明确警告过的那类问题。
      //
      // `BackgroundJobEvent` 同样消耗 `_nextSeq`（见其字段文档：「UI 拿它
      // 做列表 key，理由同 ToolCallEvent.seq」），所以这里必须一并纳入 ——
      // 只看 ToolCallEvent 会让恢复后新建的卡片复用一个已经分给某个任务卡
      // 的 seq。
      var maxSeq = -1;
      for (final e in _events) {
        final seq = switch (e) {
          ToolCallEvent(:final seq) => seq,
          BackgroundJobEvent(:final seq) => seq,
          _ => null,
        };
        if (seq != null && seq > maxSeq) maxSeq = seq;
      }
      _nextSeq = maxSeq + 1;
    }
    final rawHistory = archive['history'];
    if (rawHistory is List) {
      for (final m in rawHistory) {
        if (m is! Map) continue;
        try {
          final msg = AIMessage.fromJson(m.cast<String, dynamic>());
          if (msg.role == 'system') continue; // 已经放了新的
          _history.add(msg);
        } catch (_) {
          // 单条坏消息不该毁掉整段历史
        }
      }
    }
    // **读侧也要剥一次孤儿 tool_use。** 写侧的 `_archivableHistory` 只管住
    // 这个版本之后落的盘；升级前的存档是按老规则写的，读侧不能假设它合法。
    //
    // 旧版本确实能写出孤儿：`ai_panel.dart` 的「新建会话」与「打开历史段」
    // 都走 `archiveCurrent()`，而那两个按钮**没有 `isRunning` 门禁** —— 在
    // 一轮工具执行中途点下去，落盘的 history 末尾就是一条没有 `tool_result`
    // 配对的 assistant。
    //
    // 不剥的后果不是「恢复失败」而是更难归因的那种：这一段会话此后**每一句**
    // 都被服务端 400，因为 wire 上那个 `tool_use` 后面跟的是 user 文本。
    if (_endsWithOrphanToolCall(_history)) _history.removeLast();
    // 重建 `_loadedSkills`：恢复出来的 `_history` 里可能带着上次会话已经
    // 发过的技能正文（`[skill: nginx]\n...`）。这个记账集合是全新实例的
    // 初值为空 —— 不重建的话，模型在恢复后的会话里再问一次 `load_skill`
    // 会被当成「从没 load 过」，正文已经在上文了却又被重发一遍 8 KiB。
    //
    // 只把真正以 `kSkillBodyPrefix` 开头的 content 计入 `_loadedSkills`——被
    // `_dropOldestOutput` 换成 marker（`_kDroppedPrefix` 开头）的那些，正文
    // 已经不在历史里了，这里必须跳过，否则会变成方向相反的同一类 bug：告诉
    // 模型「正文在上文」，而上文只剩一条丢弃提示，模型拿不到又不该重试。
    //
    // 但丢弃 marker 本身也不能被无视：`_droppedMarker` 生成的文案明确写着
    // 「call load_skill again」，而长尾技能（靠 `search_skills` 才找得到的
    // 那些）不在索引里——`load_skill` 只放行「在索引内 ∪ `_searchedSkills`」。
    // 恢复出来的新实例 `_searchedSkills` 是空集，模型照 marker 的指示去
    // load，会被回一句「No skill named X」：系统自己的提示把模型推向一条
    // 死路。历史里出现过这个名字（不管是正文还是正文被丢弃后的 marker）就是
    // 「它真实存在」的权威证据，`_loadedSkills` 早就在信任同一份证据，白
    // 名单没有理由不信。
    for (final m in _history) {
      if (m.role != 'tool') continue;
      for (final r in m.toolResults ?? const <ToolResult>[]) {
        final name = _skillNameOf(r.content);
        if (name != null) {
          _loadedSkills.add(name.toLowerCase());
          _searchedSkills.add(name.toLowerCase());
          continue;
        }
        final dropped = _droppedSkillNameOf(r.content);
        if (dropped != null) _searchedSkills.add(dropped.toLowerCase());
      }
    }
    // 解锁状态也从历史里重建，与上面重建 `_loadedSkills` 同一个理由：不重建
    // 的话，模型在恢复后的会话里会发现工具又不见了，要再解锁一次 —— 而每次
    // 解锁都是一轮 prompt cache 重建。
    //
    // 判据是「有一条成功的 more_tools 结果」。失败的（未知组名）不算数，
    // 否则会把一个从没生效过的组当成已解锁。
    for (final m in _history) {
      if (m.role != 'tool') continue;
      for (final r in m.toolResults ?? const <ToolResult>[]) {
        final g = _unlockedGroupOf(r.content);
        if (g != null) _unlockedToolGroups.add(g);
      }
    }
    // plan 不单独持久化 —— 事件流里最后那条 PlanUpdatedEvent 就是它的
    // 真相来源，再存一份等于给自己制造两个可能不一致的副本。
    final plans = _events.whereType<PlanUpdatedEvent>().toList();
    if (plans.isNotEmpty) {
      final lastPlan = plans.last;
      _plan = lastPlan.steps;
      _planCurrent = lastPlan.current;
    }
    final rawQueue = archive['planQueue'];
    if (rawQueue is List) {
      for (final m in rawQueue) {
        if (m is! Map) continue;
        try {
          // 走 _enqueuePlan 而不是直接 add —— 去重键要一起恢复，否则换了
          // 实例之后同一条编辑可以再入队一次。
          _enqueuePlan(ToolCall.fromJson(m.cast<String, dynamic>()));
        } catch (_) {
          // 单条坏记录不该毁掉整个队列
        }
      }
    }
    // 字段缺失当空列表:升级前落的盘没有它。
    final rawPending = archive['pendingInputs'];
    if (rawPending is List) {
      for (final t in rawPending) {
        if (t is String) _pendingInputs.add(t);
      }
    }
    _restoreTerminalState();
  }

  /// 把恢复出来的会话重新标成「已终止」。
  ///
  /// ## 不做这件事会静默吃掉用户的操作
  ///
  /// `AgentSessionManager._onLoopChanged` 的落盘条件是
  /// `!isRunning && stopReason != null` —— 只在终态写盘。而恢复出来的 loop
  /// 如果 `_stopReason` 还是 null，它就永远不满足这个条件：
  ///
  /// 1. 用户关掉面板（loop 落盘，带着 planQueue 和提案卡）
  /// 2. 重新打开（loop 从 archive 重建，`_stopReason == null`）
  /// 3. 点「丢弃」→ 内存里队列清了、卡收了，**盘上那份没动**
  /// 4. 再关再开 → 整份方案原样复活
  ///
  /// 撤销同理（`ev.undone` 失忆，按钮再次出现——`cp -p` 幂等所以没有数据
  /// 损失，但用户会以为撤销没生效）。
  ///
  /// ## 为什么不给 archive 加字段
  ///
  /// 不需要：事件流里最后那条事件已经把终止状态说清楚了。`StoppedEvent`
  /// 自带 reason；末尾是 `PlanProposalEvent` 则意味着上次走的是
  /// [_stopWithProposal]，那条路径设的就是 `completed`。从已有数据推导比
  /// 多存一份可能与事件流不一致的副本更可靠。
  void _restoreTerminalState() {
    if (_events.isEmpty) return;
    final last = _events.last;
    final reason = switch (last) {
      StoppedEvent(:final reason) => reason,
      PlanProposalEvent() => AgentStopReason.completed,
      // 与 PlanProposalEvent 同处理：这张卡只在 `_maybeProposeKnowledge`
      // 里追加，而那条路径必然发生在 `_stop(completed)` 之后。不加这一支
      // 就会走进下面「上次被硬杀」的分支，把好端端的收尾当成崩溃。
      KnowledgeProposalEvent() => AgentStopReason.completed,
      // 其他事件结尾说明上次是被硬杀的（进程被杀、崩溃），没有终态可恢复。
      // 保持 null，下一次 send() 会把它带回正常流程。
      _ => null,
    };
    if (reason == null) {
      // 上次是被硬杀的。事件流里可能还留着 status == running 的工具卡——
      // `agentEventToJson` 对 `TransferEvent` 把 running 存成 interrupted
      // (「留一个 running 会让恢复出来的卡片永远转圈」)，但 `ToolCallEvent`
      // 没有对应处理。在这里收尾:那些命令确实发出去了，结果确实不知道。
      final stuck = _events
          .whereType<ToolCallEvent>()
          .where((e) => e.status == ToolCallStatus.running)
          .toList();
      for (final e in stuck) {
        _finishToolCall(e, ToolCallStatus.failed);
        e.output = kInterruptedOutputMarker;
      }
      _events.add(SessionInterruptedEvent(
        stuck.map((e) => '${e.toolName}(${e.displayCommand})').toList(),
      ));
      return;
    }
    _stopReason = reason;
    _state = switch (reason) {
      AgentStopReason.userCancelled => AgentLoopState.cancelled,
      AgentStopReason.error || AgentStopReason.invalidArgs =>
        AgentLoopState.failed,
      _ => AgentLoopState.done,
    };
  }

  Map<String, dynamic> toArchive() => {
        'events': _events.map(agentEventToJson).toList(),
        'history': _archivableHistory().map((m) => m.toJson()).toList(),
        // 队列必须进归档：不存的话重开面板后提案卡还在（它在 events 里），
        // 但「批准」按钮没有任何东西可执行。
        'planQueue': _planQueue.map((c) => c.toJson()).toList(),
        // 被杀时队列里压着的那句话必须活下来——用户重开面板发现自己说过的
        // 话消失了,比功能不存在更糟。
        'pendingInputs': List.of(_pendingInputs),
        // 计量必须进归档。
        //
        // `StoppedEvent`（收工总结那行的**容器**）本来就在 `events` 里，
        // 所以它能在恢复后照常渲染；但总结里的**数字**来自 `_metrics`，
        // 那是 loop 的内存状态 —— 不落盘的话 `closeLoop` 一 dispose，
        // 新 loop 的 recorder 是空的，UI 那行 `metrics: null` 于是整行
        // 不渲染（用户看到的就是「会话期间有 token 统计、结束就没了」）。
        //
        // 体积很小：实测单轮 ~244 字节，200 轮上限 ~48 KB，而归档里事件流
        // 本身动辄几百 KB。
        'metrics': _metrics.toJson(),
      };

  /// 落盘用的历史前缀:末尾若是带 `toolCalls` 的 assistant 消息,丢掉它。
  ///
  /// ## 为什么 events 全量落而 history 要截
  ///
  /// 两者用途不同。`events` 是给**人**看的记录,被杀后用户要看到完整过程;
  /// `history` 是喂**模型**的对话,结构必须永远合法。
  ///
  /// `tool_result` 总是作为紧随其后的单独一条 `role: tool` 消息落地,所以
  /// 「末尾是带 toolCalls 的 assistant」等价于「这一轮的工具结果还没回来」
  /// ——也就是进程被杀的那一刻。丢掉它,**孤儿 `tool_use` 就在落盘层被消灭
  /// 了**,恢复层不需要补占位 `tool_result`,也不需要为「补几条、补什么内容」
  /// 再做一次设计。
  ///
  /// ## 为什么现算而不是维护索引水位
  ///
  /// 直觉方案是存一个 `_lastSafeHistoryLength`,落盘时 `take(水位)`。但
  /// `_dropOldOutputsIfNeeded()` 和 compaction 都会改变 `_history` 的长度,
  /// 存下来的索引在它们跑过之后就**静默**指向别的地方,落盘的历史会从中间
  /// 某处被截断,直到某次恢复后 400 才暴露——那时归因链已经断了。
  ///
  /// 现算是无状态的,对任何改动 `_history` 的机制天然免疫。
  List<AIMessage> _archivableHistory() {
    final h = _history.where((m) => m.role != 'system').toList();
    if (_endsWithOrphanToolCall(h)) h.removeLast();
    return h;
  }

  /// 「这段历史末尾是一次没拿到结果的工具调用」——写侧与读侧共用的判据。
  ///
  /// 抽出来是因为它有**两个**调用点而不是一个：`_archivableHistory` 用它剥
  /// 写入的孤儿，`_restore` 用它剥读到的孤儿。两处必须是同一条规则，各写
  /// 一遍迟早会分叉——而分叉的那一侧不会立刻报错，要等某次请求被服务端
  /// 400 才暴露。
  static bool _endsWithOrphanToolCall(List<AIMessage> h) =>
      h.isNotEmpty &&
      h.last.role == 'assistant' &&
      (h.last.toolCalls?.isNotEmpty ?? false);

  /// 仅供测试断言内部对话历史。
  @visibleForTesting
  List<AIMessage> get debugHistory => List.unmodifiable(_history);

  /// 仅供测试断言当前解锁状态下的工具清单（供估算 schema token 用）。
  @visibleForTesting
  List<ToolSpec> debugToolSpecs() =>
      filterByUnlockedGroups(toolSpecsProvider(), _unlockedToolGroups);

  /// 仅供测试：往历史里塞一条工具结果消息。
  @visibleForTesting
  void debugSeedToolResult(ToolResult r) {
    _history.add(AIMessage(role: 'tool', content: '', toolResults: [r]));
  }

  /// 仅供测试：往历史里塞一条**携带多个** ToolResult 的消息 —— 一轮并行
  /// 工具调用产生的真实形状。用来复现「消息里一条已丢过、一条还没丢」的
  /// 组合：单结果消息一旦丢过就会被 `_dropOldestOutput` 的 indexWhere 整条
  /// 跳过，永远不会重新进入 `.map`，测不出「已丢的是否被原样保留」这件事。
  @visibleForTesting
  void debugSeedToolResults(List<ToolResult> results) {
    _history.add(AIMessage(role: 'tool', content: '', toolResults: results));
  }

  /// 仅供测试：往历史里塞一条 assistant 消息，带一个 tool_call。
  ///
  /// 配合 [debugSeedToolResult] 复现「已经跑完的一整轮」的真实形状——单独的
  /// [debugSeedToolResult] 只造出孤儿 tool_result（没有配对的 tool_use）。
  /// 压缩相关测试需要真实配对：`_dropOldestOutput` 只替换 tool_result 的
  /// 内容，从不touch tool_call 的 args，所以一条参数很长的命令（模拟真实的
  /// 长 shell 命令/heredoc）即使在输出全部被丢弃之后依然占预算——这正是
  /// 「便宜的丢弃用尽后仍超阈值」这个场景需要的非均匀历史形状。
  @visibleForTesting
  void debugSeedToolCall(ToolCall call) {
    _history.add(AIMessage(role: 'assistant', content: '', toolCalls: [call]));
  }

  /// 仅供测试：触发一次丢弃，返回是否真的丢了东西。
  @visibleForTesting
  bool debugDropOldestOutput() => _dropOldestOutput();

  /// 仅供测试：把 `_cancelRequested` 置位后直接驱动 `_executeRound`。
  ///
  /// **为什么需要绕过 `send()`/`cancel()` 走这条后门**：`_run()` 里 F2 的
  /// 修复（await-for 循环体首行 `break`，加上循环结束后、`done == null`
  /// 判断之前的取消检查）已经把「取消发生在拿到完整模型响应之前或期间」
  /// 这条路堵死了——只要 `_cancelRequested` 在流结束前的任意一次检查点变
  /// 成 true，`_run()` 会在进 `_executeRound` 之前就直接返回，压根不会
  /// 使用那次已经收到的 `done`。而从「循环后检查通过（false）」到
  /// 「调用 `_executeRound`」之间是一段没有任何 `await` 的同步代码——
  /// Dart 单线程语义下，外部的 `cancel()` 不可能插进这段同步区间。
  ///
  /// 也就是说，`_executeRound` 快路径自己的取消检查，在真实的
  /// `send()`/`cancel()` 驱动流程里已经不再是一条能被复现的竞态——这本身
  /// 是 F2 修复的一个良性副作用。但它依然是必要的防御：一旦 `_run()` 的
  /// 结构将来变化，或者出现另一条不经过流式循环就调用 `_executeRound` 的
  /// 路径，这道检查仍然成立，且不会拖累任何正常路径。要独立验证这段代码
  /// 本身的正确性（而不是间接依赖一条已经关闭的竞态窗口），只能像
  /// `debugDropOldestOutput` 那样直接驱动它。
  @visibleForTesting
  Future<List<ToolResult>> debugExecuteRoundAfterCancel(
      List<ToolCall> calls) {
    _cancelRequested = true;
    return _executeRound(calls);
  }

  /// 仅供测试：`_history` 当前长度（压缩前后对比用）。
  @visibleForTesting
  int get debugHistoryLength => _history.length;

  /// 仅供测试：把状态直接摆成「正在跑」，不真的驱动一轮。
  ///
  /// `AgentSessionManager` 的节流落盘要在 `loop.isRunning` 为 true 时触发，
  /// 但真跑一轮需要 provider/runner 脚本、时序难以对齐到毫秒级的
  /// `fakeAsync` 窗口。直接摆位置让测试能在同一个 `fakeAsync` zone 里
  /// 精确控制「现在处于运行态」这件事,不掺进一整条 `_run()` 的真实异步。
  @visibleForTesting
  void debugForceRunning() {
    _state = AgentLoopState.thinking;
    _phaseStartedAt = DateTime.now();
  }

  Future<void> send(String text, {List<Attachment>? attachments}) async {
    if (isRunning) {
      // 排队而不是丢弃。注入在轮边界，见后续任务的 `_flushPendingInputs`。
      _pendingInputs.add(text);
      _safeNotify();
      return;
    }
    _cancelRequested = false;
    _stopReason = null;
    _errorMessage = null;
    _errorStack = null;
    _consecutiveInvalidArgs = 0;
    // app 变更的批次边界 = 一轮运行。这一轮改的全部设置归入同一张卡、
    // 同一次撤销；不开新批次的话，这一轮的改动会被追加进上一张卡，点那
    // 张卡的撤销就会连带撤掉用户以为已经定下来的上一轮改动。
    //
    // 只是把指针清空，不预建批次 —— 绝大多数轮次不碰 app 设置。
    appControl?.changeLog.startBatch();
    // 上一轮的终止横幅该走了 —— 否则用户点「继续」之后，
    // 面板里会同时挂着两条「已达轮数上限」。
    //
    // 中断横幅一并摘掉，理由更硬：`resume()` 的守卫是「`_events.last` 必须是
    // `SessionInterruptedEvent`」，而用户发了新消息之后它就不在末尾了。不摘的
    // 话那条事件会永久留在流里、永久渲染一颗可点的「继续」按钮，点下去
    // `resume()` 每次都静默 early-return —— 用户只会以为 app 卡了。多次
    // 中断-续跑的会话还会攒出好几颗，只有最后一颗有效。
    //
    // 这正是 [_stopWithProposal] 那段注释警惕过的「静默死键」，同一个反模式。
    // 发新消息本身就表示用户放弃了从中断处续跑，摘掉它语义上也对。
    if (_events.isNotEmpty &&
        (_events.last is StoppedEvent ||
            _events.last is SessionInterruptedEvent)) {
      _events.removeLast();
    }
    // `_history` 有丢弃机制，`_events` 原本没有 —— 长会话里它是唯一不断
    // 长大且永不释放的结构。每条工具输出上限 8 KiB，几百轮之后就是几 MB。
    // 在每轮开头裁一次，比在渲染层做省事也更可预测。
    _trimEvents();
    _history.add(AIMessage(
        role: 'user', content: text, attachments: attachments));
    _events.add(UserTurnEvent(text, attachments: attachments));
    await _run();
  }

  /// 撤回一条排队中的输入，返回它的文本（供 UI 放回输入框）。
  ///
  /// 越界返回 null 而不是抛：UI 的点击事件与队列冲刷之间存在一帧的窗口——
  /// 用户点下的那一刻队列可能刚被冲刷。返回 null 让调用方什么都不做，这比
  /// 让一次正常的点击炸掉要好。
  String? withdrawPendingInput(int index) {
    if (index < 0 || index >= _pendingInputs.length) return null;
    final text = _pendingInputs.removeAt(index);
    _safeNotify();
    return text;
  }

  /// 把排队的输入冲刷进历史,返回是否真的注入了东西。
  ///
  /// **调用点必须满足:`_history` 的 tool_use / tool_result 配对完整。**
  /// wire protocol 要求每个 `tool_use` 恰好配一个 `tool_result`(见
  /// [_executeRound] 的注释),在配对完成之前插一条 user 消息,这段历史在
  /// 下一次请求时会被服务端 400 拒掉。
  ///
  /// 多条**合并成一条**而不是逐条 add:连续两条 `role: user` 的消息,
  /// Anthropic 的实际行为是合并、OpenAI 是原样接受,但两者都没有写进任何
  /// 接口保证。自己合并则三家 provider 行为一致。
  bool _flushPendingInputs() {
    if (_pendingInputs.isEmpty) return false;
    final merged = _pendingInputs.join('\n');
    _pendingInputs.clear();
    _history.add(AIMessage(role: 'user', content: merged));
    _events.add(UserTurnEvent(merged));
    // 必须通知：注入点 A 之后紧跟 `_dropOldOutputsIfNeeded()`，那里可能触发
    // 一次 `_compact()`——一次真实的 provider 往返，几秒起步。这段时间里界面
    // 上灰气泡还挂着而队列已经空了，用户点它只会拿到 null、没有任何反馈，
    // 很容易再打一遍造成重复输入。
    _safeNotify();
    return true;
  }

  /// 从中断处继续。
  ///
  /// **只能手动触发，不自动**：被杀那一刻在飞的命令到底执行了没，远端没有
  /// 幂等标记可查，这个不确定性没有技术解。自动续跑等于替用户做了「大概率
  /// 没做完，重跑」或「大概率做完了，跳过」的赌注——两个都可能是错的，而
  /// 只有看得到中断上下文的用户才有资格下这个判断。
  ///
  /// 末尾不是 [SessionInterruptedEvent] 时是空操作：没有中断可续，也避免
  /// 被重复调用时把一条正常的历史当中断处理。
  Future<void> resume() async {
    if (isRunning) return;
    final last = _events.isEmpty ? null : _events.last;
    if (last is! SessionInterruptedEvent) return;
    _events.removeLast();
    _history.add(
        AIMessage(role: 'user', content: buildInterruptNotice(last.lastCalls)));
    _cancelRequested = false;
    _stopReason = null;
    _errorMessage = null;
    _errorStack = null;
    _consecutiveInvalidArgs = 0;
    // app 变更的批次边界 = 一轮运行。这一轮改的全部设置归入同一张卡、
    // 同一次撤销；不开新批次的话，这一轮的改动会被追加进上一张卡，点那
    // 张卡的撤销就会连带撤掉用户以为已经定下来的上一轮改动。
    //
    // 只是把指针清空，不预建批次 —— 绝大多数轮次不碰 app 设置。
    appControl?.changeLog.startBatch();
    await _run();
  }

  void cancel() {
    if (!isRunning) return;
    _cancelRequested = true;
    // 取消之后界面上不该还挂着一段「正在转」的半截话——但已经读到眼里的字
    // 不能凭空消失，落成正式事件而不是直接清空。`_run()` 的 await-for 只在
    // 下一个 chunk 到达时才会看到 `_cancelRequested`，那时它自己再调
    // `_flushStreamingText()` 已经晚了：这里才是文本实际停止增长的那一刻。
    _flushStreamingText();
    // 唤醒卡在审批上的那一步，否则 loop 永远不会回到检查点。
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete(const ApprovalOutcome(ApprovalDecision.reject));
      }
    }
    _pending.clear();
    // 唤醒卡在提问上的那一步。与上面的审批循环同一个理由：漏掉这里 =
    // loop 永久挂起 + 整段历史泄漏。空串表示「没有答案」，executor 按
    // 会话取消处理。
    for (final c in _pendingAnswers.values) {
      if (!c.isCompleted) c.complete('');
    }
    _pendingAnswers.clear();
    // 唤醒卡在聚合审批上的那一步。它不在 `_pending` 里（那个按
    // ToolCallEvent.seq 索引，聚合卡没有对应的 seq），所以上面那个循环
    // 覆盖不到它。漏掉这里 = loop 永久挂起 + 整段历史泄漏。
    final batch = _batchGate;
    if (batch != null && !batch.isCompleted) batch.complete(false);
    _batchGate = null;
    // 唤醒可能正卡在一次长阻塞远端调用上的那一步（目前只有 check_job 的
    // 轮询）。必须在赋值之后才发起那次调用——见 `_executeCheckJob` 里的
    // 注释：`onRun` 类的同步回调可能在 `run()` 返回的 Future 完成之前就已
    // 经跑到这里，`_cancelWaiter` 如果还没被赋值，这次唤醒就没人接。
    final waiter = _cancelWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    _safeNotify();
  }

  /// 应答一条审批，按 [ToolCallEvent.seq] 定位 —— **不是 [ToolCallEvent.callId]**
  /// （理由见 [_pending] 的注释：`edit_file` 的读、写两个阶段共用同一个
  /// `callId`，按 callId 索引会让迟到的第二次点击误批准另一张卡）。
  ///
  /// 同一 [seq] 第二次调用**静默丢弃** —— 用户可能在通知和面板上各点一次，
  /// 也可能是对已经处理过的旧卡片的迟到点击；此时 `_pending` 里已经没有
  /// 它的 key（要么被上一次应答 remove 掉，要么这个 seq 从未注册过），
  /// 不会误伤任何其他仍在等待的审批。
  void respondApproval(
    int seq,
    ApprovalDecision decision, {
    String? rememberRule,
    bool silenceInSession = false,
  }) {
    final c = _pending.remove(seq);
    final target = _approvalTargets.remove(seq);
    if (c == null || c.isCompleted) return;
    if (decision == ApprovalDecision.allowOnce &&
        rememberRule != null &&
        rememberRule.trim().isNotEmpty) {
      onRuleAdded(PermissionRule(pattern: rememberRule.trim()));
    }
    // 只有「允许」才可能静默 —— 拒绝之后再静默是自相矛盾的。
    if (silenceInSession &&
        decision == ApprovalDecision.allowOnce &&
        target != null &&
        target.trim().isNotEmpty) {
      _silencedCommands.add(target.trim());
    }
    c.complete(ApprovalOutcome(decision));
  }

  /// 应答一条 `ask_user`，按 [ToolCallEvent.seq] 定位。
  ///
  /// 同一 seq 第二次调用**静默丢弃**，与 [respondApproval] 同一个理由：用户
  /// 可能在通知和面板上各点一次。
  void respondAnswer(int seq, String choice) {
    final c = _pendingAnswers.remove(seq);
    if (c == null || c.isCompleted) return;
    c.complete(choice);
  }

  @override
  bool get hasAskedThisTurn => _askedThisTurn;

  @override
  void markAskedThisTurn() => _askedThisTurn = true;

  @override
  Future<String?> awaitAnswer(ToolCallEvent ev, List<AskOption> options) {
    // 与 `_awaitApproval` 完全同构的取消闸门。挡在这一处而不是调用点——
    // 理由见那个方法的注释：cancel()/dispose() 只叫醒它们被调用那一刻在
    // map 里的等待者，此后注册的没有任何人会完成它，loop 会永久挂起并把
    // 整段历史一起泄漏。
    if (_cancelRequested || _disposed) return Future.value(null);
    _setState(AgentLoopState.awaitingAnswer);
    final completer = Completer<String>();
    _pendingAnswers[ev.seq] = completer;
    return completer.future;
  }

  /// 这条命令本轮是否已被标记为「不再问」。
  ///
  /// 三个条件缺一不可，顺序无关但都必须在：只对凭据 deny 生效（其余审批理由
  /// 各有自己的出口）、只在 bypass 档生效（ask/plan 下这个集合存在但永不被
  /// 查——那两档的语义是「每次都让你看见」）、命令原文完全相同。
  bool _isSilenced(String checkTarget, CheckResult check) =>
      check.denyHit &&
      modeProvider() == PermissionMode.bypass &&
      _silencedCommands.contains(checkTarget.trim());

  /// 批准整份方案：逐条执行队列，把结果注入历史，然后让 loop 继续。
  ///
  /// ## 结果为什么以 user 消息注入
  ///
  /// 队列里每个调用的 tool_use 在被推迟时**已经消耗掉了自己唯一的
  /// tool_result**（见 [_deferResult]）。wire protocol 不允许同一个
  /// tool_use_id 有第二个结果，所以真实执行结果只能以新的 user 消息进历史。
  ///
  /// 这个形状不是权宜之计——任何「先推迟、后执行」的设计都躲不掉它。
  ///
  /// ## 失败就停
  ///
  /// 某一条失败时停下，剩余的重新入队。不跳过继续跑：方案里的项通常有依赖
  /// 关系（改配置 → reload），前一步没成功，后一步的结果没有意义甚至有害。
  Future<void> approvePlan() async {
    if (isRunning || _planQueue.isEmpty) return;

    final queue = List.of(_planQueue);
    _planQueue.clear();
    _planKeys.clear();
    _cancelRequested = false;
    _stopReason = null;
    _errorMessage = null;
    _consecutiveInvalidArgs = 0;

    // 提案卡该走了——它代表的那批调用正在被执行。
    if (_events.isNotEmpty && _events.last is PlanProposalEvent) {
      _events.removeLast();
    }
    // 与 `send()` 同一个理由：`_events` 是长会话里唯一不断长大且永不释放的
    // 结构（每条工具输出上限 8 KiB）。反复批准方案是另一条能把它撑大的入口，
    // 之前只有 `send()` 裁剪，这条路径绕过了那个上限。
    _trimEvents();

    final lines = <String>[];
    for (var i = 0; i < queue.length; i++) {
      if (_cancelRequested) break;
      final call = queue[i];
      final r = await _executeOne(call, preApproved: true);
      final label = _planLineFor(call);
      lines.add(r.isError
          ? '${i + 1}. $label → FAILED: ${r.content}'
          : '${i + 1}. $label → ${r.content}');
      if (r.isError) {
        // 停在失败那条，剩下的放回队列等用户决定。
        for (final rest in queue.sublist(i + 1)) {
          _enqueuePlan(rest);
        }
        break;
      }
    }

    _history.add(AIMessage(
      role: 'user',
      content: '[system] The user approved the plan. Results of the queued '
          'calls:\n${lines.join('\n')}',
    ));
    await _run();
  }

  /// 丢弃整份方案。不执行任何东西，收掉提案卡，补一条正常终止。
  void discardPlan() {
    _planQueue.clear();
    _planKeys.clear();
    if (_events.isNotEmpty && _events.last is PlanProposalEvent) {
      _events.removeLast();
    }
    _events.add(StoppedEvent(AgentStopReason.completed));
    _safeNotify();
  }

  /// 把知识提议卡的第 [index] 条标记为已处理（存入或忽略）。
  ///
  /// ## 为什么必须走这里，而不是在 UI 层直接改 `ev.resolved`
  ///
  /// 落盘的唯一触发点是 `_safeNotify()` —— `AgentSessionManager` 把
  /// `_onLoopChanged` 挂在这个 loop 的 listener 上，只有 notify 发生才会
  /// 调度一次持久化。事件对象上的 `resolved` 是个可变 `Set`，在 View 层
  /// 直接 `add` 不会经过任何 notify，那次状态变化就**只活在内存里**。
  ///
  /// 后果不是「少存一个 UI 状态」那么轻：进程被杀（安卓后台清理很常见，
  /// 而「排查完 → 存下来 → 关掉 app」恰恰是这个功能最典型的收官动作）之后
  /// 从归档恢复，卡片会变回未处理。用户再点一次「存入」，`serverNote` 那条
  /// 分支会拿着**已经包含上次写入内容**的笔记再追加一遍同样的段落 ——
  /// 用户这台机器的笔记被写重复，且不可逆。
  ///
  /// 所有其它卡片决策（`discardPlan` / `approvePlan` / `approveBatch`）都遵守
  /// 这条契约，这里不能例外。
  void resolveKnowledgeProposal(KnowledgeProposalEvent ev, int index) {
    if (!ev.resolved.add(index)) return;
    _safeNotify();
  }

  /// 正在等用户整批批准的那一批。null = 当前没有。
  Completer<bool>? _batchGate;

  /// 用户点了「全部同意」。
  Future<void> approveBatch() async {
    final gate = _batchGate;
    if (gate == null || gate.isCompleted) return;
    _batchGate = null;
    _dropBatchEvent();
    gate.complete(true);
  }

  /// 用户点了「取消」。
  void discardBatch() {
    final gate = _batchGate;
    if (gate == null || gate.isCompleted) return;
    _batchGate = null;
    _dropBatchEvent();
    gate.complete(false);
  }

  void _dropBatchEvent() {
    _events.removeWhere((e) => e is BatchApprovalEvent);
    _safeNotify();
  }

  /// 撤销某一次文件编辑：把 `.flyterm.bak.<seq>` 拷回原路径。
  ///
  /// 返回是否成功。失败原因体现在事件上（[ToolCallEvent.backupMissing]）而
  /// 不是抛异常——调用方是一个按钮，它需要的是「变成什么样子」。
  ///
  /// **不走审批。** 用户主动点撤销按钮，这个点击本身就是意图确认；审批卡
  /// 存在的意义是拦住**模型**的意图，不是拦用户自己的。
  Future<bool> undoEdit(int seq) async {
    ToolCallEvent? ev;
    for (final e in _events) {
      if (e is ToolCallEvent && e.seq == seq) {
        ev = e;
        break;
      }
    }
    final backup = ev?.backupPath;
    if (ev == null || backup == null || ev.undone || ev.backupMissing) {
      return false;
    }
    final path = ev.preview?.path;
    if (path == null || path.isEmpty) return false;

    // 撤销要回到当初写入的那台机器。事件上记着机器名，反解回 id ——
    // 从 displayCommand 里解析是不行的，那个字符串是给人看的。
    String? serverId;
    if (ev.targetServerName != null) {
      final servers =
          await serverListProvider?.call() ?? const <ServerListEntry>[];
      final t = resolveServerTarget(ev.targetServerName, servers);
      if (!t.ok) {
        // 那台机器已经被用户删掉了。与备份缺失同类：把原因摆在卡片上，
        // 而不是让按钮点下去什么都不发生。
        ev.output = 'Undo failed: server `${ev.targetServerName}` is no '
            'longer saved on this device.';
        _safeNotify();
        return false;
      }
      serverId = t.serverId;
    }

    final CommandOutput out;
    try {
      out = await runnerProvider(serverId).run(
        buildUndoCommand(path, backup),
        cwd: serverId == null ? cwdProvider?.call() : null,
      );
    } catch (e, st) {
      _errorStack = st;
      // 连接层就没建立起来。把它写进卡片，否则用户点了撤销之后界面上
      // 一个像素都不变，只能理解成「这按钮坏了」。
      ev.output = 'Undo failed: $e';
      _safeNotify();
      return false;
    }

    if (out.exitCode == kMissingBackupExitCode) {
      ev.backupMissing = true;
      _safeNotify();
      return false;
    }
    if (!out.isSuccess) {
      // 权限、磁盘满一类：不标 backupMissing，按钮保持可点让用户重试。
      //
      // 但**必须把 stderr 摆出来**。这曾是整个功能里唯一一条完全无反馈的
      // 失败路径：用户点撤销、`cp` 因权限失败 → 界面上什么都不变。而隔壁
      // 那行（备份丢失）特意做了「不静默失败」，两者是同一个意图。
      //
      // 写进 `ev.output` 而不是发 SnackBar：卡片已有可展开的输出区，撤销
      // 失败的 stderr 和当初那次写入的输出放在同一个地方，用户不用在两处
      // 之间对照。
      ev.output = formatForDisplay(out);
      _safeNotify();
      return false;
    }

    ev.undone = true;
    _safeNotify();
    return true;
  }

  /// 提案摘要里一条调用的可读标签。
  static String _planLineFor(ToolCall c) {
    final path = c.args['path'];
    if (path is String && path.isNotEmpty) return '${c.name} $path';
    final cmd = c.args['command'];
    if (cmd is String && cmd.isNotEmpty) return cmd;
    return c.name;
  }

  /// provider 报「上下文超长」时，我们自己的 token 估算可能还没到阈值
  /// （估算按 chars/3.5，对 CJK 和代码都会偏低）。这种情况下强制丢一批旧的
  /// 工具输出再重试一次，而不是直接把会话判死。
  static bool _looksLikeContextOverflow(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('context_length_exceeded') ||
        s.contains('context length') ||
        s.contains('too many tokens') ||
        s.contains('prompt is too long') ||
        s.contains('maximum context');
  }

  /// 最多为 429 重试几次。
  ///
  /// 2 次：限流要么几秒就过（第一次退避就够），要么是额度用尽（等多久都没
  /// 用）。中间地带很窄，而每多试一次都是一整段历史的重发 —— 对着限流刷
  /// 请求只会加剧它。
  static const int _kMaxRateLimitRetries = 2;

  /// 服务端没给 `Retry-After` 时的退避阶梯。
  static const List<Duration> _kRateLimitBackoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  /// 一次用户提问的主循环。
  ///
  /// ## 为什么不拆（2026-10-12 评估过，与 9 月那次结论一致）
  ///
  /// 这个方法 340 行，是全文件第二大的成员（仅次于 `AgentLoop` 类本身）。
  /// `plans/2026-09-09-agent-loop-decomposition.md` 当时就评估过并**明确
  /// 推迟**：「`_resolve`… 是调度器的一部分，和 `_run` / `_executeRound`
  /// 一样属于 loop 本体。把它塞进 `AgentToolContext` 等于把调度器整个暴
  /// 露给 executor，那正是这次重构要避免的方向。但先别做 —— 这一步是设计
  /// 而不是搬迁。」
  ///
  /// 具体原因：它内部有 `done` / `gotAnyChunk` / `retriedAfterDrop` /
  /// `rateLimitRetries` 四个跨作用域变量、两处 `turn--; continue`、三种不同
  /// 的 `return _stop(...)`。抽出去需要一个带约 5 种结果的返回类型 + 出入参，
  /// **把「用 `continue` 一眼看懂的循环控制」换成「用数据编码的控制流」**
  /// —— 可读性可能更差，不是为了拆而拆能解决的。
  ///
  /// **什么条件下该回来拆**：真要做子 agent 时。那需要 `_executeRound`
  /// 可重入，而那时的约束（多个 loop 共存、状态怎么隔离）会把边界定下来。
  /// 现在拆等于在一个不知道边界的形状上先刻一刀。
  Future<void> _run() async {
    // 一次用户提问的起点。下面的 `for (turn...)` 每转一圈是**一次 LLM
    // 请求**，而收工总结要报的是整次提问 —— 少了这一行，UI 只能拿到最后
    // 一条 TurnMetrics，也就是模型给最终文本的那次（没有工具调用），于是
    // 跑了 4 个工具的提问显示成「0 次调用」。
    //
    // 与下面 `retriedAfterDrop` / `rateLimitRetries` 用局部变量是同一个
    // 理由：`_run()` 就是「一次用户请求」的天然边界。
    _metrics.beginRun();
    var retriedAfterDrop = false;

    /// 这一次用户请求里 429 已经重试过几次。
    ///
    /// **局部变量而不是字段**，与 `retriedAfterDrop` 同构：`AgentLoop` 按
    /// serverId 长期持有、跨多次面板开关复用，做成字段就永不重置 —— 用掉
    /// 两次之后，这条 loop 此后每一次提问都零重试额度，而用户完全看不出
    /// 为什么。
    ///
    /// 局部则天然是「每次用户请求重置一次」：模型内部那些轮次共用同一份额度
    /// （限流通常持续几十秒、横跨好几轮，每轮重置等于把一次限流拖成几十次
    /// 徒劳的请求），而用户下一次提问重新给满。
    var rateLimitRetries = 0;

    for (var turn = 0; turn < maxTurns; turn++) {
      // 计量：每次进入循环体就开一条新的 TurnMetrics。
      //
      // **已知的「空记录」情形**：下面 catch 块里的 context-overflow 重试路径
      // 会 `turn--; continue;` 回到这里重新走一遍，于是 startTurn() 在同一
      // 逻辑轮次里被调用两次，产生一条从未被 finishTurn() 收尾、字段全 0 的
      // 记录。这不是 bug —— 那一轮确实被打断重试过，留一条空记录如实反映
      // 了这一点，比悄悄吞掉更诚实。
      final turnSw = Stopwatch()..start();
      // `_metric()` 的设计承诺是「所有采集点都吞异常，度量绝不能弄坏会话」
      // ——`startTurn()` 是纯 List 操作、几乎不可能抛，但承诺就该完整覆盖，
      // 不该因为「这次大概率不出错」就裸调。
      try {
        _metrics.startTurn();
      } catch (_) {}
      // 抢跑状态是逐轮的：上一轮的抢跑早在轮末被消费或丢弃过
      // （`_executeRound` / `_discardSpeculations()`），这里清空是防御性的
      // 收尾，不是主要的清理路径。
      _speculations.clear();
      _flushedTextLen = 0;
      // 压缩「一轮最多一次真实调用」的旗子，理由见字段上的注释。
      _compactedThisTurn = false;
      _askedThisTurn = false;

      void finishTurn() {
        _metric((t) {
          t.turnTotalMs = turnSw.elapsedMilliseconds;
          t.historyTok = _estimateTokens();
        });
      }

      // 计量：这一轮还没发请求就被取消，`finishTurn()` 不会被调用——
      // `turnTotalMs` 留 0 表示「这轮没跑完」，不参与耗时统计。
      if (_cancelRequested) return _stop(AgentStopReason.userCancelled);
      if (_estimateTokens() > tokenBudget) {
        return _stop(AgentStopReason.tokenBudget);
      }

      // 用户可能在上一轮之后去设置里改了自定义说明。放在这里而不是 `send()`
      // 里：长会话中途改设置也该生效，不必等下一次提问。
      _refreshSystemPrompt();
      _setState(AgentLoopState.thinking);

      // 发给 provider 前先把图片附件物化成 base64 —— provider 的消息拼装是
      // 同步函数，没法在里面 await 读文件。`_history` 本身不变（不带 b64
      // 的版本才能安全归档），只有这一份「上线版」多带 base64。
      final capped = capHistoryImages(_history);
      final wire = attachmentStore == null
          ? capped
          : await materializeAttachments(capped, attachmentStore!);
      // 这一轮是否已经产出过增量。context-overflow 的 drop 重试只在
      // **一个 chunk 都没到**时才允许 —— 已经有文本渲染在屏幕上了还重来
      // 一次，用户会看到同一段话说两遍，甚至前后矛盾的两段。
      var gotAnyChunk = false;
      final streamSw = Stopwatch()..start();
      final connBase = debugNewConnectionCount;
      // 提到 try 外面：catch 要能看见它，好分辨「这一轮根本没交付」与
      // 「交付完了之后流才在收尾阶段出错」。
      AIResponse? done;
      try {
        await for (final chunk
            in providerProvider().completeWithToolsStream(
                wire,
                filterByUnlockedGroups(
                    toolSpecsProvider(), _unlockedToolGroups),
                sessionKey: sessionKey)) {
          // 流本身不认识取消——它只在乎 provider 那头还有没有字节过来。
          // 不在这里截住的话，`cancel()` 之后文本仍会一路涌进
          // `_streamingText`，Stop 按钮形同虚设。
          if (_cancelRequested) break;
          if (!gotAnyChunk) {
            // 首个 chunk：不论文本还是 tool-call-ready，都算「首字」。
            _metric((t) => t.ttftMs = streamSw.elapsedMilliseconds);
          }
          gotAnyChunk = true;
          switch (chunk) {
            case TextDelta(:final text):
              _streamingText = (_streamingText ?? '') + text;
              _safeNotify();
            case ToolCallReady(:final call):
              // 参数已就绪。`tool_partition.dart` 的 `canSpeculate` doc
              // comment 已经指出这里原先的注释与实现不符：分桶（parallel
              // 桶的成员资格）是逐条独立可判的，唯一依赖「整批组成」的是
              // 批量审批卡，而那只影响串行桶——并行桶的抢跑不需要等看到
              // 整批。所以只读且已放行的调用在这里就起飞，不必等 StreamDone。
              _maybeSpeculate(call);
            case StreamDone(:final response):
              done = response;
          }
        }
        if (_cancelRequested) {
          // 上面那个 break 落地时 `done` 十有八九是 null——这是取消导致的
          // 正常提前退出，不是下面那句「provider 违反契约」的情形，顺序不能
          // 反：先认取消，再谈契约。已经流出来的半截话要落成正式事件，
          // 否则用户读到一半的文字会凭空消失。
          // 计量：流没走完就被取消，同样不调 finishTurn() —— 理由同上。
          _flushStreamingText();
          // 抢跑可能已经在流式期间起飞了，但这一轮不会再往下走到
          // `_executeRound`（那是唯一会消费 `_speculations` 的地方）——
          // 不在这里收尾，那些 Future 会成为没人 await 的孤儿，它们的错误
          // 会变成未捕获异常。
          _discardSpeculations();
          return _stop(AgentStopReason.userCancelled);
        }
        if (done == null) {
          // provider 违反了「StreamDone 恰好一次」的契约。当成错误而不是
          // 当成「模型什么都没说」—— 后者会让 loop 判定 completed 并把一轮
          // 真实的失败伪装成正常结束。
          throw StateError('stream ended without StreamDone');
        }
      } catch (e, st) {
        // `StreamDone` 已经到手：模型这一轮已经完整交付，之后流上再抛什么
        // 都只是收尾阶段的传输错误（兼容端点不发 chunked 终止块就关连接是
        // 常见现象，dart:io 抛 `HttpException: Connection closed while
        // receiving data`）。判成失败的话，用户读到一段完整的回答之后还要
        // 再吃一个红色错误气泡，这一轮的 usage 也跟着一起丢 —— 2026-09-14
        // 真机上看到的 `本轮 0 token` 就是这么来的。
        //
        // provider 那层已经吞掉了自家的收尾错误（见各 parser 的
        // `sawCompletion`），这里守的是更靠里的一道：provider 是可插拔的，
        // 任何一家只要把 StreamDone 发出来了，这一轮就算数。
        //
        // **取消优先**：break 出来时 `done` 十有八九是 null，但万一
        // StreamDone 与 cancel 撞在一起，语义上仍然是用户取消，走下面那条
        // 既有的路径。
        if (done == null || _cancelRequested) {
          // 已经流出去的文本不能丢：用户读到了，它就该留在记录里。
          _flushStreamingText();
          // 同上：这一轮既然进了 catch，就不会再走到 `_executeRound`，
          // 抢跑的 Future 必须在这里被收尾，否则变成未捕获异常。
          _discardSpeculations();
          if (!gotAnyChunk &&
              !retriedAfterDrop &&
              _looksLikeContextOverflow(e) &&
              _dropOldestOutput()) {
            retriedAfterDrop = true;
            turn--; // 重试不算一轮
            continue;
          }
          // 429：退避之后重来。与上面那条重试共用 `!gotAnyChunk` 这道守卫 ——
          // 已经有文本渲染在屏幕上了还重来一次，用户会看到同一段话说两遍。
          // 实践中 429 总是在建连阶段就抛出（一个 chunk 都没有），这道守卫
          // 是为「兼容端点在流中途改口回 429」那种畸形情形兜底的。
          if (!gotAnyChunk &&
              e is RateLimitedException &&
              rateLimitRetries < _kMaxRateLimitRetries) {
            final wait = e.retryAfter ?? _kRateLimitBackoff[rateLimitRetries];
            rateLimitRetries++;
            if (await _waitOutRateLimit(wait, e.message)) {
              turn--; // 重试不算一轮
              continue;
            }
            // 等待期间被取消 / dispose：不算错误，走取消那条路。
            return _stop(AgentStopReason.userCancelled);
          }
          _errorStack = st;
          // `e.toString()` alone (e.g. a bare TypeError's "Null check
          // operator used on a null value") carries no location — the user
          // can reproduce it but can't tell us which of the many `!` in the
          // codebase fired. `describeError` appends the first project stack
          // frame (if one can be found) so a real-device repro turns into an
          // actionable file:line instead of a dead end.
          _errorMessage = describeError(e.toString(), st);
          finishTurn();
          return _stop(AgentStopReason.error, failed: true);
        }
      }

      // 不需要 `!`：try 里要么给 `done` 赋了非 null 要么抛，catch 里 `done`
      // 为 null 的那条路一定 return / continue —— 分析器自己推得出来。
      final resp = done;
      _metric((t) {
        t.streamTotalMs = streamSw.elapsedMilliseconds;
        t.newConnCount = debugNewConnectionCount - connBase;
      });

      _streamingText = null;

      _totalUsage = _totalUsage + resp.usage;
      // 跨会话累计。**provider 名在这里现取**，不能用 loop 创建时的那个：
      // 切模型是运行期的（`provider_switch.dart`），而 loop 按 serverId
      // 长期持有、活得比一次切换久得多。记错桶会让「哪个模型用得多久」这个
      // 唯一的可行动维度失真。
      //
      // fire-and-forget：这是纯展示用的计数，不该把一轮响应拖到写盘完成。
      // `add` 内部已对空用量短路，服务端不给 usage 时不会产生垃圾桶。
      //
      // **整段都在 `if (usageTotals != null)` 里**：没注入累计时快照必须
      // 保持为空。否则页脚会显示一个只是「本会话总量」的「累计」，
      // 看起来像跨会话累计已经工作，实际是假的 —— 这是本实现第一版真实
      // 犯过的错，靠一条「没注入时不显示」的测试抳住。
      if (usageTotals != null) {
        unawaited(
            usageTotals!.add(providerProvider().displayName, resp.usage));
        // 快照就地更新 —— 累加之后 total 变了，而 UI 不会为此收到通知
        // （prefs 不是 Listenable）。写在这里而不是靠重建时现读，是为了让
        // 页脚保持同步读取。
        _cumulativeSnapshot = _cumulativeSnapshot + resp.usage;
      }
      // 真实输入量，给 `_estimateTokens` 当下界。**用 totalInput 而不是
      // inputTokens**：后者不含缓存命中，长会话里缓存命中占大头，拿它当
      // 地板等于没有地板。
      _lastRealInput = resp.usage.totalInput;
      _metric((t) {
        t.inputTok = resp.usage.inputTokens;
        t.cachedTok = resp.usage.cachedTokens;
        t.outputTok = resp.usage.outputTokens;
        t.toolCallCount = resp.toolCalls.length;
      });

      // 只落**尚未落过**的尾巴——抢跑起飞前会先把 `_streamingText` 提前落成
      // 事件（`_flushStreamedTextSoFar`），`_flushedTextLen` 记着落到哪了。
      // 没发生过抢跑时 `_flushedTextLen` 是 0，这里退化成原来的「整段落一
      // 次」，行为不变。
      final tail = resp.text.length > _flushedTextLen
          ? resp.text.substring(_flushedTextLen)
          : '';
      if (tail.isNotEmpty) _events.add(AssistantTextEvent(tail));

      if (!resp.hasToolCalls) {
        _history.add(AIMessage(role: 'assistant', content: resp.text));
        finishTurn();
        // 这一轮没有 tool_call，`_executeRound` 不会被调用——若抢跑仍然
        // 起飞了（理论上不该发生：`ToolCallReady` 与 `resp.toolCalls` 应当
        // 一一对应，但 provider 违反契约的可能性不为零），必须在这里收尾，
        // 不能指望后面的路径来处理。
        _discardSpeculations();
        // 注入点 B:模型正要收工,但用户排了话。此时必须继续跑——loop 一旦
        // 停下,队列里那句话就没有任何东西会再来消费它。
        //
        // 这里没有配对问题:这一轮没有 tool_call,历史末尾是一条纯文本的
        // assistant 消息。
        if (_flushPendingInputs()) continue;
        if (_planQueue.isNotEmpty) return _stopWithProposal();
        // 先落终态再提炼：反过来的话，用户看完结论想接着问，面板还在为
        // 一个可选功能转圈 —— 拿主路径的延迟换附加功能，不划算。
        //
        // 不 await：`_maybeProposeKnowledge` 内部自己吞掉全部异常，且用
        // `_disposed` / `_stopReason` 两道守卫处理回来晚了的情况。
        _stop(AgentStopReason.completed);
        unawaited(_maybeProposeKnowledge());
        return;
      }

      // **叙述不进回填历史。**
      //
      // 带 tool_call 的 assistant turn 里，`resp.text` 必然是「我接下来要做
      // 什么」——答案在最后一轮（那条不带 tool_call，走上面 2038 行那支，
      // 正文照常保留）。
      //
      // 同一个问题修过两次都失败了：先在两条内置技能的正文开头写
      // "Keep it to a few lines"，再在 system prompt 加 "Never announce what
      // you are about to do"（那条规则现在还在，就在这个文件里）。两次都是
      // 加文字，两次模型都照样违反。
      //
      // 根因是自我强化：叙述进了 _history，下一轮原样发回模型，模型看到
      // 自己上一轮在叙述就接着叙述——轮次越多越严重，这正是真机转录里
      // 「越往后废话越多」的形状。断掉这个循环比再加第三条规则更根本。
      //
      // 用户看得见的那份不受影响：UI 走 `_events`（上面刚 add 过
      // AssistantTextEvent），与 `_history` 是两条路。这与 CommandOutput
      // 拆出 displayStdout 是同一手法——给人看的和给模型吃的本来就该分开。
      //
      // 回退方式：把 content 改回 `resp.text` 即可，没有别的地方依赖它为空。
      _history.add(AIMessage(
        role: 'assistant',
        content: '',
        toolCalls: resp.toolCalls,
      ));

      // 压缩要在这里起飞，不能拖到轮末的 `_dropOldOutputsIfNeeded()`。
      //
      // 这是唯一一个「起飞不会踩到任何东西」的窗口：assistant 消息（带
      // toolCalls）已经落进 `_history`，这一轮的 tool_result 消息还没落进
      // 去。`_compact()` 只会改 `_history[1..cut)`，`cut` 由
      // `findCompactionCut` 算出且天生 `<= history.length`（当前长度，不含
      // 还没 append 的 tool_result）——而 `_executeRound` 全程不碰
      // `_history`（见文件顶部工具执行链路的说明），两者互不相干，之后再
      // 把 tool_result 接到尾部也不会让 `[1, cut)` 里的下标失效。挪到
      // assistant 消息之前起飞不行：那时候还没有这一轮的 toolCalls 可看，
      // `findCompactionCut` 的「不能切在 tool 消息上」这条不变量无从谈起；
      // 挪到 tool_result 之后（即维持原来轮末那条路）就是现状——退回串行。
      final compactFuture = _maybeCompactConcurrently();

      final results = await _executeRound(resp.toolCalls);

      // 工具跑得快、压缩还没回来时，**必须等**，不能先把 tool_result 接上去
      // 就进入下一轮。
      //
      // 这不是「让快的等慢的」这么简单的取舍——不等的后果不是「少省几秒」，
      // 是「整段收益作废外加一次可能的会话中断」：下一轮开头会立刻重新估算
      // token 数，如果压缩还没 `replaceRange` 完，这次估算看到的是压缩前的
      // 大小；本该被这次压缩腾出来的预算完全体现不出来，压缩等于白跑一次
      // 真实的模型调用。更糟的是，若这一轮历史本来就顶着 `tokenBudget`
      // 的上限，下一轮开头 `_estimateTokens() > tokenBudget` 的硬停检查会
      // 直接把会话打断——用户等到的不是「省了几秒」而是一次意外中止。
      // 省下的时间至多是 `min(工具执行耗时, 压缩耗时)` 那一段重叠，不是把
      // 压缩的耗时整个藏起来；这里稳赚不亏的部分只有「重叠」这一段，等待
      // 从不倒贴。
      await compactFuture;

      _history.add(AIMessage(role: 'tool', content: '', toolResults: results));

      if (_consecutiveInvalidArgs >= _kMaxConsecutiveInvalidArgs) {
        return _stop(AgentStopReason.invalidArgs, failed: true);
      }
      // 计量：工具都跑完了才被取消，同样不调 finishTurn() —— 理由同上，
      // 取消发生的时刻是用户按 Stop 的时刻，不是这一轮真实的耗时。
      //
      // **discard 必须在这条早退之前**：取消恰好落在 `_executeRound` 刚要
      // 跑并行桶那一批时，那批里已经起飞过的抢跑一次都不会被
      // `_takeSpeculation` 处理（`_executeRound` 内部的 `if
      // (_cancelRequested) break;` 直接跳出），而下面那处兜底 discard 在这
      // 行 return 之后，永远够不到。漏掉的后果不是崩溃（起飞时挂的
      // `.catchError` 已经让那个 Future 恒以成功态完成），而是一条已经在远端
      // 真跑过的只读命令被静默遗弃、判据从没被核对过。
      if (_cancelRequested) {
        _discardSpeculations();
        return _stop(AgentStopReason.userCancelled);
      }

      // 注入点 A:这一轮的 tool_result 已经在上面补齐,配对完整,可以插
      // user 消息了。
      _flushPendingInputs();

      // 兜底：正常情况下 `_executeRound` 已经把这一轮起飞过的抢跑全部
      // 消费掉了（`_takeSpeculation` 命中或判据不符）。这里再清一次是为了
      // 「起飞了、但最终没出现在 `resp.toolCalls` 里」这种边界——理论上不
      // 该发生（`ToolCallReady` 与 `resp.toolCalls` 应当一一对应），一旦
      // 真的发生，不清空就是孤儿 Future。
      _discardSpeculations();

      await _dropOldOutputsIfNeeded();
      finishTurn();
    }
    _stop(AgentStopReason.maxTurns);
  }

  /// 会用到远端连接、因而值得提前建连接的工具。
  ///
  /// **白名单，不是黑名单。** 黑名单（「排除 `kLocalToolNames` 那四个」）会
  /// 漏掉 `save_skill` —— 它存在手机上、不碰 SSH，却不在那四个里面。而且
  /// 白名单让将来新增的工具默认**不**预热：漏掉一次优化，而不是白建一条
  /// 连接。
  ///
  /// `download_file` / `upload_file` 也在内。它们走 SFTP 而不是
  /// `runnerProvider`，但 `sftpOpsProvider`（`terminal_screen.dart:1907`）
  /// 拿的是**同一个 `AgentExecChannel` 的同一条 `SSHClient`** —— 预热帮得到
  /// 它们，而且它们是全部工具里等待窗口最长的那几个（必须审批 + 传输本身
  /// 耗时）。
  ///
  /// `copy_between_servers` **不**在内，理由是取不到目标机：它的参数是
  /// `from_server` / `to_server`，而 [_prewarmFor] 只认 `server`。要覆盖它
  /// 得让预热理解第三种参数形状，收益不值这个复杂度。
  static const Set<String> _kPrewarmTools = {
    'bash',
    'read_file',
    'glob',
    'grep',
    'run_saved_command',
    'write_file',
    'edit_file',
    'download_file',
    'upload_file',
    'run_background',
    'check_job',
  };

  /// 并发配额的分组键：这条调用打的是哪台机器。null = 当前会话机。
  ///
  /// **绝不能写成 `args['server'] as String?`。** `args` 是
  /// `Map<String, dynamic>`，值直接来自模型吐的 JSON，而模型给出
  /// `{"server": 123}` 是被认过的现实路径 —— `resolveServerTarget`
  /// （`server_targets.dart:71`）专门为它写了一条 `raw is! String` 的分支，
  /// 回一句 invalid-arguments 让模型自纠。
  ///
  /// 裸转型会绕过那道防御，把一次可恢复的参数错误变成整轮失败：`keyOf` 在
  /// `runWithLimits` 的 `pending.removeWhere` 谓词里被**同步**调用，抛出的
  /// TypeError 一路穿过 `_executeRound` 到 `_run()`，而 `send()` 里的
  /// `await _run()` 没有 try/catch —— 会话停在 running 态，连
  /// `_errorMessage` 都写不上。
  ///
  /// 非字符串归到「当前会话机」那一组：它只影响这条调用占谁的名额，而随后
  /// `resolveServerTarget` 会给出正经的错误文案，一条都执行不了。
  static String? _targetKeyOf(ToolCall c) {
    final v = c.args['server'];
    return v is String ? v : null;
  }

  /// 为一条**不可抢跑**的调用提前建好连接。
  ///
  /// 全程静默：任何失败都不记 `_errorMessage`、不进事件流。真正的错误由随后
  /// 的 `run()` 报出 —— 预热引入第二条错误路径等于同一个失败在面板上说两遍。
  Future<void> _prewarmFor(ToolCall call) async {
    final prewarm = prewarmProvider;
    if (prewarm == null) return;
    if (!_kPrewarmTools.contains(call.name)) return;

    String? serverId;
    final raw = call.args['server'];
    if (raw != null) {
      // 跨机：名字 → id 的解析是异步的（要读服务器清单）。这里 await 得起
      // —— 整个方法是 fire-and-forget 的，没有人在等它。
      final servers = await serverListProvider?.call() ?? const [];
      final target = resolveServerTarget(raw, servers);
      // 解析失败不吭声：随后的正式执行会把同一个错误回填给模型，
      // 预热不插嘴。
      if (!target.ok) return;
      serverId = target.serverId;
    } else {
      // 模型没给 `server` 时，归属可能记在任务事件上 —— 必须与执行侧
      // （`checkJob`）的解析顺序一致：显式 `server` > 事件记录的归属 > 当前
      // 会话。只在带 `job_id` 的工具上查事件：`bash` 没有这个参数，查了也
      // 查不到，白白多一次遍历。
      //
      // 不这样做的后果正是本类审查发现的浪费：跨机 `check_job(job_id)` 会
      // 预热**当前会话**那台的连接，而 `checkJob` 实际用的是事件里记的
      // id-2 —— 预热了一条根本不会用的连接，真正需要的那条仍是冷的。
      final jobId = call.args['job_id'];
      if (jobId is String) {
        serverId = _events
            .whereType<BackgroundJobEvent>()
            .where((e) => e.jobId == jobId)
            .lastOrNull
            ?.serverId;
      }
    }
    await prewarm(serverId);
  }

  /// 收到 `ToolCallReady` 时尝试让这条调用在流式期间就抢跑。
  ///
  /// 判据（`rules`/`mode`/`cwd`）在这一刻被快照进 [_Speculation]——
  /// `StreamDone` 之后 [_takeSpeculation] 会重新取一遍同样的判据做比较，
  /// 不一致就整个丢弃重跑（见该方法注释）。这里只管起飞，不管落地。
  void _maybeSpeculate(ToolCall call) {
    // 用户已经按了 Stop：这一轮接下来大概率会在 `_cancelRequested` 检查点
    // 提前退出，起飞一条注定要被丢弃的命令没有任何收益，只会多一次远端
    // 执行（抢跑的都是只读命令，多跑一次无副作用，但也没必要）。
    if (_cancelRequested) return;

    // 并发上限对抢跑同样生效——抢跑不是绕过它的后门。而且必须与并行桶用
    // **同一套两层配额**：只改并行桶而这里仍是全局 `_kMaxParallel` 的话，
    // 跨机抢跑依旧被挤在 3 里，per-target 分离等于白做。
    //
    // key 的取法与 `_executeRound` 里 `runWithLimits` 的 `keyOf` 必须一致
    // （`args['server']`，缺省 = 当前会话机）。两边不一致会让「抢跑放行的」
    // 与「并行桶放行的」是两批不同的调用。
    if (_speculations.length >= _kMaxGlobalParallel) return;
    final specKey = _targetKeyOf(call);
    final sameTarget =
        _speculations.where((s) => _targetKeyOf(s.call) == specKey).length;
    if (sameTarget >= _kMaxParallel) return;

    final rules = rulesProvider();
    final mode = modeProvider();
    // 与 `_executeCommandTool` 里那次判定用同一条 TOCTOU 防护：跨机调用
    // 根本不取当前 tab 的 cwd（那对另一台机器没有意义），只取一次、判定和
    // 执行共用同一个值。
    final cwd = call.args['server'] == null ? cwdProvider?.call() : null;

    if (!canSpeculate(call, rules: rules, mode: mode, cwd: cwd)) {
      // 抢不了跑，但这条命令**已经确定要执行**（`ToolCallReady` 到手了）。
      // 它接下来要么等用户点审批、要么排在串行桶后面 —— 那段时间连接闲着
      // 没建。fire-and-forget 一次预热把 connMs 藏进去。
      //
      // `catchError` 是必需的：未被观察的 Future 抛错会变成未捕获异常，
      // 这是抢跑那一期踩过的同一个坑。
      unawaited(_prewarmFor(call).catchError((_) {}));
      return;
    }

    // 起飞前必须先把已经流出来的文字落成正式事件——`agent_view.dart` 是
    // 「先渲染 `events`，再在末尾追加流式气泡」的顺序，工具卡片属于
    // `events`。如果不在这里提前落一次，卡片会插在文字前面：用户先看到一
    // 张来历不明的工具卡，然后才看到解释「为什么要跑这条命令」的那段话，
    // 顺序与 Claude Code 那种「文字 → 卡片 → 文字」的体验正好相反。
    _flushStreamedTextSoFar();

    final tm = ToolMetrics(tool: call.name, bucket: 'parallel')
      ..speculative = true;
    _metric((t) => t.tools.add(tm));

    // `.catchError` 把任何抛出转成一个 `isError` 的 `ToolResult`——
    // `_executeOne` 内部的 `_executeOneInner` 各分支已经把已知失败都包装
    // 成了 `ToolResult`，这里兜底的是未预料的异常，确保这个 Future 永远不
    // 会以「抛出」的方式完成。不这样做的话，`_takeSpeculation` 判据不符时
    // 拿它去 `unawaited(...)`「消费掉」会依然让异常变成未捕获异常——
    // `onError` 参数接的是那次 unawaited 消费自己的错误处理，防不住这个
    // Future 本身携带的错误。
    // 两参回调：栈要传给 `_describeToolError`，它对代码 bug 类异常（TypeError
    // / NoSuchMethodError）会附上前几帧 —— 否则那类错误只剩一句
    // `Null check operator used on a null value`，定位不到任何位置。
    final future = _executeOne(call, bucket: 'parallel', reuseMetrics: tm)
        .catchError((Object e, StackTrace st) => ToolResult(
              callId: call.id,
              content: describeToolError(e, st),
              isError: true,
            ));

    _speculations.add(_Speculation(
      call: call,
      future: future,
      rules: rules,
      mode: mode,
      cwd: cwd,
      metrics: tm,
    ));
  }

  /// 把当前尚未定稿的流式文本提前落成一条正式事件。
  ///
  /// 与 `_flushStreamingText()`（用于取消/异常路径）的区别：这个方法会
  /// 累加 [_flushedTextLen]，好让 `StreamDone` 时那句「只落尾巴」的逻辑
  /// 知道前面已经落过多少字符，避免同一段文字被落两次。
  ///
  /// 落完之后把 `_streamingText` 置为 **null**，不是空字符串——空字符串会
  /// 让面板在这一刻多渲染一个空的流式气泡；置 null 则完全不渲染，下一个
  /// `TextDelta` 的 `(_streamingText ?? '') + text` 与两种状态都兼容。
  void _flushStreamedTextSoFar() {
    final t = _streamingText;
    if (t == null || t.isEmpty) return;
    _events.add(AssistantTextEvent(t));
    _flushedTextLen += t.length;
    _streamingText = null;
    _safeNotify();
  }

  /// `_executeRound` 在真正执行一条调用之前，先问一句「这条是不是已经抢跑
  /// 过了」。命中就直接复用那个 Future（不再跑第二遍），判据变了就丢弃、
  /// 交回 `null` 让调用方走正常路径重跑。
  Future<ToolResult>? _takeSpeculation(ToolCall call) {
    _Speculation? found;
    for (final s in _speculations) {
      if (!s.consumed && s.call.id == call.id) {
        found = s;
        break;
      }
    }
    if (found == null) return null;
    final s = found;
    s.consumed = true;

    // 这里的 cwd 判据只看 `args['server']` 是否为 null，**尚未纳入「事件
    // 归属」这一档**（`_prewarmFor` / `checkJob` 已经纳入）。两者在「跨机
    // `check_job` 不带 server」时会分歧：执行侧因事件里的 serverId 而取
    // `null`，这里却取 `cwdProvider()`（当前会话目录）。
    //
    // 当前无害，因为 `check_job` 不可抢跑（不在 `canSpeculate` 放行集合里），
    // 根本不会走到抢跑判据比较。但若将来把 `check_job` 加进可抢跑集合，
    // **必须同步这里的算法**——否则同一条调用起飞时快照的 cwd 与落地时重算
    // 的 cwd 永远不等，抢跑结果会被无条件判为「判据变了」而丢弃，白白
    // 白跑一趟远端（这正是本文件多处注释反复警告的「判据分叉」）。
    final cwd = call.args['server'] == null ? cwdProvider?.call() : null;
    // **按值比较，不是 `identical`。** 理由见 `_Speculation` 的 dartdoc ——
    // 生产的 `rulesProvider()` 每次都返回一个新对象，身份比较在那里恒假。
    final stillMatches = s.rules == rulesProvider() &&
        s.mode == modeProvider() &&
        s.cwd == cwd;

    if (stillMatches) {
      s.metrics.speculativeHit = true;
      return s.future;
    }

    // 判据变了（典型如用户中途切了模式，或 cwd 变了）：抢跑的结果不能再
    // 信——但那个 Future 已经在真的跑一条远端命令了，不能不管它，否则它的
    // 错误会变成未捕获异常（Future 无人 await/观察时 Dart 会把错误上报成
    // uncaught）。`then((_) {}, onError: (_) {})` 只是为了「观察」它，
    // 结果本身已经没用了，交给调用方走正常路径重新跑一遍——抢跑的定义就是
    // 只读命令，重跑没有副作用。
    unawaited(s.future.then((_) {}, onError: (_) {}));
    _markSupersededFor(call);
    return null;
  }

  /// 把这条调用对应的、已经渲染出来的工具卡标记为「抢跑落空」。
  ///
  /// 从尾部往前找第一条 `callId` 匹配且还没被标记过的。
  ///
  /// **这里原来断言「卡此刻必然已经在 `_events` 里」，那是错的。** 审查查实：
  /// `_executeCommandTool` 里 `ToolCallEvent` 的创建排在
  /// `await serverListProvider?.call()` **之后**，所以抢跑起飞并不意味着卡
  /// 已经落地。本机调用现在不再走那次 await（见 `_executeCommandTool` 开头
  /// 的说明），卡确实是同步建的；但**跨机的抢跑调用仍要过它**，那种情形下
  /// 判据落空得足够早时，这里会找不到卡、静默什么都不标记，随后重跑建出
  /// 第二张，事件流里就留下两张 callId 相同、都不是 superseded 的卡。
  ///
  /// 找不到就什么都不做是刻意的：宁可少一个视觉标记，也不要为了标记去猜
  /// 一张还不存在的卡。
  ///
  /// `!superseded` 这个条件是防御性的：正常情况下一次抢跑只会被标记一次，
  /// 但同一个 callId 理论上可能出现在事件流的更早位置（例如同一工具在更早
  /// 的轮次里跑过），从尾部找 + 只找未标记的两条一起保证标到的是这一次。
  void _markSupersededFor(ToolCall call) {
    for (var i = _events.length - 1; i >= 0; i--) {
      final e = _events[i];
      if (e is ToolCallEvent && e.callId == call.id && !e.superseded) {
        e.superseded = true;
        _safeNotify();
        return;
      }
    }
  }

  /// 收尾所有还没被 `_takeSpeculation` 处理过的抢跑。
  ///
  /// 调用点是三处「这一轮不会再走到 `_executeRound`」的路径：取消、异常、
  /// 轮末兜底。**必须消费每一个未被观察的 Future**——`.catchError` 保证了
  /// 它不会真的抛出，但即使结果是正常返回，一个从未被 await/then 过的
  /// Future 本身不会有问题；真正的风险在于 [_executeOne] 内部若在
  /// `.catchError` 生效前就同步抛出（理论上不会，但这里不假设），那个错误
  /// 需要有地方接住。用 `then((_) {}, onError: (_) {})` 而不是简单丢弃，
  /// 就是为了兜住这最后一层。
  void _discardSpeculations() {
    for (final s in _speculations) {
      if (!s.consumed) {
        s.consumed = true;
        unawaited(s.future.then((_) {}, onError: (_) {}));
      }
    }
    _speculations.clear();
  }

  /// 执行一轮的全部 tool calls，返回**与 [calls] 等长、同序**的结果列表。
  ///
  /// 等长是硬要求：wire protocol 要求每个 `tool_use` 恰好配一个
  /// `tool_result`（`anthropic_provider.dart` 的 `_buildToolMessages`）。
  /// 少一个，这段历史在下一次请求时就会被服务端 400 拒掉 —— 而那次拒绝
  /// 发生在用户「取消之后又问了一句」的时候，看起来像是新问题引起的，
  /// 极难归因到上一次取消。
  ///
  /// **没拆的理由同 [_run]** —— 两者是同一类调度器，见那里的「为什么不拆」。
  /// 子 agent 需要它可重入时一并设计。
  Future<List<ToolResult>> _executeRound(List<ToolCall> calls) async {
    // 单个调用没有分桶的意义，走原来那条路，少一次正则判定。
    if (calls.length == 1) {
      // 并行/串行两条分桶路径在每次派发前都会看 `_cancelRequested`
      // （下面的循环），这条快路径原本没有对应检查——取消恰好落在流式
      // 响应的最后一个 chunk 与这里之间时，一条真实的远端命令（例如
      // `run_background` 起的 `apt upgrade` 链）会在 `stopReason` 已经是
      // `userCancelled` 的情况下照样执行下去。返回值必须仍是长度为 1、
      // `isError: true` 的结果——`results.length == calls.length` 是硬
      // 不变量（见本方法顶部注释），少一个会让下一次请求被服务端 400。
      // 文案与下面多调用兜底路径的措辞保持一致。
      if (_cancelRequested) {
        return [
          ToolResult(
            callId: calls.first.id,
            content: 'Not executed: the session was cancelled before this '
                'tool ran.',
            isError: true,
          ),
        ];
      }
      // 这条调用如果在流式期间已经抢跑过（`canSpeculate` 判定与这里的
      // 「单条调用」完全独立——抢跑不知道，也不需要知道，这一轮总共有几个
      // 调用），直接复用那个 Future，不再跑第二遍。
      final speculated = _takeSpeculation(calls.first);
      if (speculated != null) return [await speculated];
      return [await _executeOne(calls.first, bucket: 'serial')];
    }

    // 与 `_executeCommandTool` 里那次判定用同一个 cwd 快照。分桶结果只用于
    // 决定并发，真正的放行/弹卡判定仍在执行路径内部发生。
    final cwd = cwdProvider?.call();
    final part = partitionToolCalls(
      calls,
      rules: rulesProvider(),
      mode: modeProvider(),
      cwd: cwd,
    );

    final byIndex = <int, ToolResult>{};

    // local 桶最先跑：它们不碰 SSH、不需审批、与同轮任何调用都没有先后
    // 依赖。放在批量审批卡之前是重点 —— 那张卡会 await 到用户点击为止，
    // 排在它后面等于让一次零成本的本地查询等上人类反应时间。
    for (final idx in part.local) {
      if (_cancelRequested) break;
      try {
        byIndex[idx] = await _executeOne(calls[idx], bucket: 'local');
      } catch (e, st) {
        _errorStack = st;
        byIndex[idx] = ToolResult(
          callId: calls[idx].id,
          content: describeToolError(e, st),
          isError: true,
        );
      }
    }

    // 串行桶里若有**两条以上**需审批的调用，攒成一张卡整批问。逐张弹卡在
    // 跨机场景下要点 N 次，而并行弹 N 张卡用户分不清哪张对应哪台机器。
    //
    // 只有一条时不聚合 —— 那和现在的单张审批卡完全一样，多包一层只会让
    // 用户多点一次。
    var preApprovedIdx = <int>{};
    if (part.serial.length > 1) {
      final needApproval = <int>[];
      for (final idx in part.serial) {
        final c = calls[idx];
        // 这份名单只剩**一类**排除：确实需要审批，但聚合卡呈现不了关键
        // 信息（`download_file` / `upload_file` / `copy_between_servers` /
        // `save_skill` / `save_note` / `run_saved_command`）。它们的审批卡
        // 承载着聚合卡装不下的信息——文件大小、凭据边界红字警示、覆盖备份
        // 名、`save_skill`/`save_note` 的正文全文——而聚合卡（`_detail`）
        // 只认 `args['command']`/`args['path']`，三者都取不到就 fallback
        // 成裸的工具名。
        //
        // 原先还有第二类——`read_terminal` / `load_skill` / `set_plan` /
        // `list_servers`，根本不需要审批——现在已经不需要在这里排除了：
        // 它们进了 `tool_partition.dart` 的 `local` 桶，`_executeRound` 在
        // 走到这段批量审批逻辑之前就已经把它们跑完，压根不会出现在
        // `part.serial` 里，自然也就没有被聚合进卡片的可能。
        //
        // 不排除下面这六个的后果已经复现过两次：
        // - 传输类：一轮两个 `download_file`（其中一个是 `~/.ssh/id_rsa`）
        //   在 ask 模式下聚合成一张显示「download_file / download_file」的
        //   卡，批准后走 `preApproved: true` 跳过传输自己的审批——私钥下来
        //   了，而那条红字警示一次都没显示过。
        // - `save_skill`：`name`/`description`/`body` 三个字段全对不上
        //   `_detail` 认的 `command`/`path`，同样 fallback 成裸的
        //   `save_skill` 字符串。一轮 1 个 `save_skill` + 1 个需审批的
        //   `bash` 会聚合成一张卡，`save_skill` 那一行只显示这四个字，批准
        //   后两条都以 `preApproved: true` 执行，`save_skill` 自己的
        //   `_awaitApproval` 被跳过——用户全程只看到一行 "save_skill"，就把
        //   自己没读过的一段文字批准存进了每轮都要重发的永久 prompt。
        //   `save_note` 的 `body`/`heading`/`server` 同样对不上，同一个坑，
        //   一并排除。
        if (c.name == 'download_file' ||
            c.name == 'upload_file' ||
            c.name == 'copy_between_servers' ||
            c.name == 'save_skill' ||
            c.name == 'save_note' ||
            c.name == 'run_saved_command') {
          continue;
        }
        // `ask_user` 同样要排除，但理由与上面五个完全不同：它根本**不需要
        // 审批**（`CheckResult.decision` 恒为 `allow`），只是没有进
        // `tool_partition.dart` 的 `local` 桶（它要挂起等答案，`local` 桶的
        // 语义是「零成本、立刻出结果」），才落进这里假设的「serial 桶=都要
        // 审批」。不排除的话，一轮两个 `ask_user` 会被错当成需要用户确认的
        // 操作，聚合成一张审批卡——而它已经在自己的执行路径里挂起等答案了，
        // 这张卡永远不会有人来点。
        if (c.name == 'ask_user') {
          continue;
        }
        // `run_saved_command` 同样需要审批、但聚合卡呈现不了关键信息：
        // 它的参数是 `name` / `params`，而 `_detail` 只认
        // `args['command']` / `args['path']` —— 三个全对不上，聚合卡上只会
        // 剩一行裸的工具名，而真正要看的是展开后的完整命令。
        //
        // 根因其实是 `_detail` 去 args 里挖命令，而 `ToolCallEvent
        // .displayCommand` 早就是展开后的结果了。改那里能一次修好这一类
        // 全部五个工具，但那要动一个已稳定的组件，另开一篇。
        needApproval.add(idx);
      }
      // **只在 readOnly 模式下聚合。** 这条排除不是防御性代码，它挡一个真 bug：
      //
      // bypass：串行桶里**不全是「需审批」的东西** —— `write_file` /
      //   `edit_file` 是按**工具名**排除出并行桶的（它们有先后语义），bypass
      //   下它们照样落在串行桶里却无需任何审批。不排除的话会弹出一张本不该
      //   存在的卡。
      // ask：写文件走 `deferToPlan` 进提案队列，那条路径的语义是「攒起来
      //   最后一起批、现在先别执行」，与本卡「现在就决定、批准后立刻跑」直接
      //   冲突。ask 模式保持它自己的提案卡。
      //
      // **注意条件里不能留 `ask`**（2026-10-13）：旧命名下这里是 `ask`，因为
      // 旧 `ask` 才是「写文件弹审批卡」那一档。改名后写文件弹卡的是
      // `readOnly`，而新 `ask` 正好是旧 `plan`（写文件进提案队列）—— 若继续
      // 写 `ask`，两道 write_file 会被聚合成一张卡而不是进队列，把提案机制
      // 整个盖掉。
      //
      // 已知的小瑕疵：参数非法的调用（`check` 为 null 而落进串行桶）也会被
      // 收进卡片。它批准后会自己返回 isError，不会执行任何东西 —— 代价是
      // 卡上多列一条，不值得为它再引入一次参数预校验。
      if (needApproval.length > 1 &&
          modeProvider() == PermissionMode.readOnly) {
        final gate = Completer<bool>();
        _batchGate = gate;
        _events.add(BatchApprovalEvent(
          [for (final i in needApproval) calls[i]],
          [for (final i in needApproval) calls[i].args['server'] as String?],
        ));
        _setState(AgentLoopState.awaitingApproval);
        _safeNotify();

        final approved = await gate.future;
        if (!approved) {
          return [
            for (var i = 0; i < calls.length; i++)
              ToolResult(
                callId: calls[i].id,
                content: 'User rejected this batch. Nothing was executed.',
                isError: true,
              ),
          ];
        }
        preApprovedIdx = needApproval.toSet();
      }
    }

    // 并行桶：滑动窗口 + 两层配额。一条完成就补一条，不等整批
    // （原来是批次屏障：批 1 里一条 `journalctl` 跑 8 秒，批 2 那两条
    // `echo` 级的就干等 8 秒）。
    //
    // key 取目标机名（`server` 缺省 = 当前会话机）：per-target 配额挡的是
    // 单台机器上的连接窗口与负载，跨机之间互不相干。
    final parallelResults = await runWithLimits<ToolResult>(
      count: part.parallel.length,
      keyOf: (k) => _targetKeyOf(calls[part.parallel[k]]),
      perKeyLimit: _kMaxParallel,
      globalLimit: _kMaxGlobalParallel,
      shouldStop: () => _cancelRequested,
      task: (k) async {
        final idx = part.parallel[k];
        // 先问这一条是不是已经抢跑过——命中就复用，不必再跑一遍。
        final speculated = _takeSpeculation(calls[idx]);
        if (speculated != null) return await speculated;
        // **必须逐个 catch。** 调度器本身也兜了一层（那层只把结果留成
        // null），但 null 会被下面的兜底翻译成「会话被取消」——那对一条
        // 真的执行失败了的命令是错误的说法。两层都要。
        try {
          return await _executeOne(calls[idx],
              preApproved: preApprovedIdx.contains(idx), bucket: 'parallel');
        } catch (e, st) {
          _errorStack = st;
          return ToolResult(
            callId: calls[idx].id,
            content: describeToolError(e, st),
            isError: true,
          );
        }
      },
    );
    for (var k = 0; k < part.parallel.length; k++) {
      final r = parallelResults[k];
      if (r != null) byIndex[part.parallel[k]] = r;
    }

    // 串行桶：按模型给出的原顺序。审批要等人点，写文件有先后语义。
    for (final idx in part.serial) {
      if (_cancelRequested) break;
      byIndex[idx] = await _executeOne(calls[idx],
          preApproved: preApprovedIdx.contains(idx), bucket: 'serial');
    }

    return [
      for (var i = 0; i < calls.length; i++)
        byIndex[i] ??
            ToolResult(
              callId: calls[i].id,
              content: 'Not executed: the session was cancelled before this '
                  'tool ran.',
              isError: true,
            ),
    ];
  }

  /// [preApproved] 为 true 时跳过审批与转提案判定——调用方是 [approvePlan]，
  /// 用户已经在提案卡上批准过这一批了。若不跳过，写文件会再次被
  /// `deferToPlan` 拦回队列，变成无限循环。
  ///
  /// [bucket] 只用来打标（`ToolMetrics.bucket`），不影响执行——分桶已经在
  /// `_executeRound` 里发生过，这里只是把结果记下来供事后分析。
  ///
  /// 计时的口子开在这一层包装，而不是散在 `_executeOneInner` 内部：
  /// `execMs` 要扣掉 [ToolMetrics.waitApprovalMs]（等审批的时长绝不能算进
  /// 执行时长，见 `ToolMetrics` 的 dartdoc），扣减只需要在这里做一次减法，
  /// 不必把 Stopwatch 的启停穿进下面那棵大 switch 的每一条分支。
  Future<ToolResult> _executeOne(ToolCall call,
      {bool preApproved = false,
      String bucket = 'serial',
      ToolMetrics? reuseMetrics}) async {
    // 抢跑路径（`_maybeSpeculate`）在起飞前就已经建好并登记过一条
    // `ToolMetrics`（那条记录要在 StreamDone 之前就出现在面板上，等真正
    // 执行完成才建会来不及）。传了 `reuseMetrics` 就说明调用方已经登记过，
    // 这里不能再 `tools.add` 一遍，否则同一次调用在指标面板里出现两条。
    final tm = reuseMetrics ?? ToolMetrics(tool: call.name, bucket: bucket);
    if (reuseMetrics == null) _metric((t) => t.tools.add(tm));
    final sw = Stopwatch()..start();
    try {
      final r = await _executeOneInner(call, preApproved: preApproved, tm: tm);
      // `outBytes` 在**这一处**统一赋值，不在各 executor 的返回点各写一遍。
      //
      // 原先七个 executor 各自在「成功返回」那一行填它，于是所有失败分支
      // （传输取消/卡死、写入 exit 65、通用 catch……）恒为 0 —— 可那些失败
      // 消息同样进了 `ToolResult.content`、同样发给模型、同样烧真实 token。
      // 后果是分析「这条调用为什么让历史突然变大」时，一次输出很大但最终
      // 失败的操作看起来像零输出。而 `bash` 那条路又是另一个口径（exit != 0
      // 时照样计入 stderr），同一个字段对不同工具含义不同。
      //
      // 放在这里定义上也更准：这个字段的 dartdoc 是「回填给模型的输出字节
      // 数」，而 `r.content` 正是回填给模型的那段文本 —— 比 `ev.output`
      // 更贴切（后者不含 `_resolve` 可能前置的 warning）。
      try {
        tm.outBytes = r.content.length;
      } catch (_) {}
      return r;
    } finally {
      try {
        final raw = sw.elapsedMilliseconds - tm.waitApprovalMs;
        // 负值只可能来自记账错误：`waitApprovalMs` 的那些 Stopwatch 全部
        // 嵌套在这个 `sw` 区间**内部**，子区间不可能长于父区间。所以钳到 0
        // 之前先喊一声 —— 静默清零会让将来某次「把等待挪到 _executeOne 之外」
        // 的改动悄悄退化成永远为 0 的 execMs，而没有任何信号。
        if (raw < 0) {
          dlog('AgentMetrics', 'execMs 记账异常: elapsed='
              '${sw.elapsedMilliseconds} waitApproval=${tm.waitApprovalMs} '
              'tool=${call.name} —— 等审批的计时区间跑到了 _executeOne 之外？');
        }
        tm.execMs = raw < 0 ? 0 : raw;
      } catch (_) {}
    }
  }

  Future<ToolResult> _executeOneInner(ToolCall call,
      {bool preApproved = false, required ToolMetrics tm}) async {
    // **闸门：只受理当前档里声明过的工具名。**
    //
    // lean 档下 write_file / edit_file 的实现照样在这个文件里，只是没声明
    // 给模型。模型幻觉出一个没给它的工具名并不罕见（尤其小模型），少了这
    // 一句，那次幻觉会真的写文件。
    //
    // 错误消息里列**当前档、当前已解锁**的工具，不列全部 —— 告诉它有个它
    // 拿不到的 edit_file 只会让它反复尝试。这份清单必须与真正发给模型的那份
    // （见 `_runOnce` 里 `completeWithToolsStream` 的入参）走同一次
    // `filterByUnlockedGroups` 调用，否则会出现「闸门看来存在、但根本没发
    // 给模型」或者反过来的不一致。
    final active = activeToolNames.toList();
    if (!active.contains(call.name)) {
      _consecutiveInvalidArgs++;
      // 被锁住的工具要指名道姓说怎么解锁。只回「工具不存在」的话，模型会
      // 转去告诉用户「我做不到」—— 那正是 system prompt 里花一行文字防的
      // 失败模式，会从这个入口漏回来。
      final lockedGroup = groupOf(call.name);
      final content = lockedGroup != null
          ? '`${call.name}` is not active yet. Call '
              '`more_tools("$lockedGroup")` first, then retry.'
          : 'Unknown tool `${call.name}`. '
              'Available tools: ${active.join(', ')}.';
      return ToolResult(callId: call.id, content: content, isError: true);
    }
    return switch (call.name) {
      'write_file' =>
        _executeWriteFile(call, preApproved: preApproved, tm: tm),
      'edit_file' => _executeEditFile(call, preApproved: preApproved, tm: tm),
      'set_plan' => _executeSetPlan(call),
      'list_servers' => _executeListServers(call),
      'read_terminal' => _executeReadTerminal(call),
      'run_background' =>
        _executeRunBackground(call, preApproved: preApproved, tm: tm),
      'check_job' => _executeCheckJob(call),
      'list_jobs' => _executeListJobs(call),
      'download_file' =>
        _executeDownloadFile(call, preApproved: preApproved, tm: tm),
      'upload_file' =>
        _executeUploadFile(call, preApproved: preApproved, tm: tm),
      'copy_between_servers' =>
        _executeCopyBetweenServers(call, preApproved: preApproved, tm: tm),
      'load_skill' => _executeLoadSkill(call),
      'install_skill_assets' =>
        _skills.installSkillAssets(call, preApproved: preApproved, tm: tm),
      'search_skills' => _skills.searchSkills(call),
      'ask_user' => _ask.askUser(call),
      'save_skill' => _executeSaveSkill(call, preApproved: preApproved, tm: tm),
      'save_note' => _executeSaveNote(call, preApproved: preApproved, tm: tm),
      'web_fetch' => _executeWebFetch(call, preApproved: preApproved, tm: tm),
      'more_tools' => MoreToolsExecutors(this).moreTools(call),
      // **必须显式加 arm。** 默认分支是 `_executeCommandTool`，它走
      // `_resolve` + `checkCommand` —— 那条路判的是**命令文本**。app 工具
      // 落进去会被当成一条 shell 命令去匹配放行规则，既判错又可能意外命中
      // 远端的 allow 规则而被放行。权限判定在 AppExecutors 内部做。
      'app_state_read' => AppExecutors(this).stateRead(call),
      'app_settings_set' =>
        AppExecutors(this).settingsSet(call, preApproved: preApproved),
      'server_entry_create' || 'server_entry_update' || 'server_entry_delete' =>
        AppExecutors(this).serverEntry(call, preApproved: preApproved),
      'tunnel_create' || 'tunnel_close' =>
        AppExecutors(this).tunnel(call, preApproved: preApproved),
      'keybar_item_add' || 'keybar_item_remove' =>
        AppExecutors(this).keybar(call, preApproved: preApproved),
      'session_open' || 'session_close' =>
        AppExecutors(this).session(call, preApproved: preApproved),
      'layout_set' =>
        AppExecutors(this).layoutSet(call, preApproved: preApproved),
      'ssh_key_generate' || 'ssh_key_list' =>
        AppExecutors(this).sshKey(call, preApproved: preApproved),
      'navigate_to' =>
        AppExecutors(this).navigate(call, preApproved: preApproved),
      'saved_command_create' || 'saved_command_delete' ||
      'saved_command_list' =>
        AppExecutors(this).savedCommand(call, preApproved: preApproved),
      'skill_list' || 'skill_delete' || 'skill_set_enabled' ||
      'skill_update' || 'known_host_list' || 'known_host_forget' =>
        AppExecutors(this).manage(call, preApproved: preApproved),
      'sftp_list' || 'sftp_stat' || 'sftp_mkdir' || 'sftp_rename' ||
      'sftp_remove' || 'sftp_chmod' =>
        SftpExecutors(this).run(call, preApproved: preApproved),
      _ => _executeCommandTool(call, preApproved: preApproved, tm: tm),
    };
  }

  /// 执行 `set_plan`。不碰权限系统 —— 它什么都不执行、什么都不写，因此不走
  /// `checkCommand` / `checkFileWrite`，也不创建 `ToolCallEvent`（那是给
  /// 「有命令、有输出、可能要审批」的工具用的）。
  Future<ToolResult> _executeSetPlan(ToolCall call) async {
    final raw = call.args['steps'];
    if (raw is! List) {
      _consecutiveInvalidArgs++;
      return ToolResult(
          callId: call.id,
          content: 'Invalid arguments: `steps` must be an array of strings.',
          isError: true);
    }
    _consecutiveInvalidArgs = 0;

    // 元素用 '$e' 而不是 as String：模型偶尔会给出数字或布尔，为此把整轮
    // 判成参数非法不值得 —— 转成字符串展示出来就行。
    _plan = raw.map((e) => '$e').toList(growable: false);

    final cur = (call.args['current'] as num?)?.toInt();
    // 上界是 length 而不是 length - 1：`current == length` 表示「全部做完」，
    // 清单渲染成每一步都打勾、没有「正在做」的那一行。钳到 length - 1 的话
    // 最后一步永远停在「正在做」，一次排查结束了清单还在转 —— 而工具描述
    // 明确让模型在收工时发这个值。
    //
    // 安全性：`_planCurrent` 不做索引用（全仓库只透传给 PlanUpdatedEvent
    // 渲染），越界取值的风险不存在。
    _planCurrent = cur == null || _plan.isEmpty
        ? null
        : cur.clamp(0, _plan.length);

    _events.add(PlanUpdatedEvent(_plan, _planCurrent));
    _safeNotify();

    // 回填极短：模型自己刚发出的列表，回给它是纯浪费。
    return ToolResult(
        callId: call.id, content: 'Plan updated (${_plan.length} steps).');
  }

  /// 列出本机保存的服务器。
  ///
  /// 不碰权限系统、不创建 `ToolCallEvent`：它什么都不执行、什么都不写，读的
  /// 是本地数据库。与 `set_plan` 同类——那两样是给「有命令、有输出、可能要
  /// 审批」的工具准备的。
  Future<ToolResult> _executeListServers(ToolCall call) async {
    final servers =
        await serverListProvider?.call() ?? const <ServerListEntry>[];
    _consecutiveInvalidArgs = 0;
    // withAliases：同一个 host 上的多个条目互相标注。不标的话模型会把
    // `dk` 和 `gcproot` 当成两台机器各跑一遍命令，拿回两份逐字相同的输出。
    return ToolResult(
      callId: call.id,
      content:
          jsonEncode(withAliases(servers).map((s) => s.toJson()).toList()),
    );
  }

  /// 读当前屏幕。**不走审批**：它只读手机上已经显示着的字 —— 用户本来就在看
  /// 着这些内容，而 system prompt 每轮都已经在发一份（更旧的）同类内容了。为它
  /// 弹一张审批卡只会训练用户无脑点同意。
  Future<ToolResult> _executeReadTerminal(ToolCall call) async {
    _consecutiveInvalidArgs = 0;
    final text = terminalTextProvider?.call();
    // 三种「没内容」要分开说，否则模型只能猜是工具坏了还是真没东西：
    // provider 缺失 / tab 已关 / 屏幕确实是空的。空字符串最糟——模型往往
    // 直接忽略，然后接着凭那份过期快照瞎猜。
    if (text == null) {
      return ToolResult(
        callId: call.id,
        content: 'No terminal is currently open for this session.',
      );
    }
    if (text.trim().isEmpty) {
      return ToolResult(
        callId: call.id,
        content: 'The terminal screen is empty.',
      );
    }
    return ToolResult(callId: call.id, content: text);
  }

  /// 见 `tool_executors/skill_executors.dart`。
  Future<ToolResult> _executeLoadSkill(ToolCall call) =>
      _skills.loadSkill(call);
  /// 见 `tool_executors/skill_executors.dart`。
  Future<ToolResult> _executeSaveSkill(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _skills.saveSkill(call, preApproved: preApproved, tm: tm);

  /// 见 `tool_executors/skill_executors.dart`。
  Future<ToolResult> _executeSaveNote(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _skills.saveNote(call, preApproved: preApproved, tm: tm);

  /// 审批闸门。返回非 null 表示这次调用**已经有结论**（被拒，或进了方案），
  /// 调用方应当原样返回它、不要继续执行。
  ///
  /// ## 为什么抽出来
  ///
  /// `web_fetch` 要走同一段：建事件 → 判定 → 等审批 → 执行。它的判定和执行
  /// 都与 `_executeCommandTool` 不同（`checkWebFetch` 而非 `checkCommand`，
  /// 手机端根本不产生 shell 命令），但**中间这段一模一样**。
  ///
  /// 复制它的代价上限是「某天只改了一处，另一处仍在未经审批就执行」。而
  /// 「改一处漏一处」在这个文件里已经发生过两次并留下了记录：`_finishToolCall`
  /// 收口 8 处终态、`_skillNameOf` 抽出两处偏移量计算。审批是安全路径，
  /// 不接受第二份。
  ///
  /// ## 还有 5 处没收口
  ///
  /// 同样形状的代码还在 `_executeRunBackground`、`_executeDownloadFile`、
  /// `_executeUploadFile`、`_executeCopyBetweenServers`、`_executeSaveSkill`
  /// 里各有一份。它们的 `checkTarget` 语义各不相同（原始 command / 文件路径 /
  /// 技能名），收口它们要逐个核对，**是独立议题**——不该由一个新工具夹带
  /// 一次五处重构。此处只收口本项目真正共用的两处。
  ///
  /// ## 为什么返回 `FutureOr` 而不是 `Future`（对计划给出的签名的偏离）
  ///
  /// 原内联代码在「不需要审批」（allow / 已预批准 / 静默命中）这条快路径上
  /// 没有任何 `await`——它和调用方共享同一段同步执行，`runner.run()` 紧接着
  /// 在同一个 microtask 里起飞。把这段代码原样搬进一个 `async` 方法、调用处
  /// 用 `await` 接住，即便快路径内部仍然零 `await`，Dart 的 `await` 语义也
  /// 保证至少让出一次 microtask（这是语言规范里刻意的设计，不是实现细节）。
  ///
  /// 这一次额外的 microtask 在 `agent_quota_test.dart` 的
  /// `同一台机上仍然是 3 并发（零回归）` 里是可观测的：该测试用
  /// `Completer` 搭了一个「凑够 N 个在途请求就 releaseAll，再等凑够 M 个
  /// 再 releaseAll」的两段式闸门，`releaseAll` 之间靠 `waitForInFlight` 的
  /// 轮询衔接。抢跑（`_maybeSpeculate`）+ 配额调度（`runWithLimits`）已经
  /// 把「一个槽位腾出来 → 下一条顶上」这条链路走成了好几跳 microtask 级联；
  /// 插进去这多出的一跳，会把第 4 条命令真正调用 `runner.run()`（从而挂上
  /// 测试闸门的 `_pending` 列表）的时间点，推到测试第二次 `releaseAll()`
  /// **之后**——那条命令的 `Completer` 就再也等不到人放行，整个测试挂到
  /// 30 秒超时。用 `git stash`/`git stash pop` A/B 对照复现，双向 100% 稳定
  /// 复现，排除了计时抖动。
  ///
  /// 换成 `FutureOr`：快路径（本方法体本身不再是 `async`）直接同步返回
  /// `null`，调用处只在真拿到一个 `Future` 时才 `await`——与原内联代码在
  /// 快路径上完全零 microtask 开销，逐字节复刻原行为。仅当确实需要等审批
  /// 时才转发到下面 `_awaitApprovalGate`（那条路径本来就要挂起等人，多一次
  /// microtask 无关紧要）。
  FutureOr<ToolResult?> _gateOnApproval(
    ToolCall call,
    ToolCallEvent ev,
    String checkTarget,
    CheckResult check, {
    required bool preApproved,
    ToolMetrics? tm,
  }) {
    // 静默命中时跳过等待，但 `ev.check` 保持原样 —— 事件流要如实记录「这条
    // 确实命中了凭据边界」，只是本轮不再阻塞。
    if (preApproved ||
        check.decision != ToolDecision.needApproval ||
        _isSilenced(checkTarget, check)) {
      return null;
    }
    return _awaitApprovalGate(call, ev, checkTarget, check, tm: tm);
  }

  /// [_gateOnApproval] 里真正需要挂起等人的那条慢路径。拆出来是为了让
  /// [_gateOnApproval] 本身保持非 `async`，见那边的说明。
  Future<ToolResult?> _awaitApprovalGate(
    ToolCall call,
    ToolCallEvent ev,
    String checkTarget,
    CheckResult check, {
    ToolMetrics? tm,
  }) async {
    _approvalTargets[ev.seq] = checkTarget;
    // 只量这一段——`_awaitApproval` 挂起等的是人的反应，不是执行。外层
    // `_executeOne` 会拿这个数从总时长里扣掉，见那里的注释。
    final approvalSw = Stopwatch()..start();
    final outcome = await _awaitApproval(ev);
    try {
      tm?.waitApprovalMs = approvalSw.elapsedMilliseconds;
    } catch (_) {}
    if (outcome.decision == ApprovalDecision.reject) {
      return _rejectedResult(ev, outcome);
    }
    if (outcome.decision == ApprovalDecision.addToPlan) {
      return _deferOrRejectFromApproval(ev, call, check);
    }
    return null;
  }

  Future<ToolResult> _executeCommandTool(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    // **只有跨机调用才去取服务器列表。**
    //
    // `resolveServerTarget` 在 `args['server'] == null` 时第一行就返回
    // `const ServerTarget()`，压根不碰 `servers` —— 对本机调用，这次 await
    // 拿到的东西一个字节都用不上。
    //
    // 而它一点都不便宜：生产实现（`terminal_screen.dart` 的
    // `serverListProvider`）要跑一次 SQLite 查询，再逐台服务器 await 一次
    // `AgentExecChannel.isAvailable()`（读 secure storage / keystore）。
    // 配了几台服务器就是几次真实的异步往返，压在**每一条**本机 `bash` /
    // `read_file` 前面。
    //
    // 去掉它同时修掉一个更隐蔽的问题：`ToolCallEvent` 是在这行之后才创建
    // 并塞进 `_events` 的，所以只要这次 await 比「模型说完剩下那点话」更慢，
    // 抢跑的工具卡就会排在 StreamDone 时同步追加的尾巴文字**后面**，渲染成
    // 「文字 → 文字 → 工具卡」，与推测执行的设计目标正好相反。而
    // `agent_view` 按 `events` 原始下标渲染，`AssistantTextEvent` 没有 seq，
    // 下游没有任何东西能纠正这个顺序。
    //
    // **残留**：跨机的抢跑调用仍要过这次 await，顺序仍可能倒置。那条路本身
    // 就要建新连接、抢跑收益也最大，不值得为顺序把它禁掉；记录在案。
    final servers = call.args['server'] == null
        ? const <ServerListEntry>[]
        : await serverListProvider?.call() ?? const <ServerListEntry>[];
    final r = _resolve(call, servers);
    if (r.error != null) {
      _consecutiveInvalidArgs++;
      return ToolResult(callId: call.id, content: r.error!, isError: true);
    }
    _consecutiveInvalidArgs = 0;

    // 只取一次 —— 判定用的 cwd 与实际执行用的 cwd 必须是同一个值，否则
    // 审批等待期间用户 `cd` 到别处，会出现判定用旧目录、执行用新目录的
    // TOCTOU：目录锚定的 deny 规则可能因此被绕过。
    //
    // **跨机时根本不调用 cwdProvider**，而不是调了再丢：那个 provider 返回的
    // 是当前 tab 的目录，对另一台机器没有任何意义。`isSensitiveCwd` 因此不
    // 触发——这不是缺口，因为它防的是「用户在终端里 cd 到敏感目录、AI 随后
    // 在那里跑命令」，而 agent 自建的那条连接没有人 cd 过它。命令文本层的
    // `isCredentialDeny` 照常生效。
    final cwd = r.targetServerId == null ? cwdProvider?.call() : null;

    final check = checkCommand(
      r.checkTarget,
      rules: rulesProvider(),
      mode: modeProvider(),
      // 必须传 —— 否则 `cd ~/.aws && cat credentials` 会从目录锚定的
      // deny 模式底下溜过去。
      cwd: cwd,
    );

    final ev = ToolCallEvent(
      seq: _nextSeq++,
      callId: call.id,
      toolName: call.name,
      displayCommand: r.displayCommand,
      description: r.description,
      check: check,
      targetServerName: r.targetServerName,
    );
    _events.add(ev);

    // `_gateOnApproval` 返回 `FutureOr`：不需要审批时它同步返回 `null`，
    // 这里不能无条件 `await`——即便 `await` 一个已经是值的表达式，Dart 也会
    // 强制让出一次 microtask，那正是要避免的额外一跳（见 `_gateOnApproval`
    // 的 dartdoc）。只有真拿到一个 `Future` 时才 await 它。
    final gateResult =
        _gateOnApproval(call, ev, r.checkTarget, check, preApproved: preApproved, tm: tm);
    final gated =
        gateResult is Future<ToolResult?> ? await gateResult : gateResult;
    if (gated != null) return gated;

    ev.status = ToolCallStatus.running;
    ev.startedAt = DateTime.now();
    _setState(AgentLoopState.executing);

    final CommandOutput out;
    try {
      out = await runnerProvider(r.targetServerId)
          .run(r.execCommand,
              cwd: cwd, denoise: r.denoise, truncate: r.truncate);
    } catch (e, st) {
      _errorStack = st;
      _finishToolCall(ev, ToolCallStatus.failed);
      ev.output = toolErrorForCard(e, st);
      _safeNotify();
      return ToolResult(
        callId: call.id,
        content: describeToolError(e, st),
        isError: true,
      );
    }

    _finishToolCall(ev, out.isSuccess ? ToolCallStatus.done : ToolCallStatus.failed);
    ev.output = formatForDisplay(out);
    ev.exitCode = out.exitCode;
    _safeNotify();

    return ToolResult(
      callId: call.id,
      content: r.warning == null ? ev.output! : '${r.warning}\n${ev.output!}',
      exitCode: out.exitCode,
      timedOut: out.timedOut,
    );
  }

  /// 见 `tool_executors/web_executors.dart`。
  Future<ToolResult> _executeWebFetch(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _web.webFetch(call, preApproved: preApproved, tm: tm);




  /// 见 `tool_executors/job_executors.dart`。
  Future<ToolResult> _executeRunBackground(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _jobs.runBackground(call, preApproved: preApproved, tm: tm);

  /// 见 `tool_executors/transfer_executors.dart`。
  Future<ToolResult> _executeDownloadFile(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _transfers.download(call, preApproved: preApproved, tm: tm);

  /// 见 `tool_executors/transfer_executors.dart`。
  Future<ToolResult> _executeUploadFile(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _transfers.upload(call, preApproved: preApproved, tm: tm);

  /// 见 `tool_executors/transfer_executors.dart`。
  Future<ToolResult> _executeCopyBetweenServers(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _transfers.copyBetweenServers(call, preApproved: preApproved, tm: tm);

  /// 按 [TransferEvent.seq] 索引的取消令牌。卡片上的「取消」按钮据此定位。
  final Map<int, TransferCancelToken> _transferTokens = {};

  /// `web_fetch` 的实现，见 `tool_executors/web_executors.dart`。
  late final WebExecutors _web = WebExecutors(this);

  /// 写文件两件事的实现，见 `tool_executors/file_executors.dart`。
  late final FileExecutors _files = FileExecutors(this);

  /// 后台任务两件事的实现，见 `tool_executors/job_executors.dart`。
  late final JobExecutors _jobs = JobExecutors(this);

  /// 技能两件事的实现，见 `tool_executors/skill_executors.dart`。
  late final SkillExecutors _skills = SkillExecutors(this);

  /// `ask_user` 的实现，见 `tool_executors/ask_executors.dart`。
  late final AskExecutors _ask = AskExecutors(this);

  /// 传输三件事的实现，见 `tool_executors/transfer_executors.dart`。
  ///
  /// `late final` 而不是构造时赋值：它要拿 `this` 当 context，而 `this` 在
  /// 初始化列表里还不能用。
  late final TransferExecutors _transfers = TransferExecutors(this);

  /// 取消一次正在进行的传输。由传输卡上的按钮调用，**不走审批** ——
  /// 用户自己点的按钮不需要再问他一次。
  void cancelTransfer(int seq) => _transferTokens[seq]?.cancel();

  /// 仅供测试：直接往事件流里塞一条，绕开整个执行路径。
  @visibleForTesting
  void debugAddEvent(AgentEvent ev) {
    _events.add(ev);
    _safeNotify();
  }

  /// 仅供测试：事件上限。
  @visibleForTesting
  static int get debugMaxEvents => _kMaxEvents;

  /// 仅供测试：直接驱动裁剪。
  @visibleForTesting
  void debugTrimEvents() => _trimEvents();

  /// 已下载文件注入上下文的上限。
  ///
  /// 一份 3 MB 的 log 是几十万 token，而一轮预算是 120k。截断而不是拒绝：
  /// 日志的开头往往就够定位问题，把它拦掉等于让这个按钮在最常见的场景下
  /// 没用。
  static const int kInjectMaxBytes = 64 * 1024;

  /// 把已下载到本地的文件内容作为一条 user message 注入会话。
  ///
  /// **读本地已落盘的副本，不让模型重调 `read_file` 重读远端。** 文件已经
  /// 在手机上了，再往返一次是白费；而且远端文件可能在这几秒里已经变了 ——
  /// 用户在卡上看到的预览与模型读到的内容会不一致。
  ///
  /// 由传输卡上的按钮调用，**不走审批**：用户自己点的按钮不需要再问他一次。
  /// 凭据文件的拦截在 `TransferCard` 里（那个按钮被强制禁用）。
  Future<void> injectLocalFile(String localPath) async {
    final file = File(localPath);
    final String text;
    final int totalBytes;
    try {
      totalBytes = await file.length();
      final bytes = await file.openRead(0, kInjectMaxBytes).expand((c) => c).toList();
      // allowMalformed：日志里混进的二进制字节不该让整个按钮失效。
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      // 读不到就什么都不做 —— 发一轮「我读不到那个文件」只是浪费预算，
      // 而用户看着卡片就知道文件在哪。
      dlog('transfer', 'injectLocalFile failed: $e');
      return;
    }

    final filename = localPath.split('/').last;
    final truncated = totalBytes > kInjectMaxBytes;
    final header = truncated
        ? 'Contents of the downloaded file `$filename` '
            '(truncated: showing the first $kInjectMaxBytes of $totalBytes '
            'bytes):'
        : 'Contents of the downloaded file `$filename` '
            '($totalBytes bytes):';

    await send('$header\n\n$text');
  }

  /// 用户在传输的审批卡上点了「加入方案」。
  ///
  /// 传输不能进方案队列，理由与凭据操作不同但同样具体：上传的 picker 是
  /// 交互式的（攒批执行会让用户在毫无预期的时刻看到一个文件选择器），
  /// 两个方向都要占住带宽并阻塞 loop。plan 的攒批语义是「这些事一起做，
  /// 你先不用管」，而传输恰恰是必须有人在场的那类事。
  ///
  /// UI 上 plan 模式的审批卡会渲染「加入方案」按钮（那个按钮只在 `denyHit`
  /// 时被隐藏），所以这条路径是真的走得到的，不是防御性代码。
  ToolResult _transferNotQueueable(ToolCallEvent ev) {
    ev.status = ToolCallStatus.rejected;
    _safeNotify();
    return ToolResult(
      callId: ev.callId,
      content: 'Transfers cannot be queued into a batch plan — the upload '
          'picker is interactive and both directions occupy bandwidth, so '
          'they need the user present. Nothing was transferred. Offer it '
          'again when the user can approve it directly.',
      isError: true,
    );
  }

  /// 见 `tool_executors/job_executors.dart`。
  Future<ToolResult> _executeCheckJob(ToolCall call) => _jobs.checkJob(call);

  /// 见 `tool_executors/job_executors.dart`。
  Future<ToolResult> _executeListJobs(ToolCall call) => _jobs.listJobs(call);

  /// 终止一个后台任务。由任务卡上的「终止」按钮调用，**不走审批** ——
  /// 用户自己点的按钮不需要再问他一次。
  Future<bool> killJob(String jobId) async {
    if (!isValidJobId(jobId)) return false;
    final job = _events
        .whereType<BackgroundJobEvent>()
        .where((e) => e.jobId == jobId)
        .lastOrNull;
    job?.killed = true;
    _safeNotify();
    try {
      await runnerProvider(job?.serverId)
          .run(buildJobKillCommand(jobId),
              cwd: job?.serverId == null ? cwdProvider?.call() : null);
    } catch (_) {
      // 杀不掉就把标记退回去 —— 留一个「已终止」的假象比报错更糟，
      // 用户会以为任务停了而它还在烧 CPU。
      job?.killed = false;
      _safeNotify();
      return false;
    }
    return true;
  }

  /// 走一次审批往返。返回用户的决定。
  ///
  /// 抽出来是因为 `edit_file` 的审批发生在「已经读过文件、算出 diff」之后，
  /// 与 `bash` 的「解析完参数就问」不在同一个位置，但往返逻辑一模一样。
  Future<ApprovalOutcome> _awaitApproval(ToolCallEvent ev) {
    // 会话已被取消或关闭时不再挂起等待。
    //
    // cancel() / dispose() 只叫醒**它们被调用那一刻**在 _pending 里的等待者；
    // 此后再注册的 completer 没有任何人会完成它。edit_file 是第一条会等两次
    // 审批、中间夹一次远端执行的路径 —— 取消恰好落在那次执行期间时，第二次
    // 审批就会永远挂着：loop 回不到检查点，它持有的整段历史也回收不掉，正是
    // dispose() 特意加固要避免的那种泄漏。
    //
    // 挡在这里而不是每个调用点：调用点会随工具增加，这里只有一处。
    //
    // 不碰 ev.status：设成 awaitingApproval 会让 UI 冒出一张审批卡，而调用方
    // 拿到 reject 之后会走 `_rejectedResult`，那里会把它设成 rejected —— 提前
    // 返回的分支该让那条路径去定最终状态，而不是抢先摆出一个错误的中间态。
    if (_cancelRequested || _disposed) {
      return Future.value(const ApprovalOutcome(ApprovalDecision.reject));
    }
    ev.status = ToolCallStatus.awaitingApproval;
    _setState(AgentLoopState.awaitingApproval);
    final completer = Completer<ApprovalOutcome>();
    _pending[ev.seq] = completer;
    return completer.future;
  }

  /// 把「用户拒绝」翻译成回填给模型的结果。
  ///
  /// [outcome] 目前只用来标记状态；留着参数是为了签名对称与将来可能的
  /// 决策细分（比如区分「拒绝」与「本轮不再问」）。
  ToolResult _rejectedResult(ToolCallEvent ev, ApprovalOutcome outcome) {
    ev.status = ToolCallStatus.rejected;
    _safeNotify();
    return ToolResult(
      callId: ev.callId,
      content: 'User rejected this command.',
      isError: true,
    );
  }

  /// 用户在审批卡上点了「加入方案」之后的落点。
  ///
  /// 绝大多数时候就是入队。唯一的例外是**凭据边界命中**：那种调用不进队列，
  /// 按拒绝处理。
  ///
  /// ## 为什么凭据操作不能进方案
  ///
  /// 命中凭据边界时，审批卡上有一条醒目的警示：「此命令涉及凭据文件，允许后
  /// 内容将发送给 <provider>」。那条警示的全部价值在于**在决策的那一刻**呈现
  /// 给用户。攒进提案卡之后，它就稀释成一份列表里的一行——用户批准的是「这
  /// 三件事」，而不是「把私钥内容发给模型厂商」。
  ///
  /// 凭据边界的原则是「永不静默执行、永不能进 allowlist」，`bypass`
  /// 都盖不住它。plan 的攒批语义同样不该盖住：批一批和批一条，在这一格上不是
  /// 同一件事。
  ///
  /// 还有一层机制上的理由：进了队列之后 [approvePlan] 会以 `preApproved:
  /// true` 执行，那条路径按设计跳过所有判定——凭据警示不会再出现第二次。
  ///
  /// UI 那层已经在 `denyHit` 时不渲染「加入方案」按钮，所以正常流程走不到这个
  /// 分支。留着它是因为 UI 判断不该是唯一防线：审批可以从面板外的通知点进来，
  /// 卡片状态也可能因迟到点击而与当下不一致。
  ToolResult _deferOrRejectFromApproval(
    ToolCallEvent ev,
    ToolCall call,
    CheckResult check,
  ) {
    if (check.denyHit) {
      ev.status = ToolCallStatus.rejected;
      _safeNotify();
      return ToolResult(
        callId: ev.callId,
        content: 'Not queued: this call touches credential files, and those '
            'cannot go into a batch plan — they need a decision at the moment '
            'they are requested. Nothing was executed. Ask the user directly '
            'if you still need it.',
        isError: true,
      );
    }
    // 写文件与 bash 的措辞不同（「文件还没改」vs「命令还没跑」），按工具名分。
    final message = (call.name == 'write_file' || call.name == 'edit_file')
        ? kDeferredWriteMessage
        : kDeferredCommandMessage;
    return _deferResult(ev, call, message);
  }

  /// 把一次调用推迟到方案里，并给模型一个立刻可用的 tool_result。
  ///
  /// **必须立刻回填**：wire protocol 要求每个 tool_use 在下一个 user turn
  /// 里有恰好一个 tool_result（见 `anthropic_provider.dart` 里按
  /// `tool_use_id` 配对那段）。「先挂着等用户批了再给结果」会让 tool_use
  /// 悬空，下一轮请求直接被服务端拒绝。
  ///
  /// 批准之后的真实执行结果因此**不能**再走 tool_result（那个 id 已经用掉
  /// 了），只能以新的 user 消息注入 —— 见 [approvePlan]。整个 plan 模式的
  /// 形状就是这条约束逼出来的，改这个方法之前先读懂它。
  ToolResult _deferResult(ToolCallEvent ev, ToolCall call, String message) {
    final fresh = _enqueuePlan(call);
    ev.status = ToolCallStatus.deferred;
    ev.output = fresh ? null : 'duplicate — already in the plan';
    _safeNotify();
    return ToolResult(
      callId: ev.callId,
      content: fresh ? message : kAlreadyQueuedMessage,
      isError: !fresh,
    );
  }

  /// 见 `tool_executors/file_executors.dart`。
  Future<ToolResult> _executeWriteFile(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _files.writeFile(call, preApproved: preApproved, tm: tm);



  /// 见 `tool_executors/file_executors.dart`。
  Future<ToolResult> _executeEditFile(ToolCall call,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _files.editFile(call, preApproved: preApproved, tm: tm);

  /// 把一次 tool call 解析成「执行什么 / 用什么判定 / 展示什么」。
  ///
  /// `read_file` 执行的是 `sed`，但**判定用 `cat <path>`** —— 这样它就和
  /// 默认规则集里的 `cat *` 挂上钩，不会成为绕过规则读任意文件的后门。
  _Resolved _resolve(ToolCall call, List<ServerListEntry> servers) {
    final target = resolveServerTarget(call.args['server'], servers);
    if (!target.ok) return _Resolved(error: target.error);

    switch (call.name) {
      case 'bash':
        final cmd = call.args['command'];
        if (cmd is! String || cmd.trim().isEmpty) {
          return const _Resolved(
              error: 'Invalid arguments: `command` is required and must be a '
                  'non-empty string.');
        }
        final desc = call.args['description'];
        return _Resolved(
          execCommand: cmd.trim(),
          checkTarget: cmd.trim(),
          // 展示层加机器名前缀，两个卡片 widget 因此零改动。
          displayCommand: target.isRemote
              ? '[${target.serverName}] ${cmd.trim()}'
              : cmd.trim(),
          description: desc is String ? desc : '',
          targetServerId: target.serverId,
          targetServerName: target.serverName,
          // 目标场景：日志、状态输出里的重复行是去噪最大的收益来源。
          denoise: true,
          // 两端都可能是关键，没有判据能事先知道是哪端 —— 挖中间。
          truncate: TruncateMode.middle,
        );

      case 'read_file':
        final path = call.args['path'];
        if (path is! String || path.trim().isEmpty) {
          return const _Resolved(
              error: 'Invalid arguments: `path` is required and must be a '
                  'non-empty string.');
        }
        final offset = asPositiveInt(call.args['offset'], 1);
        final limit = asPositiveInt(call.args['limit'], 200);
        final end = offset + limit - 1;
        final p = path.trim();
        final exec = "sed -n '$offset,${end}p' -- ${shellQuotePath(p)}";
        return _Resolved(
          execCommand: exec,
          checkTarget: 'cat $p',
          displayCommand: target.isRemote
              ? '[${target.serverName}] $exec'
              : exec,
          description: 'Read $p lines $offset-$end',
          targetServerId: target.serverId,
          targetServerName: target.serverName,
        );

      // glob / grep 的 exec 命令由我们拼，模型只给 pattern 与 path。
      //
      // 所以**参数必须全部 shellQuote**。少一个，模型就能在 pattern 里塞
      // `'; rm -rf / #` 拿到任意执行 —— 而这条路绕过了元字符检测：检测的
      // 对象是 checkTarget，不是 execCommand（见本函数上方说明）。
      //
      // 判定统一用 `cat <path>`，与 read_file 同一口径。不这么做它们就成了
      // 「用户关掉 cat 规则后仍能读任意文件」的后门。
      case 'glob':
        final pattern = call.args['pattern'];
        if (pattern is! String || pattern.trim().isEmpty) {
          return const _Resolved(
              error: 'Invalid arguments: `pattern` is required and must be a '
                  'non-empty string.');
        }
        final rawPath = call.args['path'];
        // 省略 path 时用 `.`：命令由 wrapForSsh 带着 cd 到 cwd 执行，所以
        // `.` 就是用户当前所在目录（跨机调用没有 cwd，那里是登录目录）。
        final gp = (rawPath is String && rawPath.trim().isNotEmpty)
            ? rawPath.trim()
            : '.';
        final gExec = 'find ${shellQuotePath(gp)} -name '
            '${shellQuote(pattern.trim())} -type f 2>/dev/null '
            '| head -$kSearchResultLimit';
        return _Resolved(
          execCommand: gExec,
          checkTarget: 'cat $gp',
          displayCommand: target.isRemote
              ? '[${target.serverName}] $gExec'
              : gExec,
          description: 'Find files matching ${pattern.trim()} under $gp',
          targetServerId: target.serverId,
          targetServerName: target.serverName,
        );

      case 'grep':
        final pattern = call.args['pattern'];
        if (pattern is! String || pattern.trim().isEmpty) {
          return const _Resolved(
              error: 'Invalid arguments: `pattern` is required and must be a '
                  'non-empty string.');
        }
        final rawPath = call.args['path'];
        final sp = (rawPath is String && rawPath.trim().isNotEmpty)
            ? rawPath.trim()
            : '.';
        final include = call.args['include'];
        final inc = (include is String && include.trim().isNotEmpty)
            ? include.trim()
            : null;
        // ## 选项都是实测过 BusyBox 的，不是照 GNU man page 写的
        //
        // `-H` 强制文件名前缀。**不是冗余**：`grep -rn` 只在匹配到多个文件
        // 时才加前缀，path 指向单个文件时输出是裸的 `12:xxx`，而工具描述
        // 承诺的是 `file:line`。xargs 那条分支只喂进一个文件时同理。
        //
        // `-I` 跳过二进制文件。实测两家的差别比想象的小：
        //
        // - GNU：真的跳过。不加 -I 时它也**不会**把二进制内容写进 stdout，
        //   只在 stderr 说一句 `binary file matches` —— 所以 -I 省掉的是那行
        //   噪音，不是「几 KiB 乱码」。
        // - BusyBox：静默忽略这个选项，二进制照样命中，内容进 stdout（在首个
        //   NUL 处截断）。-I 在 Alpine 上救不了这个。
        //
        // 收益不大但也不为零，且两家都不报错，所以留着。
        //
        // `--` 终止选项解析：pattern 以 `-` 开头（`-v`、`--color`）时，没有
        // 它 grep 会把 pattern 当自己的开关。
        //
        // **`--include` 不能用。** BusyBox grep 不认它，直接
        // `unrecognized option` 失败 —— 而下面那个 `2>/dev/null` 会把错误
        // 吞掉、管道又让退出码归 head，于是模型收到一个空结果并据此断言
        // 「没有匹配」。用 find 挑文件再喂给 grep，两条命令都是 POSIX。
        // `-r`（空输入不跑命令）与 `-print0`/`-0`（文件名含空格不炸）都实测
        // 过 BusyBox 支持。
        //
        // 2>/dev/null 是个有代价的取舍：递归一棵大目录树会刷出几十行
        // permission denied，每一行都要付 token。代价是**空结果有歧义** ——
        // 路径不存在与真的没匹配长得一样，因为管道把退出码换成了 head 的。
        // 工具描述里因此明说了这一点，让模型不确定时去确认而不是断言。
        final sExec = inc == null
            ? 'grep -rnHI -- ${shellQuote(pattern.trim())} ${shellQuotePath(sp)} '
                '2>/dev/null | head -$kSearchResultLimit'
            : 'find ${shellQuotePath(sp)} -type f -name ${shellQuote(inc)} '
                '-print0 2>/dev/null | xargs -0 -r grep -nHI -- '
                '${shellQuote(pattern.trim())} 2>/dev/null '
                '| head -$kSearchResultLimit';
        return _Resolved(
          execCommand: sExec,
          checkTarget: 'cat $sp',
          displayCommand: target.isRemote
              ? '[${target.serverName}] $sExec'
              : sExec,
          description: 'Search for ${pattern.trim()} in $sp',
          targetServerId: target.serverId,
          targetServerName: target.serverName,
        );

      case 'run_saved_command':
        final rawName = call.args['name'];
        if (rawName is! String || rawName.trim().isEmpty) {
          return const _Resolved(
              error: 'Invalid arguments: `name` is required.');
        }
        final askedName = rawName.trim();
        final saved = savedCommandProvider?.call(askedName);
        if (saved == null) {
          final available =
              savedCommandNamesProvider?.call() ?? const <String>[];
          return _Resolved(
              error: available.isEmpty
                  ? 'You have no saved commands available.'
                  : 'No saved command named `$askedName`. '
                      'Available: ${available.join(', ')}.');
        }

        // 模型给的 params 可能是任何形状。统一折成 Map<String, String>：
        // 数字/布尔用 '$v' 转成字符串（JSON 里没有整数这回事，模型给
        // `{"port": 8080}` 很常见），非 Map 一律当成空。
        final rawParams = call.args['params'];
        final params = <String, String>{};
        if (rawParams is Map) {
          rawParams.forEach((k, v) => params['$k'] = '$v');
        }

        // 第一层：参数不能改变命令的结构。**在权限判定之前** —— 第二层
        // （checkCommand，在 _executeCommandTool 里）管的是「这条命令能不能
        // 跑」，连 bypass 都不该让一个注入过的参数走到那一步。
        final paramCheck = validateCommandParams(saved, params);
        if (paramCheck.error != null) {
          return _Resolved(error: paramCheck.error);
        }

        final expanded = saved.expand(params);
        if (expanded.trim().isEmpty) {
          return const _Resolved(
              error: 'That command expands to an empty string.');
        }
        final shownParams = saved.params.isEmpty
            ? ''
            : '：${saved.params.map((p) => '$p=${params[p]}').join(', ')}';
        return _Resolved(
          execCommand: expanded,
          // 判定用展开后的完整命令 —— 判的必须是真正要跑的那条。
          checkTarget: expanded,
          displayCommand:
              target.isRemote ? '[${target.serverName}] $expanded' : expanded,
          description: '运行「${saved.name}」$shownParams',
          warning: paramCheck.extraKeys.isEmpty
              ? null
              : '[ignored unknown parameter(s): '
                  '${paramCheck.extraKeys.join(', ')}]',
          targetServerId: target.serverId,
          targetServerName: target.serverName,
          // 展开之后跑的就是一条普通命令，与 `bash` 同一个理由：两端都可能
          // 是关键。收藏命令里 `journalctl -u x -n 2000` 这种形状很典型。
          //
          // **`denoise` 这里仍然没传（保持既有行为）。** 那是去噪那次改动
          // 就有的缺口，与本次无关；顺手加会把一次「截断方向」的改动变成
          // 「顺带改了输出内容」，两件事该分开验。
          truncate: TruncateMode.middle,
        );

      default:
        // 走到这里说明某个工具进了分档清单却没实现分派 —— 是我们的 bug，
        // 不是模型的问题（幻觉出的工具名已经在 `_executeOne` 开头被闸门
        // 拦下了，走不到这里）。回一条 isError 让会话能继续，而不是崩掉。
        return _Resolved(
            error: 'Tool `${call.name}` is declared but not implemented.');
    }
  }


  /// 仅供测试断言 token 估算把哪些字段算了进去。
  @visibleForTesting
  int debugEstimateTokens() => _estimateTokens();

  /// 当前历史 + 工具 schema 占多少 token。
  ///
  /// **这个数就是 token 数**，不是「某种折算单位」。2026-09-14 之前它是
  /// `chars / 3.5`，对每一类内容都偏低 13%–267%（命令输出偏低近一倍，而那
  /// 正是历史的大头），于是 `tokenBudget` 那个数字谁也没法据它判断「离
  /// 上下文上限还有多远」。速率与实测依据见 `token_estimate.dart`。
  int _estimateTokens() {
    var tok = 0;
    for (final m in _history) {
      tok += estimateMessageTokens(m);
    }
    // 工具 schema 单独传给 provider，不在 `_history` 里 —— 旧实现整段漏算，
    // full 档实测 3739 token。
    tok += _toolSchemaTokens();
    // 真实 usage 当**下界**：上一轮真的送出去过这么多，当前历史只会更长。
    // 见 `_lastRealInput` 的 dartdoc（含它必须作废的那个条件）。
    return tok > _lastRealInput ? tok : _lastRealInput;
  }

  /// 工具 schema 的 token 数，按解锁状态缓存。
  ///
  /// 缓存不是过早优化：`_estimateTokens()` 在 `_dropOldOutputsIfNeeded` 的
  /// while 循环里被反复调用，而这一项在一轮内不会变 —— 每次都重新
  /// `jsonEncode` 十九个工具的 schema 是实打实的浪费。
  int? _toolSchemaTokensCache;

  int _toolSchemaTokens() => _toolSchemaTokensCache ??= estimateToolSchemaTokens(
      filterByUnlockedGroups(toolSpecsProvider(), _unlockedToolGroups));

  /// 保留窗口占预算的比例。
  ///
  /// 25%：太小则模型丢掉刚刚查过的细节、开始重复；太大则压缩省不下多少，
  /// 很快又要再压一次（而每次都是一发真实调用）。
  static const double _kKeepRatio = 0.25;

  /// 把早期历史压成一段结构化摘要。返回是否真的压了。
  ///
  /// **失败绝不改动 `_history`，也绝不让会话死。** 摘要是优化不是命脉：
  /// 429、断网、模型返回空，全部退化成「这次没压成」，继续由 drop 顶到硬停。
  Future<bool> _compact() async {
    final cut = findCompactionCut(
      _history,
      keepTokens: (tokenBudget * _kKeepRatio).round(),
    );
    if (cut == 0) return false;

    final dropped = _history.sublist(1, cut);
    final String summary;
    try {
      // 用 complete 而不是 completeWithTools：摘要是一次无工具的文本任务。
      // 带上工具定义会让模型尝试去调它们（而这一轮没有 loop 接住结果）。
      summary = await providerProvider().complete(buildSummaryRequest(dropped));
    } catch (_) {
      // 有意不记 _errorMessage / _errorStack：那两个字段驱动的是「会话因
      // 错误终止」的横幅，而这里会话照常继续。把一次可恢复的降级显示成
      // 终止错误，比不显示更糟。
      return false;
    }

    // 事实由代码从被砍掉的那段提取，不依赖上面那次 complete() —— 它返回
    // 空字符串时（不抛异常，历史照样被替换）事实块仍然完整。
    _history.replaceRange(
        1, cut, [buildSummaryMessage(summary, extractSessionFacts(dropped))]);
    // 历史变短了，上一次真实测量不再对应当前这份历史。见 `_lastRealInput`。
    _lastRealInput = 0;
    // 压缩整段替换了历史，被替换掉的范围里可能有任意几份技能正文。逐条
    // 去认代价高、收益低（摘要之后模型本来就该重新取），直接全清。
    _loadedSkills.clear();
    _events.add(CompactedEvent(
      droppedMessages: dropped.length,
      summary: summary.trim(),
    ));
    _safeNotify();
    return true;
  }

  /// 若此刻已经超过阈值且免费手段用尽，起一次**与工具执行并发**的压缩。
  ///
  /// ## 为什么要在这里单独起一份，而不是让轮末的 `_dropOldOutputsIfNeeded`
  /// 顺带做掉
  ///
  /// `_dropOldOutputsIfNeeded()` 的调用点在 `await _executeRound(...)` 之后
  /// ——那意味着 `_compact()`（一次真实的、非流式的模型往返）会在工具都跑完
  /// 之后才开始，用户等完工具还要再等一次模型调用。这次调用与本轮工具执行
  /// 之间没有任何数据依赖：`_compact()` 只读写 `_history[1..cut)`，
  /// `_executeRound` 全程不碰 `_history`。两件互不相干的事却排成一串，
  /// 是纯粹的账面浪费。
  ///
  /// 调用方（`_run()`）会在 assistant 消息 append 之后、`_executeRound`
  /// 之前调这个方法拿到一个 Future，让它与工具执行同时跑，再在两者都完成
  /// 之后才把 tool_result 接上 `_history`——具体理由见那边的注释，这里不
  /// 重复。
  ///
  /// `_dropOldOutputsIfNeeded()` **保持完全不动**，继续留在轮末：它是兜底，
  /// 不是主路径。等它跑到时，`findCompactionCut` 通常已经因为这次并发压缩
  /// 成功而返回 0（没什么可压的了）；只有这次并发尝试失败（模型报错、
  /// 断网）或压得不够多时，它才会真的再做点什么——这正是「免费手段优先，
  /// 真调用兜底」这条既有原则在并发路径下的延续，不是新增了第二条判断。
  Future<void> _maybeCompactConcurrently() async {
    final threshold = (tokenBudget * 0.8).round();
    if (_estimateTokens() <= threshold) return;
    // 先把免费的丢弃用尽——这一段是同步的，不值得并发（也没法并发：它不
    // 含任何 await）。丢弃与压缩共享同一条「先免费后真调用」的降级顺序，
    // 与 `_dropOldOutputsIfNeeded` 完全一致。
    var guard = _history.length + 1;
    var dropped = 0;
    while (_estimateTokens() > threshold && guard-- > 0) {
      if (!_dropOldestOutput()) break;
      dropped++;
    }
    _metric((t) => t.dropCount += dropped);
    if (_estimateTokens() <= threshold) return;

    // 置位在调用之前，而不是等结果出来——即便这次 `_compact()` 抛错，也是
    // 「这一轮真的尝试过压缩」，轮末的 `_dropOldOutputsIfNeeded()` 不该再
    // 因为失败就补发第二次请求。见 `_compactedThisTurn` 上的注释。
    _compactedThisTurn = true;
    final sw = Stopwatch()..start();
    await _compact();
    _metric((t) => t.compactMs = sw.elapsedMilliseconds);
  }

  /// 上下文超预算时，**从最早的工具输出开始丢**，保留命令本身。
  ///
  /// 绝不丢 assistant 的推理文本 —— 那是模型的思路链，丢了它会原地打转。
  /// 免费的丢弃手段用尽后，花一次真实调用把早期历史压成摘要（见 `_compact`）。
  Future<void> _dropOldOutputsIfNeeded() async {
    final threshold = (tokenBudget * 0.8).round();
    // 迭代上限是**熔断器**，不是逻辑的一部分。
    //
    // 这个 while 里没有 await：一旦 _dropOldestOutput() 谎报「丢掉了东西」
    // 而历史其实没变短，循环就会同步霸占 isolate —— 在这个 app 里那意味着
    // 整个 UI 线程冻死，而不是「agent 这一轮失败了」。连 package:test 的
    // 超时都触发不了，因为事件循环根本轮不上。
    //
    // 正常情况下迭代次数不会超过历史条数，所以这个上限永远够用；它只在
    // 未来某次回归破坏了 _dropOldestOutput 的契约时才生效。
    var guard = _history.length + 1;
    while (_estimateTokens() > threshold && guard-- > 0) {
      // 第一级：免费。丢得动就继续丢。
      if (_dropOldestOutput()) continue;
      // 第二级：丢不动了，花一次调用把早期历史压成摘要。
      //
      // 但只在本轮**还没**真的尝试过压缩时才发——`_maybeCompactConcurrently`
      // 可能已经在工具执行期间并发压过一次。它失败最常见的原因是 429
      // 限流，这里再补发一次只会加剧限流，而不是提高成功率。一轮最多一次
      // 真实的摘要调用，失败就等下一轮再说：压缩是优化不是命脉。见
      // `_compactedThisTurn` 上的注释。
      //
      // break 而不是 continue：压缩之后不再原地循环 —— 一轮里最多压一次，
      // 下一轮开头的预算判定会重新决定还要不要压。原地循环会在摘要没能
      // 压到阈值以下时连发好几次调用。
      if (!_compactedThisTurn) {
        _compactedThisTurn = true;
        await _compact();
      }
      break;
    }
  }

  /// 是否允许丢弃这条工具结果的内容。
  ///
  /// 两类例外，理由不同但结论一样——都不能被 drop 碰：
  /// - 已经是 marker 的（[_kDroppedPrefix]）：再丢一次只会用 marker 自己的
  ///   长度覆盖行数，第二次丢弃会写出 `[output dropped: 1 lines]`。
  /// - `run_background` 的回填（[kJobStartedPrefix]）：job id 只活在这段
  ///   文本里，丢了模型就再也找不回那个还在跑的任务。
  static bool _isDroppable(String content) =>
      !content.startsWith(_kDroppedPrefix) &&
      !content.startsWith(kJobStartedPrefix);

  /// 丢弃最早一条尚未被丢弃的工具输出。返回是否真的丢了东西
  /// （false = 已经没有可丢的了，调用方不该无限重试）。
  bool _dropOldestOutput() {
    final idx = _history.indexWhere((m) =>
        m.role == 'tool' &&
        (m.toolResults?.any((r) => _isDroppable(r.content)) ?? false));
    if (idx < 0) return false;
    final old = _history[idx];
    // 丢掉的如果是技能正文，把它从「已加载」里摘掉 —— 否则模型下次 load
    // 会被告知「正文在上文」，而上文里只剩一条 marker。
    //
    // 这里是**精确移除**而不是像 `_compact` 那样全清：drop 每次超预算就
    // 发生一次、非常频繁，全清会让所有技能正文被反复重发 8 KiB，比不省
    // 还差。
    for (final r in old.toolResults ?? const <ToolResult>[]) {
      if (!_isDroppable(r.content)) continue;
      if (!r.content.startsWith(kSkillBodyPrefix)) continue;
      final close = r.content.indexOf(']');
      if (close <= kSkillBodyPrefix.length) continue;
      _loadedSkills.remove(
          r.content.substring(kSkillBodyPrefix.length, close).toLowerCase());
    }
    _history[idx] = AIMessage(
      role: 'tool',
      content: '',
      toolResults: old.toolResults!
          .map((r) => ToolResult(
                callId: r.callId,
                content: _isDroppable(r.content) ? _droppedMarker(r) : r.content,
                isError: r.isError,
                exitCode: r.exitCode,
                timedOut: r.timedOut,
              ))
          .toList(),
    );
    // 历史变短了，上一次真实测量不再对应当前这份历史。见 `_lastRealInput`。
    _lastRealInput = 0;
    return true;
  }

  /// 把尚未定稿的流式文本落成一条正式事件。只在**异常路径**上调用 ——
  /// 正常路径由 `resp.text` 定稿，两条路都做会产出两条重复事件。
  void _flushStreamingText() {
    final t = _streamingText;
    _streamingText = null;
    if (t != null && t.isNotEmpty) {
      _events.add(AssistantTextEvent(t));
    }
  }

  /// 工具调用进入终态的**唯一**入口。
  void _finishToolCall(ToolCallEvent ev, ToolCallStatus status) =>
      applyToolCallTerminalState(ev, status);

  /// dispose 之后再调 notifyListeners 会触发 ChangeNotifier 的 assert。
  /// `_run()` 在 loop 被 dispose 后仍会走完当前这一步（返回、_stop），
  /// 那期间的通知必须静默丢弃。
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ═════════ AgentToolContext 实现 ═════════
  //
  // 搬到 `tool_executors/` 的 executor 只认这一组公开方法，碰不到上面那些
  // 私有字段。每一个都是**纯转发**，故意不夹逻辑 —— 一旦在这里加判断，
  // 「loop 内部直接用私有成员」和「executor 走 context」两条路径就会行为
  // 分叉，而它们跑的是同一个工具。

  @override
  int nextSeq() => _nextSeq++;

  @override
  void addEvent(AgentEvent e) => _events.add(e);

  @override
  void notifyChanged() => _safeNotify();

  @override
  void enterState(AgentLoopState s) => _setState(s);

  @override
  void finishToolCall(ToolCallEvent ev, ToolCallStatus status) =>
      _finishToolCall(ev, status);

  @override
  Future<ApprovalOutcome> awaitApproval(ToolCallEvent ev) =>
      _awaitApproval(ev);

  @override
  Future<ApprovalOutcome> timedAwaitApproval(ToolCallEvent ev, ToolMetrics? tm) {
    // 与 11 处原来的写法逐字等价：量的是「挂起等人类反应」那一段，
    // 累加进 waitApprovalMs，且计时段任何异常都不能反过来弄挂调用。
    final sw = Stopwatch()..start();
    return _awaitApproval(ev).then((outcome) {
      try {
        tm?.waitApprovalMs += sw.elapsedMilliseconds;
      } catch (_) {}
      return outcome;
    });
  }

  @override
  ToolResult rejectedResult(ToolCallEvent ev, ApprovalOutcome outcome) =>
      _rejectedResult(ev, outcome);

  @override
  ToolResult transferNotQueueable(ToolCallEvent ev) =>
      _transferNotQueueable(ev);

  @override
  bool get cancelRequested => _cancelRequested;

  @override
  bool get disposed => _disposed;

  @override
  void noteInvalidArgs() => _consecutiveInvalidArgs++;

  @override
  void resetInvalidArgs() => _consecutiveInvalidArgs = 0;

  @override
  void noteToolError(StackTrace st) => _errorStack = st;

  @override
  void registerTransfer(int transferSeq, TransferCancelToken token) =>
      _transferTokens[transferSeq] = token;

  @override
  void unregisterTransfer(int transferSeq) =>
      _transferTokens.remove(transferSeq);

  @override
  ToolResult deferOrRejectFromApproval(
          ToolCallEvent ev, ToolCall call, CheckResult check) =>
      _deferOrRejectFromApproval(ev, call, check);

  // 纯转发，**不加 `async`** —— 见接口那边关于 microtask 的说明。
  @override
  FutureOr<ToolResult?> gateOnApproval(
          ToolCall call, ToolCallEvent ev, String checkTarget, CheckResult check,
          {bool preApproved = false, ToolMetrics? tm}) =>
      _gateOnApproval(call, ev, checkTarget, check,
          preApproved: preApproved, tm: tm);

  @override
  ToolResult deferWrite(ToolCallEvent ev, ToolCall call) =>
      _deferResult(ev, call, kDeferredWriteMessage);

  @override
  void registerCancelWaiter(Completer<void> waiter) => _cancelWaiter = waiter;

  @override
  void unregisterCancelWaiter() => _cancelWaiter = null;

  @override
  bool isSkillLoaded(String key) => _loadedSkills.contains(key);

  @override
  void markSkillLoaded(String key) => _loadedSkills.add(key);

  @override
  bool isSkillSearched(String key) => _searchedSkills.contains(key);

  @override
  void markSkillSearched(String key) => _searchedSkills.add(key);

  @override
  Set<String> get searchedSkillNames => Set.unmodifiable(_searchedSkills);

  /// 把事件列表裁到上限以内，并在头部留下一条 [TruncatedEvent] 说明丢了多少。
  ///
  /// **[TruncatedEvent] 自己不占配额。** 它是元信息不是内容 —— 让它占一格会导致
  /// 每次裁剪都比上限少留一条真实事件，多裁几次之后差异会累积得很明显。
  ///
  /// 抽成方法而不是在两个调用点各写一遍：原先那两处是逐字重复的，加了「累加而非
  /// 插入第二条」的逻辑之后，重复会变成两份需要同步维护的分支。
  void _trimEvents() {
    final head = _events.isNotEmpty && _events.first is TruncatedEvent
        ? _events.first as TruncatedEvent
        : null;
    final contentCount = _events.length - (head == null ? 0 : 1);
    if (contentCount <= _kMaxEvents) return;

    final drop = contentCount - _kMaxEvents;
    // head 存在时从下标 1 开始删 —— 保住它，随后累加计数。
    _events.removeRange(head == null ? 0 : 1, (head == null ? 0 : 1) + drop);
    if (head != null) {
      head.droppedEvents += drop;
    } else {
      _events.insert(0, TruncatedEvent(drop));
    }
  }

  /// 测试钩子——`notifyListeners()` 在 `ChangeNotifier` 上是 protected，
  /// 测试代码够不到，只能借这个 public 包装间接调用。
  @visibleForTesting
  void debugNotify() => _safeNotify();

  /// 仅供测试：直接设置正在流式输出的文本（不走真实网络流）。
  ///
  /// 自动滚动最难的一条路径就是「每个 chunk 一次通知」——真实 provider 的
  /// 流没法在 widget 测试里复现，只能直接驱动这个字段。
  @visibleForTesting
  void debugSetStreamingText(String? text) {
    _streamingText = text;
  }

  void _setState(AgentLoopState s) {
    _state = s;
    _phaseStartedAt = DateTime.now();
    _safeNotify();
  }

  @override
  void dispose() {
    // **必须幂等。** cancel() 与 respondApproval() 都刻意做了重复调用安全，
    // 唯独 dispose 没有 —— 而它恰恰是 Flutter 里最容易被调用两次的那个
    // （widget 销毁竞态、Provider 自动 dispose、错误处理路径）。少了这行，
    // 第二次调用会撞上 ChangeNotifier 的 debugAssertNotDisposed。
    if (_disposed) return;
    _disposed = true;
    _cancelRequested = true;
    // 取消之后界面上不该还挂着一段正在转的半截话。
    _streamingText = null;
    // **正在等审批的调用必须叫醒。** `_executeOne` 卡在
    // `await completer.future` 上，没人 complete 它，`_run()` 就永远回不来
    // —— 这条 loop 连同它持有的全部历史都回收不掉，而用户以为会话已经关了。
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete(const ApprovalOutcome(ApprovalDecision.reject));
      }
    }
    _pending.clear();
    // 同一类泄漏，`ask_user` 的等待者不在 `_pending` 里（见 cancel() 里的
    // 同款注释）。
    for (final c in _pendingAnswers.values) {
      if (!c.isCompleted) c.complete('');
    }
    _pendingAnswers.clear();
    // 同一类泄漏，聚合审批的等待者不在 `_pending` 里（见 cancel() 里的
    // 同款注释）。
    final batch = _batchGate;
    if (batch != null && !batch.isCompleted) {
      batch.complete(false);
    }
    _batchGate = null;
    super.dispose();
  }

  void _stop(AgentStopReason reason, {bool failed = false}) {
    _stopReason = reason;
    _state = switch (reason) {
      AgentStopReason.userCancelled => AgentLoopState.cancelled,
      _ => failed ? AgentLoopState.failed : AgentLoopState.done,
    };
    _events.add(StoppedEvent(reason));
    // 排队中的输入退回输入框。**无条件执行,不按 reason 分支**:
    // `_run()` 里「模型收工时若有排队则 continue」已经保证了 completed
    // 时队列必然为空,那条分支跑到这里自然无事发生。少一处条件判断就少
    // 一处将来可能被改坏的地方。
    //
    // 不自动发出去:用户点停止通常是想改口,拿他没确认过的输入去启动一次
    // 新的执行是不能接受的。也不静默丢弃:那是他打的字。
    if (_pendingInputs.isNotEmpty) {
      onPendingReturned?.call(_pendingInputs.join('\n'));
      _pendingInputs.clear();
    }
    _safeNotify();
  }

  /// 模型自然停下、但队列里攒了东西时的终止。
  ///
  /// 与 [_stop] 的区别只在事件：这里发 [PlanProposalEvent] 而不是
  /// [StoppedEvent]。`stopReason` 仍是 `completed`——模型确实正常完成了它
  /// 这一轮的工作，只是有一份方案在等批准。
  void _stopWithProposal() {
    _stopReason = AgentStopReason.completed;
    _state = AgentLoopState.done;
    // 先摘掉事件流里还挂着的旧提案卡，保证同一时刻只有一张活卡。
    //
    // 触发路径：用户在提案卡还在的时候又追问一句 —— `send()` 只摘尾部的
    // `StoppedEvent`、不摘提案卡也不清队列，于是这一轮结束时队列仍非空，
    // 又追加一张列着同一批调用的卡。旧那张此时是个**静默死键**：队列已被
    // 新卡接管，点它的「批准」命中 `approvePlan` 的 `_planQueue.isEmpty`
    // 早退，什么都不会发生 —— 比「界面上有两张卡」更容易让人以为 app 坏了。
    //
    // 这里只保证界面上没有死键，**不预判**「用户追问时该不该自动丢弃已攒
    // 的队列」那个产品语义（队列本身一个字都不动）。那个问题记在 roadmap
    // 里，需要真机上看用户实际怎么用才好定。
    _events.removeWhere((e) => e is PlanProposalEvent);
    _events.add(PlanProposalEvent(List.of(_planQueue)));
    _safeNotify();
  }

  /// 收工时提议把这次学到的东西存下来。
  ///
  /// ## 为什么整段都不能让异常逃出去
  ///
  /// 这是锦上添花的功能，跑在**主路径的收尾**上。一次提炼失败让 `send()`
  /// 抛异常，代价是用户丢掉整轮排查的终态 —— 拿主功能给附加功能陪葬。
  ///
  /// ## 两道守卫
  ///
  /// 提炼是异步的（不 await 就 `_stop`，见调用处），回来时 loop 状态可能
  /// 已经变了：
  ///
  /// 1. `_disposed` —— 用户关了面板且对象已销毁
  /// 2. `_stopReason == null` —— 用户已经发了新消息，loop 又跑起来了。硬塞
  ///    会让卡片插在新一轮 `UserTurnEvent` 后面，位置错乱
  ///
  /// 两种情况都**丢弃**这次提议。那次提炼的 token 白花了，但小概率、金额
  /// 很小，不值得为它加一套持久化重试队列。下次收工还有机会。
  Future<void> _maybeProposeKnowledge() async {
    final distill = knowledgeDistiller;
    if (distill == null) return;
    if (!shouldProposeKnowledge(
      reason: AgentStopReason.completed,
      events: _events,
      alreadyProposed: _knowledgeProposed,
    )) {
      return;
    }
    // 先置位再 await：提炼期间用户若又跑完一轮,不该再触发第二次。
    _knowledgeProposed = true;

    final List<KnowledgeCandidate> candidates;
    try {
      candidates = await distill(List.of(_events));
    } catch (_) {
      return;
    }
    if (candidates.isEmpty) return;
    if (_disposed || _stopReason == null) return;

    _events.add(KnowledgeProposalEvent(candidates));
    _safeNotify();
  }

  /// 为「编辑重发 / 重试」做准备：标记最后一轮、裁掉它在 `_history` 里的部分，
  /// 返回那一轮的原文供 UI 放回输入框。
  ///
  /// 返回 null = 没有可重发的轮次（会话还是空的），UI 什么都不做。
  ///
  /// **只作用于最后一轮**，与直连模式的门禁一致。中间某轮的重发要处理「其后
  /// 多轮的工具调用」，是另一个量级的问题。
  String? prepareResend() {
    if (isRunning) return null;
    final idx = _events.lastIndexWhere((e) => e is UserTurnEvent);
    if (idx < 0) return null;
    final turn = _events[idx] as UserTurnEvent;
    if (turn.supersededByEdit) return null; // 已经被重发过，不重复标记
    turn.supersededByEdit = true;
    truncateHistoryForResend(_history);
    _safeNotify();
    return turn.text;
  }
}

@visibleForTesting
/// 工具执行异常写进 tool result 的文案。
///
/// **代码 bug 类异常要带栈，执行失败类不带。**
///
/// 起因是一次真机事故：`bash` 工具的每一条调用都只回一句
/// `Execution failed: Null check operator used on a null value` —— 连
/// `echo hi` 都是。那句话零信息量：它没说哪个文件、哪一行，而 `TypeError`
/// 必然是我们自己的代码在某个 null 上用了 `!`，栈是唯一能定位它的东西。
/// 栈当时确实被记进了 [_errorStack]，但没有任何界面读它，于是排查只能靠
/// 在源码里逐个 grep `!`。
///
/// 判据取 `TypeError` / `NoSuchMethodError` 而不是「所有异常」：命令返回
/// 非 0、超时、连接断开这些是**正常的执行失败**，它们的 message 本身就说
/// 明了问题，附栈只会挤占 8 KiB 的输出预算、还把模型的注意力引向我们的
/// 实现细节。
///
/// 只取前 4 帧：够定位到出事的那个函数，又不至于把一屏都占满。
String describeToolError(Object e, StackTrace st) {
  // 判据与卡片那一路共用 `isCodeBugError`（`tool_models.dart`）：同一个异常
  // 在「给模型的 tool_result」与「给用户的卡片」上必须归为同一类。两处各写
  // 一遍条件，迟早会漂移成「模型拿到了栈、用户面前只有一句话」——2026-09-13
  // 排查真机「切后台后命令执行失败」时正是这个割裂让排查卡住了。
  if (!isCodeBugError(e)) return 'Execution failed: $e';
  final frames = st.toString().split('\n').take(4).join('\n');
  return 'Execution failed: $e\n$frames';
}

/// 历史里同时最多留几张图。
const int kMaxHistoryImages = 3;

/// 把超出 [max] 的**最老**图片从历史里摘掉，正文追加一条 marker。
///
/// 「最多 3 张」算的是全部消息里 `kind == image` 的**总数**，不是带图消息的
/// 条数。text 类不计入 —— 它的正文已进 `content`，不构成重发成本。
///
/// marker 带文件名，与 skill 正文那条同构（`_droppedMarker` 已为 skill 做过
/// 一次特殊文案，理由相同：通用的 `[dropped]` 不带线索，模型不知道那里曾有
/// 什么，只会凭残留印象往下做）。
@visibleForTesting
List<AIMessage> capHistoryImages(List<AIMessage> history,
    {int max = kMaxHistoryImages}) {
  final total = history.fold<int>(
      0,
      (s, m) =>
          s +
          (m.attachments ?? const [])
              .where((a) => a.kind == AttachmentKind.image)
              .length);
  if (total <= max) return history;

  var toDrop = total - max;
  final out = List<AIMessage>.from(history);
  for (var i = 0; i < out.length && toDrop > 0; i++) {
    final atts = out[i].attachments;
    if (atts == null || atts.isEmpty) continue;
    final kept = <Attachment>[];
    final dropped = <String>[];
    for (final a in atts) {
      if (a.kind == AttachmentKind.image && toDrop > 0) {
        dropped.add(a.name ?? 'image');
        toDrop--;
      } else {
        kept.add(a);
      }
    }
    if (dropped.isEmpty) continue;
    final markers = dropped
        .map((n) =>
            '[image dropped: $n — resend it if you still need to look at it]')
        .join('\n');
    out[i] = AIMessage(
      role: out[i].role,
      content: '${out[i].content}\n$markers',
      type: out[i].type,
      command: out[i].command,
      displayText: out[i].displayText,
      toolCalls: out[i].toolCalls,
      toolResults: out[i].toolResults,
      attachments: kept,
    );
  }
  return out;
}

/// 终态赋值 + 耗时计算。`AgentLoop._finishToolCall` 与测试钩子共用这一份。
void applyToolCallTerminalState(ToolCallEvent ev, ToolCallStatus status) {
  ev.status = status;
  // startedAt 为 null = 这次调用压根没开始执行（审批被拒、批量提案被丢弃），
  // 那种情况没有「耗时」可言，保持 null。
  final started = ev.startedAt;
  if (started != null && ev.durationMs == null) {
    ev.durationMs = DateTime.now().difference(started).inMilliseconds;
  }
}

/// 仅供测试：`AgentLoop._finishToolCall` 的逻辑本体。
///
/// 抽成顶层函数而不是把方法改成 public —— 它不需要任何实例状态，而 public
/// 方法会出现在生产代码的补全列表里，诱导别人绕过 `_finishToolCall` 直接调。
@visibleForTesting
void finishToolCallForTest(ToolCallEvent ev, ToolCallStatus status) =>
    applyToolCallTerminalState(ev, status);

/// 编辑重发时裁掉 `_history` 的最后一轮。
///
/// **边界必须落在 `role == 'user'` 上，这不是随手选的。** user 之后的
/// `assistant(toolCalls)` 与 `tool(toolResults)` 是成对出现的，从 user 起整段
/// 拿掉不会留下孤儿 `tool_use`；而孤儿会让下一次请求被服务端 400 拒掉 ——
/// `_flushPendingInputs` 的注释里写着同一件事：「wire protocol 要求每个
/// tool_use 恰好配一个 tool_result，在配对完成之前插一条 user 消息，这段历史
/// 在下一次请求时会被服务端 400 拒掉」。
///
/// 也不能按事件 seq 反查下标：`_events` 与 `_history` 没有稳定的位置对应关系
/// （compaction 会重写 history、`_pendingInputs` 会在轮边界注入、`_kMaxEvents`
/// 会裁 events），任何基于下标的映射都会在这三件事之一发生后失准。
void truncateHistoryForResend(List<AIMessage> history) {
  final idx = history.lastIndexWhere((m) => m.role == 'user');
  if (idx < 0) return;
  history.removeRange(idx, history.length);
}
