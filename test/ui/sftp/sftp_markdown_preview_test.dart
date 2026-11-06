import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/sftp/sftp_entry.dart';
import 'package:flyterm/sftp/sftp_service.dart';
import 'package:flyterm/ui/sftp/sftp_markdown_preview_screen.dart';

/// Minimal [SftpOps] that only implements what the preview path touches.
class _FakeOps implements SftpOps {
  _FakeOps(this.content);

  final String content;
  bool throwOnRead = false;

  /// stat 返回的真实大小。null = 用 content.length。
  int? statSize;

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async {
    if (throwOnRead) throw Exception('Permission denied');
    return Uint8List.fromList(content.codeUnits);
  }

  @override
  Future<List<SftpName>> listdir(String path) async => [];

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(size: statSize ?? content.length);

  @override
  Future<String> readlink(String path) async => path;

  @override
  Future<void> mkdirRecursive(String path) async {}

  @override
  Future<int> download(String path, StreamSink<List<int>> sink,
          {void Function(int bytesRead)? onProgress}) async =>
      0;

  @override
  Future<void> downloadFromOffset(String path, StreamSink<List<int>> sink,
      {int offset = 0, void Function(int bytesRead)? onProgress}) async {}

  @override
  Future<void> writeBytes(String path, Uint8List data) async {}

  @override
  Future<void> upload(String remotePath, Stream<List<int>> data,
      int totalBytes, void Function(int bytes)? onProgress) async {}

  @override
  Future<void> remove(String path) async {}

  @override
  Future<void> rmdir(String path) async {}

  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> createFile(String path) async {}

  @override
  Future<void> setPermissions(String path, int permissions) async {}

  @override
  Future<String> absolutePath(String path) async => '/home/test';
}

SftpEntry _mdEntry({int size = 100}) => SftpEntry(
      name: 'README.md',
      path: '/home/test/README.md',
      isDir: false,
      size: size,
      modTime: DateTime(2024, 1, 1),
    );

Widget _wrap(SFTPService svc, SftpEntry entry) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SftpMarkdownPreviewScreen(entry: entry, svc: svc),
    );

void main() {
  const sample = '''
# Title

Some **bold** text and a [link](https://example.com).

- one
- two

| a | b |
| - | - |
| 1 | 2 |

```
echo hi
```
''';

  testWidgets('renders markdown instead of raw source', (tester) async {
    final svc = SFTPService.testWith(() async => _FakeOps(sample));
    await tester.pumpWidget(_wrap(svc, _mdEntry()));
    await tester.pumpAndSettle();

    expect(find.byType(Markdown), findsOneWidget);
    // The literal heading marker must not survive into the rendered output.
    expect(find.textContaining('# Title'), findsNothing);
    // Rendered pieces are present as real widgets, not punctuation.
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
  });

  testWidgets('offers a route back to the source editor', (tester) async {
    final svc = SFTPService.testWith(() async => _FakeOps(sample));
    await tester.pumpWidget(_wrap(svc, _mdEntry()));
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byTooltip(l.sftpViewSource), findsOneWidget);
  });

  testWidgets('does not show AI action chips in a file preview',
      (tester) async {
    final svc = SFTPService.testWith(
      () async => _FakeOps('```bash\necho hi\n```'),
    );
    await tester.pumpWidget(_wrap(svc, _mdEntry()));
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    // "Run" is an AI-panel affordance; it must not leak into file preview.
    expect(find.text(l.aiRunAction), findsNothing);
    expect(find.text(l.aiSaveAction), findsNothing);
    expect(find.text(l.aiCopyAction), findsNothing);
  });

  testWidgets('warns when the file was truncated by the read cap',
      (tester) async {
    // 真实文件比返回的内容大 —— 截断结论来自读取结果本身。
    final ops = _FakeOps(sample)..statSize = 800 * 1024;
    final svc = SFTPService.testWith(() async => ops);
    await tester.pumpWidget(_wrap(svc, _mdEntry()));
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.sftpMarkdownTruncated), findsOneWidget);
  });

  testWidgets('列表快照过期时仍能正确提示截断', (tester) async {
    // 快照说 100 字节（不超上限），实际 800 KB —— 旧代码靠快照判断，
    // 会漏掉截断提示，用户可编辑并保存，把远端文件截断覆盖。
    final ops = _FakeOps('a' * 100)..statSize = 800 * 1024;
    final svc = SFTPService.testWith(() async => ops);
    await tester.pumpWidget(_wrap(svc, _mdEntry(size: 100)));
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.sftpMarkdownTruncated), findsOneWidget,
        reason: '截断结论来自实际读取，不来自过期的 entry.size');
  });

  testWidgets('no truncation notice for a small file', (tester) async {
    final svc = SFTPService.testWith(() async => _FakeOps(sample));
    await tester.pumpWidget(_wrap(svc, _mdEntry()));
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.sftpMarkdownTruncated), findsNothing);
  });

  testWidgets('shows an error instead of an empty document on read failure',
      (tester) async {
    final ops = _FakeOps(sample)..throwOnRead = true;
    final svc = SFTPService.testWith(() async => ops);
    await tester.pumpWidget(_wrap(svc, _mdEntry()));
    await tester.pumpAndSettle();

    expect(find.byType(Markdown), findsNothing);
    expect(find.textContaining('Permission denied'), findsOneWidget);
  });

  testWidgets('remote images are not fetched; alt text is shown',
      (tester) async {
    final svc = SFTPService.testWith(
      () async => _FakeOps('![architecture diagram](https://ex.com/a.png)'),
    );
    await tester.pumpWidget(_wrap(svc, _mdEntry()));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.text('architecture diagram'), findsOneWidget);
  });

  testWidgets('preview renders at a larger base size than the AI panel',
      (tester) async {
    // Reading a document, not scanning a chat log.
    expect(SftpMarkdownPreviewScreen.previewBaseFontSize, greaterThan(12.5));
    expect(SftpMarkdownPreviewScreen.previewBaseFontSize, lessThanOrEqualTo(16));
  });
}
