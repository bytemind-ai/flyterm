// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

/// Shell 元字符检测。
///
/// 命中任意一个即表示这条命令**不能**走 allow 规则快路径，必须弹审批。
/// 这是前缀规则体系成立的前提 —— `systemctl status nginx; rm -rf /`
/// 的前缀也是 `systemctl status`。
///
/// 我们**不做 shell 解析**：引号内的元字符同样算命中。宁可多问一次，
/// 也不要写一个能被引号嵌套绕过的解析器。
///
/// ## 这道防线只防一半，另一半靠默认规则集的准入标准
///
/// 本检测防的是「用 shell 操作符把多条命令拼在一行」。它**完全不防**
/// 「单条命令自带二级执行原语」：
///
/// ```
/// find /tmp -exec rm -rf {} +        // 无元字符，却能执行任意命令
/// awk 'BEGIN{system("id")}' f        // 同上
/// xargs / eval / perl -e / sed 的 e 命令 / tar --checkpoint-action=exec
/// ```
///
/// 正则拦不住这一类，也不该试 —— 它们在语法上就没有元字符。约束这一类
/// 靠的是 `permission_rules.dart` 的默认清单准入标准：**默认自动放行的
/// 命令不得具备执行其他程序或写文件的能力**（`find *` 因此被排除在默认
/// 清单之外）。
///
/// 改动默认清单前请重读这段。
final RegExp _metacharRe = RegExp(r'[;|`><&\n\r]|\$\(');

bool hasShellMetachar(String command) => _metacharRe.hasMatch(command);

/// POSIX 单引号转义。单引号内除 `'` 外一切失去特殊含义，这是完备的。
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 给**文件路径**用的引号化：和 [shellQuote] 一样安全，但让开头的 `~` 还能
/// 被 shell 展开。
///
/// ## 为什么需要它
///
/// `shellQuote('~/.bashrc')` 得到 `'~/.bashrc'`，而单引号内 `~` **不展开**
/// —— 命令于是去操作一个字面名为 `~` 的目录，必然失败（实测 BusyBox 与
/// GNU 都报 `nonexistent directory`）。
///
/// 而 `~` 恰恰是模型最自然的写法：当初发现这个 bug 时，`read_file` /
/// `write_file` / `edit_file` 都要引号化路径，于是同一个 `~/...` 路径
/// 「读得到、写不进」（读走的是不加引号的 `cat`，一直正常）。
///
/// ## 为什么这样安全
///
/// 转成 `"$HOME"'/.bashrc'`：`$HOME` 在双引号内展开，路径其余部分仍在单
/// 引号里。注入防护一点没少 —— 实测把 `'; touch /tmp/PWNED; #` 塞进路径
/// 不会逃逸，它被当成字面文件名。
///
/// 只认 `~`、`~/` 与 `$HOME/`，不认 `~user/`：那要知道别人的家目录，而 shell
/// 的 `~user` 展开在这里帮不上忙（它在双引号内同样不展开），且这个写法在
/// 排查场景里几乎不出现。`~user/x` 会被整段当作字面路径 —— 与修复前的行为
/// 一致，不是新的退步。
///
/// ## `$HOME/` 是 2026-10-13 补的
///
/// `~` 修了之后，同一个病在 `$HOME/` 这个写法上又复发了一次：
/// `install_skill_assets` 当时拼的是 `'$HOME/.flyterm/skill-assets/<slug>'`，
/// 引号化后单引号内 `$HOME` 不展开，于是在 cwd 下建了个**字面名为 `$HOME`
/// 的目录**，而 `mkdir`/写入都返回 0 —— 装 "成功" 了但文件落错地方。
///
/// 调用方已改用 `~`（正确意图）。这里补上 `$HOME/` 是**堵住复发**：
/// `$HOME/` 在本仓库是个自然写法（`remote_skills.dart`、
/// `aqt_server_installer.dart` 都在用），总有人会把它传进来。
String shellQuotePath(String path) {
  if (path == '~') return r'"$HOME"';
  if (path.startsWith('~/')) {
    return '${r'"$HOME"'}${shellQuote(path.substring(1))}';
  }
  if (path.startsWith(r'$HOME/') || path == r'$HOME') {
    // `substring(5)` 而不是 `substring(6)`：`$HOME` 占 0..4，下标 5 是那个
    // 斜杠。从 6 开始会把斜杠切掉，拼出 `".$HOME".flyterm/...'` 这种
    // **丢掉一层目录**的路径。（`~/` 那条分支用的是 `substring(1)`，同样
    // 保留了斜杠 —— 两条分支必须同构。）
    final rest = path == r'$HOME' ? '' : shellQuote(path.substring(5));
    return '${r'"$HOME"'}$rest';
  }
  return shellQuote(path);
}

/// 把命令包装成可以安全通过 `SSHClient.execute` 传输的形式。
///
/// 沿用 `shell_completion_service.dart:47` 已验证的手法：整个脚本 base64
/// 编码，wire 上永远是 `echo <b64>|base64 -d|bash`，不需要任何引号处理。
///
/// **调用顺序至关重要**：元字符检测的对象是模型给出的原始 [command]，
/// 不是本函数的返回值 —— 本函数自己会引入 `&&`。检测在前，包装在后。
String wrapForSsh(String command, {String? cwd}) {
  final script = cwd == null || cwd.isEmpty
      ? command
      : 'cd ${shellQuote(cwd)} && $command';
  final b64 = base64.encode(utf8.encode(script));
  return 'echo $b64|base64 -d|bash';
}
