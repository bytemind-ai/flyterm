// SPDX-License-Identifier: GPL-3.0-or-later
/// `@` 引用的解析、匹配与插入 —— 全部纯函数。
///
/// **不 import `flutter/material.dart`。** 这一层是本项目里最该单测的那类
/// 逻辑（光标边界、多个 `@`、插入后光标落点），保持零 Flutter 依赖让它可以
/// 用普通 unit test 覆盖，widget 那边只负责把输入喂进来、把结果画出去 ——
/// 与 `runningBarLabel` 同一个分工（见 `agent_view.dart` 里 `_RunningBar`
/// 的注释）。
library;

import '../../ai/agent/skill.dart';
import '../../data/models/favorite_command.dart';
import '../../data/models/server.dart';
import '../../sftp/sftp_entry.dart';

/// 一次 `@` 引用的类别。
enum MentionKind { file, server, skill, command }

/// 触发符。
///
/// **与 [MentionKind] 是两个维度，不要合并。** 前者是「用户敲了哪个字符」，
/// 后者是「候选是什么东西」——浮层的分组标题与图标按后者画，候选集来源按
/// 前者分流。合成一个枚举会让「slash 下有 skill 和 command 两组」这件事
/// 表达不出来。
enum TriggerKind {
  /// `/` —— 动作：技能、收藏命令。只在消息开头。
  slash,

  /// `@` —— 引用：服务器、文件。行首或空白之后。
  at,
}

/// 光标当前所处的补全上下文。
class MentionQuery {
  /// 这次补全是哪个触发符起的。
  final TriggerKind kind;

  /// 触发符之后到光标之间的文本（不含触发符本身）。
  final String query;

  /// 触发符本身在原文里的下标。
  final int start;

  /// 光标下标（替换区间的右端，开区间）。
  final int end;

  /// 这次 slash 是不是发生在**消息第 0 位**。
  ///
  /// 只对 [TriggerKind.slash] 有意义（`@` 本来就是「行首或空白之后」，
  /// 没有这个二分）。两处的判据强度不同，见 [parseMention]：
  ///
  ///   - 消息开头：query 为空也开浮层，列出全部技能与命令 —— 那是「我想挑
  ///     一个」的入口。
  ///   - 消息中途：**必须精确命中**一个技能/命令名才开。判据在
  ///     [slashExactMatch]，浮层那一侧执行。
  ///
  /// 把位置这一信息带出来而不是在浮层里重算，是因为浮层不该再解析一遍
  /// 原文 —— 解析只有 [parseMention] 一处。
  final bool atStart;

  const MentionQuery({
    required this.kind,
    required this.query,
    required this.start,
    required this.end,
    this.atStart = false,
  });
}

const _kWhitespace = {' ', '\n', '\t'};

/// 判断光标是否落在一个补全上下文里。不是就返回 null（调用方据此关浮层）。
///
/// ## `/` 有两档判据，这是本项目语境逼出来的
///
/// `@` 的判据是「行首或空白之后 + 中间不含空白」。`/var/log/nginx` 完全符合
/// 这一条——而运维消息里路径满天飞（`看下 /var/log`、`ls /etc`、`把 /a 拷到
/// /b`）。照抄会让浮层每打一句话弹三次。
///
/// 所以 `/` 按位置分两档，**空白仍是两档共用的边界**：
///
///   1. **消息开头**（第 0 位）：query 为空也开浮层，列出全部技能与命令。
///      没人会拿一条消息的开头写裸路径。
///   2. **消息中途**（斜杠前是空白、斜杠到光标之间无空白）：这里最像路径，
///      所以判据收紧到「**必须精确命中**一个技能/命令名」，由
///      [slashExactMatch] 执行。`看下 /var/log` 里 `var` 不是技能名 →
///      不弹；`磁盘满了 /排查磁盘` 精确命中 → 弹。
///
/// 第二档是本函数**只能给出语法形状、给不出结论**的地方：名字表不在纯函数
/// 手里。所以这里照常返回 slash 上下文（带 [MentionQuery.atStart] = false），
/// 由调用方拿 [slashExactMatch] 决定开不开。把「是不是精确命中」也塞进解析
/// 函数会让它凭空多出三份候选名单的依赖。
///
/// 「第一个空格之前」这条界线同时管住了收尾：`/排查磁盘 web-02 上的` 里，用户
/// 一旦开始打 args，浮层就该关——那时他在补充上下文，不是在挑技能。
MentionQuery? parseMention(String text, int cursor) {
  if (cursor <= 0 || cursor > text.length) return null;

  // 第 1 档：slash 在第 0 位。位置性判据，最强、最无歧义。
  if (text.startsWith('/')) {
    final head = text.substring(0, cursor);
    if (!_kWhitespace.any(head.contains)) {
      return MentionQuery(
        kind: TriggerKind.slash,
        query: text.substring(1, cursor),
        start: 0,
        end: cursor,
        atStart: true,
      );
    }
    // 落到这里说明光标已经在 args 里了，继续往下看有没有 `@`——
    // `/排查磁盘 @web-02` 是合法输入。
  }

  // 第 2 档：消息中途的 slash。与 `@` 共享「斜杠前是空白」这条边界，
  // 但要在 [slashExactMatch] 那一关才决定开不开。
  //
  // 放在 `@` 的查找**之前**：`/排查 @web-02` 这种输入里，光标停在 `web-02`
  // 后面时 `@` 更近、也更该赢（用户正在挑那台机器）；但光标停在 `/排查`
  // 后面时最近的 slash 才该赢。按「谁的触发符离光标更近」比较，而不是固定
  // 优先级。
  final midSlash = text.lastIndexOf('/', cursor - 1);
  final midOk = midSlash > 0 &&
      _kWhitespace.contains(text[midSlash - 1]) &&
      !_kWhitespace.any(text.substring(midSlash + 1, cursor).contains);

  final at = text.lastIndexOf('@', cursor - 1);
  if (midOk && at < midSlash) {
    return MentionQuery(
      kind: TriggerKind.slash,
      query: text.substring(midSlash + 1, cursor),
      start: midSlash,
      end: cursor,
      atStart: false,
    );
  }
  if (at < 0) return null;
  if (at > 0 && !_kWhitespace.contains(text[at - 1])) return null;
  final q = text.substring(at + 1, cursor);
  for (final c in _kWhitespace) {
    if (q.contains(c)) return null;
  }
  return MentionQuery(
    kind: TriggerKind.at,
    query: q,
    start: at,
    end: cursor,
  );
}

/// 把 file 类的 query 切成「要 listdir 的目录」和「本地过滤前缀」。
///
/// `dir` 为空串表示 query 里还没有 `/` —— 调用方据此判断「还没进文件模式」，
/// 不发远端请求。
({String dir, String prefix}) splitDirPrefix(String query) {
  final i = query.lastIndexOf('/');
  if (i < 0) return (dir: '', prefix: query);
  // i == 0 时 substring(0, 0) 是空串，而空串不是合法路径 —— 根目录必须还原
  // 成 '/'，否则 listdir('') 会得到一个「目录不存在」的二次错误。
  return (
    dir: i == 0 ? '/' : query.substring(0, i),
    prefix: query.substring(i + 1),
  );
}

/// 把 `@` 的 query 切成「目标机器名」和「路径」。
///
/// 冒号取自 scp 的 `user@host:path`。选它不只是因为运维熟——**模型更熟**：
/// 这个形状在训练数据里出现过无数次，prompt 里只需一句「等于 server 参数 +
/// 路径」，不必解释这个组合是什么。
///
/// 按**首个**冒号切：路径里带冒号是合法的（`/a:b`），机器名里不是。
///
/// [hasColon] 与 `path.isEmpty` 是**两件事**，调用方都要看：前者决定「要不要
/// 列这台机的目录」，后者决定「列哪个目录」（空 = home）。`web-02:` 这种刚打
/// 完冒号的状态两者同时成立。
({String server, String path, bool hasColon}) splitServerPath(String query) {
  final i = query.indexOf(':');
  if (i < 0) return (server: '', path: query, hasColon: false);
  return (
    server: query.substring(0, i),
    path: query.substring(i + 1),
    hasColon: true,
  );
}

/// 句中 slash 是否**精确命中**一个技能或收藏命令的名字。
///
/// 消息中途的 `/` 与路径长得一模一样（`/var/log` 和 `/排查磁盘` 在语法上都是
/// 「空白 + 斜杠 + 一串非空白」），唯一分得开它们的是**名字表**：前者不是任何
/// 技能名，后者是。<u>句中的浮层因此只在精确命中时才开</u>，代价是打第一个字
/// 的阶段没有列表辅助 —— 但句中本来就是在补充上下文，不是「我想挑一个技能」
/// 的入口，那个入口是消息开头的 `/`。
///
/// **大小写不敏感**，与 [matchLocal] 的前缀匹配同一个口径：用户按名字点出来的
/// 东西不该因为 `Nginx` / `nginx` 的差别而弹不出来。
bool slashExactMatch({
  required String query,
  required List<SkillIndexEntry> skills,
  required List<FavoriteCommand> commands,
}) {
  if (query.isEmpty) return false;
  final q = query.toLowerCase();
  return skills.any((s) => s.name.toLowerCase() == q) ||
      commands.any((c) => c.name.toLowerCase() == q);
}

/// 浮层里的一个候选。
class MentionCandidate {
  final MentionKind kind;

  /// 列表里显示的主文本。file 类是文件名，其余是对象名。
  final String label;

  /// 插进输入框的内容（**不含** `@`）。file 类是绝对路径。
  final String insertText;

  /// 第二行小字。没有就是 null。
  final String? subtitle;

  /// 仅 file 类有意义：true 表示点它是**下钻**，不是插入。
  final bool isDir;

  const MentionCandidate({
    required this.kind,
    required this.label,
    required this.insertText,
    this.subtitle,
    this.isDir = false,
  });
}

/// 按触发符匹配本地候选 —— 纯内存，零远端往返。
///
/// [kind] 决定出哪几类，这是本次拆分的核心：
///   slash → 技能、收藏命令（动词：让 agent 做什么）
///   at    → 服务器（名词：拿什么当参数）；文件走远端，不在这里
///
/// [perKindLimit] 是**每类**的渲染上限，不是全局上限：本地几类是「我知道要
/// 哪个，帮我少打字」，一类超过 8 条说明前缀还不够具体。file 类的上限另算
/// （见 `MentionField`），因为浏览目录时要能看清目录里有什么。
///
/// [hasOtherServers] 为 false 时整个 server 类不出现，与
/// `agentToolSpecsFor(hasOtherServers: ...)` 同一个判据 ——
/// `agent_tools.dart` 那边的注释写明了理由：「漏传的后果应该是『少两个
/// 工具』，而不是『告诉模型它有两个其实用不了的工具』」。同一条对 UI 侧成立。
List<MentionCandidate> matchLocal({
  required TriggerKind kind,
  required String query,
  required List<Server> servers,
  required List<SkillIndexEntry> skills,
  required List<FavoriteCommand> commands,
  bool hasOtherServers = false,
  int perKindLimit = 8,
}) {
  final q = query.toLowerCase();
  bool hit(String name) => q.isEmpty || name.toLowerCase().contains(q);

  if (kind == TriggerKind.slash) {
    return [
      for (final s in skills.where((s) => hit(s.name)).take(perKindLimit))
        MentionCandidate(
          kind: MentionKind.skill,
          label: s.name,
          insertText: s.name,
          subtitle: s.description,
        ),
      // 收藏命令列的是 `AiCommandManager` 已按 `aiEnabled` 过滤过的那份
      // （调用方传进来时就已经过滤）。那个默认 false 的开关语义是「我收藏它
      // 是为了自己一键点」≠「我允许 AI 替我跑」，列出模型消费不了的名字，
      // 用户点了必然失败。
      for (final c in commands.where((c) => hit(c.name)).take(perKindLimit))
        MentionCandidate(
          kind: MentionKind.command,
          label: c.name,
          insertText: c.name,
          subtitle: c.command,
        ),
    ];
  }

  if (!hasOtherServers) return const [];
  return [
    // `serverType == 'ssh'` 过滤放在这里而不是调用方：`matchLocal` 是唯一
    // 入口，在这里过滤能保证任何调用方都不会漏。
    //
    // 与 `terminal_screen.dart` 里 `serverListProvider` 是同一个口径 ——
    // `resolveServerTarget` 只在那份已过滤的列表里按 name 精确匹配，混进
    // 本地 shell profile 的名字会导致「用户点了、模型传出去、找不到同名
    // ssh 服务器」的必然失败。改一处要想到另一处。
    for (final s in servers
        .where((s) => s.serverType == 'ssh' && hit(s.name))
        .take(perKindLimit))
      MentionCandidate(
        kind: MentionKind.server,
        label: s.name,
        insertText: s.name,
        subtitle: s.host,
      ),
  ];
}

/// 把候选写回输入框，返回新文本与新光标位置。
///
/// [trailingSpace] 为 false 是**目录下钻**用的：补了空格
/// `parseMention` 就不再 active、浮层会关掉，下钻链直接断掉。所以下钻时插入
/// `<dir>/` 且不补空格，让结果仍然落在同一个 `@` 上下文里。
({String text, int cursor}) applyMention({
  required String text,
  required MentionQuery q,
  required String insertText,
  bool trailingSpace = true,
}) {
  final head = text.substring(0, q.start);
  final tail = text.substring(q.end);
  // 前缀跟着触发符走，不额外开参数：`q` 里已经有 kind，多一个参数就多一处
  // 能传错的地方。
  final prefix = q.kind == TriggerKind.slash ? '/' : '@';
  final body = '$prefix$insertText${trailingSpace ? ' ' : ''}';
  return (text: '$head$body$tail', cursor: head.length + body.length);
}

/// 列一个远端目录。返回的 [SftpEntry] 已带拼好的绝对 `path` ——
/// 复用 `SftpEntry.fromSftpName` 已经处理过的 `/` 根目录边界。
///
/// [serverId] 为 null = 当前会话那台机。非 null 时装配处会走
/// `_execChannelForServerId`，与当前机那条路共用同一份 channel 缓存，所以
/// 目标机如果已经连着就是秒回。
typedef RemoteDirLister = Future<List<SftpEntry>> Function(
  String dir, {
  String? serverId,
});

/// 把 `~` / `.` 起头的路径解析成绝对路径。
///
/// 跨机同样需要它：`@web-02:` 要列那台机的 home，而 **SFTP 不展开 `~`**
/// （OpenSSH 的 sftp-server 会把 `absolutePath('~/x')` 拼成
/// `<cwd>/~/x` 这种废路径），只能用 `absolutePath('.')` 求 home。
typedef RemotePathResolver = Future<String> Function(
  String path, {
  String? serverId,
});
