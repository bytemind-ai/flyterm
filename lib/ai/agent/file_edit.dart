// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'shell_guard.dart';
import 'skill.dart' show AgentSkillAsset;

/// `edit_file` / `write_file` 能处理的最大文件字节数。
///
/// 这个数字不是随便定的，是被 `kMaxOutputBytes`（8192）**算出来**的：
///
/// 读取必须走 base64（见下方 [buildReadForEditCommand] 的说明），base64 把
/// N 字节膨胀成 4·⌈N/3⌉。同一条命令还带回 sha256（64 字符）与文件大小两行。
/// 8192 - 约 80 = 8100 可用，÷ 4 × 3 = 6075。取 6000 留余量。
///
/// 这是「读—改—写」方案的固有边界，不是实现瑕疵：读不到完整内容就不能安全
/// 地整体覆写。更大的文件需要流式处理，那不是手机上该做的事。
const int kMaxEditFileBytes = 6000;

/// 写入前发现文件已被改动时，远端脚本用这个退出码。
///
/// 挑一个不与常见命令冲突的值：1/2 太常见，126/127 是 shell 保留的
/// 「不可执行 / 找不到」。
const int kStaleFileExitCode = 65;

/// 一次替换的结果。[content] 非空表示成功，[error] 非空表示放弃。
/// 两者永远只有一个非空。
class EditResult {
  /// 替换后的完整内容。null = 没做替换。
  final String? content;

  /// 给模型看的失败原因。null = 成功。
  final String? error;

  /// `old_string` 命中的起始行号（1-based），用于审批卡展示。
  final int? atLine;

  const EditResult._({this.content, this.error, this.atLine});

  const EditResult.ok(String content, int atLine)
      : this._(content: content, atLine: atLine);

  const EditResult.failed(String error) : this._(error: error);
}

/// 在 [content] 里把 [oldString] 换成 [newString]，**要求恰好命中一次**。
///
/// 唯一性校验是这个工具能不能用的关键。命中多次时改第一处了事，等于静默
/// 改错地方 —— 用户在审批卡上看到的是「把 listen 80 改成 8080」，实际改的
/// 是另一个 server 块。所以多次命中一律不改，让模型带上更多上下文重试。
EditResult applyEdit({
  required String content,
  required String oldString,
  required String newString,
}) {
  if (oldString.isEmpty) {
    return const EditResult.failed(
        '`old_string` must not be empty: it would match everywhere. '
        'Include the exact text you want replaced.');
  }
  if (oldString == newString) {
    return const EditResult.failed(
        '`old_string` and `new_string` are identical — nothing to change.');
  }

  final first = content.indexOf(oldString);
  if (first < 0) {
    return const EditResult.failed(
        '`old_string` not found in the file. Read the file first and copy the '
        'text exactly, including indentation.');
  }
  // 数出现次数。不用 split().length - 1：oldString 含正则元字符时那条路要
  // 转义，而 indexOf 循环没有这个问题。
  var count = 0;
  var at = 0;
  while (true) {
    final i = content.indexOf(oldString, at);
    if (i < 0) break;
    count++;
    at = i + oldString.length;
  }
  if (count > 1) {
    return EditResult.failed(
        '`old_string` appears $count times in the file. Add surrounding lines '
        'to make it unique — I will not guess which one you meant.');
  }

  // 只替换这一处。用 replaceRange 而不是 replaceAll：后者会把结果里**新
  // 出现**的同样文本也换掉（`a=1` → `a=1 # patched` 就会无限套娃）。
  final out = content.replaceRange(first, first + oldString.length, newString);

  if (utf8.encode(out).length > kMaxEditFileBytes) {
    return const EditResult.failed(
        'The result would be too large to write safely (limit is '
        '$kMaxEditFileBytes bytes). Use `bash` with a targeted command '
        'instead.');
  }

  // 行号 = 命中位置之前的换行数 + 1
  final atLine = content.substring(0, first).split('\n').length;
  return EditResult.ok(out, atLine);
}

/// 读取远端文件的解析结果。
class EditFileRead {
  final String? content;
  final String? sha256;
  final String? error;

  const EditFileRead._({this.content, this.sha256, this.error});
  const EditFileRead.ok(String content, String sha)
      : this._(content: content, sha256: sha);
  const EditFileRead.failed(String error) : this._(error: error);
}

/// 拼出「读整份文件用于编辑」的命令。
///
/// ## 为什么必须走 base64，不能直接 cat
///
/// `SshCommandRunner._prepare` 对所有输出做 `redactSecrets`。直接读一份含
/// `password: hunter2` 的配置，回到 Dart 手里已经是
/// `password: [redacted by FlyTerm]`；把它当作「文件当前内容」做替换再整体
/// 覆写，**用户的密码就被写成了那个字面量** —— 而且改的正是他最不希望被动
/// 的那一行。ANSI 剥离与 8 KiB 截断同理。
///
/// base64 之后，脱敏正则在 base64 字母表里匹配不到 `key: value` 形状。
///
/// ## 为什么还要带 sha256
///
/// 上面那条只是「我们想到的」环节。sha256 是总闸：客户端解码后本地重算比对
/// （见 [parseEditFileRead]），字节被任何环节动过都会对不上。它同时充当写回
/// 时的 TOCTOU 凭据，一举两得。
///
/// `base64 -w0` 是 GNU 扩展，BusyBox 没有 —— 用 `tr -d` 去换行才通用；
/// `tr -d "\r\n"` 而不是只删 `\n`，因为部分环境（CRLF 结尾的输出、某些
/// PTY 配置）会带回 `\r`，留着会混进 base64 载荷导致 decode 失败。
///
/// ## 为什么用 `< $q` 而不是 `-- $q` 传参
///
/// `sha256sum` 之类的 GNU coreutils 摘要工具，在文件名含反斜杠或换行时会
/// 给输出整行加 `\` 前缀并转义文件名里的特殊字符——这会让 `cut -d" " -f1`
/// 切出一个带转义序列的哈希，永远对不上本地重算的结果，读取端表现为
/// 「文件被别人改过」的永久性误报。改成 `sha256sum < $q`，coreutils 走
/// stdin 分支，输出固定是 `<hash>  -`，没有文件名、没有转义。`base64` 本身
/// 不受这个问题影响，但统一用 stdin 重定向传输更一致、也不依赖 `--` 在不同
/// coreutils/BusyBox 变体间的兼容性。
String buildReadForEditCommand(String path) {
  final q = shellQuotePath(path);
  return 'sha256sum < $q | cut -d" " -f1 && '
      'wc -c < $q && '
      'base64 < $q | tr -d "\\r\\n"';
}

/// 解析 [buildReadForEditCommand] 的 stdout：三行 sha / size / base64。
///
/// 任何一步不对就返回 error 而不是「尽量凑一份内容出来」—— 这里凑出来的
/// 内容会被整体写回磁盘。
EditFileRead parseEditFileRead(String stdout) {
  // 不能先 `.trim().split('\n')`：空文件时 base64 段是空字符串，trim 会把
  // 它前面那个换行也吃掉，3 行退化成 2 行。改用定位前两个换行符的方式，
  // 显式保留（可能为空的）第三段。
  final firstNl = stdout.indexOf('\n');
  final secondNl = firstNl < 0 ? -1 : stdout.indexOf('\n', firstNl + 1);
  if (firstNl < 0 || secondNl < 0) {
    return const EditFileRead.failed(
        'Could not read the file (unexpected output). It may not exist.');
  }
  final sha = stdout.substring(0, firstNl).trim();
  final size = int.tryParse(stdout.substring(firstNl + 1, secondNl).trim());
  if (size == null) {
    return const EditFileRead.failed('Could not determine the file size.');
  }
  if (size > kMaxEditFileBytes) {
    return EditFileRead.failed(
        'File is $size bytes; I can only safely rewrite files up to '
        '$kMaxEditFileBytes bytes. Use `bash` with sed/awk for this one — it '
        'will go through approval as usual.');
  }

  final List<int> bytes;
  try {
    // base64 只剩一段，但传输过程中可能仍有尾随空白，normalize 掉。
    bytes = base64.decode(stdout.substring(secondNl + 1).trim());
  } catch (_) {
    return const EditFileRead.failed(
        'The file contents came back malformed (truncated transfer). '
        'Not editing it.');
  }

  // 一行的纵深防御：sha256 已经覆盖「字节被动过」，但上面的大小上限判定
  // （`size > kMaxEditFileBytes`）发生在解码之前，靠的是服务端报的那个数字。
  // 这行把「上限判定基于一个谎报的数字」这条推理彻底封死——不依赖它，但
  // 加上它不用多想。
  if (bytes.length != size) {
    return const EditFileRead.failed(
        'Reported file size does not match the decoded content length; '
        'refusing to trust it.');
  }

  // **总闸**：本地重算哈希。脱敏、截断、ANSI 剥离、传输截字——任何一条动过
  // 字节都会在这里被拦下。逐个判断这些环节不如直接校验哈希，一次覆盖全部。
  //
  // 措辞刻意不说「磁盘上的内容和我读到的不一样」：那会让人去追一个不存在
  // 的并发写者。真正常见的诱因是脱敏正则误命中 base64 载荷（padding 的
  // `=` 落进了 `key=value` 形状）或传输截断——都跟「有人在改这个文件」
  // 无关。fail-closed 是对的，但诊断方向不能带偏。
  final localSha = sha256.convert(bytes).toString();
  if (localSha != sha) {
    return const EditFileRead.failed(
        'checksum mismatch: the content changed in transit (likely '
        'redacted or truncated) before it could be compared — this does '
        'not necessarily mean someone else edited the file. Refusing to '
        'write it back. Use `bash` for this edit.');
  }

  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return const EditFileRead.failed(
        'That file is not valid UTF-8 text; I will not edit it as text.');
  }
  return EditFileRead.ok(text, sha);
}

/// 备份文件路径：与目标同目录，文件名前加一个点，末尾带调用序号。
///
/// 加点前缀不是美化——Debian nginx 默认 `include sites-enabled/*;`、
/// 部分发行版的 `include conf.d/*;` 都不过滤扩展名，`<path>.flyterm.bak`
/// 放在原文件旁边会被当成又一份配置一并 include 进去，下次 `nginx -t` /
/// reload 直接报 duplicate server——这正好命中本计划自己举的示范场景
/// （改 nginx 的 `listen 80`）。`*` glob 天然跳过点开头的文件，点前缀
/// 因此规避了这个坑；`cp -p` 仍然保留原文件的权限位，点前缀不引入新的
/// 泄密面（不加点的版本反而会在 `~/.ssh/`、git 工作区里留下显眼残留）。
///
/// 拆分规则：`dir` 取到最后一个 `/`（含这个 `/` 本身），`base` 取其后的部分。
///
/// 关键是「路径里根本没有 `/`」和「`/` 恰好在下标 0」这两种情况不能用同一
/// 套字符串拼接处理：前者（纯相对文件名，如 `f`）的 `dir` 必须是空串，
/// 拼出 `.f.flyterm.bak`（相对路径，和原文件一样是相对的）；后者（根目录
/// 下的文件，如 `/f`）的 `dir` 必须是 `/`，拼出 `/.f.flyterm.bak`
/// （仍在根目录）——如果这里手滑把 `dir.isEmpty` 判断套用到「`/` 在下标
/// 0」的情况、丢掉这个 `/`，`/f` 就会退化成相对路径 `.f.flyterm.bak`，
/// 指向的是远端进程的当前工作目录，而不是根目录。这不只是「备份放错
/// 地方」：agent 的 cwd 常是用户 home 或某个只读目录，`cp` 到那里失败，
/// `|| exit 1` 会触发，根目录下的文件就变成永远编辑不了，报错还指向一个
/// 和用户操作看起来毫不相干的备份步骤。用 `lastIndexOf('/') + 1` 切片、
/// 把 `/` 本身带进 `dir`，两种情况自然统一，不需要再判断 `dir.isEmpty`。
///
/// ## 为什么带 [seq]
///
/// 不带序号时同名备份会被覆盖：同一个文件被改两次，第一次的原始内容永久
/// 丢失，用户只能回退到「第一次修改之后」的状态。带上序号之后每次编辑各
/// 有一份自己的备份，每张工具卡都能独立回退。
///
/// 用 `ToolCallEvent.seq` 作为序号：它是会话内单调递增的计数器，天然不
/// 重复，不需要新造一个 ID 体系。
///
/// 公开（去掉下划线）是为了让测试能直接断言路径拼接的三种边界——这个函数
/// 的历史 bug 全在拼接上，只能通过 `buildWriteFileCommand` 间接测会让失败
/// 信息指不到问题源头。
String dotBackupPathForSeq(String path, int seq) {
  final lastSlash = path.lastIndexOf('/');
  final dir = lastSlash < 0 ? '' : path.substring(0, lastSlash + 1);
  final base = lastSlash < 0 ? path : path.substring(lastSlash + 1);
  return '$dir.$base.flyterm.bak.$seq';
}

/// 拼出写回命令。
///
/// ## 为什么用重定向而不是写临时文件再 mv
///
/// `mv` 会替换 inode，新文件拿的是默认权限与属主 —— 一份 `600 root:root`
/// 的配置会变成 `644 <登录用户>`。而 `> file` 是原地截断+写入，inode 不变，
/// 权限与属主都保住。
///
/// ## 为什么备份失败必须中止，而不是无声继续
///
/// 写入中途失败会留下半个文件，`.flyterm.bak` 是唯一的兜底。如果备份这步
/// 用 `;` 分隔、失败了就无声跳过，那么目录不可写 / 磁盘满 / `.flyterm.bak`
/// 恰好是个目录这几种情况下，`>` 照样会立刻截断目标文件——备份没做成，
/// 原内容却已经没了。所以备份失败要 `exit 1` 中止整条命令。
///
/// 但「文件本来就不存在」（`write_file` 新建）不算失败，不能一律 `&&`：
/// 用 `[ -e ]` 判存在性，存在才要求备份成功，不存在就跳过备份直接写。
///
/// ## 为什每 sha256sum 用 `< $q` 而不是 `-- $q`
///
/// 同 [buildReadForEditCommand]：文件名含反斜杠/换行时，GNU 摘要工具会
/// 转义输出、让比对永远失败，client 端会把这解释成「文件被别人改了」去
/// 追一个不存在的并发写者。改用 stdin 重定向绕开这条转义规则。
///
/// ## 为什么校验和写入必须在同一条命令里
///
/// 拆成「先查哈希」「再写入」两次往返，中间那段时间足够别的进程改动文件，
/// TOCTOU 窗口就是这两次往返的间隔。放进一条命令，窗口压到命令内部。
///
/// ## 为什么整条命令要包一层 `{ ...; }`
///
/// `wrapForSsh`（`shell_guard.dart`）把最终命令拼成
/// `cd '<cwd>' && <这条命令>`。如果这条命令内部是用 `;` 分隔的一串语句，
/// `&&` **只约束到分号列表里的第一条**——`cd` 失败时，staleness 校验和
/// 备份步骤会被跳过，但后面 `;` 分隔的写入步骤仍会无条件执行：文件写到了
/// 错误目录（相对路径时落进 `$HOME`），退出码却是 0，调用方以为成功了。
/// 包成 `{ 整条命令; }` 之后，`cd` 失败会让整个大括号组短路，退出码非 0。
String buildWriteFileCommand(
  String path,
  List<int> bytes, {
  String? expectedSha,
  /// 备份文件的序号，取自 `ToolCallEvent.seq`。**必填**：给默认值会让漏传
  /// 的调用点静默共用同一个备份编号，退回「同名覆盖」那个 bug，而编译器
  /// 一句话都不说。
  required int seq,
}) {
  final q = shellQuotePath(path);
  final bq = shellQuotePath(dotBackupPathForSeq(path, seq));
  // base64 字母表只有 A-Za-z0-9+/=，天然不含任何 shell 特殊字符；加单引号
  // 是为了让「载荷是一个词」这件事在命令文本里也显式成立。
  //
  // 先赋值到 shell 变量、再用 "$b64" 引用（而不是直接
  // `printf %s '$b64' | ...`）：这个单引号字面量因此出现在命令的最前面，
  // 早于任何 $q 的引用。对短路径（如 `/f`）这不是纯粹的美化——`shellQuote`
  // 包出来的 `'/f'` 本身恰好落在 base64 字母表内，如果 base64 载荷不是
  // 命令里第一个单引号片段，就没法从文本上把「路径」和「载荷」区分开。
  final b64 = base64.encode(bytes);

  final backup = 'if [ -e $q ]; then cp -p -- $q $bq || exit 1; fi';
  final write = "b64='$b64'; $backup; printf %s \"\$b64\" | base64 -d > $q";

  final body = expectedSha == null
      ? write
      : 'if [ "\$(sha256sum < $q | cut -d" " -f1)" != "$expectedSha" ]; '
          'then exit $kStaleFileExitCode; fi; $write';

  return '{ $body; }';
}

/// 撤销时备份文件已不存在的退出码。
///
/// 和 [kStaleFileExitCode] 一样挑一个不与常见命令冲突的值：需要把「备份没了」
/// 与「cp 因权限/磁盘失败」分开——前者要把按钮永久置灰（重试没意义），后者
/// 应该让用户能重试。
const int kMissingBackupExitCode = 66;

/// 拼出撤销命令：把备份拷回原路径。
///
/// `cp -p` 而不是 `mv`：与 [buildWriteFileCommand] 同一个理由——`mv` 换
/// inode，新文件拿默认权限与属主，一份 `600 root:root` 的配置会变成
/// `644 <登录用户>`。`cp -p` 原地覆盖内容并保留权限位。
///
/// 先判存在性再拷：备份可能被用户手工清掉、被别的工具删掉，或者当初根本
/// 没生成（`write_file` 新建文件时没有可备份的原文件）。这几种都该给出
/// [kMissingBackupExitCode] 而不是一句含混的 cp 报错。
///
/// 整条包在 `{ ...; }` 里，同 [buildWriteFileCommand]：`wrapForSsh` 会拼成
/// `cd '<cwd>' && <这条命令>`，而 `&&` 只约束到分号列表的第一条。不包大括号
/// 的话，`cd` 失败时后面的 `cp` 仍会无条件执行——在相对路径下就是把备份拷到
/// 了错误的目录，退出码却是 0。
String buildUndoCommand(String path, String backupPath) {
  final q = shellQuotePath(path);
  final bq = shellQuotePath(backupPath);
  return '{ [ -e $bq ] || exit $kMissingBackupExitCode; cp -p -- $bq $q; }';
}

/// 拼出「投送一个技能的全部附件」的单条命令。
///
/// ## 为什么是单条命令而不是每个附件一次往返
///
/// N 个附件 = N 次手机→服务器往返。手机链路的往返成本是整个 agent 交互里
/// 最贵的一项，而这是一次原子意图（`install_skill_assets`），没有中间需要
/// 用户或模型决策的步骤。全部压进一条。
///
/// ## 为什么用 base64
///
/// 附件正文是任意字符串（可能含单引号、反引号、`$`、换行）。直接拼进命令
/// 就得转义，而转义是这类拼接 bug 的温床。base64 字母表只有
/// `A-Za-z0-9+/=`，天然不含任何 shell 特殊字符 —— 载荷是一个词，不需要
/// 转义。这与 [buildWriteFileCommand] 选择 base64 的理由完全相同。
///
/// ## 为什么先 mkdir -p 再逐个写
///
/// 附件的 `path` 可以带目录（`scripts/x.sh`）。`-p` 让嵌套目录一次建好，
/// 且已存在时不报错 —— 重装同一技能是正常操作。
///
/// ## 为什么 chmod 只对 executable 的做
///
/// `executable` 是显式信号，不从扩展名猜。只对它 `chmod +x` 意味着
/// 数据文件（`templates/*.conf`）落下去就是 600/644，不会被误当程序。
///
/// ## 为什么包一层 `{ ...; }`
///
/// 同 [buildWriteFileCommand]：`wrapForSsh` 会拼成 `cd '<cwd>' && <这条>`，
/// 而 `&&` 只约束到分号列表的第一条。不包大括号的话，`cd` 失败时后面的写入
/// 仍会执行 —— 相对路径落进 `$HOME`，退出码却是 0。
///
/// ## `installDir` 必须是安全的字面量
///
/// 调用方拼的是 `\$HOME/<固定目录>/<slug>`，其中 slug 已经过
/// [slugifySkillDir] 只保留 `A-Za-z0-9._-`。所以这里**不能**再 shellQuote
/// 整个串 —— 那会把 `$HOME` 变成字面量美元符号。这是本函数唯一一处与
/// [buildWriteFileCommand] 不同的拼接约定。
String buildInstallAssetsCommand(
  String installDir,
  List<AgentSkillAsset> assets,
) {
  final parts = <String>['mkdir -p ${shellQuotePath(installDir)}'];
  for (final a in assets) {
    final full = '$installDir/${a.path}';
    final q = shellQuotePath(full);
    final b64 = base64.encode(utf8.encode(a.content));
    // 先 mkdir 这个附件的父目录（`a.path` 可能带子目录）。
    final lastSlash = full.lastIndexOf('/');
    if (lastSlash > 0) {
      parts.add('mkdir -p ${shellQuotePath(full.substring(0, lastSlash))}');
    }
    // 与 buildWriteFileCommand 一样：先赋值到变量再引用，让单引号字面量
    // （base64 载荷）出现在命令的显式位置，不依赖它恰好落在字母表内。
    parts.add("b64='$b64'; printf %s \"\$b64\" | base64 -d > $q");
    if (a.executable) {
      parts.add('chmod +x $q');
    }
  }
  return '{ ${parts.join('; ')}; }';
}

/// 技能名 → 安全的目录名。
///
/// 只保留 `A-Za-z0-9._-`，其余（含中文、空格、斜杠）折成 `-`，并折叠连续
/// 连字符、去掉首尾连字符。名字全被折掉时回落到 `skill`。
///
/// **必须与 `buildInstallAssetsCommand` 的“路径是安全字面量”假设一致**：
/// 那个函数不 shellQuote `installDir`，安全性就靠这里产出的字符集。改这里
/// 的字符集必须同时检查那边。
String slugifySkillDir(String name) {
  final s = name
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return s.isEmpty ? 'skill' : s;
}
