// test/ssh/utf8_boundary_test.dart
//
// UTF-8 边界保护单元测试。覆盖 d5.jpg 报告的 QUIC RESUME 之后 prompt 后
// 出现 □□□□ tofu 的两个根因路径：
//   A. 跨 transport 的 utf8 residue 续接
//   B. swallowAndStrip 按字节切但跳过 leading continuation bytes
//
// SessionTab 是 ChangeNotifier 且依赖 xterm/AIEngine 等大型对象，难以独立
// 实例化，所以这里直接测它暴露的 2 个 static helper。

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/session_manager.dart';

void main() {
  group('trailingIncompleteUtf8Bytes', () {
    test('全 ASCII 无残留', () {
      expect(SessionTab.trailingIncompleteUtf8Bytes([0x68, 0x69]), 0);
    });

    test('完整 CJK 字符无残留', () {
      // "中" = 0xE4 0xB8 0xAD (3-byte UTF-8)
      expect(
          SessionTab.trailingIncompleteUtf8Bytes([0xE4, 0xB8, 0xAD]), 0);
    });

    test('CJK leading byte 单独残留 (1 byte)', () {
      // chunk ends with E4 alone — needs 2 more bytes
      expect(SessionTab.trailingIncompleteUtf8Bytes([0x68, 0xE4]), 1);
    });

    test('CJK leading + 1 continuation 残留 (2 bytes)', () {
      // chunk ends with E4 B8 — needs 1 more byte
      expect(
          SessionTab.trailingIncompleteUtf8Bytes([0x68, 0xE4, 0xB8]), 2);
    });

    test('4-byte emoji leading 残留 (1 byte)', () {
      // 😀 = F0 9F 98 80
      expect(SessionTab.trailingIncompleteUtf8Bytes([0xF0]), 1);
    });

    test('4-byte emoji 2/4 残留', () {
      expect(SessionTab.trailingIncompleteUtf8Bytes([0xF0, 0x9F]), 2);
    });

    test('4-byte emoji 3/4 残留', () {
      expect(
          SessionTab.trailingIncompleteUtf8Bytes([0xF0, 0x9F, 0x98]), 3);
    });

    test('空字节数组', () {
      expect(SessionTab.trailingIncompleteUtf8Bytes(const []), 0);
    });
  });

  group('alignToUtf8CharStart', () {
    test('start 已在 ASCII 边界，不动', () {
      final bytes = [0x68, 0x69, 0x6A]; // "hij"
      expect(SessionTab.alignToUtf8CharStart(bytes, 0), 0);
      expect(SessionTab.alignToUtf8CharStart(bytes, 1), 1);
    });

    test('start 在 CJK leading byte (0xE4)，不动', () {
      final bytes = [0xE4, 0xB8, 0xAD]; // "中"
      expect(SessionTab.alignToUtf8CharStart(bytes, 0), 0);
    });

    test('start 在 continuation byte (0xB8)，跳到下一个 leading', () {
      // "中" 的 2 个 continuation byte 紧接 ASCII
      final bytes = [0xB8, 0xAD, 0x68]; // 缺 leading 的损坏流
      expect(SessionTab.alignToUtf8CharStart(bytes, 0), 2);
    });

    test('start 在 continuation byte (0xAD)，跳过 1 个', () {
      final bytes = [0xE4, 0xAD, 0x68];
      expect(SessionTab.alignToUtf8CharStart(bytes, 1), 2);
    });

    test('全部都是 continuation byte，跳到末尾', () {
      final bytes = [0x80, 0x9F, 0xBF]; // 全 continuation
      expect(SessionTab.alignToUtf8CharStart(bytes, 0), 3);
    });

    test('start 超出长度，返回 length', () {
      final bytes = [0x68];
      expect(SessionTab.alignToUtf8CharStart(bytes, 5), 5);
    });

    test('emoji 切断恢复', () {
      // 想象：swallow 把 0xF0 0x9F 0x98 吞掉了，剩下 0x80 + ASCII
      final bytes = [0x80, 0x68, 0x69];
      expect(SessionTab.alignToUtf8CharStart(bytes, 0), 1);
    });
  });

  group('integration: swallow + UTF-8 alignment scenario', () {
    // 模拟 d5.jpg 场景：prelude swallow N 字节恰好切在 CJK 中间，
    // 没有对齐的话剩下 continuation byte 会让 decoder 输出 U+FFFD。
    // 对齐之后，破损字符被丢弃，后续 ASCII 干净进入 xterm。
    test('swallow 切在 CJK 中间，对齐丢破损 char 保留 prompt', () {
      // 假设服务端 ring buffer 字节流（重连之前）：
      //   "abc中def" = 61 62 63 E4 B8 AD 64 65 66
      // alt-buffer prelude swallow 设为 4 (切到 "中" 的第 1 个 continuation)
      // 期望：吞掉前 4 字节 + 2 个 continuation byte = 跳到 index 6 "def"
      final bytes = [
        0x61, 0x62, 0x63, 0xE4, // <- swallow 4 ends here, mid CJK
        0xB8, 0xAD,             // continuation bytes (2 个) 要丢
        0x64, 0x65, 0x66,       // "def"
      ];
      const swallow = 4;
      final aligned = SessionTab.alignToUtf8CharStart(bytes, swallow);
      expect(aligned, 6);
      expect(bytes.sublist(aligned), [0x64, 0x65, 0x66]);
    });

    test('swallow 恰好落在 char 边界，不丢任何字节', () {
      // "abc中def" — swallow 3 落在 "中" 之前
      final bytes = [
        0x61, 0x62, 0x63,       // <- swallow 3 ends here (aligned)
        0xE4, 0xB8, 0xAD,       // "中"
        0x64, 0x65, 0x66,       // "def"
      ];
      const swallow = 3;
      final aligned = SessionTab.alignToUtf8CharStart(bytes, swallow);
      expect(aligned, 3); // 无 continuation byte 需要跳
      expect(bytes.sublist(aligned), [0xE4, 0xB8, 0xAD, 0x64, 0x65, 0x66]);
    });
  });
}
