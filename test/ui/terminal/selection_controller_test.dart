import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:flyterm/ui/terminal/selection_controller.dart';

/// 造一个 80x24 的终端，写入若干行文本。
/// 注意 write 的换行必须是 \r\n —— 单个 \n 只下移不回车，
/// 第二行会从上一行的列位置开始，测试断言的坐标就全错了。
Terminal _terminalWith(List<String> lines) {
  final t = Terminal(maxLines: 1000);
  t.resize(80, 24);
  t.write(lines.join('\r\n'));
  return t;
}

void main() {
  group('TerminalSelectionController 骨架', () {
    test('初始状态不活跃', () {
      final t = _terminalWith(['hello world']);
      final xterm = TerminalController();
      final c = TerminalSelectionController(t, xterm);

      expect(c.isActive, isFalse);
      expect(c.begin, isNull);
      expect(c.end, isNull);
    });

    test('clear 在不活跃时是安全的空操作', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.clear();

      expect(c.isActive, isFalse);
    });
  });

  group('selectWordAt', () {
    test('选中普通单词', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(2, 0)); // 'l' in hello

      expect(c.isActive, isTrue);
      expect(c.begin, const CellOffset(0, 0));
      expect(c.end, const CellOffset(5, 0)); // exclusive
      expect(c.readText(), 'hello');
    });

    test('第二行的单词坐标正确', () {
      final t = _terminalWith(['hello', 'world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(1, 1));

      expect(c.begin, const CellOffset(0, 1));
      expect(c.readText(), 'world');
    });

    // 这条原本断言"落在空格上只选那一格"。那是选区重写引入的退化 ——
    // master 一直会向外找最近的词。长按很难正好落在字上，只给用户一个空格
    // 等于没选中。行为已推翻，断言随之改写。
    test('落在空格上 → 选中相邻的词，而不是那个空格', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(5, 0)); // 空格

      expect(c.isActive, isTrue);
      expect(c.readText(), 'world');
    });

    test('y 越界被 clamp，不抛异常', () {
      final t = _terminalWith(['hello']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(0, 9999));

      expect(c.isActive, isTrue);
    });

    test('重复选词不会 double dispose', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(2, 0));
      c.selectWordAt(const CellOffset(7, 0));

      expect(c.readText(), 'world');
    });
  });

  group('拖拽', () {
    test('拖 end 端向右扩展选区', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0)); // 'hello'

      c.beginDrag(SelectionEnd.end);
      c.updateDrag(const CellOffset(11, 0));
      c.endDrag();

      expect(c.readText(), 'hello world');
      expect(c.isDragging, isFalse);
    });

    test('拖 start 端向左扩展，固定端不动', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(7, 0)); // 'world' → (6,0)-(11,0)

      c.beginDrag(SelectionEnd.start);
      c.updateDrag(const CellOffset(0, 0));
      c.endDrag();

      expect(c.begin, const CellOffset(0, 0));
      expect(c.end, const CellOffset(11, 0));
    });

    test('拖 start 端越过 end 后自动归一化', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0)); // (0,0)-(5,0)

      c.beginDrag(SelectionEnd.start);
      c.updateDrag(const CellOffset(9, 0)); // 越过 end
      c.endDrag();

      // begin 永远在 end 之前
      final b = c.begin!;
      final e = c.end!;
      expect(b.y < e.y || (b.y == e.y && b.x <= e.x), isTrue);
    });

    test('未 beginDrag 时 updateDrag 是空操作', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));

      c.updateDrag(const CellOffset(11, 0));

      expect(c.readText(), 'hello');
    });

    test('选区不活跃时 beginDrag 不进入拖拽态', () {
      final t = _terminalWith(['hello']);
      final c = TerminalSelectionController(t, TerminalController());

      c.beginDrag(SelectionEnd.end);

      expect(c.isDragging, isFalse);
    });

    test('跨行拖拽', () {
      final t = _terminalWith(['hello', 'world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(0, 0));

      c.beginDrag(SelectionEnd.end);
      c.updateDrag(const CellOffset(5, 1));
      c.endDrag();

      expect(c.readText(), 'hello\nworld');
    });
  });

  group('detach 自动退出', () {
    test('primary buffer 追加新行不影响选区', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));

      t.write('\r\nnew output line');
      c.onTerminalChanged();

      expect(c.isActive, isTrue);
      expect(c.readText(), 'hello');
    });

    test('切到 alt buffer 后选区退出', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));

      t.write('\x1b[?1049h'); // 进 alt buffer
      c.onTerminalChanged();

      expect(c.isActive, isFalse);
    });

    test('onTerminalChanged 在不活跃时是空操作', () {
      final t = _terminalWith(['hello']);
      final c = TerminalSelectionController(t, TerminalController());

      c.onTerminalChanged();

      expect(c.isActive, isFalse);
    });

    test('退出时通知监听者', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));
      var notified = 0;
      c.addListener(() => notified++);

      t.write('\x1b[?1049h');
      c.onTerminalChanged();

      expect(notified, greaterThan(0));
    });
  });

  group('TerminalController.dispose', () {
    test('dispose 后 buffer line 上不留 anchor', () {
      final t = _terminalWith(['hello world']);
      final xterm = TerminalController();
      final c = TerminalSelectionController(t, xterm);
      c.selectWordAt(const CellOffset(2, 0));

      expect(t.buffer.lines[0].anchors, isNotEmpty);

      xterm.dispose();

      expect(t.buffer.lines[0].anchors, isEmpty);
    });
  });

  group('alt buffer —— 冻结模式', () {
    /// 进 alt buffer 并写入内容。TUI（vim / Claude Code）就跑在这里。
    Terminal altWith(List<String> lines) {
      final t = Terminal(maxLines: 1000);
      t.resize(80, 24);
      t.write('\x1b[?1049h'); // 切 alt buffer
      t.write(lines.join('\r\n'));
      return t;
    }

    test('在 alt buffer 里能建立选区', () {
      final t = altWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(2, 0));

      expect(c.isActive, isTrue);
      expect(c.readText(), 'hello');
    });

    test('TUI 原地覆写重绘后，选区还在，文本是选中那一刻的', () {
      final t = altWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));

      // 光标归位后原地覆写 —— 这是 htop / Claude Code 刷新屏幕的典型做法，
      // 它不替换 BufferLine 对象，所以 anchor 根本不会 detach。
      t.write('\x1b[1;1H');
      t.write('XXXXX世界');
      c.onTerminalChanged();

      expect(c.isActive, isTrue, reason: '重绘不该让 TUI 里的选区消失');
      expect(c.readText(), 'hello', reason: '复制到的必须是选中时看到的文字');
    });

    test('TUI 清屏重绘后选区仍在 —— anchor 在这条路径上真的会 detach', () {
      final t = altWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));

      // ESC[2J 清屏 + 重画。区别于原地覆写：这条路径会替换 BufferLine
      // 对象，anchor 会 detach —— 冻结模式不依赖 anchor，所以不受影响。
      // Claude Code / opencode 那类 TUI 的全屏刷新走的就是这一类。
      t.write('\x1b[2J\x1b[1;1H');
      t.write('completely different content');
      c.onTerminalChanged();

      expect(c.isActive, isTrue, reason: '清屏重绘不该让 TUI 里的选区消失');
      expect(c.readText(), 'hello');
    });

    test('切回 primary buffer 时选区退出', () {
      final t = altWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));

      t.write('\x1b[?1049l'); // 退出 alt buffer
      c.onTerminalChanged();

      expect(c.isActive, isFalse);
    });

    test('冻结模式下拖拽会按当前屏幕重新取文本', () {
      final t = altWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0)); // 'hello'

      c.beginDrag(SelectionEnd.end);
      c.updateDrag(const CellOffset(11, 0));
      c.endDrag();

      expect(c.readText(), 'hello world',
          reason: '用户是照着当前屏幕拖的，快照要跟着更新');
    });

    test('primary buffer 仍然走 anchor 模式，跟着文本滚动', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());
      c.selectWordAt(const CellOffset(2, 0));

      // 追加输出：primary 里老行还在，anchor 存活，选区跟着文本走
      t.write('\r\nmore output');
      c.onTerminalChanged();

      expect(c.isActive, isTrue);
      expect(c.readText(), 'hello');
    });
  });

  /// 不变量：FlyTerm 选区不活跃 ⇒ TerminalController 的选区必须为空。
  ///
  /// 手势下线（builtinSelectionGestures: false）之后理论上没人能再往
  /// controller 里塞选区，但"理论上没人"不是防线。幽灵高亮就是这条不变量
  /// 被破坏的样子：屏幕上留着一块谁都不负责清理的高亮。
  /// 选词的分隔符只有空格和空 cell —— 终端里 . : - / 遍地都是，把它们当分隔符
  /// 就选不出路径、时间戳、IP、长参数，而那些正是最常被复制的东西。
  ///
  /// 点在空白上时向外找最近的词，也是必须的：长按很难正好落在字上，只选中一个
  /// 空格对用户毫无用处。这两条 master 一直都有，选区重写时丢了。
  group('selectWordAt —— 终端场景的选词', () {
    test('点在路径中间的 / 上 → 选中整条路径', () {
      final t = _terminalWith(['cd /usr/local/bin']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(7, 0)); // 落在 /usr/ 的第二个 /

      expect(c.readText(), '/usr/local/bin');
    });

    test('点在时间戳的冒号上 → 选中整个时间戳', () {
      final t = _terminalWith(['at 15:28:41 done']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(5, 0)); // 落在第一个 :

      expect(c.readText(), '15:28:41');
    });

    test('点在长参数的 -- 上 → 选中整个参数', () {
      final t = _terminalWith(['git push --force-with-lease']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(10, 0)); // 落在 --

      expect(c.readText(), '--force-with-lease');
    });

    test('点在词之间的空格上 → 选中右边那个词', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(5, 0)); // 空格

      expect(c.readText(), 'world');
    });

    test('点在行尾空白上 → 右边没有词，回头选左边最近的', () {
      final t = _terminalWith(['hello world']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(40, 0)); // 远在文本右侧的空白

      expect(c.readText(), 'world');
    });

    test('整行空白 → 退化成选单格，不抛异常', () {
      final t = _terminalWith(['', 'second line']);
      final c = TerminalSelectionController(t, TerminalController());

      c.selectWordAt(const CellOffset(3, 0));

      expect(c.isActive, isTrue);
      expect(c.begin!.x, 3);
      expect(c.end!.x, 4);
    });

    test('CJK 连续文本整段选中', () {
      final t = _terminalWith(['前面 中文词组 后面']);
      final c = TerminalSelectionController(t, TerminalController());

      // CJK 是双宽字符，"前面" 占 4 列，空格 1 列，"中文词组" 从第 5 列起。
      c.selectWordAt(const CellOffset(6, 0));

      expect(c.readText(), '中文词组');
    });
  });

  group('不变量：选区不活跃 ⇒ xterm 选区为空', () {
    test('clear 之后两边都空', () {
      final t = _terminalWith(['hello world']);
      final xterm = TerminalController();
      final c = TerminalSelectionController(t, xterm);

      c.selectWordAt(const CellOffset(2, 0));
      expect(c.isActive, isTrue);
      expect(xterm.selection, isNotNull);

      c.clear();

      expect(c.isActive, isFalse);
      expect(xterm.selection, isNull);
    });

    test('alt buffer 冻结选区 clear 之后同样为空', () {
      final t = Terminal(maxLines: 1000);
      t.resize(80, 24);
      t.write('\x1b[?1049h');
      t.write('hello world');
      final xterm = TerminalController();
      final c = TerminalSelectionController(t, xterm);

      c.selectWordAt(const CellOffset(2, 0));
      expect(xterm.selection, isNotNull);

      c.clear();

      expect(xterm.selection, isNull);
    });

    test('自动失效（切回 primary）之后为空', () {
      final t = Terminal(maxLines: 1000);
      t.resize(80, 24);
      t.write('\x1b[?1049h');
      t.write('hello world');
      final xterm = TerminalController();
      final c = TerminalSelectionController(t, xterm);
      c.selectWordAt(const CellOffset(2, 0));

      t.write('\x1b[?1049l'); // 退出 TUI，回 primary
      c.onTerminalChanged();

      expect(c.isActive, isFalse);
      expect(xterm.selection, isNull);
    });

    test('FlyTerm 是 controller 选区的唯一写入者 —— 建立即同步', () {
      final t = _terminalWith(['hello world']);
      final xterm = TerminalController();
      final c = TerminalSelectionController(t, xterm);

      c.selectWordAt(const CellOffset(2, 0));

      final sel = xterm.selection!;
      expect('${sel.begin.x},${sel.begin.y}', '${c.begin!.x},${c.begin!.y}');
      expect('${sel.end.x},${sel.end.y}', '${c.end!.x},${c.end!.y}');
    });
  });
}
