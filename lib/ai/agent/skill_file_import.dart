// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'remote_skills.dart' show PendingSkill;
import 'skill.dart';
import 'zip_reader.dart' show unzip;

class FileImportResult {
  final PendingSkill? skill;
  final String? error;

  const FileImportResult({this.skill, this.error});
}

/// 一次导入可能产出多份技能（目录/zip 里可能装了不止一个）。
class SkillBundleResult {
  final List<PendingSkill> skills;

  /// 解析失败被跳过的份数。
  final int skipped;

  /// 非 null = 这次读取本身失败了，要显示给用户。
  final String? error;

  const SkillBundleResult({
    this.skills = const [],
    this.skipped = 0,
    this.error,
  });
}

/// 弹系统文件选择器，返回用户选中的路径。null = 用户取消了。
///
/// 与 `agent_loop` 的 `pickLocalFile` 分开：那个是模型驱动的上传流程
/// （`upload_file` 工具），这个是设置页里的导入，两者的取消语义和后续处理
/// 都不一样。
Future<String?> pickSkillFilePath() async {
  final res = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['md', 'markdown', 'txt'],
  );
  return res?.files.single.path;
}

/// 弹选择器选**一个目录**（CC 风格的 `<name>/SKILL.md` + 附件）。
///
/// 与 [pickSkillFilePath] 分开而不是加一个参数：`file_picker` 选目录与选
/// 文件是两套完全不同的平台调用（`getDirectoryPath` 拿不到多选、也不走
/// `allowedExtensions`），合成一个函数就得在一个签名里描述两种取消/失败
/// 语义。
Future<String?> pickSkillDirectoryPath() =>
    FilePicker.platform.getDirectoryPath();

/// 弹选择器选一个 zip / .skill 包。
Future<String?> pickSkillArchivePath() async {
  final res = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['zip', 'skill'],
  );
  return res?.files.single.path;
}

/// 读一个本地文件并解析成待导入的技能。
///
/// **绝不抛。** 文件不存在、权限不足、不是 UTF-8 —— 全部折成 [error]，
/// 让导入页显示一行说明。用户在手机文件管理器里选错文件是极常见的事，
/// 不该表现为崩溃。
Future<FileImportResult> importSkillFromFile(String path) async {
  final String raw;
  try {
    // 显式 utf8.decode 而不是 readAsString：后者在遇到非法字节时抛的是
    // FileSystemException，与「文件读不到」混在一起，分不清该给用户哪句话。
    raw = utf8.decode(await File(path).readAsBytes());
  } on FormatException {
    return const FileImportResult(error: 'That file is not valid UTF-8 text.');
  } catch (e) {
    return FileImportResult(error: 'Could not read that file: $e');
  }

  // 用 path 包的 basename 而不是手动按 Platform.pathSeparator 切：
  // file_picker 在 Android 上返回的路径不一定和运行平台的分隔符一致
  // （例如内容 URI 转换出的路径），basename 对两种分隔符都认。
  final filename = p.basename(path);
  final fallback = filename.contains('.')
      ? filename.substring(0, filename.lastIndexOf('.'))
      : filename;

  final parsed = parseSkillMarkdown(raw, fallbackName: fallback);
  if (parsed.error != null) return FileImportResult(error: parsed.error);

  return FileImportResult(
    skill: PendingSkill(
      name: parsed.name,
      description: parsed.description,
      body: parsed.body,
      source: SkillSource.file,
    ),
  );
}

/// 读一个本地**目录**（CC 风格的 `<name>/SKILL.md` + 附件）。
///
/// 目录里可以装一份或多份技能（每个 `SKILL.md` 一份），所以返回的是列表。
///
/// **绝不抛。** 与 [importSkillFromFile] 同一约定：读不了就折成 error。
/// 用户选错目录是常事。
///
/// 递归有深度上限：选到一个大目录（比如 `/` 或 `Download/`）时不能把整棵
/// 树读完——那既慢又会把无关文件全当附件。超出的部分直接不列。
Future<SkillBundleResult> importSkillsFromDirectory(String rootPath) async {
  const maxFiles = 200;
  const maxDepth = 6;

  final files = <String, List<int>>{};
  var truncated = false;
  try {
    final root = Directory(rootPath);
    if (!await root.exists()) {
      return const SkillBundleResult(error: 'That folder no longer exists.');
    }

    Future<void> walk(Directory dir, int depth) async {
      if (truncated || depth > maxDepth) return;
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        return; // 单个子目录读不了就跳过，不拖垮整次导入
      }
      for (final e in entries) {
        if (files.length >= maxFiles) {
          truncated = true;
          return;
        }
        final rel = p.relative(e.path, from: rootPath).replaceAll('\\', '/');
        if (e is File) {
          try {
            files[rel] = await e.readAsBytes();
          } catch (_) {
            // 读不了的文件跳过。
          }
        } else if (e is Directory) {
          final base = p.basename(e.path);
          // 常见的垃圾目录直接不进——它们只会变成附件。
          if (base == '__MACOSX' || base.startsWith('.')) continue;
          await walk(e, depth + 1);
        }
      }
    }

    await walk(root, 0);
  } catch (e) {
    return SkillBundleResult(error: 'Could not read that folder: $e');
  }

  if (files.isEmpty) {
    return const SkillBundleResult(
        error: 'That folder has no readable files in it.');
  }

  final rejected = <String>[];
  final skills = skillsFromFileSet(
    files,
    source: SkillSource.file,
    onRejected: rejected.add,
  );
  if (skills.isEmpty) {
    return SkillBundleResult(
      skipped: rejected.length,
      error: 'No skill found in that folder. A skill folder needs a '
          '`SKILL.md` with `name:` and `description:` in its frontmatter.',
    );
  }
  return SkillBundleResult(
    skills: skills,
    // 目录里被拒的文件 + 因为数量上限没读完的部分，都算“没导进来”。
    skipped: rejected.length + (truncated ? 1 : 0),
  );
}

/// 从「一组相对路径 → 文件内容」构造技能。目录导入、zip 导入、远端目录导入
/// 共用这一段。
///
/// ## 识别的两种形态
///
/// 1. **目录形态**：某个 `SKILL.md`，以它所在目录为一棵技能的根。同目录下
///    其余文件全部进附件（相对该目录的路径）。一份技能一份 `SKILL.md`。
/// 2. **崇平形态**：直接就是一堆 `.md`，每个算一份无附件技能。（与改造前
///    的崇平导入兼容。）
///
/// 一份文件集里两种可以共存：`a/SKILL.md` 与 `b.md` 同时导入是合法的。
///
/// ## 为什么以 `SKILL.md` 为锚而不是“每个子目录一份技能”
///
/// 后者会把附件目录（如 `scripts/`）当成一份独立技能。锚在 `SKILL.md` 上
/// 是 CC 的约定，也是唯一能把“这是一个技能”与“这是一堆文件”分开的判据。
///
/// ## 附件路径的校验
///
/// 每个附件路径过一遍 `parseAssetPath`（拒绝对路径、`..`、反斜杠…）。
/// **不安全的文件直接跳过并计入 skipped**，而不是整份技能失败：一份技能
/// 里混进一个奇怪文件名（比如 macOS 的 `__MACOSX/` 碎片）不该让它彻底导
/// 不进来。被拒的文件名会随 [SkillBundleResult] 一起回给调用方展示。
List<PendingSkill> skillsFromFileSet(
  Map<String, List<int>> files, {
  required SkillSource source,
  Set<String> skippedPaths = const {},
  void Function(String path)? onRejected,
}) {
  final out = <PendingSkill>[];

  // 归一化：分隔符统一成 `/`，去掉开头的 `./`。zip 里两种都可能出现。
  final norm = <String, List<int>>{};
  for (final e in files.entries) {
    var key = e.key.replaceAll('\\', '/');
    while (key.startsWith('./')) {
      key = key.substring(2);
    }
    if (key.isEmpty) continue;
    norm[key] = e.value;
  }

  // 找出所有 SKILL.md（大小写不敏感），并确定它们的根目录。
  final skillRoots = <String, String>{}; // rootDir -> skillMdPath
  for (final key in norm.keys) {
    final base = p.posix.basename(key);
    if (base.toLowerCase() == 'skill.md') {
      final dir = p.posix.dirname(key);
      skillRoots[dir == '.' ? '' : dir] = key;
    }
  }

  // 每个附件只能归属到一个技能。先到先得按 root 长度降序（嵌套时取更深的
  // 那个）——实际上技能目录不该嵌套，这里只是给一个确定性的行为。
  final rootsByDepth = skillRoots.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  final claimed = <String>{};

  for (final root in rootsByDepth) {
    final mdPath = skillRoots[root]!;
    final raw = _decodeUtf8(norm[mdPath]!);
    if (raw == null) {
      onRejected?.call(mdPath);
      continue;
    }
    final fallback = root.isEmpty ? 'skill' : p.posix.basename(root);
    final parsed = parseSkillMarkdown(raw, fallbackName: fallback);
    if (parsed.error != null) {
      onRejected?.call(mdPath);
      continue;
    }

    final assets = <AgentSkillAsset>[];
    for (final key in norm.keys) {
      if (key == mdPath) continue;
      if (claimed.contains(key)) continue;
      // 归属：必须以 root/ 开头（root 为空时全部归它）。
      final rel = root.isEmpty
          ? key
          : (key.startsWith('$root/') ? key.substring(root.length + 1) : null);
      if (rel == null) continue;
      if (parseAssetPath(rel) == null) {
        onRejected?.call(key);
        continue;
      }
      final content = _decodeUtf8(norm[key]!);
      if (content == null) {
        onRejected?.call(key);
        continue;
      }
      assets.add(AgentSkillAsset(
        path: rel,
        content: content,
        // 可执行位从扩展名/无扩展名推。zip 能带 POSIX 位但 `file_picker`
        // 不给我们；远端 tar 那条路会另行覆盖。这是一条**保守**的推断：
        // 只给脚本类扩展名/后缀加位，不给数据文件加。
        executable: _looksExecutable(rel),
      ));
      claimed.add(key);
    }

    out.add(PendingSkill(
      name: parsed.name,
      description: parsed.description,
      body: parsed.body,
      source: source,
      assets: assets,
      dirName: root.isEmpty ? null : root,
    ));
  }

  // 崇平形态：剩下的 `.md` 一份一份算技能。已经在 SKILL.md 技能里被 claim
  // 的不再重复。
  for (final key in norm.keys) {
    if (claimed.contains(key)) continue;
    if (!key.toLowerCase().endsWith('.md')) continue;
    if (p.posix.basename(key).toLowerCase() == 'skill.md') continue;
    final raw = _decodeUtf8(norm[key]!);
    if (raw == null) {
      onRejected?.call(key);
      continue;
    }
    final fallback = p.posix.basenameWithoutExtension(key);
    final parsed = parseSkillMarkdown(raw, fallbackName: fallback);
    if (parsed.error != null) {
      onRejected?.call(key);
      continue;
    }
    out.add(PendingSkill(
      name: parsed.name,
      description: parsed.description,
      body: parsed.body,
      source: source,
    ));
  }

  return out;
}

String? _decodeUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// 从相对路径猜这个文件是不是“要被执行的”。
///
/// 只认几种明确的脚本形状。**刻意不从内容读 shebang**：那个要把整份文件
/// 解出来看，而这一步的目标恰恰是「不做判断就看一眼」；而误判方向也要选
/// 对的——把一个数据文件标成可执行不致命但又多余，把脚本漏掉只是多一步
/// `chmod`。真正的权威在用户的编辑器里，导入后可改。
bool _looksExecutable(String relPath) {
  final base = p.posix.basename(relPath).toLowerCase();
  const exts = [
    '.sh', '.bash', '.zsh', '.fish', '.py', '.rb', '.pl', '.ps1', '.tcl',
  ];
  for (final e in exts) {
    if (base.endsWith(e)) return true;
  }
  // scripts/ 目录下没有扩展名的文件，也当脚本。
  final dir = p.posix.dirname(relPath).toLowerCase();
  if (dir == 'scripts' || dir.endsWith('/scripts')) {
    if (!base.contains('.')) return true;
  }
  return false;
}

/// 读一个 zip / `.skill` 包（用户把技能目录压成一个文件）。
///
/// **绝不抛。** 同其它导入路径的约定。
Future<SkillBundleResult> importSkillsFromArchive(String path) async {
  final Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (e) {
    return SkillBundleResult(error: 'Could not read that file: $e');
  }

  final files = unzip(bytes);
  if (files == null) {
    return const SkillBundleResult(
        error: 'That file is not a readable zip archive. Zip the skill '
            'folder itself (it should contain a `SKILL.md`).');
  }
  if (files.isEmpty) {
    return const SkillBundleResult(error: 'That archive has no files in it.');
  }

  final rejected = <String>[];
  final skills = skillsFromFileSet(
    files,
    source: SkillSource.file,
    onRejected: rejected.add,
  );
  if (skills.isEmpty) {
    return SkillBundleResult(
      skipped: rejected.length,
      error: 'No skill found in that archive. A skill folder needs a '
          '`SKILL.md` with `name:` and `description:` in its frontmatter.',
    );
  }
  return SkillBundleResult(skills: skills, skipped: rejected.length);
}
