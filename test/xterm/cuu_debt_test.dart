// TUI 重绘时「帧高 > 视口高」导致的内容重复。
//
// ink / Claude Code 这类 TUI 重绘一帧的动作是：CUU(帧高−1) 回到帧首 →
// `\x1b[J` 擦到屏幕末尾 → 重画整帧。而 `setCursorY` 是 clamp(0, viewHeight−1)
// —— 光标上移到视口第 0 行就停住，不会进 scrollback（这是正确的 VT 行为）。
//
// 于是帧高超过视口高时：应用少上移了 (帧高 − 视口高) 行，以为回到帧首、实际
// 停在帧中间；`\x1b[J` 只擦得到光标以下，帧的上半截原样留着；应用又完整重画
// 一遍，那截就成了重复，且每次 SIGWINCH 累积一份。
//
// 手机上键盘一弹，视口只剩二十来行，一条带表格代码块的长回复必然超过。
//
// 对策：CUU 想上移却被视口顶部挡住时把差额记为「欠账」，紧接着的 `\x1b[J`
// 执行前，把紧邻视口上方的欠账行删掉 —— 那正是应用以为自己会擦掉、实际没
// 擦到的部分。这是协议层的意图信号，不是文本比对，所以不会误删真实历史。
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

List<String> _allText(Terminal t) {
  final out = <String>[];
  final lines = t.buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    final s = lines[i].getText().trimRight();
    if (s.isNotEmpty) out.add(s);
  }
  return out;
}

int _dupKinds(Terminal t) {
  final counts = <String, int>{};
  for (final s in _allText(t)) {
    counts[s] = (counts[s] ?? 0) + 1;
  }
  return counts.values.where((v) => v > 1).length;
}

int _countPrefix(Terminal t, String prefix) =>
    _allText(t).where((s) => s.startsWith(prefix)).length;

/// 画一帧：h 行，最后一行不换行，光标停在帧尾 —— 真实 TUI 的画法。
void _drawFrame(Terminal t, int h) {
  for (var i = 0; i < h; i++) {
    t.write('F-$i');
    if (i < h - 1) t.write('\r\n');
  }
}

/// 重绘一帧：CUU 回帧首 → 擦到屏幕末尾 → 重画。
void _redrawFrame(Terminal t, int h) {
  t.write('\x1b[${h - 1}A\r');
  t.write('\x1b[J');
  _drawFrame(t, h);
}

/// 视口 45 行、50 行历史、画一个 [frameHeight] 行的帧。
Terminal _seed(int frameHeight, {int viewHeight = 45}) {
  final t = Terminal(maxLines: 3000);
  t.resize(80, viewHeight);
  for (var i = 0; i < 50; i++) {
    t.write('HIST-$i\r\n');
  }
  _drawFrame(t, frameHeight);
  return t;
}

void main() {
  const full = 45, kb = 27;

  group('CUU 欠账补擦', () {
    test('帧高 40 > 键盘视口 27：三次弹收不产生重复', () {
      final t = _seed(40);
      expect(_dupKinds(t), 0, reason: '前置条件');

      for (var r = 1; r <= 3; r++) {
        t.resize(80, kb);
        _redrawFrame(t, 40);
        t.resize(80, full);
        _redrawFrame(t, 40);
      }

      expect(_dupKinds(t), 0, reason: '帧的上半截不该被留下成为副本');
      expect(_countPrefix(t, 'F-'), 40, reason: '帧行数必须恒定，不能累积');
      expect(_countPrefix(t, 'HIST-'), 50, reason: '历史一行都不能少');
    });

    test('帧高 28 刚超过键盘视口 27：临界点同样干净', () {
      final t = _seed(28);

      for (var r = 1; r <= 3; r++) {
        t.resize(80, kb);
        _redrawFrame(t, 28);
        t.resize(80, full);
        _redrawFrame(t, 28);
      }

      expect(_dupKinds(t), 0);
      expect(_countPrefix(t, 'F-'), 28);
      expect(_countPrefix(t, 'HIST-'), 50);
    });

    test('帧高 20 < 键盘视口 27：不触发补擦，无副作用', () {
      final t = _seed(20);

      for (var r = 1; r <= 3; r++) {
        t.resize(80, kb);
        _redrawFrame(t, 20);
        t.resize(80, full);
        _redrawFrame(t, 20);
      }

      expect(_dupKinds(t), 0);
      expect(_countPrefix(t, 'F-'), 20);
      expect(_countPrefix(t, 'HIST-'), 50);
    });

    test('小视口下连续重绘（全程不 resize）也不累积', () {
      // 触发条件是「帧高 > 视口高」，与 resize 无关 —— 用户把窗口调小后
      // 一直用，同样会每帧留一份副本。
      final t = _seed(40, viewHeight: kb);

      for (var i = 0; i < 5; i++) {
        _redrawFrame(t, 40);
      }

      expect(_dupKinds(t), 0);
      expect(_countPrefix(t, 'F-'), 40);
      expect(_countPrefix(t, 'HIST-'), 50);
    });

    test('欠账被无关的字符写入打断后作废，不补擦', () {
      final t = _seed(40);
      t.resize(80, kb);
      final sbBefore = t.buffer.scrollBack;

      t.write('\x1b[39A\r'); // CUU 越界 → 欠 13
      t.write('X'); // 无关写入 → 欠账必须作废
      t.write('\x1b[J');

      expect(t.buffer.scrollBack, sbBefore,
          reason: 'CUU 与 ED 之间插了写入，就不是全帧重绘，不能删 scrollback');
      expect(_countPrefix(t, 'HIST-'), 50, reason: '历史不能被误删');
    });

    test('alt buffer 天然免疫：scrollBack 恒为 0，且不影响 primary 历史', () {
      final t = Terminal(maxLines: 3000);
      t.resize(80, full);
      for (var i = 0; i < 50; i++) {
        t.write('HIST-$i\r\n');
      }
      t.write('\x1b[?1049h'); // 进 alt
      _drawFrame(t, 20);
      expect(t.buffer.isAltBuffer, isTrue);

      t.resize(80, kb);
      // 在 alt 里疯狂换行 + CUU 越界重绘，试图把 scrollback 撑出来。
      for (var i = 0; i < 60; i++) {
        t.write('ALT-$i\r\n');
      }
      t.write('\x1b[39A\r\x1b[J');
      _drawFrame(t, 20);

      // 这是补擦逻辑在 alt 下不生效的**前提**：alt 的 index 走 scrollUp，
      // 而 alt 下 scrollUp 是原地平移不 push。哪天这个前提被改掉，这条会红，
      // 提醒去重新审视 _consumeCuuDebt 的 isAltBuffer 分支。
      expect(t.buffer.scrollBack, 0,
          reason: 'alt buffer 不该积累 scrollback');
      expect(t.buffer.lines.length, kb,
          reason: 'alt 的 lines 恒等于 viewHeight');

      t.write('\x1b[?1049l');
      expect(_countPrefix(t, 'HIST-'), 50,
          reason: 'alt 里的一切操作都不该动到 primary 的历史');
    });
  });
}
