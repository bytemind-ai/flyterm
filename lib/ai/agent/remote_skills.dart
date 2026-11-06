// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io' show gzip;

import 'command_runner.dart';
import 'skill.dart';
import 'skill_file_import.dart' show skillsFromFileSet;

/// 远端技能目录。`~` 由远端 shell 展开，所以**不能** shellQuote。
const String kRemoteSkillsDir = '~/.flyterm/skills';

/// 分隔符。用一个不可能出现在 markdown 正文里的形状，避免正文里恰好有
/// 一行 `---` 就把解析切乱。
const String _kMarker = '===FLYTERM-SKILL:';

/// 一份待导入的技能（还没落库，name 可能撞、description 可能是空的）。
class PendingSkill {
  final String name;
  final String description;
  final String body;
  final SkillSource source;

  /// 随技能一起导入的附件（脚本 / 模板）。
  ///
  /// 目录形态（`<name>/SKILL.md` + 目录里其余文件）或 zip 导入时非空；
  /// 崇平的单个 `.md` 导入时为空 —— 那种形态本来就没地方放附件。
  final List<AgentSkillAsset> assets;

  /// 目录形态导入时的目录名，仅用于预览页显示来源。null = 崇平文件。
  final String? dirName;

  const PendingSkill({
    required this.name,
    required this.description,
    required this.body,
    required this.source,
    this.assets = const [],
    this.dirName,
  });

  PendingSkill copyWith({
    String? name,
    String? description,
    String? body,
    List<AgentSkillAsset>? assets,
    String? dirName,
  }) =>
      PendingSkill(
        name: name ?? this.name,
        description: description ?? this.description,
        body: body ?? this.body,
        source: source,
        assets: assets ?? this.assets,
        dirName: dirName ?? this.dirName,
      );
}

class RemoteSkillsResult {
  final List<PendingSkill> skills;

  /// 解析失败被跳过的份数。预览页据此显示一行「N 份无法解析」。
  final int skipped;

  /// 非 null = 这次拉取本身失败了。**要显示给用户**。
  final String? error;

  const RemoteSkillsResult({
    this.skills = const [],
    this.skipped = 0,
    this.error,
  });
}

/// 一次远端拉取最多接多少字节。
///
/// 一份技能的正文上限 8 KiB + 附件合计 16 KiB = 24 KiB，tar + base64 再
/// 膨胀约 1.35 倍 → 33 KiB。留一倍余量到 64 KiB，一次拉回若干份也不至于
/// 被截。
///
/// **为什么要显式抬这个值**：`CommandRunner.run` 默认按
/// `kMaxOutputBytes`（8 KiB）截断，那是给“模型要读的文本”定的。用 8 KiB
/// 去接一份带脚本的技能，后半截会被默默丢掉——而这里拿回来的是要解包的
/// 结构数据，截一半就是解析失败。
const int kRemoteSkillFetchBytes = 64 * 1024;

/// 从远端 `~/.flyterm/skills/` 批量拉取。
///
/// ## 支持的两种形态
///
/// 1. **目录形态**：`<name>/SKILL.md` + 目录里其余文件（脚本 / 模板）
/// 2. **崇平形态**：目录下的 `*.md`，每份算一条无附件技能
///
/// 两者可以共存。判定与拆包都在 `skillsFromFileSet` 里，这里只负责
/// 把字节取回来。
///
/// ## 为什么用 tar 而不是逐文件 head -c
///
/// 改造前是 `for f in *.md; do head -c ...; done`——那个形状装不下目录。
/// 目录形态要把一棵子树完整取回，`tar` 是远端只跑一条命令、客户端一次解包
/// 的最简做法。`base64` 包一层是因为 tar 是二进制，直接走 stdout 会在
/// UTF-8 解码那一步就坏掉（`decodeOutput` 会把它当 binary 处理）。
///
/// ## 为什么失败要报错，不能静默
///
/// 这是**用户点按钮**的一次性动作。他在等一个结果，静默返回空列表会
/// 让他以为服务器上真的没有技能。**失败要报错给用户。**
///
/// ## 相同的地方：不经过 checkCommand
///
/// 这条命令由我们发起，不是模型的意图，不该弹审批卡。`CommandRunner` 的
/// `redactSecrets` 照常生效 —— 技能里写了 `password: xxx` 会变成
/// `[redacted by FlyTerm]`，对会发给模型厂商的文本来说这是好事。
Future<RemoteSkillsResult> fetchRemoteSkills(CommandRunner runner) async {
  final CommandOutput out;
  try {
    out = await runner.run(
      _fetchCommand,
      maxBytes: kRemoteSkillFetchBytes,
    );
  } catch (e) {
    return RemoteSkillsResult(error: 'Could not reach the server: $e');
  }
  if (out.timedOut) {
    return const RemoteSkillsResult(
        error: 'Timed out while reading the skills directory.');
  }
  if (out.exitCode == -1) {
    return const RemoteSkillsResult(
        error: 'The command did not complete on the server.');
  }

  final text = out.stdout;
  if (!text.contains(_kMarker)) {
    // 目录不存在或者是空的 —— 不是失败。
    return const RemoteSkillsResult();
  }

  final payload = text.substring(text.indexOf(_kMarker) + _kMarker.length);
  final files = _unpackTarGzBase64(payload);
  if (files == null) {
    return const RemoteSkillsResult(
        error: 'The server returned a bundle this app could not read. Is '
            '`tar` available on it?');
  }

  final rejected = <String>[];
  final skills = skillsFromFileSet(
    files,
    source: SkillSource.remote,
    onRejected: rejected.add,
  );
  return RemoteSkillsResult(skills: skills, skipped: rejected.length);
}

/// 远端打包命令。
///
/// 逐条说明：
///
/// - `[ -d dir ] || exit 0`：目录不存在不是错误，空输出让客户端按“什么都没有”
///   处理。
/// - `cd` 到技能目录再 `tar .`：这样 tar 里的路径就是相对于 `~/.flyterm/
///   skills/` 的（`deploy/SKILL.md`），客户端不用剥前缀。
/// - `--exclude` 排掉常见垃圾（macOS 元数据、编辑器备份）—— 不排的话它们
///   会变成附件被写进用户服务器，而它们多数不可读文本。
/// - `2>/dev/null` 盖掉“没有匹配”之类的噪音，让错误流干净。
/// - `| base64 -w0`：不分行。很多 base64 实现默认 76 列换行，分行会让
///   payload 里全是 `\n`，解包前得先拼回来（能做但多一步）。`-w0` 是 GNU
///   扩展，busybox 不认——所以留着下一层的容错：`_unpackTarGzBase64` 自己
///   会把 payload 里的空白去掉再解，两种都吃。
const String _fetchCommand =
    'd="\$HOME/$_kRemoteSkillsDirName"; '
    '[ -d "\$d" ] || exit 0; '
    'cd "\$d" || exit 0; '
    'echo "$_kMarker"; '
    'tar --exclude=._* --exclude=__MACOSX --exclude=*.swp --exclude=*~ '
    '-czf - . 2>/dev/null | base64; echo';

/// `~/.flyterm/skills` 的裸形式（没有 `~/`），给 shell 变量拼使用。
const String _kRemoteSkillsDirName = '.flyterm/skills';

/// 解开 `base64(tar.gz(...))`，返回「相对路径 → 字节」。
///
/// 解不开（不是 gzip、不是 tar、载荷被截断）一律返回 null，由调用方报错。
///
/// **手写一个极小的 tar 解析而不是引第三方包**：我们只需要 GNU/BSD tar 产
/// 出的普通文件，不需要符号链接、硬链接、稀疏文件、PAX 扩展头。引一个包
/// 只为了读这几种就没用到的形状，代价是 apk 变大 + 一条新的供应链。
///
/// 看不懂的条目（目录、链接、PAX）**跳过**：目录不是内容，PAX 头只是元数据，
/// 它们不影响普通文件的提取。
Map<String, List<int>>? _unpackTarGzBase64(String payload) {
  // 去掉所有空白（base64 可能被 76 列换行过，也可能没有）。
  final cleaned = payload.replaceAll(RegExp(r'\s'), '');
  if (cleaned.isEmpty) return const {};

  final List<int> tgz;
  try {
    tgz = base64.decode(base64.normalize(cleaned));
  } on FormatException {
    return null;
  }

  final List<int> tar;
  try {
    tar = gzip.decode(tgz);
  } catch (_) {
    return null;
  }

  final files = <String, List<int>>{};
  var offset = 0;
  var sawHeader = false;
  while (offset + 512 <= tar.length) {
    final header = tar.sublist(offset, offset + 512);
    // 全零块 = 归档结束。
    if (header.every((b) => b == 0)) {
      sawHeader = true; // 完整的空归档也是合法的
      break;
    }
    sawHeader = true;

    final name = _tarString(header, 0, 100);
    final sizeField = _tarString(header, 124, 12).trim();
    final size = int.tryParse(sizeField, radix: 8) ?? 0;
    final typeFlag = header[156];
    // 前缀字段（ustar）拼在名字前。
    var prefix = _tarString(header, 345, 155);

    offset += 512;
    if (offset + size > tar.length) return null; // 载荷被截断

    final full = prefix.isEmpty ? name : '$prefix/$name';
    // '0' 或 NUL = 普通文件；'x'/'g' PAX 头、'L' 长名、目录、链接都跳过。
    final isRegular = typeFlag == 0x30 || typeFlag == 0;
    if (isRegular && size > 0) {
      files[full] = tar.sublist(offset, offset + size);
    }

    // 条目数据按 512 对齐。
    offset += ((size + 511) ~/ 512) * 512;
    prefix = '';
  }
  // 一个完整的 tar 至少有一个头块（空目录就是两个全零块）。连一个头都读
  // 不到 = 载荷在传输中被截断了。不把这种情况当成“空目录”，否则用户看到
  // 的是“服务器上没有技能”，而真实原因是那次读取没完成。
  if (!sawHeader) return null;
  return files;
}

/// 读 tar 头里的一个 ASCII 字段，在第一个 NUL 处截断。
String _tarString(List<int> header, int start, int length) {
  final end = (start + length).clamp(0, header.length);
  final bytes = header.sublist(start, end);
  final nul = bytes.indexOf(0);
  final slice = nul < 0 ? bytes : bytes.sublist(0, nul);
  return String.fromCharCodes(slice);
}
