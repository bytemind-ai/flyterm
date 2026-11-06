// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dartssh2/dartssh2.dart';

/// 软链解析的三态。
///
/// 用枚举而不是两个 bool：**「未解析」和「解析失败」必须分开** —— 未解析时
/// 不能画断链角标，否则每一行软链都会先闪一下断链再变成正常。target 是懒查
/// 的（见 `SftpInlineView`），所以这个中间态真实存在。
enum SftpLinkState {
  /// 不是软链。
  none,

  /// 是软链，已解析出目标。
  ok,

  /// 是软链，但解析失败（目标不存在 / 无权限访问目标）。
  dangling,
}

/// Broad classification of a remote file, used to pick an icon, a colour and
/// a tap behaviour in the SFTP browser.
///
/// Deliberately coarse: this drives presentation, not content handling. If a
/// new type needs different *behaviour*, give it a case; if it only needs a
/// different icon, map it onto an existing case.
enum FileKind {
  directory,
  image,
  video,
  audio,
  pdf,
  archive,
  code,
  text,
  config,
  font,
  database,

  /// Markdown. Separate from [text] because it has its own rendered view.
  markdown,

  /// Recognisably binary (executables, libraries, disk images outside the
  /// archive set) — anything we know better than to try to render.
  binary,

  /// No rule matched. Treated as binary for behaviour purposes.
  unknown,
}

class SftpEntry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime modTime;
  /// Lower 12 bits of the file mode (setuid/setgid/sticky + rwxrwxrwx).
  /// Null when the server did not return permission info (rare).
  final int? permissions;

  /// 软链解析状态。非软链为 [SftpLinkState.none]。
  final SftpLinkState linkState;

  /// `readlink` 的目标路径。**懒加载** —— 列目录时只解析「目标是不是目录」，
  /// 不取 target 字符串（那要额外一次往返，而用户一次只看得到十几行）。
  /// 未查到时为 null，即使 [linkState] 是 [SftpLinkState.ok]。
  final String? linkTarget;

  /// 软链的目标是否是目录。列目录时由一次 `stat(followLink: true)` 得出。
  final bool linkTargetIsDir;

  const SftpEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modTime,
    this.permissions,
    this.linkState = SftpLinkState.none,
    this.linkTarget,
    this.linkTargetIsDir = false,
  });

  factory SftpEntry.fromSftpName(
    SftpName name,
    String parentPath, {
    /// 软链解析结果。非软链传默认值 [SftpLinkState.none]。
    ///
    /// 由调用方（`SFTPService.listDirectory`）在列表阶段并发查得 —— 放在这里
    /// 查会让 `fromSftpName` 变成异步的，而它现在是纯函数、被多个地方用。
    SftpLinkState linkState = SftpLinkState.none,
    bool linkTargetIsDir = false,
  }) {
    final isLink = linkState != SftpLinkState.none;
    // 软链指向目录时也视为「可进入」—— 这是本次修复的核心：
    // attr.isDirectory 对软链恒为 false（mode.type 是 symbolicLink），
    // 旧代码因此让 /usr/lib64、current → 2026-10 这类点不进去。
    final isDir = name.attr.isDirectory || (isLink && linkTargetIsDir);
    final size = name.attr.size ?? 0;
    final modTime = name.attr.modifyTime != null
        ? DateTime.fromMillisecondsSinceEpoch(name.attr.modifyTime! * 1000)
        : DateTime.fromMillisecondsSinceEpoch(0);
    final path =
        parentPath == '/' ? '/${name.filename}' : '$parentPath/${name.filename}';
    // Strip file-type bits (upper 4 bits of mode), keep only permission bits.
    final permissions =
        name.attr.mode != null ? name.attr.mode!.value & 0xFFF : null;
    return SftpEntry(
      name: name.filename,
      path: path,
      isDir: isDir,
      size: size,
      modTime: modTime,
      permissions: permissions,
      linkState: linkState,
      linkTargetIsDir: linkTargetIsDir,
    );
  }

  // ── Extension tables ─────────────────────────────────────────────────────
  //
  // Extensions are matched case-insensitively and only the *final* component
  // counts, so `backup.tar.gz` classifies as an archive via `gz` — which is
  // what the user sees and what the system opener needs anyway.

  static const _imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif',
    'svg', 'ico', 'tiff', 'tif', 'avif',
  };

  static const _videoExtensions = {
    'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'flv', 'wmv', 'mpg',
    'mpeg', '3gp',
  };

  static const _audioExtensions = {
    'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'wma', 'aiff',
  };

  static const _pdfExtensions = {'pdf'};

  /// Markdown gets its own kind rather than riding on [FileKind.text] because
  /// it routes to a *rendered* view — a different screen, not just a different
  /// icon. `README` and friends (extensionless) stay [FileKind.text]; we can't
  /// tell their format from the name alone.
  static const _markdownExtensions = {'md', 'markdown'};

  static const _archiveExtensions = {
    'zip', 'tar', 'gz', 'bz2', 'xz', 'zst', '7z', 'rar', 'jar', 'war',
    'deb', 'rpm', 'apk', 'iso', 'dmg',
  };

  static const _codeExtensions = {
    'dart', 'py', 'rb', 'go', 'rs', 'c', 'cpp', 'cc', 'h', 'hpp',
    'java', 'kt', 'kts', 'swift', 'php', 'lua', 'pl', 'scala', 'cs',
    'js', 'jsx', 'ts', 'tsx', 'vue', 'svelte', 'sh', 'bash', 'zsh',
    'fish', 'sql', 'r', 'jl', 'ex', 'exs', 'clj', 'hs', 'm', 'mm',
  };

  /// Machine-readable configuration and structured data. Separate from
  /// [FileKind.text] because "open in editor" is the same but the icon and
  /// the user's mental model differ.
  static const _configExtensions = {
    'yaml', 'yml', 'toml', 'ini', 'conf', 'cfg', 'env', 'properties',
    'json', 'xml', 'plist',
  };

  static const _textExtensions = {
    'txt', 'md', 'markdown', 'log', 'csv', 'tsv', 'rst',
    'html', 'htm', 'css', 'scss', 'less',
  };

  static const _fontExtensions = {'ttf', 'otf', 'woff', 'woff2', 'eot'};

  static const _databaseExtensions = {'db', 'sqlite', 'sqlite3', 'mdb', 'dump'};

  static const _binaryExtensions = {
    'exe', 'dll', 'so', 'dylib', 'o', 'a', 'class', 'pyc', 'wasm', 'bin',
    'dat', 'img', 'vmdk',
  };

  // ── Extensionless names ──────────────────────────────────────────────────
  //
  // A large share of the files a developer actually edits carry no extension
  // at all. Before this table existed they all fell through to "unknown
  // binary" and could not be opened in the editor.

  static const _codeNames = {
    'dockerfile', 'containerfile', 'makefile', 'gnumakefile', 'cmakelists.txt',
    'rakefile', 'gemfile', 'vagrantfile', 'jenkinsfile', 'procfile', 'justfile',
    'taskfile.yml', 'build', 'workspace', 'cargo.lock', 'brewfile', 'podfile',
    'fastfile', 'appfile', 'berksfile', 'thorfile', 'guardfile',
  };

  static const _configNames = {
    '.bashrc', '.zshrc', '.profile', '.bash_profile', '.bash_aliases',
    '.bash_logout', '.zprofile', '.zshenv', '.gitconfig', '.gitignore',
    '.gitattributes', '.gitmodules', '.editorconfig', '.npmrc', '.yarnrc',
    '.dockerignore', '.vimrc', '.inputrc', '.curlrc', '.wgetrc', '.tmux.conf',
    '.screenrc', '.env', '.env.local', '.env.example', '.fetchmailrc',
    '.exrc', '.gdbinit', '.htaccess', '.rsync-exclude',
  };

  static const _textNames = {
    'license', 'licence', 'copying', 'readme', 'changelog', 'changes',
    'authors', 'contributors', 'install', 'notice', 'todo', 'version',
    'news', 'history', 'patents', 'maintainers', 'codeowners',
  };

  /// Lowercased final extension of [filename], or `''` when there is none.
  ///
  /// Dotfiles return `''`: `.bashrc` is a name, not an extension, and treating
  /// `bashrc` as one would misclassify it as soon as any rule used that key.
  static String extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0 || dot == filename.length - 1) return '';
    return filename.substring(dot + 1).toLowerCase();
  }

  /// Classification of this entry. Computed on demand — the const constructor
  /// rules out a `late final` cache, and the work is a few hash lookups.
  FileKind get kind {
    if (isDir) return FileKind.directory;

    // Full-name tables win over the extension tables. Some well-known files
    // *do* carry an extension (`CMakeLists.txt`, `.env.local`) and the
    // extension alone would misclassify them — `txt` would make the build
    // file look like prose, and `local` isn't a type at all.
    //
    // Markdown is the deliberate exception: `README.md` must classify by its
    // extension, not by the `readme` name rule, or the single most likely
    // file a user opens would skip the rendered view. So the name tables are
    // consulted only when the extension doesn't already answer.
    final lower = name.toLowerCase();
    final ext = extensionOf(name);
    if (_markdownExtensions.contains(ext)) return FileKind.markdown;

    if (_codeNames.contains(lower)) return FileKind.code;
    if (_configNames.contains(lower)) return FileKind.config;
    if (_textNames.contains(lower)) return FileKind.text;

    if (ext.isNotEmpty) {
      if (_imageExtensions.contains(ext)) return FileKind.image;
      if (_videoExtensions.contains(ext)) return FileKind.video;
      if (_audioExtensions.contains(ext)) return FileKind.audio;
      if (_pdfExtensions.contains(ext)) return FileKind.pdf;
      if (_archiveExtensions.contains(ext)) return FileKind.archive;
      if (_codeExtensions.contains(ext)) return FileKind.code;
      if (_configExtensions.contains(ext)) return FileKind.config;
      if (_textExtensions.contains(ext)) return FileKind.text;
      if (_fontExtensions.contains(ext)) return FileKind.font;
      if (_databaseExtensions.contains(ext)) return FileKind.database;
      if (_binaryExtensions.contains(ext)) return FileKind.binary;
    }

    return FileKind.unknown;
  }

  bool get isImageFile => kind == FileKind.image;

  /// 是否是软链。由 [linkState] 派生，不单独存字段 —— 两个来源会不一致。
  bool get isSymlink => linkState != SftpLinkState.none;

  /// 软链且目标是目录。UI 画角标用；导航只看 [isDir]。
  bool get isSymlinkToDir => isSymlink && linkTargetIsDir;

  /// Text the editor can safely load: source, config and prose. Images,
  /// archives and media are excluded.
  bool get isTextFile => isEditableText;

  bool get isEditableText =>
      kind == FileKind.code ||
      kind == FileKind.config ||
      kind == FileKind.text ||
      kind == FileKind.markdown;

  /// Whether to open the rendered Markdown view instead of the source editor.
  bool get isMarkdownFile => kind == FileKind.markdown;

  /// Whether handing this file to the OS is a sensible thing to do. Covers
  /// everything we can't render ourselves — media, PDFs, archives, fonts,
  /// database files and unrecognised binaries whose type only the system
  /// can decide.
  bool get isOpenableBySystem {
    switch (kind) {
      case FileKind.directory:
      case FileKind.code:
      case FileKind.text:
      case FileKind.config:
      case FileKind.markdown:
        return false;
      case FileKind.image:
      case FileKind.video:
      case FileKind.audio:
      case FileKind.pdf:
      case FileKind.archive:
      case FileKind.font:
      case FileKind.database:
      case FileKind.binary:
      case FileKind.unknown:
        return true;
    }
  }

  String get displaySize {
    if (isDir) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Returns the rwxrwxrwx string for the lower 9 permission bits.
  /// Returns empty string when [permissions] is null.
  String get permissionsString {
    final p = permissions;
    if (p == null) return '';
    String b(int mask, String c) => (p & mask) != 0 ? c : '-';
    return '${b(0x100, 'r')}${b(0x80, 'w')}${b(0x40, 'x')}'
        '${b(0x20, 'r')}${b(0x10, 'w')}${b(0x8, 'x')}'
        '${b(0x4, 'r')}${b(0x2, 'w')}${b(0x1, 'x')}';
  }
}
