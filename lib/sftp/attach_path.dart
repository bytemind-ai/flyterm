// SPDX-License-Identifier: GPL-3.0-or-later
// lib/sftp/attach_path.dart

/// 在远端路径里不安全、必须替换掉的字符。
///
/// **黑名单而不是白名单。** 白名单式的 slugify（只留 `[A-Za-z0-9._-]`）会把
/// `报错截图.png` 打成 `_____.png` —— 而中文在 shell 里本来就安全，不需要引号。
/// 这里只挑真正会让 shell 解析出问题的那些。
const String _unsafeChars = r''' $`"'\|&;<>()*?[]{}~#!''';

bool _isUnsafe(int rune) {
  // 控制字符（含换行、制表符）一律清掉
  if (rune < 0x20 || rune == 0x7f) return true;
  return _unsafeChars.runes.contains(rune);
}

/// 把文件名改写成在 shell、AI 对话、vim 里都不需要引号的形式。
///
/// 返回值与入参相同时表示原名本来就安全 —— 调用方据此决定要不要提示用户
/// 「已重命名」。默默改掉的话，用户回头 `ls` 找不到自己传的名字。
String sanitizeAttachName(String raw) {
  final buf = StringBuffer();
  var lastWasUnderscore = false;
  for (final r in raw.runes) {
    if (_isUnsafe(r)) {
      // 连续的不安全字符折叠成一个下划线，避免 `a   b` 变成 `a___b`
      if (!lastWasUnderscore) {
        buf.write('_');
        lastWasUnderscore = true;
      }
    } else {
      buf.writeCharCode(r);
      lastWasUnderscore = false;
    }
  }
  final trimmed = buf.toString().replaceAll(RegExp(r'^_+|_+$'), '');
  // 全是特殊字符时不能返回空串 —— 空文件名会让上传失败在一个与用户操作
  // 毫无关系的错误上。
  return trimmed.isEmpty ? 'file' : trimmed;
}

/// 重名时的下一个候选：`foo.png` → `foo-2.png`。
///
/// 只认**最后一个**点，所以 `a.tar.gz` → `a.tar-2.gz`。这不完美（理想是
/// `a-2.tar.gz`），但要正确处理多重扩展名就得维护一张已知复合后缀表，
/// 而这里只需要一个不冲突的名字，不需要好看。测试把这个行为显式锁住了。
///
/// 点开头的隐藏文件（`.bashrc`）不把开头那个点当扩展名分隔符。
String nextAttachName(String name, int n) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '$name-$n'; // 无扩展名，或 `.bashrc` 这种
  return '${name.substring(0, dot)}-$n${name.substring(dot)}';
}

/// 远端的绝对路径。用于 SFTP 上传的目标。
String buildAttachPath({required String cwd, required String name}) {
  final base = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
  return '$base/$name';
}

/// 插进命令行的那串文本。
///
/// **一律绝对路径。** 曾经 cwd 已知时返回相对路径 `./name`（理由：短、在
/// shell 里是有效参数），但那对 **AI agent** 不成立：agent 执行工具时的 cwd
/// 未必等于终端 cwd，`./name` 会解析到别处，于是「上传成功、把路径喂给 AI
/// 却读不到」。绝对路径在任何 cwd 下都对，对 shell 用户也只是长一点 —— 用
/// 一点输入长度换掉一整类 cwd 不一致的失败，划算。
///
/// cwd 未知时用 [home]（SFTP 查询到的家目录）兜底，仍拼绝对路径。
String buildInsertText({
  required String? cwd,
  required String name,
  String? home,
}) {
  final dir = (cwd != null && cwd.isNotEmpty) ? cwd : (home ?? '/');
  return buildAttachPath(cwd: dir, name: name);
}
