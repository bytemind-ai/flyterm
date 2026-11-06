import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 缓冲区里所有非空行的文本（scrollback + 视口）。
List<String> _allText(Terminal t) {
  final out = <String>[];
  final lines = t.buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    final s = lines[i].getText().trimRight();
    if (s.isNotEmpty) out.add(s);
  }
  return out;
}

void main() {
  group('Buffer.resize — 键盘弹收', () {
    test('光标停在底行：45 -> 25 -> 45 往返无损', () {
      final t = Terminal(maxLines: 3000);
      t.resize(80, 45);
      for (var i = 0; i < 120; i++) {
        t.write('LINE-$i\r\n');
      }
      final before = _allText(t);
      expect(before.length, 120);

      t.resize(80, 25);
      t.resize(80, 45);

      expect(_allText(t), before);
    });

    test('光标不在底行：45 -> 25 -> 45 往返无损', () {
      final t = Terminal(maxLines: 3000);
      t.resize(80, 45);
      for (var i = 0; i < 120; i++) {
        t.write('LINE-$i\r\n');
      }
      t.write('\x1b[10A');
      final before = _allText(t);
      expect(before.length, 120);

      t.resize(80, 25);
      t.resize(80, 45);

      expect(_allText(t), before,
          reason: 'shrink 应把顶部行让进 scrollback，而不是从末尾删行');
    });

    test('alt buffer：shrink 保持原语义，内容与光标不错位', () {
      final t = Terminal(maxLines: 3000);
      t.resize(80, 45);
      t.write('\x1b[?1049h');
      for (var i = 0; i < 5; i++) {
        t.write('ALT-$i\r\n');
      }
      expect(t.buffer.isAltBuffer, isTrue);
      expect(t.buffer.cursorY, 5, reason: '前置条件');

      t.resize(80, 25);

      expect(t.buffer.lines.length, 25, reason: 'alt 无 scrollback');
      expect(t.buffer.cursorY, 5, reason: 'alt 走原分支，光标不该被递减');
      expect(_allText(t), ['ALT-0', 'ALT-1', 'ALT-2', 'ALT-3', 'ALT-4'],
          reason: 'alt 顶部内容不应被 clearScrollback 削掉');
    });

    test('旋转：宽高同时变化，内容不丢', () {
      final t = Terminal(maxLines: 3000);
      t.resize(80, 45);
      for (var i = 0; i < 60; i++) {
        t.write('ROT-$i\r\n');
      }
      t.write('\x1b[10A');
      final before = _allText(t);

      t.resize(120, 25);
      t.resize(80, 45);

      expect(_allText(t), before);
    });

    test('相同尺寸 resize 不重置 DECSTBM，但仍触发 onResize', () {
      final t = Terminal(maxLines: 500);
      t.resize(80, 40);
      t.write('\x1b[5;20r');
      expect(t.buffer.marginTop, 4);
      expect(t.buffer.marginBottom, 19);

      var calls = 0;
      t.onResize = (w, h, pw, ph) => calls++;

      t.resize(80, 40);

      expect(t.buffer.marginTop, 4, reason: '相同尺寸不应重置滚动区域');
      expect(t.buffer.marginBottom, 19);
      expect(calls, 1,
          reason: 'onResize 仍需触发 — SSH PTY 靠它纠正 80x24 默认尺寸');
    });
  });
}
