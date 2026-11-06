// SPDX-License-Identifier: GPL-3.0-or-later
import 'permission_rules.dart';
import 'tool_models.dart';
import 'tool_registry.dart';
import 'web_fetch.dart';

/// 一轮 tool calls 的分桶结果。三个列表装的是**原始下标**，不是 ToolCall
/// 本身 —— 执行完要按原下标把结果归位，模型给出的调用顺序有语义。
///
/// 三桶互不重叠，并集覆盖全部下标。
class ToolPartition {
  /// 完全在手机本地完成、不碰 SSH、不需审批的下标。**最先执行。**
  final List<int> local;

  /// 可以并发执行的下标。
  final List<int> parallel;

  /// 必须按原顺序逐个执行的下标。
  final List<int> serial;

  const ToolPartition({
    required this.local,
    required this.parallel,
    required this.serial,
  });
}

/// 完全在手机本地完成的工具。
///
/// 三条共同点缺一不可：**不碰 SSH**（没有网络往返）、**不需审批**
/// （`_executeOne` 的对应分支压根不走权限系统）、**无顺序语义**
/// （与同轮任何调用都没有先后依赖）。
///
/// 它们原本落在串行桶里，排在需审批的调用**后面** —— 于是一轮里既有
/// `read_terminal` 又有待审批 `bash` 时，读屏要等用户点完批准才跑。
/// 单开一桶最先执行，附带的体验收益比性能收益大：`set_plan` 的
/// checklist 会在用户还盯着审批卡时就出现。
const Set<String> kLocalToolNames = {
  'read_terminal',
  'load_skill',
  'search_skills',
  'set_plan',
  'list_servers',
};

/// 把一轮 tool calls 分成「可并发的」与「必须串行的」两桶。
///
/// ## 为什么不是全并行
///
/// 两个真实的坏结果：
///
/// 1. **顺序依赖被打破。** 同轮 `edit_file nginx.conf` + `bash nginx -t`
///    并发执行 = 在**旧配置**上验证通过，模型据此给出错误结论。这类失败
///    不报错，只是安静地错。
/// 2. **审批卡同时弹三张。** 用户不知道先点哪个。
///
/// ## 为什么这个划分不损失收益
///
/// 并行的价值全部来自「多条独立查询命令一起发」（`ps` / `ss` /
/// `journalctl`），而那些恰恰是命中 allowlist 的自动放行命令。需审批的
/// 调用本来就要等人点，并行零收益。
///
/// ## 这次判定**不替代** `_executeCommandTool` 内部那次判定
///
/// 那里有一句「只取一次 cwd —— 判定用的与执行用的必须是同一个值」的
/// TOCTOU 防护。这个函数接收**已经取好的** [cwd]，结果只用于分桶；真正
/// 决定「放行还是弹卡」的仍是执行路径内部那次判定（幂等，同样的输入必然
/// 同样的结果）。多算一次正则匹配的成本可以忽略，换来的是不动那道防护。
///
/// ## 判定规则
///
/// - 工具名在 [kLocalToolNames] 里 → local 桶（最先判定，见下）
/// - `bash` / `read_file` 且 `check` 返回 [ToolDecision.allow] → 并行桶
/// - 其余一切（需审批、写文件、未知工具名、参数非法）→ 串行桶
///
/// 写文件工具**按工具名**排除，不看 check 结果：`bypass` 模式下
/// `checkFileWrite` 会返回 allow，但那两个工具仍然有顺序语义（先写后验），
/// 并发它们没有任何好处。
ToolPartition partitionToolCalls(
  List<ToolCall> calls, {
  required PermissionRuleSet rules,
  required PermissionMode mode,
  String? cwd,
}) {
  final local = <int>[];
  final parallel = <int>[];
  final serial = <int>[];

  for (var i = 0; i < calls.length; i++) {
    final c = calls[i];
    // local 判定必须在**一切之前**：这四个工具走 default 分支时 check 是
    // null，会掉进串行桶。放在后面等于白写。
    if (kLocalToolNames.contains(c.name)) {
      local.add(i);
      continue;
    }
    // 跨机调用与当前 tab 的 cwd 无关：那条连接是 agent 自建的，登录默认
    // 目录，没有人 `cd` 过它。用当前 tab 的 cwd 去判它，会让「用户碰巧
    // 停在 ~/.aws」把一批与本机无关的远端只读命令全拖进串行桶。
    //
    // 这里的取值必须与 `_executeCommandTool` 里那次判定一致 —— 两边不一致
    // 会出现「分桶时判成需审批、执行时判成放行」。
    final effectiveCwd = c.args['server'] == null ? cwd : null;
    final CheckResult? check;
    switch (c.name) {
      case 'bash':
        final cmd = c.args['command'];
        // 参数非法时判定不了，丢串行桶让执行路径去回 isError。
        check = (cmd is String && cmd.trim().isNotEmpty)
            ? checkCommand(cmd.trim(),
                rules: rules, mode: mode, cwd: effectiveCwd)
            : null;
      case 'read_file':
        final path = c.args['path'];
        check = (path is String && path.trim().isNotEmpty)
            ? checkReadFile(path.trim(),
                rules: rules, mode: mode, cwd: effectiveCwd)
            : null;
      // 两个纯搜索工具，没有顺序语义 —— 「在哪个文件里」和「哪些文件叫这个
      // 名字」互不影响，同一轮问三处正是它们最典型的用法。
      //
      // path 可以省略（默认当前目录），所以这里不像 read_file 那样把缺参数
      // 当判定不了：缺 path 时判 `cat .`，与 `_resolve` 里的默认值同源。
      // 两边不一致会出现「分桶时判成需审批、执行时判成放行」。
      case 'glob':
      case 'grep':
        final path = c.args['path'];
        final p = (path is String && path.trim().isNotEmpty)
            ? path.trim()
            : '.';
        check = c.args['pattern'] is String
            ? checkReadFile(p, rules: rules, mode: mode, cwd: effectiveCwd)
            : null;
      // 只读的网络取数，没有顺序语义 —— 一轮里同时查两个文档页正是它的
      // 典型用法。
      //
      // **via 的解析必须与 `_executeWebFetch` 里那次完全一致**，包括「非法
      // 值退回默认路由」这条：两边不一致会出现「分桶时判成需审批、执行时
      // 判成放行」。
      //
      // 参数非法与非 http scheme 都判 null（落串行桶）：它们会在执行时返
      // `isError`，抢跑没有意义，而落并行桶意味着允许抢跑。
      case 'web_fetch':
        final rawUrl = c.args['url'];
        if (rawUrl is! String || rawUrl.trim().isEmpty) {
          check = null;
          break;
        }
        final u = rawUrl.trim();
        final parsed = Uri.tryParse(u);
        if (parsed == null ||
            parsed.host.isEmpty ||
            (parsed.scheme != 'http' && parsed.scheme != 'https')) {
          check = null;
          break;
        }
        final wfVia = switch (c.args['via']) {
          'phone' => WebTarget.phone,
          'server' => WebTarget.server,
          _ => resolveWebTarget(u),
        };
        check = checkWebFetch(u, rules: rules, mode: mode, via: wfVia);
      default:
        check = null;
    }
    if (check != null && check.decision == ToolDecision.allow) {
      parallel.add(i);
    } else {
      serial.add(i);
    }
  }

  return ToolPartition(local: local, parallel: parallel, serial: serial);
}

/// 这条调用能否在流式期间就抢跑（不等 StreamDone）。
///
/// ## 直接复用 [partitionToolCalls]，不写第二份判定
///
/// 判据分叉本身就是 bug —— 这一点本文件上面与 `agent_loop.dart` 里
/// `_executeCommandTool` 的 cwd TOCTOU 注释两处都强调过。所以这里不重新
/// 实现「什么算只读放行」，而是把单条调用喂给同一个函数，看它落不落进
/// 并行桶。
///
/// 这样一来三条硬边界是**自动成立**的，不是靠这里再写一遍：
///
/// - 需审批的落串行桶 → 不抢跑（抢跑它等于未经审批执行命令）
/// - `write_file` / `edit_file` 按工具名被排除出并行桶 → 不抢跑
///   （它们有先后语义：同轮 `edit_file nginx.conf` + `bash nginx -t` 抢跑
///   = 在旧配置上验证通过，而这类失败不报错，只是安静地错）
/// - 本地工具落 local 桶 → 不抢跑（它们零成本，抢跑只会打乱事件顺序）
///
/// ## 但「落进并行桶」只是**必要**条件，不是充分条件
///
/// 并行桶的判据是 `decision == allow`，也就是**免审批**；而抢跑真正需要的
/// 性质是**重跑安全** —— `agent_loop.dart` 的 `_takeSpeculation` 在判据变化
/// 时会丢弃抢跑结果、按正常路径再跑一遍，整个设计的安全性建立在「抢跑的只
/// 可能是只读命令，重跑没有副作用」这句话上。
///
/// **那句话曾经是假的。** 免审批 ≠ 只读：
///
/// - 用户用审批卡上的「总是允许」加一条 `crontab *`，`crontab -l | sort -u
///   | crontab -` 就免审批了，但它会写
/// - `bypass` 档（「全部放行不要问」）里 `checkCommand` 第二步就无条件
///   返回 allow，**任何**命令都落并行桶，包括 `rm -rf`
///
/// 现实后果实测过：一次「创建定时任务」的会话在远端留下了两条一模一样的
/// crontab 记录。所以这里在并行桶之外再加一道 [_isRerunSafe]。
///
/// ## 为什么是「再加一道」而不是「改并行桶的判据」
///
/// 两者问的不是同一个问题。并行桶问「能不能**并发**跑」—— 免审批的写命令
/// 并发跑是合理的（用户已经授权，而且它们之间没有声明过先后依赖）。抢跑问
/// 的是「能不能**白跑一次**」，那要严格得多。把两者合并会让免审批的写命令
/// 退回串行桶，白白损失并发收益。
///
/// ## `agent_loop.dart` 里「执行要等 StreamDone」那句注释与实现不符
///
/// 那里写着执行必须等 StreamDone，理由是「分桶判定需要看到这一轮的全部
/// 调用」。但 [partitionToolCalls] 的循环里每条只看自己的 `check` 结果，
/// 不看批的组成 —— 依赖整批组成的只有**批量审批卡**，而那只影响串行桶。
/// 并行桶的成员资格是逐条独立可判的，这正是抢跑成立的前提。
bool canSpeculate(
  ToolCall call, {
  required PermissionRuleSet rules,
  required PermissionMode mode,
  String? cwd,
}) =>
    partitionToolCalls([call], rules: rules, mode: mode, cwd: cwd)
        .parallel
        .isNotEmpty &&
    _isRerunSafe(call, cwd: cwd);

/// 内置只读基线 —— [_isRerunSafe] 判 bash 时用的规则集。
///
/// 用 [defaultAllowRules] 而不是用户当前的规则集，是这道闸门的全部意义：
/// 默认集有明确的准入标准（「不能执行其他程序或写文件」，见
/// `permission_rules.dart` 里那段），用户用「总是允许」加的规则没有。
const PermissionRuleSet _builtinReadOnlyRules =
    PermissionRuleSet(defaultAllowRules);

/// 这条调用白跑一次是否无副作用。
///
/// 判据刻意**不看**用户规则、也不看当前档位：它回答的是命令本身的性质，
/// 不是「用户授权了没有」。后者由 [partitionToolCalls] 那一半负责。
///
/// 对 bash 走 [checkCommand] 而不是直接 `rules.allows(...)`，是为了连带继承
/// 凭据 deny、敏感 cwd、元字符这三道闸门 —— 复合命令（`a; b`）在这里判
/// `needApproval`，于是一律不抢跑，不必在这里再写一遍它们的逻辑。
/// 固定传 [PermissionMode.ask]：`bypass` 会让 `checkCommand` 在第二步就无
/// 条件放行，那正是要绕开的那条短路。
bool _isRerunSafe(ToolCall call, {String? cwd}) {
  switch (call.name) {
    // 工具本身即只读，与参数无关。
    case 'read_file':
    case 'glob':
    case 'grep':
    case 'web_fetch':
      return true;
    case 'bash':
      final cmd = call.args['command'];
      if (cmd is! String || cmd.trim().isEmpty) return false;
      // 与 `partitionToolCalls` 同源的 cwd 取法 —— 跨机调用与当前 tab 的
      // cwd 无关。两边分叉会让同一条调用在两处判出不同结果。
      final effectiveCwd = call.args['server'] == null ? cwd : null;
      return checkCommand(
            cmd.trim(),
            rules: _builtinReadOnlyRules,
            mode: PermissionMode.ask,
            cwd: effectiveCwd,
          ).decision ==
          ToolDecision.allow;
    // 其余一切（含写文件工具、未知工具名）默认不安全。新增工具要抢跑必须
    // 在这里显式登记 —— 默认拒绝，不是默认放行。
    default:
      return false;
  }
}
