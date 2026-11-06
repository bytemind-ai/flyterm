import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/zip_reader.dart';

import '_tar_bundle.dart';

void main() {
  test('deflate 条目解出来', () {
    final z = buildZip({'a/b.txt': 'hello world'});
    final files = unzip(z);
    expect(files, isNotNull);
    expect(utf8.decode(files!['a/b.txt']!), equals('hello world'));
  });

  test('stored 条目也解出来', () {
    final z = buildZip({'x.txt': 'plain'}, deflate: false);
    final files = unzip(z);
    expect(utf8.decode(files!['x.txt']!), equals('plain'));
  });

  test('多文件 + 中文名', () {
    final z = buildZip({
      'deploy/SKILL.md': '# body',
      'deploy/scripts/run.sh': 'echo hi',
      '让/笔记.txt': '中文内容',
    });
    final files = unzip(z)!;
    expect(files.keys.toSet(),
        equals({'deploy/SKILL.md', 'deploy/scripts/run.sh', '让/笔记.txt'}));
    expect(utf8.decode(files['让/笔记.txt']!), equals('中文内容'));
  });

  test('目录条目被跳过（不以空文件形式出现）', () {
    final z = buildZip({'dir/': '', 'dir/f.txt': 'x'});
    final files = unzip(z)!;
    expect(files.keys, equals(['dir/f.txt']));
  });

  test('不是 zip → null', () {
    expect(unzip(Uint8List.fromList(utf8.encode('not a zip at all'))), isNull);
  });

  test('截断的 zip → 不抛（可能 null 或部分）', () {
    final z = buildZip({'a.txt': 'x' * 500});
    final cut = Uint8List.fromList(z.sublist(0, z.length ~/ 2));
    // 中央目录没了 → null。关键是**不抛**。
    expect(() => unzip(cut), returnsNormally);
  });

  test('大文件（跨多个块）也不坏', () {
    final big = 'x' * 100000;
    final z = buildZip({'big.txt': big});
    final files = unzip(z)!;
    expect(utf8.decode(files['big.txt']!), hasLength(100000));
  });
}
