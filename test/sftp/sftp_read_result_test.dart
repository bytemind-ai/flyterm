import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_read_result.dart';

void main() {
  group('ReadResult 截断判据', () {
    test('大小已知且读满 —— 未截断', () {
      final r = ReadResult.fromBytes(
        'hello',
        maxBytes: 1024,
        totalSize: 5,
      );
      expect(r.content, 'hello');
      expect(r.truncated, isFalse);
      expect(r.totalSize, 5);
    });

    test('大小已知且没读满 —— 截断', () {
      // 这正是原 bug 的场景：文件 800 KB，读取上限 512 KB。
      // 旧代码靠 entry.size 猜，快照过期时猜错 → 截断内容被保存回远端。
      final r = ReadResult.fromBytes(
        'x' * 10,
        maxBytes: 5,
        totalSize: 800,
      );
      expect(r.truncated, isTrue, reason: '读到 10 字节（上限 5）但文件有 800');
      expect(r.totalSize, 800);
    });

    test('大小未知但读满上限 —— 判为截断（保守）', () {
      final r = ReadResult.fromBytes(
        'x' * 5,
        maxBytes: 5,
        totalSize: null,
      );
      expect(r.truncated, isTrue, reason: '读到上限，无法排除还有更多');
      expect(r.totalSize, isNull);
    });

    test('大小未知且没读满 —— 未截断', () {
      final r = ReadResult.fromBytes('abc', maxBytes: 512, totalSize: null);
      expect(r.truncated, isFalse);
    });

    test('空文件不算截断', () {
      final r = ReadResult.fromBytes('', maxBytes: 512, totalSize: 0);
      expect(r.content, isEmpty);
      expect(r.truncated, isFalse);
    });

    test('大小恰好等于上限时按已知大小判定', () {
      // 512 KB 的文件读满 512 KB 上限：totalSize 已知且相等 → 未截断。
      final r = ReadResult.fromBytes('x' * 10, maxBytes: 10, totalSize: 10);
      expect(r.truncated, isFalse);
    });

    test('truncated 可显式指定，覆盖推断（服务端返回带截断标志时用）', () {
      final r = ReadResult(
        content: 'abc',
        truncated: true,
        totalSize: 3,
      );
      expect(r.truncated, isTrue);
    });
  });
}
