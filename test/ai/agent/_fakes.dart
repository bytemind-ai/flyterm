import 'dart:io' show Directory;

import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/knowledge.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';
import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/ai/agent/server_notes_manager.dart'
    show ServerNoteSaveResult;
import 'package:flyterm/ai/agent/server_targets.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/ai/agent/skill_search.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/usage_totals.dart';
import 'package:flyterm/ai/agent/app_permission.dart';
import 'package:flyterm/ai/agent/tool_groups.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/web_fetch.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/sftp/sftp_service.dart' show SftpOps;

/// 名字不带下划线：跨文件 import 用得着。
class FakeProvider extends AIProvider {
  /// 元素是 [AIResponse]（正常返回）或任意对象（抛出去）。
  final List<Object> script;

  /// 每轮收到的消息与工具清单，供断言。
  final List<List<AIMessage>> seen = [];
  final List<List<ToolSpec>> seenTools = [];

  /// 每轮调用时的回调 —— 用来在轮次之间改变外部状态（如切换档位）。
  final void Function(List<ToolSpec> tools)? onCall;

  /// 流式脚本。null = 不覆盖流式实现，走基类默认的「包装成单元素流」。
  ///
  /// 非 null 时每轮取一项：`List<AgentChunk>` 按序 yield；其他对象抛出去。
  /// 独立于 [script] 是刻意的 —— 大部分既有测试只关心非流式那条路的行为，
  /// 让它们继续走默认包装，不必为流式改一遍。
  final List<Object>? streamScript;

  /// 非工具调用的 `complete()` 脚本。元素是 String（返回）或任意对象（抛出）。
  ///
  /// 与 [script] 分开：`complete` 走的是完全不同的路径（知识提炼用它），
  /// 混进同一个脚本会让既有测试的下标全部错位。
  final List<Object>? completeScript;

  /// `complete()` 收到的消息，供断言。
  final List<List<AIMessage>> seenComplete = [];

  int _i = 0;
  int _si = 0;
  int _ci = 0;

  /// 最近一次调用收到的 `sessionKey`。
  ///
  /// 存在的理由很具体：`AgentLoop` 那边「加了字段却忘了在调用点传参」是
  /// 个静默失败——不加这个记录的话，所有测试都照常通过。
  String? lastSessionKey;

  FakeProvider(
    this.script, {
    this.onCall,
    this.streamScript,
    this.completeScript,
    bool supportsTools = true,
  }) : _supportsTools = supportsTools;

  final bool _supportsTools;

  /// 刻意取真实长度，不是 `'fake'`。
  ///
  /// 生产实现是 `'Anthropic (claude-sonnet-4-5-20250929)'` 这种四十来字符的
  /// 串（见各 provider 的 displayName）。这里曾经只有四个字符，于是「模型名
  /// 把面板头部撑溢出、把新建会话按钮挤出屏幕」这个 bug 在全套测试里毫无反应
  /// —— 假数据不具代表性，测的就不是真实处境。
  @override
  String get displayName => 'Fake (claude-sonnet-4-5-20250929)';

  @override
  String get providerType => 'fake';

  @override
  bool get supportsTools => _supportsTools;

  @override
  Future<String> complete(List<AIMessage> messages) async {
    seenComplete.add(List.of(messages));
    if (completeScript == null || _ci >= completeScript!.length) return '';
    final item = completeScript![_ci++];
    if (item is String) return item;
    throw item;
  }

  @override
  Future<AIResponse> completeWithTools(
      List<AIMessage> messages, List<ToolSpec> tools,
      {String? sessionKey}) async {
    lastSessionKey = sessionKey;
    seen.add(List.of(messages));
    seenTools.add(List.of(tools));
    onCall?.call(tools);
    if (_i >= script.length) return const AIResponse(text: 'fallback done');
    final item = script[_i++];
    if (item is AIResponse) return item;
    throw item;
  }

  @override
  Stream<AgentChunk> completeWithToolsStream(
      List<AIMessage> messages, List<ToolSpec> tools,
      {String? sessionKey}) {
    lastSessionKey = sessionKey;
    if (streamScript == null) {
      return super.completeWithToolsStream(messages, tools,
          sessionKey: sessionKey);
    }
    seen.add(List.of(messages));
    seenTools.add(List.of(tools));
    onCall?.call(tools);
    return _emit();
  }

  Stream<AgentChunk> _emit() async* {
    if (_si >= streamScript!.length) {
      yield const StreamDone(AIResponse(text: 'fallback done'));
      return;
    }
    final item = streamScript![_si++];
    if (item is List<AgentChunk>) {
      for (final c in item) {
        // 每个 chunk 之间让出一次事件循环 —— 真实流不会在一个 microtask
        // 里全部到达，测试若跑在那种时序里，「流到一半取消」根本没有插入点。
        await Future<void>.delayed(const Duration(milliseconds: 1));
        yield c;
      }
      return;
    }
    throw item;
  }
}

class FakeRunner implements CommandRunner {
  /// 执行过的命令，按顺序。
  final List<String> ran = [];

  /// 每次调用收到的 cwd，与 [ran] 一一对应。多机测试用它断言跨机传的是 null。
  final List<String?> cwds = [];

  /// 按序返回；用尽之后重复最后一条（多数测试只关心前几条）。
  final List<CommandOutput> results;

  final void Function(String command)? onRun;

  FakeRunner({
    List<CommandOutput>? results,
    CommandOutput? result,
    this.onRun,
  }) : results = results ??
            [
              result ??
                  const CommandOutput(stdout: 'ok', stderr: '', exitCode: 0)
            ];

  @override
  Future<CommandOutput> run(String command,
      {String? cwd,
      Duration? timeout,
      bool denoise = false,
      int? maxBytes,

      TruncateMode truncate = TruncateMode.head}) async {
    ran.add(command);
    cwds.add(cwd);
    onRun?.call(command);
    // **这个延迟是必需的，不是凑数。**
    //
    // 真实执行要跨一次网络往返，必然落到 macrotask。若 fake 只用 microtask
    // 返回，整条 loop 会在任何 Timer 回调之前跑完 —— 包括测试自己的
    // `await Future.delayed(Duration.zero)`。于是「跑到一半去 cancel」这种
    // 测试根本没有可插入的时机：cancel 执行时 loop 早已结束，
    // `if (!isRunning) return;` 让它成了空操作，断言看到的是 completed。
    //
    // Dart 会先排空整个 microtask 队列，再执行 Timer。fake 必须在这一点上
    // 像真的，否则测试跑在一个现实中不存在的时序里。
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return results[ran.length - 1 < results.length
        ? ran.length - 1
        : results.length - 1];
  }

  @override
  Future<void> dispose() async {}
}

AIResponse bashCall(String id, String cmd, [String desc = 'why']) =>
    AIResponse(toolCalls: [
      ToolCall(id: id, name: 'bash', args: {'command': cmd, 'description': desc})
    ]);

/// 构造一条测试用 loop。参数一律用**平凡值**而不是闭包，除了 [toolSpecs]
/// —— 后者要在轮次之间变化，用来测「换档不需要重建 loop」。
/// 全部参数具名，包括 provider 与 runner。
///
/// 位置参数在这里是陷阱：两个参数类型不同但调用点长得很像，写反了编译器报的
/// 是「类型不匹配」而不是「顺序搞反了」，而这个辅助会被十几个测试调用。
AgentLoop makeLoop({
  required FakeProvider provider,
  CommandRunner? runner,
  PermissionRuleSet rules = const PermissionRuleSet(defaultAllowRules),

  /// 直接注入 `rulesProvider`，优先于 [rules]。
  ///
  /// 存在的理由是**对象身份**：[rules] 那条路包出来的闭包每次返回同一个
  /// 实例，而生产接线是 `() => mgr.rules`，它每次都从 prefs 反序列化出一个
  /// **新**对象。抢跑落地的判据用的是 `identical(...)`，两者在这一点上行为
  /// 相反 —— 只能传值的 helper 永远测不出那条路径。
  PermissionRuleSet Function()? rulesProvider,
  PermissionMode mode = PermissionMode.ask,
  int maxTurns = 25,
  List<PermissionRule>? added,
  Map<String, dynamic>? restoreFrom,
  List<ToolSpec> Function() toolSpecs = _defaultToolSpecs,

  /// 当前 tab 的 cwd。默认固定返回 `/tmp`——大多数测试不关心 cwd 会不会变。
  /// 抢跑的「判据在飞行途中变了」这类测试需要在起飞之后改变返回值，因此
  /// 这里接受一个 closure 而不是一个平凡值。
  String? Function() cwdProvider = _defaultCwd,

  /// 按 serverId 取 ops。key 为 null 表示当前会话那台。
  Map<String?, SftpOps>? sftpOpsByServerId,
  Future<SftpOps> Function()? sftpOpsProvider,
  Future<Directory> Function()? relayTempDirProvider,
  Future<Directory> Function()? downloadDirProvider,
  bool Function()? publishToPublicStore,
  Future<String?> Function()? pickLocalFile,

  /// 按 serverId 分别记录的 runner —— 多机测试用它断言「哪条命令打了哪台」。
  Map<String, CommandRunner>? runnersByServerId,

  /// 提供给 loop 的服务器清单。null = 不支持多机。
  List<ServerListEntry>? servers,

  /// 直接注入 `serverListProvider`，优先于 [servers]。
  ///
  /// 存在的唯一理由是**数调用次数**：生产实现要跑 SQLite + 逐台读 keystore，
  /// 而 `_executeCommandTool` 只在跨机调用时才需要它。想断言「本机调用没去
  /// 碰它」就必须能观测它有没有被调，[servers] 那条路包出来的闭包做不到。
  Future<List<ServerListEntry>> Function()? serverListProvider,

  /// `read_terminal` 的数据源。null = 没有可读的终端。
  String? Function()? terminalTextProvider,

  /// 技能正文来源。null = 这个 loop 不支持技能。
  Future<String?> Function(String name, {Set<String> alsoAllow})?
      skillBodyProvider,

  /// 索引里的技能名，用于匹配与错误提示。
  List<String> Function()? skillNamesProvider,

  /// 技能检索。null = 这个 loop 不支持检索。
  List<SkillSearchHit> Function(String query, {int limit})?
      skillSearchProvider,

  /// `save_skill` 的落库回调。
  Future<void> Function(String name, String description, String body,
      List<AgentSkillAsset>? assets)? skillSaver,

  /// 按 name 读技能附件。null = 这个 loop 不支持附件。
  Future<List<AgentSkillAsset>> Function(String name,
      {Set<String> alsoAllow})? skillAssetProvider,

  /// `save_note` 的落库回调。null = 这个 loop 不支持机器笔记。
  Future<ServerNoteSaveResult> Function(
          String? serverId, String heading, String body)?
      serverNoteSaver,

  /// 按名字取一条可调用的收藏命令。**同步** —— `_resolve` 不能 await。
  FavoriteCommand? Function(String name)? savedCommandProvider,

  /// 索引里的收藏命令名，用于未命中时的错误提示。
  List<String> Function()? savedCommandNamesProvider,

  /// 预热回调。测试用它断言「哪些工具触发了预热、预热的是哪台机器」。
  Future<void> Function(String? serverId)? prewarmProvider,

  /// 非正常终止时排队文本的退回目标。测试用它断言「没有静默吞掉用户输入」。
  void Function(String text)? onPendingReturned,

  /// 收尾知识提炼。null = 这个 loop 不做自动沉淀。
  Future<List<KnowledgeCandidate>> Function(List<AgentEvent> events)?
      knowledgeDistiller,

  /// 手机端取数的 fake。null = 手机端路径不可用（只能走远端）。
  WebFetcher? webFetcher,

  /// app 控制门面。null = 这个 loop 不支持 app 工具。
  AppControlService? appControl,

  /// `server` 名字 → serverId 的解析。null = 一律解析不出目标。
  Future<String?> Function(String? name)? serverIdResolver,
  UsageTotals? usageTotals,

  /// 预先解锁的工具组（`more_tools` 的分组，见 `tool_groups.dart`）。
  ///
  /// **默认全解锁。** 这个 helper 被同目录几十个测试用，它们绝大多数写于
  /// `more_tools` 之前，直接调用 `upload_file` / `web_fetch` / `save_skill`
  /// 等工具——那些用例验证的是**工具本身的行为**，不是解锁机制。默认全解锁
  /// 让它们保持原本的语义，否则会集体收到「is not active yet」而不是它们
  /// 要断言的东西。
  ///
  /// 验证解锁机制的用例（`more_tools_test.dart`）显式传 `const {}`。
  /// null = 全解锁（**从 kToolGroups 派生**，新增组自动包含）。
  /// 写死组名列表会让「加了新组但测试没解锁它」表现成一堆不相干的用例
  /// 挂在工具数对不上，根因极难定位 —— 已经踩过一次。
  Set<String>? unlockedGroups,
}) {
  final loop = AgentLoop(
      providerProvider: () => provider,
      runnerProvider: (id) =>
          (id == null ? null : runnersByServerId?[id]) ?? runner ?? FakeRunner(),
      prewarmProvider: prewarmProvider,
      serverListProvider: serverListProvider ??
          (servers == null ? null : () async => servers),
      terminalTextProvider: terminalTextProvider,
      rulesProvider: rulesProvider ?? () => rules,
      modeProvider: () => mode,
      onRuleAdded: (r) => added?.add(r),
      systemPromptProvider: (_) => 'test prompt',
      cwdProvider: cwdProvider,
      maxTurns: maxTurns,
      restoreFrom: restoreFrom,
      toolSpecsProvider: toolSpecs,
      sftpOpsProvider: (sftpOpsByServerId == null && sftpOpsProvider == null)
          ? null
          : (id) async {
              final byId = sftpOpsByServerId?[id];
              if (byId != null) return byId;
              if (sftpOpsProvider != null) return sftpOpsProvider();
              throw StateError('no SftpOps for server $id');
            },
      relayTempDirProvider: relayTempDirProvider,
      downloadDirProvider: downloadDirProvider,
      publishToPublicStore: publishToPublicStore,
      pickLocalFile: pickLocalFile,
      skillBodyProvider: skillBodyProvider,
      skillNamesProvider: skillNamesProvider,
      skillSearchProvider: skillSearchProvider,
      skillSaver: skillSaver,
      skillAssetProvider: skillAssetProvider,
      serverNoteSaver: serverNoteSaver,
      knowledgeDistiller: knowledgeDistiller,
      savedCommandProvider: savedCommandProvider,
      savedCommandNamesProvider: savedCommandNamesProvider,
      webFetcher: webFetcher,
      appControl: appControl,
      serverIdResolver: serverIdResolver,
      usageTotals: usageTotals,
    );
  loop.onPendingReturned = onPendingReturned;
  for (final g in unlockedGroups ?? kToolGroups.keys.toSet()) {
    loop.unlockToolGroup(g);
  }
  return loop;
}

/// 默认 lean 而非 full —— 既有测试都只用 bash / read_file，给它们 full
/// 档等于让不相关的测试跟着新工具一起变。
List<ToolSpec> _defaultToolSpecs() => leanToolSpecs;

String? _defaultCwd() => '/tmp';
