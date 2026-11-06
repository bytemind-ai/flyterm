// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../data/models/server.dart';
import '../../data/repositories/server_repository.dart';
import '../../data/secure_storage.dart';
import '../../data/terminal_settings.dart';
import '../../sftp/sftp_service.dart' show sftpOpsFromClient;
import '../../ssh/session_manager.dart';
import '../ai_provider_service.dart';
import '../attachment_store.dart';
import 'agent_exec_channel.dart';
import 'agent_instructions.dart';
import 'agent_loop.dart';
import 'usage_totals.dart';
import 'agent_prompt.dart';
import 'agent_runner_resolve.dart';
import 'agent_session_manager.dart';
import 'agent_skill_manager.dart';
import 'agent_tools.dart';
import 'ai_command_manager.dart';
import 'builtin_skill_index.dart';
import 'builtin_skill_manager.dart';
import 'builtin_skill_merge.dart';
import '../../app_control/app_control_service.dart';
import 'app_permission.dart';
import 'command_runner.dart';
import 'exec_channel_factory.dart';
import 'knowledge_distiller.dart';
import 'saved_command_index.dart';
import 'server_notes_manager.dart';
import 'server_targets.dart';
import 'skill.dart';
import 'skill_index.dart';
import 'skill_search.dart';

/// `buildAgentLoop` 需要的全部 provider,一次性抓好。
///
/// ## 为什么是「抓好」而不是「每次 read」
///
/// `AgentLoop` 的寿命**长于创建它的那个 State**:它由 [AgentSessionManager]
/// 持有,面板关了、tab 切了、页面退了,它还在跑。而注入给它的闭包是模型在
/// **任意时刻**回调的。只要回调发生时那个 State 已经 unmount,闭包里的
/// `context.read` 就会抛 `State.context` 空检查——表现成「bash 工具持续失败,
/// 报同一个客户端错误」,且与服务器端毫无关系。
///
/// 这段约束原先写在 `terminal_screen.dart` 的字段注释里(`_serverRepoForAgent`
/// 那三个),现在随装配代码一起搬过来,只维护一处。
///
/// 只收**长寿单例**。[settings] 与 [attachments] 是例外的可空项,见各自文档。
class AgentAssemblyDeps {
  final ServerRepository servers;
  final SessionManager sessions;
  final SecureStorageService storage;
  final AgentSessionManager agentMgr;
  final AIProviderService ai;
  final AgentSkillManager skills;
  final BuiltinSkillManager builtinSkills;
  final AiCommandManager savedCommands;

  /// 机器笔记库。进程级单例，与 [skills] 同形。
  final ServerNotesManager serverNotes;

  /// 可空:widget 测试大多不搭这个 provider,写成不可空会让装配在测试里抛
  /// `ProviderNotFoundException`。`global_ai_screen.dart` 的 `_switchModel`
  /// 早就是这个写法,这里保持一致。
  ///
  /// null 时下载落点与「发布到系统媒体库」两个能力不可用 —— 本期全局会话
  /// 本来就不声明传输类工具,不构成缺口。
  final TerminalSettings? settings;

  /// 可空:同上。null = 这个会话不支持图片附件,附件按钮不渲染。
  final AttachmentStore? attachments;

  /// app 自身控制。可空:同上。null = 这个会话不声明 app 工具。
  ///
  /// **进程级单例**（由 `main.dart` 注入），不是每会话一个。两个 AI 会话
  /// 各持一份撤销栈会在交叉改动时产生错误状态：A 记 `13→15`、B 记 `15→17`，
  /// A 撤销就把设置退回 13，悄悄抹掉 B 的意图。app 设置本来就是全局的,
  /// 撤销栈跟着全局才自洽。
  final AppControlService? appControl;

  /// 跨会话 token 累计。可空:同上 —— 没注入时 agent 行为完全不变,只是
  /// 面板底部不显示累计那一截。生产路径由 `AgentSessionManager` 传入。
  final UsageTotals? usageTotals;

  const AgentAssemblyDeps({
    required this.servers,
    required this.sessions,
    required this.storage,
    required this.agentMgr,
    required this.ai,
    required this.skills,
    required this.builtinSkills,
    required this.savedCommands,
    required this.serverNotes,
    this.settings,
    this.attachments,
    this.appControl,
    this.usageTotals,
  });

  /// 从一棵 provider 树读一次。
  ///
  /// **必须在 `initState` 或别的「context 一定可用」的时机调用**,之后把结果
  /// 存进字段。不要在闭包里调它——那正是本类要避免的事。
  factory AgentAssemblyDeps.fromContext(BuildContext context) =>
      AgentAssemblyDeps(
        servers: context.read<ServerRepository>(),
        sessions: context.read<SessionManager>(),
        storage: context.read<SecureStorageService>(),
        agentMgr: context.read<AgentSessionManager>(),
        ai: context.read<AIProviderService>(),
        skills: context.read<AgentSkillManager>(),
        builtinSkills: context.read<BuiltinSkillManager>(),
        savedCommands: context.read<AiCommandManager>(),
        serverNotes: context.read<ServerNotesManager>(),
        settings: context.read<TerminalSettings?>(),
        attachments: context.read<AttachmentStore?>(),
        appControl: context.read<AppControlService?>(),
        // `SharedPreferences` 在 `main.dart` 里是非可空 provider，但这里
        // 必须按可空读：`fromContext` 会被各种 widget 测试调用，它们的
        // provider 树里没有 prefs —— 硬读会让那些测试全部报
        // `ProviderNotFoundException`。累计是纯展示的附加项，拿不到就不记。
        usageTotals: switch (context.read<SharedPreferences?>()) {
          final p? => UsageTotals(p),
          null => null,
        },
      );
}

/// 「要不要把 app 自身控制的工具装进工具清单」的判据。
///
/// **只剩 `hasService` 一个条件**（2026-10-13）。原先还有 `mode != off` 一条，
/// 但 `AppPermissionMode.off` 已随两档合并被删除 —— 现在没有"关闭 app 工具"
/// 这个档，App 写操作靠审批卡拦（`ask` / `readOnly` 档）或放行（`bypass` 档），
/// 而硬清单 [kAppHardApproval] 在任何档位都审批。
///
/// [hasService] 为 false 时（没有 `AppControlService`）工具调用必然回
/// `not available`，声明它只会让模型白试一轮 —— 与 `hasOtherServers` 为 false
/// 时藏掉 `copy_between_servers` 是同一条原则：**不告诉模型它有用不了的东西**。
///
/// 抽成顶层纯函数而不是内嵌在 `buildAgentLoop` 的闭包里，理由与下面
/// [resolveHasOtherServers] 完全相同：那一行判据因为埋在闭包里、依赖一整套
/// provider 装配，长期没有任何测试覆盖。这条判据同样「语义新、容易被改错」，
/// 不该重蹈覆辙。
bool shouldDeclareAppTools({required bool hasService}) => hasService;

/// 「要不要把 `list_servers` 之类暴露多机信息的工具装进工具清单」的判据。
///
/// 抽成顶层纯函数是因为这是全部改动里语义最新、最容易被改错的一行判据
/// （两种模式用的阈值不同），却因为内嵌在 `buildAgentLoop` 的闭包里、依赖
/// 一整套 provider 装配而长期没有任何测试覆盖它。纯函数不需要
/// `AgentAssemblyDeps`，可以直接用四种 `(sshServerCount, requireExplicitServer)`
/// 组合钉死。
///
/// ## 为什么两个模式的阈值不同
///
/// - **终端页 AI 面板**（[requireExplicitServer] = false，会话绑定在当前这台
///   机器上）：问的是「除了正在用的这台，还有没有**别的**机器可切」，所以要
///   先刨掉自己，阈值是 `> 1`。
/// - **全局 AI tab**（[requireExplicitServer] = true，没有「当前这台」这个
///   概念，`server` 参数本身就是必填）：问的是「有没有**至少一台**机器可
///   打」，没有「自己」要刨，阈值是 `>= 1`。
///
/// 两边都在问「`list_servers` 这类工具对模型有没有意义」，但「有没有意义」
/// 的基准点不同——这正是为什么不能共用同一个阈值。
bool resolveHasOtherServers({
  required int sshServerCount,
  required bool requireExplicitServer,
}) =>
    requireExplicitServer ? sshServerCount >= 1 : sshServerCount > 1;

/// 造一条 agent 会话。两个调用方共用:终端页 AI 面板、底部全局 AI tab。
///
/// ## 两个身份必须分开
///
/// [sessionKey] 是**会话身份** —— loop 在 [AgentSessionManager] 里的键、
/// 归档落在 `agent_sessions.server_id` 的哪一行、信任档 `modeFor` 查哪一条
/// 覆盖。终端页传 `server.id`,全局 tab 传 `AIEngine.kGlobalServerId`。
///
/// [defaultServer] 是**默认执行目标** —— `runnerProvider(null)` 打哪台。
/// 终端页传当前 tab 的机器;全局 tab 传 **null**,因为它不属于任何机器。
///
/// 这两个以前是同一个东西(都从 `tab.server` 来),把它们拆开正是全局会话
/// 能成立的全部原因。[defaultServer] 为 null 时:
///
/// - `server` 参数在工具清单里提升为必填(见 `agentToolSpecsFor`)
/// - 模型仍漏传时,[resolveAgentRunner] 回 [MissingServerRunner] 让它自纠
/// - 不声明依赖终端或当前会话的工具(`read_terminal` / job 三件套 / 传输)
///
/// ## 关于 `restoreFrom`
///
/// 调用方必须在调用本函数**之前**把存档 await 好传进来 —— 本函数是同步的
/// (被 `loopFactory: AgentLoop Function()` 这个同步签名约束)。
AgentLoop buildAgentLoop({
  required AgentAssemblyDeps deps,
  required String sessionKey,
  required Server? defaultServer,

  /// 服务器清单快照。`runnerProvider` 是同步闭包,等不了异步查询 —— 这份
  /// 缓存存在的全部理由。调用方在建 loop 之前刷新它。
  required List<Server> Function() serverCache,

  /// 发给模型的语言。调用方在有 `context` 的地方求值
  /// (`Localizations.localeOf(context).toLanguageTag()`)。
  required String languageTag,

  /// 当前 l10n 的语言自称，见 `buildAgentSystemPrompt` 的同名参数。
  String? languageName,

  /// 构造时的一次性快照,**刻意不是每轮现取**:它们真的每轮都变,放进
  /// `systemPromptProvider` 闭包会让 system 消息每轮变一次内容,Anthropic 的
  /// cache 断点就在那个字段上——前缀每轮失效,等于每轮全价重算。
  String? cwdSnapshot,
  String? terminalSnapshot,

  /// `read_terminal` 的数据源。**每轮现取**,这是它与 [terminalSnapshot] 的
  /// 全部区别:快照会随会话变旧,而这条 loop 寿命跨多次面板开关。
  /// null = 这个会话没有终端(全局 tab)。
  String? Function()? terminalTextProvider,

  /// 当前工作目录。null = 没有(全局 tab,每台机器用登录默认目录)。
  String? Function()? cwdProvider,

  /// 这台机器的 agent 笔记（**app 端存储**，来自 `ServerNotesManager`）。
  /// null = 这个会话没有归属机器（全局 tab）。
  String? Function()? machineNotes,

  /// 模型每次调 `list_servers`(或任何带 `server` 的工具)时，把刚查到的最新
  /// 清单回传给调用方刷新它那份缓存。
  ///
  /// 这是搬运前 `serverListProvider` 里那句 `if (mounted) _serverCache = list`
  /// 的等价物：`serverCache` 本身是只读 getter，没有写入口，所以回写必须由
  /// 调用方自己做（它才知道 `mounted` 和该往哪个字段写）。
  ///
  /// 没有它的后果不是报错而是**沉默地过期**：全局 AI tab 靠 IndexedStack 常驻、
  /// 没有「重开面板」这个自愈点，会话期间新增的服务器会一直不出现在 system
  /// prompt 内联的机器名单里。
  void Function(List<Server> servers)? onServersRefreshed,

  Map<String, dynamic>? restoreFrom,
}) {
  final mgr = deps.agentMgr;
  final svc = deps.ai;
  final skills = deps.skills;
  final builtin = deps.builtinSkills;
  final savedCmds = deps.savedCommands;
  final sessions = deps.sessions;
  final settings = deps.settings;

  // 构造时算一次,喂给下面的 systemPrompt 快照。`toolSpecsProvider` 是独立
  // 闭包、每轮自己重新调 resolveToolTier —— 两处不共享这个值是刻意的。
  final tier = _resolveToolTierSafe(svc, mgr.toolTierOverride);

  // 全局会话(没有默认机器)必须显式带 server。
  final requireExplicitServer = defaultServer == null;

  Server? serverById(String id) {
    for (final s in serverCache()) {
      if (s.id == id) return s;
    }
    return null;
  }

  AgentExecChannel channelFor(Server s) => execChannelForServer(
        mgr: mgr,
        server: s,
        sessions: sessions,
        storage: deps.storage,
      );

  CommandRunner runnerFor(Server s) {
    final ch = channelFor(s);
    return SshCommandRunner(ch.obtain, onDeadChannel: ch.invalidate);
  }

  /// 除「当前这台」之外还有别的 ssh 机器吗?
  ///
  /// 真正的判据抽成了顶层纯函数 [resolveHasOtherServers]（不需要任何
  /// provider/context，可以直接单测两个阈值分叉），这里只负责从
  /// `serverCache()` 数出 ssh 条目数再喂给它。
  bool hasOtherServers() => resolveHasOtherServers(
        sshServerCount:
            serverCache().where((s) => s.serverType == 'ssh').length,
        requireExplicitServer: requireExplicitServer,
      );

  final loop = AgentLoop(
    // 跨会话累计。下面用的 `providerProvider().displayName` 才是桶的 key ——
    // 不能拿这里的 snapshot，切模型是运行期的。
    usageTotals: deps.usageTotals,
    // 现取而非定死 —— 用户换 provider 之后,这条已存在的 loop 也该用新的。
    providerProvider: () => svc.provider!,
    runnerProvider: (serverId) => resolveAgentRunner(
      serverId: serverId,
      defaultServer: defaultServer,
      serverById: serverById,
      runnerFor: runnerFor,
    ),
    // 预热与 runnerProvider 取的是**同一条** channel —— 不同源的话,预热建好
    // 的连接不是随后执行要用的那条,白建。
    prewarmProvider: (serverId) async {
      final target = serverId == null ? defaultServer : serverById(serverId);
      if (target == null) return;
      await channelFor(target).obtain();
    },
    rulesProvider: () => mgr.rules,
    modeProvider: () => mgr.modeFor(sessionKey),
    toolSpecsProvider: () => agentToolSpecsFor(
      _resolveToolTierSafe(svc, mgr.toolTierOverride),
      hasSkills: skills.names.isNotEmpty,
      hasSkillOverflow: skills.overflowCount > 0,
      hasSavedCommands: savedCmds.indexEntries.isNotEmpty,
      hasOtherServers: hasOtherServers(),
      requireExplicitServer: requireExplicitServer,
      // 闭包，每轮重新求值：用户在设置里开关 app 控制，当前会话下一轮就
      // 跟上，不用重开会话。
      hasAppControl: shouldDeclareAppTools(hasService: deps.appControl != null),
    ),
    onRuleAdded: (r) => mgr.addRule(r),
    systemPromptProvider: (inputs) => buildAgentSystemPrompt(
      activeToolNames: inputs.activeToolNames,
      hasAtReference: inputs.hasAtReference,
      cwd: cwdSnapshot,
      terminalContext: terminalSnapshot,
      languageTag: languageTag,
      languageName: languageName,
      tier: tier,
      hasOtherServers: hasOtherServers(),
      requireExplicitServer: requireExplicitServer,
      // 全局会话把机器名直接内联进 prompt,省掉开场必然要发的那一轮
      // `list_servers`。几十个 token 换一整轮往返。
      serverNames: requireExplicitServer
          ? [
              for (final s in serverCache())
                if (s.serverType == 'ssh') s.name
            ]
          : const [],
      mode: mgr.modeFor(sessionKey),
      instructions: composeInstructions(
        global: mgr.instructions,
        machine: machineNotes?.call(),
      ),
      savedCommandIndex: composeSavedCommandIndex(savedCmds.indexEntries),
      skillIndex: composeSkillIndex(skills.indexEntries),
      builtinSkillIndex: composeBuiltinSkillIndex(builtin.entries),
      hasSkillOverflow: skills.overflowCount > 0,
    ),
    cwdProvider: cwdProvider,
    terminalTextProvider: terminalTextProvider,
    serverListProvider: () async {
      final list = await deps.servers.findAll();
      onServersRefreshed?.call(list);
      final out = <ServerListEntry>[];
      for (final s in list) {
        // 本地 shell 一类没有 host 的条目对 agent 无意义,跳过。
        if (s.serverType != 'ssh') continue;
        out.add(ServerListEntry(
          id: s.id,
          name: s.name,
          groupName: s.groupName,
          host: s.host,
          credsOk: await channelFor(s).isAvailable(),
        ));
      }
      return out;
    },
    sftpOpsProvider: (serverId) async {
      final target = serverId == null ? defaultServer : serverById(serverId);
      if (target == null) {
        throw StateError('No target server for SFTP; pass `server`.');
      }
      return sftpOpsFromClient(await channelFor(target).obtain());
    },
    relayTempDirProvider: getTemporaryDirectory,
    downloadDirProvider: settings?.resolveDownloadDir,
    publishToPublicStore: () => settings?.downloadsToPublicStore ?? false,
    pickLocalFile: () async {
      final r = await FilePicker.platform.pickFiles();
      return r?.files.singleOrNull?.path;
    },
    restoreFrom: restoreFrom,
    skillBodyProvider: (name, {Set<String> alsoAllow = const {}}) =>
        resolveSkillBody(
      name: name,
      builtinBody: builtin.bodyOf,
      userBody: skills.bodyOf,
      alsoAllow: alsoAllow,
    ),
    skillNamesProvider: () =>
        mergeSkillNames(builtin: builtin.names, user: skills.names),
    builtinSkillNamesProvider: () => builtin.allNames,
    skillSearchProvider: (query, {int limit = kSkillSearchLimit}) =>
        searchSkills(skills.skills, query, limit: limit),
    skillSaver: (name, description, body, assets) => skills.save(
      name: name,
      description: description,
      body: body,
      source: SkillSource.ai,
      // `assets` 为 null（模型没给这个参数）时**不传**，让 repo 保持“不动
      // 附件”。两者不同：null = 这次保存没提附件，`[]` = 这条技能现在
      // 没有附件。
      assets: assets,
    ),
    skillAssetProvider: (name, {alsoAllow = const {}}) =>
        skills.assetsOf(name, alsoAllow: alsoAllow),
    serverNoteSaver: (serverId, heading, body) async {
      // serverId 为 null = 用当前会话那台。全局会话没有「那台」，必须由
      // 模型在 `server` 参数里给出，拿不到就报错而不是猜一个落点 —— 猜错
      // 会把一台机器的事实写进另一台的笔记，而且没人会发现。
      final target = serverId ?? defaultServer?.id;
      if (target == null) {
        return const ServerNoteSaveResult.failed(
            'This session is not tied to one machine. Pass `server` to say '
            'which one these notes belong to.');
      }
      return deps.serverNotes.appendNote(
        serverId: target,
        heading: heading,
        body: body,
      );
    },
    savedCommandProvider: savedCmds.byName,
    savedCommandNamesProvider: () => savedCmds.names,
    knowledgeDistiller: (events) async {
      if (!mgr.knowledgeCaptureEnabled) return const [];
      return KnowledgeDistiller(() => svc.provider!).distill(
        buildDistillInput(
          events: events,
          existingSkills: skills.indexEntries,
          currentMachineNotes: machineNotes?.call(),
        ),
      );
    },
    attachmentStore: deps.attachments,
    appControl: deps.appControl,
    // 把 `server` 名字解析成 id。复用 `resolveServerTarget` 而不是在这里
    // 重写一遍 —— 「省略 server 时用当前会话那台」这条逻辑在 `server_targets`
    // 里已有实现与测试。
    serverIdResolver: (name) async {
      // 这里可以 await（与 `runnerProvider` 的同步闭包不同）：计划任务工具
      // 本来就要落库，本来就在异步路径上。
      //
      // 列表要转成 `ServerListEntry` —— `resolveServerTarget` 判的是那个
      // 类型。转换只取解析真正会用到的字段（id / name），其余留空：多填的
      // 字段只会让将来有人误以为它们被用到了。
      final all = await deps.servers.findAll();
      final entries = [
        for (final s in all)
          if (s.serverType == 'ssh')
            ServerListEntry(
                id: s.id, name: s.name, host: s.host, credsOk: true),
      ];
      final target = resolveServerTarget(name, entries);
      if (!target.ok) return null;
      // `serverId` 为 null = 模型省略了 `server`，用当前会话那台。
      return target.serverId ?? defaultServer?.id;
    },
  );
  mgr.register(sessionKey, loop);
  return loop;
}

/// [resolveToolTier] 包一层,让一个瞬时不可用的 provider 不能掀掉整轮。
///
/// 「用哪一档工具」是低风险选择且有合理回落(lean 档两个工具都能从 `bash`
/// 调到),不该因为 `svc.provider` 在两次读之间竞态成 null 就空检查崩掉。
/// 对比 `providerProvider: () => svc.provider!` —— 那个故意留着抛:没有
/// provider 就没有模型可调,那种失败需要响亮,而不是被悄悄降级。
AgentToolTier _resolveToolTierSafe(
  AIProviderService svc,
  AgentToolTier? override,
) {
  final provider = svc.provider;
  if (provider == null) return AgentToolTier.lean;
  return resolveToolTier(providerType: provider.providerType, override: override);
}
