import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_entry.dart';

SftpEntry _file({
  String name = 'file.txt',
  String path = '/home/user/file.txt',
  bool isDir = false,
  int size = 1024,
}) =>
    SftpEntry(
      name: name,
      path: path,
      isDir: isDir,
      size: size,
      modTime: DateTime(2024, 1, 1),
    );

void main() {
  group('SftpEntry.isTextFile', () {
    test('true for .txt', () {
      expect(_file(name: 'readme.txt').isTextFile, isTrue);
    });

    test('true for .sh', () {
      expect(_file(name: 'deploy.sh').isTextFile, isTrue);
    });

    test('true for .dart', () {
      expect(_file(name: 'main.dart').isTextFile, isTrue);
    });

    test('true for .conf', () {
      expect(_file(name: 'nginx.conf').isTextFile, isTrue);
    });

    test('false for .png', () {
      expect(_file(name: 'image.png').isTextFile, isFalse);
    });

    test('false for directory', () {
      expect(_file(name: 'dir', isDir: true).isTextFile, isFalse);
    });

    test('false for file with no extension', () {
      expect(_file(name: 'binaryfile').isTextFile, isFalse);
    });
  });

  group('SftpEntry.displaySize', () {
    test('shows bytes for small files', () {
      expect(_file(size: 512).displaySize, '512 B');
    });

    test('shows KB for kilobyte-range files', () {
      expect(_file(size: 2048).displaySize, '2.0 KB');
    });

    test('shows MB for megabyte-range files', () {
      expect(_file(size: 2 * 1024 * 1024).displaySize, '2.0 MB');
    });

    test('empty string for directories', () {
      expect(_file(name: 'dir', isDir: true).displaySize, '');
    });
  });

  group('SftpEntry path', () {
    test('root parent produces /filename path', () {
      final e = SftpEntry(
        name: 'foo.txt',
        path: '/foo.txt',
        isDir: false,
        size: 0,
        modTime: DateTime.now(),
      );
      expect(e.path, '/foo.txt');
    });

    test('nested parent produces correct path', () {
      final e = SftpEntry(
        name: 'bar.sh',
        path: '/home/user/bar.sh',
        isDir: false,
        size: 0,
        modTime: DateTime.now(),
      );
      expect(e.path, '/home/user/bar.sh');
    });
  });

  group('SftpEntry.kind — extensions', () {
    test('every image extension maps to FileKind.image', () {
      for (final ext in const [
        'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif',
        'svg', 'ico', 'tiff', 'tif', 'avif',
      ]) {
        expect(_file(name: 'a.$ext').kind, FileKind.image, reason: ext);
      }
    });

    test('every video extension maps to FileKind.video', () {
      for (final ext in const [
        'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'flv', 'wmv', 'mpg',
        'mpeg', '3gp',
      ]) {
        expect(_file(name: 'a.$ext').kind, FileKind.video, reason: ext);
      }
    });

    test('every audio extension maps to FileKind.audio', () {
      for (final ext in const [
        'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'wma', 'aiff',
      ]) {
        expect(_file(name: 'a.$ext').kind, FileKind.audio, reason: ext);
      }
    });

    test('pdf maps to FileKind.pdf', () {
      expect(_file(name: 'doc.pdf').kind, FileKind.pdf);
    });

    test('every archive extension maps to FileKind.archive', () {
      for (final ext in const [
        'zip', 'tar', 'gz', 'bz2', 'xz', 'zst', '7z', 'rar', 'jar', 'war',
        'deb', 'rpm', 'apk', 'iso', 'dmg',
      ]) {
        expect(_file(name: 'a.$ext').kind, FileKind.archive, reason: ext);
      }
    });

    test('compound .tar.gz resolves via the final extension', () {
      expect(_file(name: 'backup.tar.gz').kind, FileKind.archive);
    });

    test('every code extension maps to FileKind.code', () {
      for (final ext in const [
        'dart', 'py', 'rb', 'go', 'rs', 'c', 'cpp', 'cc', 'h', 'hpp',
        'java', 'kt', 'kts', 'swift', 'php', 'lua', 'pl', 'scala', 'cs',
        'js', 'jsx', 'ts', 'tsx', 'vue', 'svelte', 'sh', 'bash', 'zsh',
        'fish', 'sql', 'r', 'jl', 'ex', 'exs', 'clj', 'hs', 'm', 'mm',
      ]) {
        expect(_file(name: 'a.$ext').kind, FileKind.code, reason: ext);
      }
    });

    test('every config extension maps to FileKind.config', () {
      for (final ext in const [
        'yaml', 'yml', 'toml', 'ini', 'conf', 'cfg', 'env', 'properties',
        'json', 'xml', 'plist',
      ]) {
        expect(_file(name: 'a.$ext').kind, FileKind.config, reason: ext);
      }
    });

    test('markup and docs map to FileKind.text', () {
      for (final ext in const ['txt', 'log', 'csv', 'tsv',
        'rst', 'html', 'htm', 'css', 'scss', 'less']) {
        expect(_file(name: 'a.$ext').kind, FileKind.text, reason: ext);
      }
    });

    test('markdown extensions get their own kind', () {
      for (final ext in const ['md', 'markdown']) {
        expect(_file(name: 'a.$ext').kind, FileKind.markdown, reason: ext);
      }
    });

    test('every font extension maps to FileKind.font', () {
      for (final ext in const ['ttf', 'otf', 'woff', 'woff2', 'eot']) {
        expect(_file(name: 'a.$ext').kind, FileKind.font, reason: ext);
      }
    });

    test('every database extension maps to FileKind.database', () {
      for (final ext in const ['db', 'sqlite', 'sqlite3', 'mdb', 'dump']) {
        expect(_file(name: 'a.$ext').kind, FileKind.database, reason: ext);
      }
    });

    test('unknown extension maps to FileKind.unknown', () {
      expect(_file(name: 'a.qqqzzz').kind, FileKind.unknown);
    });
  });

  group('SftpEntry.kind — extensionless dotfiles and build files', () {
    test('Dockerfile family are code', () {
      for (final n in const [
        'Dockerfile', 'dockerfile', 'Containerfile', 'Makefile', 'makefile',
        'GNUmakefile', 'CMakeLists.txt', 'Rakefile', 'Gemfile', 'Vagrantfile',
        'Jenkinsfile', 'Procfile', 'Justfile', 'Taskfile.yml', 'BUILD',
        'WORKSPACE', 'Cargo.lock',
      ]) {
        expect(_file(name: n).kind, FileKind.code, reason: n);
      }
    });

    test('shell rc dotfiles are config', () {
      for (final n in const [
        '.bashrc', '.zshrc', '.profile', '.bash_profile', '.bash_aliases',
        '.gitconfig', '.gitignore', '.gitattributes', '.editorconfig',
        '.npmrc', '.dockerignore', '.vimrc', '.inputrc', '.curlrc',
        '.wgetrc', '.tmux.conf', '.screenrc', '.env', '.env.local',
        '.fetchmailrc', '.exrc', '.gdbinit',
      ]) {
        expect(_file(name: n).kind, FileKind.config, reason: n);
      }
    });

    test('plain-name docs are text', () {
      for (final n in const [
        'LICENSE', 'LICENCE', 'COPYING', 'README', 'CHANGELOG', 'CHANGES',
        'AUTHORS', 'CONTRIBUTORS', 'INSTALL', 'NOTICE', 'TODO', 'VERSION',
        'NEWS', 'HISTORY',
      ]) {
        expect(_file(name: n).kind, FileKind.text, reason: n);
      }
    });

    test('extensionless README stays text, not markdown', () {
      // We can't know it's Markdown from the name, and rendering it as such
      // would be a guess. The editor is the honest default.
      expect(_file(name: 'README').kind, FileKind.text);
      expect(_file(name: 'README').isMarkdownFile, isFalse);
    });

    test('README.md is markdown, not the extensionless README rule', () {
      // Regression: the well-known-name tables are consulted before the
      // extension tables, so `readme` used to return text and send the most
      // likely Markdown file in the world to the source editor.
      for (final n in const [
        'README.md', 'readme.md', 'ReadMe.md', 'CHANGELOG.md',
        'CHANGES.md', 'LICENSE.md', 'CONTRIBUTING.md', 'docs.md',
      ]) {
        expect(_file(name: n).kind, FileKind.markdown, reason: n);
        expect(_file(name: n).isMarkdownFile, isTrue, reason: n);
      }
    });

    test('Dockerfile-like names are unaffected by the markdown rule', () {
      expect(_file(name: 'Dockerfile').kind, FileKind.code);
      expect(_file(name: 'CMakeLists.txt').kind, FileKind.code);
      expect(_file(name: '.env.local').kind, FileKind.config);
    });

    test('case-insensitive matching for known names', () {
      expect(_file(name: 'dockerfile').kind, FileKind.code);
      expect(_file(name: 'license').kind, FileKind.text);
      expect(_file(name: 'ReadMe').kind, FileKind.text);
    });

    test('unknown extensionless name is unknown', () {
      expect(_file(name: 'mysteryblob').kind, FileKind.unknown);
    });

    test('a dotfile not in the list is unknown', () {
      expect(_file(name: '.weirdthing').kind, FileKind.unknown);
    });
  });

  group('SftpEntry.kind — case and precedence', () {
    test('uppercase extension still classifies', () {
      expect(_file(name: 'PHOTO.PNG').kind, FileKind.image);
      expect(_file(name: 'MAIN.DART').kind, FileKind.code);
      expect(_file(name: 'DOC.PDF').kind, FileKind.pdf);
      expect(_file(name: 'NOTES.MD').kind, FileKind.markdown);
    });

    test('mixed-case extension still classifies', () {
      expect(_file(name: 'clip.Mp4').kind, FileKind.video);
    });

    test('directory with a file-like name is still a directory', () {
      expect(_file(name: 'foo.txt', isDir: true).kind, FileKind.directory);
      expect(_file(name: 'archive.zip', isDir: true).kind, FileKind.directory);
      expect(_file(name: 'Dockerfile', isDir: true).kind, FileKind.directory);
    });

    test('name ending in a dot is unknown, not a crash', () {
      expect(_file(name: 'trailing.').kind, FileKind.unknown);
    });
  });

  group('SftpEntry derived getters', () {
    test('isImageFile tracks FileKind.image', () {
      expect(_file(name: 'a.svg').isImageFile, isTrue);
      expect(_file(name: 'a.mp4').isImageFile, isFalse);
    });

    test('isTextFile is true for code/config/text but not binary', () {
      expect(_file(name: 'a.dart').isTextFile, isTrue);
      expect(_file(name: 'a.yaml').isTextFile, isTrue);
      expect(_file(name: 'a.md').isTextFile, isTrue);
      expect(_file(name: 'README.md').isTextFile, isTrue);
      expect(_file(name: 'Dockerfile').isTextFile, isTrue);
      expect(_file(name: '.gitignore').isTextFile, isTrue);
      expect(_file(name: 'a.zip').isTextFile, isFalse);
      expect(_file(name: 'a.mp4').isTextFile, isFalse);
      expect(_file(name: 'a.png').isTextFile, isFalse);
      expect(_file(name: 'a.qqqzzz').isTextFile, isFalse);
    });

    test('isEditableText matches isTextFile', () {
      expect(_file(name: 'a.dart').isEditableText, isTrue);
      expect(_file(name: 'a.zip').isEditableText, isFalse);
    });

    test('markdown is editable text but routes to the rendered view', () {
      expect(_file(name: 'a.md').isEditableText, isTrue);
      expect(_file(name: 'a.md').isMarkdownFile, isTrue);
      expect(_file(name: 'a.txt').isMarkdownFile, isFalse);
      expect(_file(name: 'a.dart').isMarkdownFile, isFalse);
      expect(_file(name: 'a.md', isDir: true).isMarkdownFile, isFalse);
    });

    test('markdown is not handed to the system opener', () {
      expect(_file(name: 'a.md').isOpenableBySystem, isFalse);
    });

    test('isOpenableBySystem covers media, docs and archives', () {
      for (final n in const [
        'a.mp4', 'a.mp3', 'a.pdf', 'a.zip', 'a.ttf', 'a.sqlite', 'a.qqqzzz',
      ]) {
        expect(_file(name: n).isOpenableBySystem, isTrue, reason: n);
      }
    });

    test('isOpenableBySystem is false for plain text and directories', () {
      expect(_file(name: 'a.txt').isOpenableBySystem, isFalse);
      expect(_file(name: 'a.dart').isOpenableBySystem, isFalse);
      expect(_file(name: 'dir', isDir: true).isOpenableBySystem, isFalse);
    });
  });

  group('SftpEntry.extensionOf', () {
    test('returns lowercased extension', () {
      expect(SftpEntry.extensionOf('A.PNG'), 'png');
      expect(SftpEntry.extensionOf('archive.tar.gz'), 'gz');
    });

    test('returns empty string when there is no extension', () {
      expect(SftpEntry.extensionOf('Dockerfile'), '');
      expect(SftpEntry.extensionOf('.bashrc'), '');
      expect(SftpEntry.extensionOf('trailing.'), '');
    });
  });

  group('SftpEntry 软链', () {
    SftpEntry link({
      String name = 'link',
      bool targetIsDir = false,
      String? target = '/real',
      SftpLinkState state = SftpLinkState.ok,
    }) =>
        SftpEntry(
          name: name,
          path: '/dir/$name',
          isDir: false,
          size: 0,
          modTime: DateTime(2024, 1, 1),
          linkState: state,
          linkTarget: target,
          linkTargetIsDir: targetIsDir,
        );

    test('非软链时 linkState 为 none', () {
      expect(_file(name: 'a.txt').linkState, SftpLinkState.none);
      expect(_file(name: 'a.txt').isSymlink, isFalse);
      expect(_file(name: 'a.txt').isSymlinkToDir, isFalse);
    });

    test('指向目录的软链 isDir 为 true（可进入）', () {
      final e = SftpEntry(
        name: 'current',
        path: '/app/current',
        isDir: true, // fromSftpName 会把软链指向目录的情况置为 true
        size: 0,
        modTime: DateTime(2024, 1, 1),
        linkState: SftpLinkState.ok,
        linkTarget: '/app/2026-10',
        linkTargetIsDir: true,
      );
      expect(e.isDir, isTrue);
      expect(e.isSymlink, isTrue);
      expect(e.isSymlinkToDir, isTrue);
    });

    test('指向文件的软链不是目录', () {
      final e = link(targetIsDir: false);
      expect(e.isSymlink, isTrue);
      expect(e.isSymlinkToDir, isFalse);
    });

    test('悬空软链的 state 是 dangling', () {
      final e = link(target: null, state: SftpLinkState.dangling);
      expect(e.isSymlink, isTrue);
      expect(e.linkState, SftpLinkState.dangling);
      expect(e.linkTarget, isNull);
    });

    test('isSymlink 由 linkState 派生，不是独立字段', () {
      expect(link(state: SftpLinkState.none).isSymlink, isFalse);
      expect(link(state: SftpLinkState.ok).isSymlink, isTrue);
      expect(link(state: SftpLinkState.dangling).isSymlink, isTrue);
    });
  });
}
