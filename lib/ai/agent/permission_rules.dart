// SPDX-License-Identifier: GPL-3.0-or-later
/// 一条 allow 规则。
///
/// [pattern] 以 ` *` 结尾表示前缀匹配（`systemctl status *`），否则要求
/// 整条命令逐词相等（`uptime`）。匹配在**词**的粒度上做，因此
/// `systemctl status *` 不会匹配 `systemctl statusx`。
///
/// 不做正则、不做语义分析。规则体系的安全性来自「含元字符的命令一律
/// 弹审批」这条前提（见 shell_guard.dart），不来自 pattern 本身的表达力。
class PermissionRule {
  final String pattern;

  /// true = 来自默认规则集（用户可禁用但不可删）
  final bool builtin;
  final bool enabled;

  const PermissionRule({
    required this.pattern,
    this.builtin = false,
    this.enabled = true,
  });

  /// 分词只按**空格与制表符**，不用 `\s`。
  ///
  /// Dart 的 `\s` 还包含 VT / FF / NBSP(U+00A0) / U+2028 / U+3000，而
  /// bash 的词分隔符只有空格、制表符、换行。用 `\s` 会让引擎认为
  /// `systemctl<VT>status nginx` 是三个词从而匹配 `systemctl status *`，
  /// 但 bash 会把它当成**一个**词去找同名程序 ——
  /// 「引擎以为批准的」与「实际会跑的」出现分歧。
  ///
  /// 换行不必在此处理：含 `\n` / `\r` 的命令已被 `shell_guard.dart` 一票
  /// 否决，走不到规则匹配这一步。
  static List<String> _tokens(String s) =>
      s.trim().split(RegExp(r'[ \t]+')).where((t) => t.isNotEmpty).toList();

  bool matches(String command) {
    if (!enabled) return false;
    final cmdTokens = _tokens(command);
    if (cmdTokens.isEmpty) return false;

    final p = pattern.trim();
    if (p.endsWith('*')) {
      final prefix = _tokens(p.substring(0, p.length - 1));
      if (prefix.isEmpty) return true; // 裸 "*" = 全放行
      if (cmdTokens.length < prefix.length) return false;
      for (var i = 0; i < prefix.length; i++) {
        if (cmdTokens[i] != prefix[i]) return false;
      }
      return true;
    }

    final exact = _tokens(p);
    if (exact.length != cmdTokens.length) return false;
    for (var i = 0; i < exact.length; i++) {
      if (exact[i] != cmdTokens[i]) return false;
    }
    return true;
  }

  PermissionRule copyWith({bool? enabled}) => PermissionRule(
        pattern: pattern,
        builtin: builtin,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'pattern': pattern,
        if (builtin) 'builtin': true,
        if (!enabled) 'enabled': false,
      };

  static PermissionRule fromJson(Map<String, dynamic> j) => PermissionRule(
        pattern: j['pattern'] as String,
        builtin: j['builtin'] as bool? ?? false,
        enabled: j['enabled'] as bool? ?? true,
      );

  /// 值相等。三个字段全部参与 —— `enabled` 漏掉会让「用户刚禁用了一条规则」
  /// 比较成「没变」。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PermissionRule &&
          other.pattern == pattern &&
          other.builtin == builtin &&
          other.enabled == enabled;

  @override
  int get hashCode => Object.hash(pattern, builtin, enabled);
}

class PermissionRuleSet {
  final List<PermissionRule> rules;
  const PermissionRuleSet(this.rules);

  bool allows(String command) => rules.any((r) => r.matches(command));

  List<Map<String, dynamic>> toJson() =>
      rules.map((r) => r.toJson()).toList();

  static PermissionRuleSet fromJson(List<dynamic> j) => PermissionRuleSet(
        j
            .map((e) => PermissionRule.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );

  /// 值相等 —— **这个类必须可以按值比较，不能只靠对象身份。**
  ///
  /// 理由很具体：`AgentLoop` 的抢跑落地要判断「起飞到落地之间，权限判据变了
  /// 没有」。那里原先用的是 `identical(...)`，而生产接线
  /// （`AgentSessionManager.rules`）每次读都从 prefs 反序列化出一个**新**
  /// 对象 —— 判据于是永远不成立，抢跑结果被无条件丢弃、命令在远端又跑一遍。
  /// 用户的 crontab 里因此出现过两条一模一样的任务。
  ///
  /// 顺序参与比较：规则是按序匹配的，重排本身就是一次语义变化。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PermissionRuleSet) return false;
    if (other.rules.length != rules.length) return false;
    for (var i = 0; i < rules.length; i++) {
      if (other.rules[i] != rules[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(rules);
}

/// 从一条被批准的命令生成建议规则：**通配最后一个词，至少保留两个词**。
///
/// ```
/// uptime                       → uptime *
/// ls -la                       → ls -la *
/// systemctl status nginx       → systemctl status *
/// rm -rf /tmp/cache            → rm -rf *
/// kubectl -n prod get pods     → kubectl -n prod get *
/// kubectl exec pod -- rm -rf / → kubectl exec pod -- rm -rf *
/// git push origin main         → git push origin *
/// ```
///
/// ## 为什么不按 flag 切
///
/// 试过两个更"聪明"的启发式，都在真实命令上塌方：
///
/// 1. **「第二个词不是 flag 就带上，否则只取第一个词」** ——
///    `rm -rf /tmp/cache` → `rm *`。批准「删一个缓存目录」等于批准了 `rm -rf /`。
///    「命令名 + flag」正是最需要精确的形状，它偏偏在这个形状上丢得最多。
///
/// 2. **「保留命令名 + 所有 flag + 第一个非 flag 子命令词」** ——
///    修好了 1，却在**全局 flag 写在子命令前**时同样塌方：
///    `kubectl -n prod get pods` → `kubectl -n *`，放行该 namespace 下任意
///    kubectl 动作，包括 `delete` 和 `exec -- rm -rf /`。而「全局 flag 在前、
///    动词在后」正是 kubectl / docker / aws / gcloud / ssh 最常见的写法。
///    它还让规则宽窄取决于参数值的符号：`nice -n 5 cmd` → `nice -n *`，
///    `nice -n -5 cmd` → `nice -n -5 *`。
///
/// 根因是一样的：**不解析每个命令自己的语法，就分不清 boolean flag、
/// 带值 flag、子命令、位置参数**。任何基于 `-` 前缀的猜测都会在某类命令上
/// 猜反，而猜反的方向是"规则变宽"。
///
/// 所以不猜。只做一件不依赖任何语法知识的事：**去掉最后一个词**。它对每一
/// 类命令都给出不比上面两个方案更宽的规则，而且实现只有两行。
///
/// 「至少保留两个词」是为了 `sudo reboot` 这类两词命令不退化成 `sudo *`。
///
/// 代价是规则更窄：`journalctl -u nginx -n 50` → `journalctl -u nginx -n *`，
/// 换个 unit 看日志要再批一次。接受 —— **规则宽窄的默认值应偏保守，放宽是
/// 用户在卡片上主动做的动作**（审批卡允许直接编辑这段文本）。
String suggestRule(String command) {
  final tokens = PermissionRule._tokens(command);
  if (tokens.isEmpty) return '';
  // 通配最后一个词；两词及以下全部保留，避免退化成裸命令名。
  final kept =
      tokens.length <= 2 ? tokens : tokens.sublist(0, tokens.length - 1);
  return '${kept.join(' ')} *';
}

/// 默认 allow 规则集 —— 「无感排查」的全部来源。
///
/// 这是本设计里唯一带我们主观判断的地方，因此它必须对用户**可见、可编辑、
/// 可整组关闭**，且首次启用 agent 模式时强制过目一次。
///
/// 写操作（`rm`、`systemctl restart`、`kubectl delete/exec/apply`）**不在**
/// 集内，照常弹审批。
///
/// ## 准入标准：不得具备执行其他程序或写文件的能力
///
/// 元字符检测（`shell_guard.dart`）只防住「shell 操作符拼多条命令」，防不住
/// 「单条命令自带二级执行原语」。所以这条标准是后者的唯一约束。
///
/// **`find *` 因此被排除**：`find /tmp -exec rm -rf {} +` 不含任何元字符，
/// 却匹配 `find *` 前缀 —— 零审批执行任意破坏性命令。`-delete` / `-execdir`
/// / `-ok` 同理。find 落到审批流程，用户批准一次即可。
///
/// 同理不得加入的还有：`awk`（`system()`）、`xargs`、`eval`、`sed`（`e` 命令）、
/// `perl` / `python`（`-e` / `-c`）、`tar`（`--checkpoint-action`）、`env`、
/// `timeout`、`nice`、`git`（`-c core.pager=`）。
///
/// **往这个清单里加任何东西之前，先问：它能不能执行别的程序、能不能写文件。**
const List<PermissionRule> defaultAllowRules = [
  PermissionRule(pattern: 'systemctl status *', builtin: true),
  PermissionRule(pattern: 'journalctl *', builtin: true),
  PermissionRule(pattern: 'ps *', builtin: true),
  PermissionRule(pattern: 'df *', builtin: true),
  PermissionRule(pattern: 'free *', builtin: true),
  PermissionRule(pattern: 'ss *', builtin: true),
  PermissionRule(pattern: 'netstat *', builtin: true),
  PermissionRule(pattern: 'ls *', builtin: true),
  PermissionRule(pattern: 'tail *', builtin: true),
  PermissionRule(pattern: 'head *', builtin: true),
  PermissionRule(pattern: 'grep *', builtin: true),

  PermissionRule(pattern: 'uname *', builtin: true),
  PermissionRule(pattern: 'uptime *', builtin: true),
  PermissionRule(pattern: 'stat *', builtin: true),
  PermissionRule(pattern: 'cat *', builtin: true),
  PermissionRule(pattern: 'kubectl get *', builtin: true),
  PermissionRule(pattern: 'kubectl describe *', builtin: true),
  PermissionRule(pattern: 'kubectl logs *', builtin: true),
  PermissionRule(pattern: 'kubectl top *', builtin: true),
  PermissionRule(pattern: 'docker ps *', builtin: true),
  PermissionRule(pattern: 'docker logs *', builtin: true),
  PermissionRule(pattern: 'docker stats *', builtin: true),

  // git 只读子命令。
  //
  // **这没有违反上面那条准入标准。** 那段文字把 `git` 列为不得加入，理由是
  // `-c core.pager=` 能执行外部程序 —— 那针对的是**裸 `git`**（即 `git *`）。
  //
  // 子命令前缀规则天然把它挡在外面：全局 `-c` 只能出现在子命令**之前**，
  // 所以 `git -c core.pager=x status` 的词序列是
  // `[git, -c, core.pager=x, status]`，匹配 `git status ` 这个词前缀时第二个
  // 词就对不上（`-c` ≠ `status`），`PermissionRule.matches` 在词粒度上直接
  // 失败。有一条测试锁死这个性质。
  //
  // 不加 `git show`（可配 pager）、不加 `git config`（`--global core.pager`
  // 是写）、不加裸 `git`。
  //
  // `git branch -d` 会删本地分支引用，仍然放行：准入标准管的是「能否执行其他
  // 程序或写文件」，不是「绝对无副作用」（同一集合里 `journalctl *` 也覆盖
  // `--vacuum-time`）；且本地分支引用可由 reflog 恢复。要收紧只能整条移除 ——
  // 规则体系不支持「排除某些 flag」。
  PermissionRule(pattern: 'git status *', builtin: true),
  PermissionRule(pattern: 'git diff *', builtin: true),
  PermissionRule(pattern: 'git log *', builtin: true),
  PermissionRule(pattern: 'git branch *', builtin: true),
];

/// 凭据外泄 deny 清单。
///
/// **这不是执行边界，是数据边界。** `cat ~/.ssh/id_rsa` 本身是合法的只读
/// 操作 —— 用户自己也读得到。危险的是读完之后内容进了模型厂商的请求体，
/// 而用户可能意识不到这一层。
///
/// 命中的效果是「**永不静默执行、永不能进 allowlist**」，而非硬拒绝：
/// 照常弹审批，用户点了就跑。`bypass` 模式同样不能覆盖它。
///
/// 我们**不做破坏性判断** —— `rm -rf` 用户看得懂，他自己批准就是他的选择。
///
/// ## 这里的取舍方向与 allow 规则相反：宁可宽
///
/// deny 误命中的代价是「多弹一次审批」，几秒钟；漏命中的代价是私钥进了
/// 别人的服务器，不可撤销。所以模式写得宽一点、允许后缀变体、允许命令中间
/// 夹 flag，都是刻意的。
///
/// 这份清单**不可能穷尽**，这是明确接受的。它挡的是「模型顺手 cat 一下」
/// 这类最常见的路径，不是防御一个想外泄凭据的攻击者 —— 后者本来就有一万种
/// 写法，而且他还得先骗过审批卡上的用户。
final List<RegExp> _credentialDenyPatterns = [
  // SSH 私钥。路径形式与裸文件名形式都要拦 —— 用户的 cwd 可能就在 ~/.ssh，
  // 那时命令只是 `cat id_rsa`。`.pub` 是公钥，放行。
  RegExp(r'\.ssh/id_(?!\w*\.pub)'),
  RegExp(r'(^|[\s/"\x27])id_(rsa|dsa|ecdsa|ed25519)(?!\w*\.pub)'),
  RegExp(r'\.ssh/identity(\s|$|["\x27])'), // protocol-1 时代的默认私钥名
  // authorized_keys（含旧的 authorized_keys2）不是私钥，但对它的写等价于
  // 免审批装一个 SSH 后门（追加一行公钥即可免密登录），读也会暴露已授权
  // 身份列表；裸文件名版兜 cwd 已经在 ~/.ssh 下的情况。
  RegExp(r'(^|[\s/"\x27])authorized_keys2?(\s|$|["\x27])'),
  // 证书、密钥、密钥库、以及 terraform state（apply 后常含明文口令）
  RegExp(r'\.(pem|key|p12|pfx|jks|kdbx|tfstate)(\.\w+)?(\s|$|["\x27])'),
  // 系统密码库（gshadow 是组密码）。裸文件名版是为了堵 cwd 绕过 ——
  // `cd /etc && cat shadow` 里没有 `/etc/` 这个前缀。`/etc` 本身是常见
  // 工作目录，不能整个列为敏感 cwd，所以这一条只能靠裸名兜。
  RegExp(r'/etc/g?shadow'),
  RegExp(r'(^|[\s/"\x27])g?shadow(\s|$|["\x27])'),
  // /proc/<pid>/environ 是 printenv 的等价物：整份环境变量，常含注入的 token。
  RegExp(r'/proc/[^/\s]+/environ'),
  // dotenv，含 .env.local / .env.production 这类最常见的写法
  RegExp(r'(^|[\s/"\x27])\.env(\.\w+)?(\s|$|["\x27])'),
  // 云厂商凭据目录
  RegExp(r'\.aws/credentials'),
  RegExp(r'\.config/gcloud'),
  RegExp(r'\.azure/'), // accessTokens.json 明文缓存 OAuth token
  RegExp(r'\.oci/'),
  RegExp(r'\.gnupg/'),
  RegExp(r'\.docker/config\.json'),
  RegExp(r'\.kube/config'), // 含 client cert 与 token
  // 各类工具的明文凭据文件
  RegExp(r'(^|[\s/"\x27])\.(netrc|pgpass|npmrc|my\.cnf|git-credentials)(\s|$|["\x27])'),
  // 项目内下载的服务账号密钥。不加开头锚点 —— GCP 官方建议的文件名常带
  // 前缀词（`gcp-service-account-key.json`），锚点会让它整个漏掉。
  RegExp(r'service[-_]?account[\w.-]*\.json'),
  RegExp(r'credentials\.json'),
  // k8s secret。kubectl、动词、资源名三者之间**任意位置**都可能夹 flag：
  // `kubectl -n prod get secret x` 与 `kubectl get -n prod secrets` 都要拦。
  // 早先只放宽了前一种，于是后一种照漏 —— 同一个病修一半等于没修。
  RegExp(r'\bkubectl\b.*\b(get|describe)\b.*\bsecrets?\b'),
  // 裸 printenv 会把整个环境（常含注入的 token）dump 出来。
  // 不拦 `env CMD` 形式：那是设置变量后执行，且 `/usr/bin/env python` 极常见。
  RegExp(r'(^|[\s;])printenv(\s|$)'),
];

/// 命令里所有 `.flyterm.bak` 结尾的词。
final RegExp _backupTokenRe =
    RegExp(r'\S*?\.flyterm\.bak(?=\s|$|["\x27])');

/// 从备份名反解原文件名：`<dir>/.<name>.flyterm.bak` → `<dir>/<name>`。
///
/// 循环剥离而非只做一层：编辑一个备份文件本身会产生二阶备份
/// （`..env.flyterm.bak.flyterm.bak`），只剥一层得到 `.env.flyterm.bak`，而
/// dotenv 模式要求 `\.env(\.\w+)?` 后紧跟空白或结尾，`.flyterm.bak` 不满足 ——
/// 于是漏过。
///
/// **循环必然终止**：每轮去掉 11 个字符的后缀加 1 个前导点，字符串长度严格
/// 递减。不终止只会发生在「反解后不缩短」的写法上。
///
/// 返回 null = 这不是我们生成的备份名（没有前导点），调用方按原样保守处理。
String? _restoreBackupName(String token) {
  const suffix = '.flyterm.bak';
  var cur = token;
  var peeled = false;
  while (cur.endsWith(suffix)) {
    final base = cur.substring(0, cur.length - suffix.length);
    final slash = base.lastIndexOf('/');
    final dir = slash < 0 ? '' : base.substring(0, slash + 1);
    final name = base.substring(slash + 1);
    if (!name.startsWith('.')) return peeled ? cur : null;
    cur = '$dir${name.substring(1)}';
    peeled = true;
  }
  return peeled ? cur : null;
}

/// 命令是否触碰凭据边界。
///
/// ## 备份文件走反解，不再一刀切
///
/// `edit_file`/`write_file` 写回前会把原文件备份成 `<dir>/.<name>.flyterm.bak`
/// （见 `file_edit.dart` 的 `_dotBackupPath`）。这类名字曾经被无条件拦截，
/// 代价是编辑一个完全不敏感的文件（比如 nginx.conf）产生的备份之后被单独
/// cat，也要多弹一次审批。
///
/// 现在按**原文件**是否敏感判定：反解出原名再跑同一份模式表。
/// `~/..env.flyterm.bak` 反解出 `~/.env`，照常命中 dotenv 模式被拦——那正是
/// 当初加这条规则要堵的洞，收窄不能把它放掉。
///
/// 反解不出原名（没有前导点，不是我们生成的）时**保持拦截**：这一层的不确定
/// 一律向「多问一次」退化。
bool isCredentialDeny(String command) {
  if (_credentialDenyPatterns.any((p) => p.hasMatch(command))) return true;
  for (final m in _backupTokenRe.allMatches(command)) {
    final original = _restoreBackupName(m.group(0)!);
    // 反解不出来 = 不是我们生成的备份名，保守拦截。
    if (original == null) return true;
    if (_credentialDenyPatterns.any((p) => p.hasMatch(original))) return true;
  }
  return false;
}

/// 工作目录本身落在凭据目录里。
///
/// ## 为什么必须有这一条
///
/// deny 清单里多数模式是**目录锚定**的（`.aws/credentials`、`.kube/config`、
/// `.gnupg/` …）。只要把敏感目录放进 cwd、命令里只留裸文件名，锚点就失效：
///
/// ```
/// cwd=~/.aws   cat credentials      // `.aws/credentials` 匹配不到
/// cwd=~/.kube  cat config           // `.kube/config` 匹配不到
/// cwd=~/.ssh   cat identity         // `.ssh/identity` 匹配不到
/// ```
///
/// 早先只给 `id_rsa` 补了裸文件名兼容，其余八条没跟进 —— 局部打补丁的典型
/// 后果。与其给每一条都编一个裸名变体（`config`、`credentials` 这种词太通用，
/// 编出来必然大面积误伤），不如换个维度：**cwd 落在凭据目录里时，该目录下
/// 的所有命令一律弹审批。**
///
/// 在 `~/.ssh` 里操作本来就该被用户看见一眼，这不算打扰。
///
/// 注意 `/etc` 不在此列 —— 它是最常见的工作目录之一（读 nginx.conf 等），
/// 整个拦掉会让 agent 寸步难行。`/etc/shadow` 由上面的裸文件名模式负责。
final RegExp _sensitiveCwdRe = RegExp(
  r'(^|/)\.(ssh|aws|azure|oci|gnupg|kube|docker|password-store)(/|$)'
  r'|(^|/)\.config/gcloud(/|$)'
  r'|^/etc/ssl/private(/|$)',
);

bool isSensitiveCwd(String? cwd) =>
    cwd != null && cwd.isNotEmpty && _sensitiveCwdRe.hasMatch(cwd);
