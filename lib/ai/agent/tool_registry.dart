// SPDX-License-Identifier: GPL-3.0-or-later
import 'permission_rules.dart';
import 'pipeline_gate.dart';
import 'shell_guard.dart';
import 'web_fetch.dart' show WebTarget;

/// 三档权限。命名描述**它能做什么**，而不是"要不要问你"。
///
/// ## 为什么从 plan/ask/bypass 改名
///
/// 旧命名的问题是 `ask` 这个词只说了"会问"，没说问了之后能发生什么，而用户
/// 要回答的真实问题是"我现在允许 AI 在这台机器上做什么"。`plan` 那档更麻烦：
/// 它在**命令判定上与 `ask` 完全一致**（见下面的说明），却占了一个独立的档位，
/// 用户得理解"plan 和 ask 到底差在哪"。
///
/// 现在只有三档，各自一句话说得清。
///
/// ## plan 去哪了
///
/// 它没有消失，只是降格为 [ask] 档内的呈现：`checkFileWrite` 在 [ask] 档返回
/// [ToolDecision.deferToPlan]，于是写文件攒进提案队列一次批准 —— 这正是旧
/// `plan` 的行为。所以迁移时老 `plan` 读成 [ask]，行为**完全不变**。
///
/// ## 不要给 `checkCommand` 加一个什么都不做的 readOnly/ask 分支
///
/// 那一档的判定与 [bypass] 之外的路径完全一致（命中 allowlist 放行，其余弹
/// 卡），凭空多写一个分支只会将来被改坏。
///
/// 与 [ask] 的唯一差别在 `checkFileWrite`：
/// - [readOnly] 返回 `needApproval`（写文件弹卡）
/// - [ask] 返回 `deferToPlan`（写文件进提案队列）
///
/// 以及 [readOnly] 不生成 allow 规则（`suggestRule` 为空 → `canRemember`
/// 为 false）：只读档的语义是"AI 不能改东西"，让它长出写规则的 allow 规则
/// 自相矛盾。
enum PermissionMode {
  /// AI 只能看：allow 规则命中的只读命令放行，其余一律弹审批。
  readOnly,

  /// AI 能做，但每次写操作都问。写文件走提案队列，攒起来整批批准。
  ///
  /// **新用户的默认档。**
  ask,

  /// 除凭据边界与硬清单外，一律直接执行。
  bypass,
}

enum ToolDecision {
  allow,
  needApproval,

  /// 不执行、不弹卡，直接进提案队列等用户整批批准。
  ///
  /// 只有 [PermissionMode.ask] 档下的写文件工具会走到这里——那两个工具
  /// 100% 是写，无需任何语义判定。
  deferToPlan,
}

enum ApprovalReason {
  shellMetachar,
  noMatchingRule,
  credentialDeny,

  /// 写文件工具（`write_file` / `edit_file`）。
  ///
  /// 单独一个 reason 而不是复用 `noMatchingRule`，是为了让
  /// [CheckResult.canRemember] 自动为 false —— 那个 getter 从 reason 派生，
  /// 加一个值就自动获得「不可记住」，不需要在任何地方再写一次条件。
  fileWrite,
}

class CheckResult {
  final ToolDecision decision;
  final ApprovalReason? reason;

  /// 「允许并记住」将生成的规则，展示给用户确认。
  final String suggestedRule;

  const CheckResult({
    required this.decision,
    this.reason,
    this.suggestedRule = '',
  });

  /// 命中凭据边界 —— 审批卡要显示警示。
  ///
  /// **从 [reason] 派生而不是独立存字段**：早先这两个是构造参数，于是
  /// 「改了分支的 flag 但忘了改 reason」在类型层面完全合法，只能靠单测兜。
  /// review 时实测把元字符分支的 `denyHit` 改成 true，13 个测试全绿 ——
  /// 那样普通的 `ls -la | grep foo` 会弹出「凭据外泄」警告而无人察觉。
  /// 派生之后这类不一致写不出来。
  bool get denyHit => reason == ApprovalReason.credentialDeny;

  /// 审批卡是否显示「总是允许」。只有「没有匹配的规则」这一种情形可以记：
  /// 凭据边界永远不能进 allowlist，复合命令的前缀规则没有意义。
  ///
  /// **还要求 [suggestedRule] 非空**（2026-10-13 加）：[PermissionMode.readOnly]
  /// 档刻意不生成规则建议（见 `checkCommand` 的末尾分支），此时若
  /// `canRemember` 仍为 true，审批卡会显示一个「总是允许」按钮 + 一段空的规则
  /// 文本。
  ///
  /// 收紧的影响面：`reason == noMatchingRule` 时 `suggestRule` 只对空命令返回
  /// `''`，而空命令走不到判定。所以除 readOnly 档外行为不变。
  bool get canRemember =>
      reason == ApprovalReason.noMatchingRule &&
      suggestedRule.trim().isNotEmpty;
}

/// 判定一条 bash 命令该放行还是弹审批。
///
/// 判定顺序不可调换 —— 这个顺序就是安全设计本身：
///
/// 1. **凭据边界最先**（命令命中 deny 清单，**或** cwd 落在凭据目录里）——
///    它是唯一连 `bypass` 都覆盖不了的一条
/// 2. **bypass 次之** —— 用户明确选了「全部放行不要问」，复合命令也一并放行
/// 3. **管道窄门** —— 每段都已放行的纯只读管道直接通过，见 `pipeline_gate.dart`
/// 4. **元字符再次** —— 其余复合命令无视所有 allow 规则，因为词前缀规则被
///    `systemctl status nginx; rm -rf /` 轻易绕过
/// 5. **最后才查 allow 规则**
///
/// 传入的 [command] 必须是**模型给出的原始命令**，不是 `wrapForSsh` 之后的
/// 结果 —— 后者自己带 `&&`，会让每条命令都判成 shellMetachar。
///
/// [cwd] 是这条命令将要执行的目录。**必须传**，否则 `cd ~/.aws && cat
/// credentials` 这类绕过会从目录锚定的 deny 模式底下溜过去。
CheckResult checkCommand(
  String command, {
  required PermissionRuleSet rules,
  required PermissionMode mode,
  String? cwd,
}) {
  if (isCredentialDeny(command) || isSensitiveCwd(cwd)) {
    return const CheckResult(
      decision: ToolDecision.needApproval,
      reason: ApprovalReason.credentialDeny,
    );
  }

  // bypass 在元字符之前返回 —— 用户明确选了「全部放行不要问」，复合命令
  // 也一并放行。凭据边界已经在上面拦掉了，那一条 bypass 覆盖不了。
  if (mode == PermissionMode.bypass) {
    return const CheckResult(decision: ToolDecision.allow);
  }

  // 纯只读管道：每一段都已被用户授权放行 —— 不该因为一个管道符退回审批。
  //
  // 位置不可挪动：在凭据 deny 之后（否则 `cat ~/.ssh/id_rsa | head` 会绕过
  // 数据边界），在元字符之前（那一步是 return，放后面就是死代码）。
  // 安全论证见 `pipeline_gate.dart` 的 dartdoc。
  if (isReadOnlyPipeline(command, rules)) {
    return const CheckResult(decision: ToolDecision.allow);
  }

  if (hasShellMetachar(command)) {
    return const CheckResult(
      decision: ToolDecision.needApproval,
      reason: ApprovalReason.shellMetachar,
    );
  }

  if (rules.allows(command)) {
    return const CheckResult(decision: ToolDecision.allow);
  }

  return CheckResult(
    decision: ToolDecision.needApproval,
    reason: ApprovalReason.noMatchingRule,
    // readOnly 档不生成规则建议 —— 这一档不该长出 allow 规则。空串经由
    // CheckResult.canRemember 让审批卡不显示「总是允许」。
    suggestedRule: mode == PermissionMode.readOnly ? '' : suggestRule(command),
  );
}

/// `read_file` **不是免审批的后门**。它视同 `cat <path>` 参与同一套判定：
/// 默认规则集里有 `cat *` 所以默认放行；用户关掉那条规则后，读文件也开始
/// 弹审批；deny 清单与敏感 cwd 照常生效。
///
/// 若不这样统一，`read_file` 就成了绕过所有规则读任意文件的通道。
CheckResult checkReadFile(
  String path, {
  required PermissionRuleSet rules,
  required PermissionMode mode,
  String? cwd,
}) =>
    checkCommand('cat $path', rules: rules, mode: mode, cwd: cwd);

/// 判定一次文件写入。
///
/// 与 [checkCommand] 的区别只有一条：**allow 规则不参与**，所以永远不会
/// 自动放行，也永远不能「允许并记住」。
///
/// 理由是现成的：默认放行清单的准入标准是「不得具备执行其他程序或写文件的
/// 能力」（`find *` 当初正因此出局）。写文件工具天生违反这条，没有任何参数
/// 组合能让它变安全。让它进 allowlist 意味着用户批准一次「改这个配置」之后，
/// 模型可以静默改任何文件。
///
/// ## 但 bypass 照常覆盖它
///
/// 判定顺序沿用 [checkCommand]：**凭据 deny → bypass → 强制审批**。
///
/// 那条准入标准约束的是 allowlist，不是 bypass。`bypass` 是用户明确选的
/// 「全部放行不要问」，而在这个模式下 `bash` 已经可以无审批跑 `rm -rf /`。
/// 让 `write_file` 在同一模式下反而弹审批，是把更弱的操作管得更严 —— 用户
/// 会认为那是 bug。
CheckResult checkFileWrite(
  String path, {
  // 有意未使用：保持与 [checkCommand] 签名对称；allow 规则不参与写文件判定。
  required PermissionRuleSet rules,
  required PermissionMode mode,
  String? cwd,
}) {
  if (isCredentialDeny(path) || isSensitiveCwd(cwd)) {
    return const CheckResult(
      decision: ToolDecision.needApproval,
      reason: ApprovalReason.credentialDeny,
    );
  }
  if (mode == PermissionMode.bypass) {
    return const CheckResult(decision: ToolDecision.allow);
  }

  // ask 档：不弹卡，进提案队列。（旧 `plan` 档的行为，2026-10-13 降格为
  // ask 档内的呈现。）
  //
  // 位置在 bypass 之后、凭据边界之下——判定顺序与 [checkCommand] 完全一致
  // 且不可调换：凭据边界最先（转提案会让一次凭据写入绕过那道警示条），
  // bypass 次之（用户明确选了全放行，ask 的攒批语义不该反过来管得更严）。
  if (mode == PermissionMode.ask) {
    return const CheckResult(decision: ToolDecision.deferToPlan);
  }

  return const CheckResult(
    decision: ToolDecision.needApproval,
    reason: ApprovalReason.fileWrite,
  );
}

/// `web_fetch` 的判定伪命令：`web_fetch <host>`，**恰好两个词**。
///
/// ## 为什么复用 shell 命令的规则体系
///
/// 三条性质刚好对齐，不是凑巧能用：
///
/// 1. [PermissionRule.matches] 在**词**粒度上比较，而 `Uri.host` 不含空格
///    —— 伪命令必然是两个词
/// 2. pattern 不以 ` *` 结尾时要求**逐词相等** → 精确到域名，
///    `web_fetch nginx.org` 不会放行 `nginx.org.attacker.com`
/// 3. reason 用 [ApprovalReason.noMatchingRule] 时 [CheckResult.canRemember]
///    **自动**为 true（那个 getter 从 reason 派生），不需要在任何地方再写
///    一次条件
///
/// 于是域名规则直接落进现有 [PermissionRuleSet]、现有存储、现有规则管理页
/// —— 一个新结构、一个新枚举值都不用加。
///
/// 用户在规则管理页手写 `web_fetch *` 等于「任意 URL 免审批」。那与手写裸
/// `*` 全放行同性质，是用户的选择。
String webFetchTarget(String host) => 'web_fetch $host';

/// 判定一次 `web_fetch` 该放行还是弹审批。
///
/// **两条路径的权限增量根本不同**，所以口径分开：
///
/// - `server`：agent 本来就能 `bash curl`（弹一次卡即可）。本工具不新增任何
///   权限，只是把命令行收进实现、给输出加上限 —— 与 `grep`/`glob` 相对
///   `bash grep` 的关系完全一致。在这条路径上再收一次审批费，是对同一个能力
///   重复收费。
/// - `phone`：agent 现在**完全不能**从手机侧发网络请求。这是全新的信任边界，
///   且用的是用户的手机网络身份，所以按域名首次审批。
///
/// **scheme 校验不在这里。** 非 http/https 的 URL 在 executor 的参数校验阶段
/// 就返回 `isError`，压根走不到判定 —— `file:///root/.ssh/id_rsa` 不该有机会
/// 出现在审批卡上让用户点。
///
/// 凭据 deny 清单不适用：那些模式匹配的是 shell 命令文本里的**本机**文件
/// 路径，URL 里没有。
CheckResult checkWebFetch(
  String url, {
  required PermissionRuleSet rules,
  required PermissionMode mode,
  required WebTarget via,
}) {
  if (via == WebTarget.server) {
    return const CheckResult(decision: ToolDecision.allow);
  }
  if (mode == PermissionMode.bypass) {
    return const CheckResult(decision: ToolDecision.allow);
  }
  final host = Uri.tryParse(url)?.host ?? '';
  final target = webFetchTarget(host);
  if (rules.allows(target)) {
    return const CheckResult(decision: ToolDecision.allow);
  }
  return CheckResult(
    decision: ToolDecision.needApproval,
    reason: ApprovalReason.noMatchingRule,
    // 与 checkCommand 同一口径：readOnly 档不生成规则建议。
    suggestedRule: mode == PermissionMode.readOnly ? '' : target,
  );
}
