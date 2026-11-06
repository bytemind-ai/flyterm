// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../../../l10n/app_localizations.dart' show lookupAppLocalizations;
import '../agent_events.dart';
import '../agent_tool_context.dart';
import '../command_runner.dart';
import '../file_edit.dart';
import '../server_targets.dart';
import '../skill.dart';
import '../tool_models.dart';
import '../tool_registry.dart';
import '../turn_metrics.dart';
import 'arg_parsing.dart';

/// 技能正文进历史时的前缀，形状是 `[skill: nginx]\n<正文>`。
///
/// 定义在这里而不是 `AgentLoop` 上：这个格式的**生产者**是下面的
/// `loadSkill`，loop 只是在 `_restore` 时反过来解析它，用来重建「哪些技能
/// 的全文已经发过」。格式归写它的那一方。
const String kSkillBodyPrefix = '[skill: ';

/// `save_note` 审批卡的 `description`。
///
/// 审批卡在有 `preview` 时不渲染 `displayCommand`（那一行恰恰是唯一带机器名
/// 的展示字符串，形如 `[dk] save note`），而 `save_note` 又没有像
/// `save_skill` 那样的模型给定 `description` 参数可填——结果用户在卡片上
/// 完全看不出这是在写哪台机器的笔记。这里补一个有机器名的 description，
/// 补齐那道信息缺口。
///
/// 这一层是纯 Dart / 拿不到 `BuildContext`，用不了 `context.l10n`。按系统
/// locale 直查是已有先例——见 `main.dart` 的 `_approvalNotificationTitle`
/// 对 `ask_user` 通知标题的处理，同样的理由：这里也早于、也绕开了任何
/// widget 树。取不到（不支持的 locale）时退回英文，不能让审批卡上出现
/// 一片空白。
String saveNoteApprovalDescription(String? serverHint) {
  try {
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final l = lookupAppLocalizations(locale);
    return serverHint == null
        ? l.agentServerNotesOverviewEntry
        : l.agentServerNotesForMachine(serverHint);
  } catch (_) {
    return serverHint == null ? 'Machine notes' : 'Machine notes: $serverHint';
  }
}

/// 技能两件事：装载一份技能的全文、把这次排查沉淀成一份新技能。
///
/// 第二个搬进 `tool_executors/` 的域。它对 loop 内部的需求只多出一样
/// ——「这份技能的全文发过没有」这一个 Set 的 contains + add，在
/// [AgentToolContext] 里露成 `isSkillLoaded` / `markSkillLoaded` 两个方法，
/// 而不是把可变集合的引用整个交出去。
class SkillExecutors {
  final AgentToolContext ctx;

  SkillExecutors(this.ctx);

  /// 读一份技能正文。
  ///
  /// **不碰权限系统**：它什么都不执行、什么都不写，读的是本地数据库 ——
  /// 与 `set_plan` / `list_servers` 同类。
  ///
  /// **但创建 `ToolCallEvent`**，这一点与那两个不同：面板要在时间线上显示
  /// 一条「使用技能：X」，而事件是 UI 唯一的数据源。复用 `ToolCallEvent`
  /// 而不是新增事件类型，是为了白拿它已有的归档序列化 —— 新类型要改
  /// `agentEventToJson` / `agentEventFromJson` 两处，漏一处就是会话恢复时
  /// 静默丢卡片。
  Future<ToolResult> loadSkill(ToolCall call) async {
    final raw = call.args['name'];
    // raw 是否合法要在建事件**之后**才判定——面板已经在渲染一条「使用
    // 技能」卡了（模型确实发起了这次调用），参数非法只是它的一种终态，
    // 不是「这次调用不存在」。
    final askedRaw = raw is String ? raw.trim() : '';
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand:
          askedRaw.isEmpty ? 'load skill' : 'load skill: $askedRaw',
      description: '',
      // 不参与权限判定，但事件结构要求一个 CheckResult。给 allow —— 它
      // 如实描述了发生的事：这次调用没有被任何规则拦过。
      check: const CheckResult(decision: ToolDecision.allow),
    );
    ctx.addEvent(ev);

    if (raw is! String || askedRaw.isEmpty) {
      ctx.noteInvalidArgs();
      const msg = 'Invalid arguments: `name` is required.';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg, isError: true);
    }
    final asked = askedRaw;
    final available = ctx.skillNamesProvider?.call() ?? const <String>[];
    String? matched;
    for (final n in available) {
      if (n.toLowerCase() == asked.toLowerCase()) {
        matched = n;
        break;
      }
    }

    // 索引里没有，但本会话 `search_skills` 返回过 —— 放行。原样用模型给的
    // 名字：白名单是从检索结果里记的，大小写就是库里的那个。
    matched ??= ctx.isSkillSearched(asked.toLowerCase()) ? asked : null;

    if (matched == null) {
      ctx.noteInvalidArgs();
      final msg = available.isEmpty
          ? 'You have no skills available.'
          : 'No skill named `$asked`. Available: ${available.join(', ')}.';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg, isError: true);
    }
    ctx.resetInvalidArgs();

    final key = matched.toLowerCase();
    if (ctx.isSkillLoaded(key)) {
      const msg = 'This skill was already loaded earlier in this '
          'conversation; its full text is above.';
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg);
    }

    final body = await ctx.skillBodyProvider
        ?.call(matched, alsoAllow: ctx.searchedSkillNames);
    if (body == null) {
      const msg = 'That skill could not be read. It may have been deleted '
          'or disabled.';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg, isError: true);
    }

    ctx.markSkillLoaded(key);
    final assets = await _assetsFor(matched);
    final content = '$kSkillBodyPrefix$matched]\n$body'
        '${_assetManifest(matched, assets)}';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = content;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: content);
  }

  /// 读附件。没接 provider 时返回空 —— 与「技能没有附件」同一件事。
  Future<List<AgentSkillAsset>> _assetsFor(String name) async {
    final provider = ctx.skillAssetProvider;
    if (provider == null) return const [];
    try {
      return await provider(name, alsoAllow: ctx.searchedSkillNames);
    } catch (_) {
      // 附件读不出来不该让技能本身也 load 不了：正文才是主体，附件是附加物。
      return const [];
    }
  }

  /// 附件清单段。**没有附件时返回空串** —— 那是绝大多数技能，返回值必须
  /// 与改造前逐字节相同。
  String _assetManifest(String skillName, List<AgentSkillAsset> assets) {
    if (assets.isEmpty) return '';
    final lines = assets
        .map((a) => '  ${a.path}${a.executable ? '  (executable)' : ''}')
        .join('\n');
    return '\n\n--- assets ---\n'
        'install with `install_skill_assets` (call it once, before using any '
        'of them), then run them from ~/$kSkillAssetsDirName/$skillName/\n'
        '$lines';
  }

  /// 投送一份技能的附件到远端。
  ///
  /// ## 为什么是一个工具，而不是让模型连调 N 次 `write_file`
  ///
  /// 三个附件 = 三张审批卡 + 三次手机→服务器往返。“投送这个技能的附件”
  /// 是**一个**意图，审批应当是针对这个意图的一次点击。工具表也付不起
  /// 每个附件一个工具的成本（`agent_tools.dart` 顶部那条“工具数恒定”）。
  ///
  /// ## 权限判定复用 `checkFileWrite`
  ///
  /// 附件写入就是文件写入，不新建判定函数。计划模式下它会进提案队列
  /// （`deferToPlan`）—— 这里**不像 `saveSkill` 那样绕开 plan**：那个绕开的
  /// 理由是“写的是手机本地，与服务器状态无关”，而这里改的确实是服务器。
  ///
  /// ## 一次 `bash` 完成全部写入
  ///
  /// 每个文件一段 `printf %s '<b64>' | base64 -d > <path>`。base64 字母表
  /// 不含任何 shell 特殊字符，所以载荷是一个词，不会破坏命令拼接。
  Future<ToolResult> installSkillAssets(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final raw = call.args['name'];
    final asked = raw is String ? raw.trim() : '';

    // 事件必须带齐 `check` / `displayCommand` / `preview`，而它们是 final
    // 的，且 `preview` 依赖附件（异步读库）。所以**先做参数与服务解析、
    // 再一次性建事件**。
    //
    // 这与 `loadSkill` / `saveSkill` “先建事件再校验参数” 的约定看似矛盾，
    // 其实是同一条原则的两个实现：那个约定要保证的是「模型确实发起的调用
    // 在时间线上可见，参数非法只是它的一种终态」，而不是「事件必须最先
    // 构造」。这里失败路径同样会 addEvent 一条带错误回填的事件，可见性
    // 不打折扣。
    //
    // 唯一代价：异步读库期间面板上还看不到这张卡。这个窗口比审批等待短
    // 得多，且期间本来也没有可展示的东西（附件内容就是这张卡的主体）。
    final available = ctx.skillNamesProvider?.call() ?? const <String>[];
    String? matched;
    for (final n in available) {
      if (n.toLowerCase() == asked.toLowerCase()) {
        matched = n;
        break;
      }
    }
    // 白名单与 `load_skill` 同源：只放行进了索引的，或本会话搜到过的。
    // 不这么做，`install_skill_assets` 就是绕过索引上限的后门。
    matched ??= (asked.isNotEmpty && ctx.isSkillSearched(asked.toLowerCase()))
        ? asked
        : null;

    final baseDisplay =
        asked.isEmpty ? 'install skill assets' : 'install assets: $asked';

    // 注意：此后的失败用 `failEvent` 而非 `invalid` —— 事件还没建。
    ToolResult failEvent(String msg) {
      final ev = ToolCallEvent(
        seq: ctx.nextSeq(),
        callId: call.id,
        toolName: call.name,
        displayCommand: baseDisplay,
        description: '',
        check: const CheckResult(decision: ToolDecision.allow),
      );
      ctx.addEvent(ev);
      return ctx.failTool(ev, call, msg);
    }

    if (asked.isEmpty) {
      return failEvent('Invalid arguments: `name` is required.');
    }
    if (matched == null) {
      return failEvent(available.isEmpty
          ? 'You have no skills available.'
          : 'No skill named `$asked`. Available: ${available.join(', ')}.');
    }

    final assetsProvider = ctx.skillAssetProvider;
    final assets = assetsProvider == null
        ? const <AgentSkillAsset>[]
        : await assetsProvider(matched,
            alsoAllow: ctx.searchedSkillNames);

    final servers =
        await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
    final target = resolveServerTarget(call.args['server'], servers);
    if (!target.ok) {
      return failEvent(target.error!);
    }

    // 落到 `~/.flyterm/skill-assets/<slug>`。
    //
    // **用 `~` 而不是 `$HOME`**（2026-10-13 修）：`shellQuotePath` 会把路径
    // 单引号化，而单引号内 `$HOME` **不展开** —— `'$HOME/.flyterm/...'` 会在
    // cwd 下创建一个**字面名为 `$HOME` 的目录**，命令还返回 0，于是安装
    // "成功"了、文件却落在模型根本跑不到的地方。
    //
    // 这正是 `shell_guard.dart` 里记录过的那个 `~` bug 的同族：路径被引号化
    // 后，shell 的特殊前缀不再展开。当时修了 `~`，`$HOME/` 这个写法漏了。
    //
    // `shellQuotePath` 的 `~/` 分支会产出 `"$HOME"'/.flyterm/...'`：`$HOME`
    // 在双引号内展开，其余部分仍在单引号里，注入防护一点没少。
    final installDir = '~/$kSkillAssetsDirName/${slugifySkillDir(matched)}';
    final cwd = target.isRemote ? null : ctx.cwdProvider?.call();
    // 判定用的路径：**不含 slug**。
    //
    // ## 为什么不拼 slug
    //
    // slug 来自技能名（`slugifySkillDir` 保留 `.` 与 `-`），而凭据 deny
    // 清单里有一批**不带路径锚点**的模式 —— `credentials.json`、
    // `service[-_]?account[\w.-]*\.json`、`\.env(\.\w+)?`。于是技能名叫
    // `credentials.json` 时这个串会**误命中**，审批卡弹出一条与事实无关的
    // 「内容将发送给 <provider>」警告；`bypass` 档下还会被莫名拦住 ——
    // 凭据边界是唯一连 bypass 都盖不住的一条。
    //
    // 而真正决定危险程度的是**目录**：`.flyterm/skill-assets/` 永远不敏感。
    // 同一目录下那个文件夹叫什么名字，不改变这件事有多危险。
    //
    // ## 为什么是绝对形态而不是 `~`
    //
    // 这里也不再猜家目录（曾经写死 `/root`）：那个前缀只是为了让规则引擎
    // 有个字符串可看，而扫一遍 deny 清单可知 `~` 与任何真实家目录都不影响
    // 匹配结果。猜错家目录则可能在将来某个模式加上路径锚点时静静失效。
    final checkPath = '/$kSkillAssetsDirName';
    final check = checkFileWrite(checkPath,
        rules: ctx.rulesProvider(), mode: ctx.modeProvider(), cwd: cwd);

    // 附件清单现在就能拿到，所以它可以是审批卡的主体。
    // **审批卡要展开附件全文**（与 `SkillSaveCard` 同一个安全理由：用户在
    // 批准一段自己没读过的、将来会被执行的文字）。
    final preview = assets.isEmpty
        ? null
        : FileEditPreview(
            path: installDir,
            newText: assets
                .map((a) =>
                    '=== ${a.path}${a.executable ? ' (executable)' : ''} ===\n'
                    '${a.content}')
                .join('\n\n'),
          );

    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: target.isRemote
          ? '[${target.serverName}] install ${assets.length} asset(s) for '
              '$matched'
          : 'install ${assets.length} asset(s) for $matched',
      description: '',
      check: check,
      preview: preview,
      targetServerName: target.serverName,
    );
    ctx.addEvent(ev);

    ToolResult invalid(String msg) => ctx.failTool(ev, call, msg);

    if (assets.isEmpty) {
      // 不是错误：模型可能只是不确定这个技能有没有附件。
      const msg = 'That skill has no attached files, so there is nothing to '
          'install. Follow its steps directly.';
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg);
    }

    // 纵深防御：库里存着一条坏路径就得在这里拦住。校验在 `save_skill` 已经
    // 做过一次，但**库里的旧行不受新校验约束**（用户可能手工编辑过）。
    for (final a in assets) {
      if (parseAssetPath(a.path) == null) {
        return invalid('This skill has an unsafe asset path (`${a.path}`) '
            'stored. Fix it in the skill editor before installing.');
      }
    }
    ctx.resetInvalidArgs();
    if (!preApproved) {
      if (check.decision == ToolDecision.deferToPlan) {
        return ctx.deferWrite(ev, call);
      }
      if (check.decision == ToolDecision.needApproval) {
        final outcome = await ctx.timedAwaitApproval(ev, tm);
        if (outcome.decision == ApprovalDecision.reject) {
          return ctx.rejectedResult(ev, outcome);
        }
        if (outcome.decision == ApprovalDecision.addToPlan) {
          return ctx.deferOrRejectFromApproval(ev, call, check);
        }
      }
    }

    // 结构性兜底，理由同 `saveSkill` 那一段。
    if (ctx.cancelRequested || ctx.disposed) {
      ev.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id,
          content: 'Session was cancelled before installing. Nothing was '
              'written.',
          isError: true);
    }

    final command = buildInstallAssetsCommand(installDir, assets);
    ev.status = ToolCallStatus.running;
    ev.startedAt = DateTime.now();
    ctx.enterState(AgentLoopState.executing);

    final CommandOutput out;
    try {
      out = await ctx.runnerProvider(target.serverId).run(command, cwd: cwd);
    } catch (e, st) {
      ctx.noteToolError(st);
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = toolErrorForCard(e, st);
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id, content: 'Install failed: $e', isError: true);
    }

    ev.exitCode = out.exitCode;
    if (!out.isSuccess) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = formatForModel(out);
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id,
          content: ev.output!,
          isError: true,
          exitCode: out.exitCode);
    }

    // 回填要包含落地目录的绝对路径 —— 模型接下来用 `bash` 跑它们，靠的就是
    // 这个串。`$HOME` 在远端已展开（下面命令里用的是 `$HOME`），这里回给
    // 模型一份可读的形状。
    final msg = 'Installed ${assets.length} asset(s) to $installDir. Run them '
        'from there, e.g. `$installDir/${assets.first.path}`.';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    ctx.notifyChanged();
    return ToolResult(
        callId: call.id, content: msg, exitCode: out.exitCode);
  }

  /// 把附件的**原始**内容拼进技能正文，供审批卡展示。
  ///
  /// 这是安全要求而不是美化：用户在批准「一段自己没读过的、将来会被执行
  /// 的文字」，只给文件名等于让他批一个盲盒。
  ///
  /// 容错优先——参数形状不对时就不展示附件段，把「哪里不对」留给后面的
  /// 校验去说。这里抛异常会把一张可批准的卡变成一次崩溃。
  static String _bodyWithAssetPreview(String body, Object? rawAssets) {
    if (rawAssets is! List || rawAssets.isEmpty) return body;
    final buf = StringBuffer(body);
    buf.write('\n\n=== attached files ===');
    for (final item in rawAssets) {
      if (item is! Map) continue;
      final p = item['path'];
      final c = item['content'];
      final x = item['executable'] == true;
      buf.write('\n\n--- ${p is String ? p : '(missing path)'}'
          '${x ? '  (executable)' : ''} ---\n');
      buf.write(c is String ? c : '(missing content)');
    }
    return buf.toString();
  }

  /// 按关键词检索技能，返回 name + description（**不含正文**）。
  ///
  /// 命中的名字会记进本会话白名单，随后 `load_skill` 才放行它们——这是
  /// 「模型只能用它真搜到过的」这条约束的实现点。
  Future<ToolResult> searchSkills(ToolCall call) async {
    final raw = call.args['query'];
    final query = raw is String ? raw.trim() : '';
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand:
          query.isEmpty ? 'search skills' : 'search skills: $query',
      description: '',
      check: const CheckResult(decision: ToolDecision.allow),
    );
    ctx.addEvent(ev);

    if (query.isEmpty) {
      // 刻意不把空 query 当成「列出全部」：那会变成绕过索引上限的后门，
      // 一次把几百条描述灌进 context。
      ctx.noteInvalidArgs();
      const msg = 'Invalid arguments: `query` is required and must be '
          'non-empty keywords.';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg, isError: true);
    }
    ctx.resetInvalidArgs();

    final hits = ctx.skillSearchProvider?.call(query) ?? const [];
    if (hits.isEmpty) {
      // 措辞要明确「这就是全部」，否则模型会换个关键词反复试，每次一轮
      // 工具往返。
      final msg = 'No skills matched "$query". The ones listed in the '
          'system prompt are all you have.';
      ctx.finishToolCall(ev, ToolCallStatus.done);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg);
    }

    for (final h in hits) {
      ctx.markSkillSearched(h.name.toLowerCase());
    }
    final listed = hits.map((h) => '- ${h.name}: ${h.description}').join('\n');
    final content = 'Matched ${hits.length} skill(s). Call `load_skill` '
        'with one of these exact names:\n$listed';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = content;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: content);
  }

  /// 保存一份技能到手机本地。
  ///
  /// ## 为什么不复用 `checkFileWrite`
  ///
  /// 那个函数在 plan 模式返回 `deferToPlan`，把写操作攒进提案队列。但提案
  /// 队列的语义是「对**这台服务器**的一批改动，批准后一起执行」，而这里写
  /// 的是手机本地的知识库，与服务器状态无关。混进那份方案会让用户在一张
  /// 「改 nginx 配置」的方案卡里看到一条「保存技能」，不知道自己在批准
  /// 什么。
  ///
  /// 所以判定只有两行：bypass 放行，其余弹卡。
  ///
  /// bypass 放行是为了和 `checkFileWrite` 那段注释保持同一个逻辑 —— 那个
  /// 模式下 `bash` 已经能无审批跑 `rm -rf /`，让 `save_skill` 反而要问，
  /// 用户会当成 bug。技能列表在设置页里随时可见可删，不是隐蔽的持久化。
  Future<ToolResult> saveSkill(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final name = call.args['name'];
    final description = call.args['description'];
    final body = call.args['body'];

    final n = name is String ? name.trim() : '';
    final existing = n.isEmpty
        ? false
        : (ctx.skillNamesProvider?.call() ?? const <String>[])
            .any((e) => e.toLowerCase() == n.toLowerCase());

    // 先建事件再校验参数 —— 与 `_executeLoadSkill` 同一约定：模型确实发起
    // 了这次调用，参数非法只是它的一种终态，不是「这次调用不存在」。
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand: n.isEmpty
          ? 'save skill'
          : (existing ? 'update skill: $n' : 'save skill: $n'),
      description: description is String ? description.trim() : '',
      check: const CheckResult(
        decision: ToolDecision.needApproval,
        reason: ApprovalReason.fileWrite,
      ),
      // 复用文件编辑的预览载荷：path 放技能名，newText 放正文。UI 层按
      // toolName 分派到技能专用的卡片。
      //
      // 附件一并拼进 `newText`（而不是另开事件字段）：`SkillSaveCard` 直接
      // 渲染 `preview.newText`，拼进去就自动展开，无需改事件序列化——而改
      // 序列化要同时动 `agentEventToJson` / `agentEventFromJson` 两处，漏
      // 一处就是会话恢复时静默丢卡。
      //
      // 用的是**未校验**的原始参数：用户看到的应当就是模型发来的东西，
      // 校验失败是之后的另一种终态。
      preview: body is String
          ? FileEditPreview(
              path: n, newText: _bodyWithAssetPreview(body, call.args['assets']))
          : null,
    );
    ctx.addEvent(ev);

    ToolResult invalid(String msg) => ctx.failTool(ev, call, msg);

    if (n.isEmpty) {
      return invalid('Invalid arguments: `name` is required.');
    }
    if (description is! String || description.trim().isEmpty) {
      return invalid('Invalid arguments: `description` is required — it is '
          'the only part the user sees in every future prompt.');
    }
    if (body is! String || body.trim().isEmpty) {
      return invalid('Invalid arguments: `body` is required.');
    }

    // 内置技能的名字不能被占用。
    //
    // 拦在这里而不是让它存进去：`load_skill` 是内置优先，存进去的那条永远
    // 读不到，但设置页会照常列出它 —— 用户看到一条"已启用"却不生效的技能，
    // 没法解释。
    final builtin = ctx.builtinSkillNamesProvider?.call() ?? const <String>[];
    if (builtin.any((b) => b.toLowerCase() == n.toLowerCase())) {
      return invalid('`$n` is the name of a built-in skill. Pick a different '
          'name — a skill saved under that name would never be readable.');
    }

    final descBytes = utf8.encode(description.trim()).length;
    if (descBytes > kMaxSkillDescriptionBytes) {
      return invalid('That description is $descBytes bytes; the limit is '
          '$kMaxSkillDescriptionBytes. It rides along in every prompt, so it '
          'has to be one short line saying WHEN the skill applies.');
    }
    final bodyBytes = utf8.encode(body).length;
    if (bodyBytes > kMaxSkillBodyBytes) {
      return invalid('That body is $bodyBytes bytes; the limit is '
          '$kMaxSkillBodyBytes. Split it into two skills, or cut it down.');
    }

    // 附件校验。走与正文同一套 invalid() 分支（[assets] 错误时同样先建了
    // 事件、再拒绝，与其余参数一致）。
    final rawAssets = call.args['assets'];
    final List<AgentSkillAsset>? assets;
    if (rawAssets == null) {
      // 不传 = 与改造前完全一致（null 传给 repo 表示“不动附件”）。
      assets = null;
    } else if (rawAssets is! List) {
      return invalid('Invalid arguments: `assets` must be an array.');
    } else {
      if (rawAssets.length > kMaxSkillAssets) {
        return invalid('That is ${rawAssets.length} assets; the limit is '
            '$kMaxSkillAssets. Fold the extras into the body, or split this '
            'into two skills.');
      }
      final parsed = <AgentSkillAsset>[];
      var total = 0;
      for (final item in rawAssets) {
        if (item is! Map) {
          return invalid('Invalid arguments: each asset must be an object '
              'with `path` and `content`.');
        }
        final rawPath = item['path'];
        final rawContent = item['content'];
        if (rawPath is! String || rawContent is! String) {
          return invalid('Invalid arguments: each asset needs a string `path` '
              'and a string `content`.');
        }
        final p = parseAssetPath(rawPath);
        if (p == null) {
          return invalid('Unsafe asset path `$rawPath`. It must be a relative '
              'path with no leading `/`, no `..` segments and no backslashes '
              '- it is written INSIDE the skill\'s own directory on the '
              'server.');
        }
        final bytes = utf8.encode(rawContent).length;
        if (bytes > kMaxSkillAssetBytes) {
          return invalid('Asset `$p` is $bytes bytes; the per-file limit is '
              '$kMaxSkillAssetBytes.');
        }
        total += bytes;
        if (total > kMaxSkillAssetsTotalBytes) {
          return invalid('These assets total $total bytes; the limit is '
              '$kMaxSkillAssetsTotalBytes. Split this into two skills.');
        }
        final exec = item['executable'];
        if (exec != null && exec is! bool) {
          return invalid('Invalid arguments: `executable` must be a boolean.');
        }
        parsed.add(AgentSkillAsset(
            path: p, content: rawContent, executable: exec == true));
      }
      assets = parsed;
    }

    if (ctx.skillSaver == null) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = 'Saving skills is not available in this session.';
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id,
          content: 'Saving skills is not available in this session.',
          isError: true);
    }
    ctx.resetInvalidArgs();

    if (!preApproved && ctx.modeProvider() != PermissionMode.bypass) {
      // 只量这一段——`_awaitApproval` 挂起等的是人的反应，不是执行。外层
      // `_executeOne` 会拿这个数从总时长里扣掉，见那里的注释。
      final outcome = await ctx.timedAwaitApproval(ev, tm);
      // `!= allowOnce` 一网打尽：用户在卡上点「加入方案」也走拒绝路径。
      // 那个按钮本来就不该出现在技能卡上（`CheckResult.canRemember` 从
      // `reason` 派生，`fileWrite` 已让它是 false），万一 UI 上漏了，
      // 语义退化成「拒绝」比退化成「静默丢弃」安全。
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    // 结构性兜底，理由同 `_runFileWrite` 开头那段：把「取消之后不写」从
    // 「我们检查了这些路径」变成「写入这个动作本身拒绝在取消后执行」。
    if (ctx.cancelRequested || ctx.disposed) {
      ev.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id,
          content: 'Session was cancelled before the save. Nothing was '
              'stored.',
          isError: true);
    }

    try {
      await ctx.skillSaver!(n, description.trim(), body, assets);
    } catch (e) {
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = 'Failed to save: $e';
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id,
          content: 'Failed to save the skill: $e',
          isError: true);
    }

    // 回填极短：正文是模型自己刚给出的，回给它是纯浪费（与 `_runFileWrite`
    // 的「成功时不回填文件内容」同一个理由）。
    final msg = existing ? 'Updated skill `$n`.' : 'Saved skill `$n`.';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg);
  }

  /// 追加一条机器笔记（`save_note`）。
  ///
  /// 骨架照抄 [saveSkill]：先建事件再校验参数、审批流程、
  /// `cancelRequested || disposed` 结构性兜底、按成败分支回填。三处不同：
  /// 这里没有撞名检查（`server_id` 是主键，一台机器一份笔记）、没有模型可填
  /// 的 `description` 参数（笔记整份进 prompt，不需要索引行；`ToolCallEvent`
  /// 上给审批卡看的 `description` 是本地合成的，见
  /// [saveNoteApprovalDescription]，两者不是一回事）、也没有自己的字节
  /// 上限检查 —— 收口在 `ServerNotesManager.appendNote`，这里只负责把它的
  /// 拒绝结果翻译成模型看得懂的话。
  Future<ToolResult> saveNote(ToolCall call,
      {bool preApproved = false, ToolMetrics? tm}) async {
    final body = call.args['body'];
    final headingRaw = call.args['heading'];
    final heading = headingRaw is String ? headingRaw.trim() : '';
    final serverRaw = call.args['server'];
    final serverHint = serverRaw is String && serverRaw.trim().isNotEmpty
        ? serverRaw.trim()
        : null;

    // 先建事件再校验参数 —— 与 `saveSkill` 同一约定：模型确实发起了这次
    // 调用，参数非法只是它的一种终态，不是「这次调用不存在」。
    // displayCommand 先用模型给的原始 server 名字占位 —— 把它解析成 id
    // 要查一遍服务器清单（异步），不值得为了一个展示字符串拖慢事件的创建。
    final ev = ToolCallEvent(
      seq: ctx.nextSeq(),
      callId: call.id,
      toolName: call.name,
      displayCommand:
          serverHint == null ? 'save note' : '[$serverHint] save note',
      // 见 `saveNoteApprovalDescription` 的文档：审批卡在有 preview 时不显示
      // displayCommand，这是用户唯一能看到机器名的地方。
      description: saveNoteApprovalDescription(serverHint),
      check: const CheckResult(
        decision: ToolDecision.needApproval,
        reason: ApprovalReason.fileWrite,
      ),
      // 复用文件编辑的预览载荷：path 放标题（没有就放个占位），newText 放
      // 正文。`tool_call_card.dart` 目前只对 `save_skill` 开了专用卡片
      // （`SkillSaveCard`），`save_note` 没有对应分支，走的是审批卡里
      // `FileDiffView` 的通用渲染——这份 heading/body 结构直接喂给它就够用，
      // 还没到需要专门卡片的地步。
      preview: body is String
          ? FileEditPreview(
              path: heading.isEmpty ? 'note' : heading, newText: body)
          : null,
    );
    ctx.addEvent(ev);

    ToolResult invalid(String msg) => ctx.failTool(ev, call, msg);

    if (body is! String || body.trim().isEmpty) {
      return invalid('Invalid arguments: `body` is required.');
    }

    // `server` 解析成 id 的方式与 `write_file` / `edit_file` 一致：名字查不
    // 到就报错附上可用名单，不猜、不落到一个用户没说过的地方。
    final servers =
        await ctx.serverListProvider?.call() ?? const <ServerListEntry>[];
    final target = resolveServerTarget(serverRaw, servers);
    if (!target.ok) {
      return invalid(target.error!);
    }

    if (ctx.serverNoteSaver == null) {
      return invalid('Saving notes is not available in this session.');
    }
    ctx.resetInvalidArgs();

    if (!preApproved && ctx.modeProvider() != PermissionMode.bypass) {
      // 只量这一段 —— 见 `saveSkill` 同一行的注释。
      final outcome = await ctx.timedAwaitApproval(ev, tm);
      if (outcome.decision != ApprovalDecision.allowOnce) {
        return ctx.rejectedResult(ev, outcome);
      }
    }

    // 结构性兜底，理由同 `saveSkill` 同一段。
    if (ctx.cancelRequested || ctx.disposed) {
      ev.status = ToolCallStatus.rejected;
      ctx.notifyChanged();
      return ToolResult(
          callId: call.id,
          content: 'Session was cancelled before the save. Nothing was '
              'stored.',
          isError: true);
    }

    final r = await ctx.serverNoteSaver!(target.serverId, heading, body);
    if (!r.ok) {
      // 两种失败分开讲。failed 自带现成的人话（比如「存量本身就超限，
      // 得去设置里精简」），直接转发；rejected 只有一个数字，要包装成
      // 可执行的指令 —— 告诉模型超了多少，它才知道该砍多少，而不是
      // 盲目重试同样长度的内容。
      final msg = r.error ??
          'That would put this machine\'s notes ${r.overflowBytes} bytes '
              'over the limit. The whole file is resent every turn, so it '
              'has a hard cap. Shorten what you are adding, or tell the user '
              'to trim the existing notes in Settings.';
      ctx.finishToolCall(ev, ToolCallStatus.failed);
      ev.output = msg;
      ctx.notifyChanged();
      return ToolResult(callId: call.id, content: msg, isError: true);
    }

    // 回填极短：正文是模型自己刚给出的，回给它是纯浪费。
    const msg = 'Note saved.';
    ctx.finishToolCall(ev, ToolCallStatus.done);
    ev.output = msg;
    ctx.notifyChanged();
    return ToolResult(callId: call.id, content: msg);
  }
}
