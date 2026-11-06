// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// 拖拽中的是哪一端。
enum SelectionEnd { start, end }

/// 选区真相的两种形态。同一时刻**只可能是其中一种**。
///
/// 这不是回到"一份选区三份真相"的老路。那个老问题是同一个选区被三处状态
/// 同时表示、互相同步、形成回边；这里是**按 buffer 的语义分派**，任一时刻
/// `_state` 只指向一个对象，没有第二处需要同步。
///
/// 分派依据是两种 buffer 的本质差异：
///
/// | | primary | alt |
/// |---|---|---|
/// | 内容会移动吗 | 会（滚动、scrollback 挤出） | 不会（固定 N 行） |
/// | 内容会原地变吗 | 基本不会（追加为主） | 一直在变（TUI 重绘） |
/// | 坐标稳定吗 | 不稳定 | 稳定 |
/// | 该用什么当真相 | anchor | 坐标 + 文本快照 |
sealed class _Selection {
  const _Selection();
}

/// primary buffer：内容随滚动移动，坐标不稳定，anchor 才是真相。
class _Anchored extends _Selection {
  const _Anchored(this.base, this.extent, this.buffer);

  final CellAnchor base;
  final CellAnchor extent;

  /// 建立选区那一刻的活跃 buffer。
  ///
  /// 切 primary↔alt **不会**让 anchor detach：`Terminal` 的 `_mainBuffer` /
  /// `_altBuffer` 是两个 `late final` 常驻实例（`terminal.dart:94,101`），
  /// 切换只是把 `_buffer` 指针换过去（`:763`），选区所在的 `BufferLine`
  /// 对象毫发无损。光看 anchor 检测不出"当前显示的已经不是这个 buffer"。
  final Buffer buffer;
}

/// alt buffer：屏幕是固定的 N 行、没有 scrollback，坐标天然稳定；而内容被
/// 前台 TUI 一秒重绘好几次。
///
/// 这种形状下 anchor 是**错的工具**——它只在 line 对象存活时才有意义，而
/// 全屏重绘（滚动区域、insert/delete lines、清屏）会整批替换 line，于是
/// 选区每秒被丢弃好几次。用户在 Claude Code / opencode 里长按选择，手感
/// 就是"点了没反应"。
///
/// 更隐蔽的是另一半：如果 TUI 只是光标定位后**原地覆写**字符，line 对象
/// 不变、anchor 不 detach、buffer 也没换——选区好端端地留着，但底下的字
/// 已经换了一茬。这时候从 buffer 现取文本，复制到的是新内容。看着对、
/// 复制错，比选区消失更糟。
///
/// 所以这里把坐标和文本**一起冻住**：坐标定死用于画高亮，文本在进选区
/// 那一刻就取好。之后不管屏幕怎么翻腾，复制到的永远是用户当时看到的。
class _Frozen extends _Selection {
  const _Frozen(this.begin, this.end, this.text);

  final CellOffset begin;
  final CellOffset end;

  /// 建立（或拖拽结束）那一刻的文本。[readText] 直接返回它，不回 buffer 取。
  final String text;
}

/// 终端选区的唯一真相。
///
/// ## 没有回边
///
/// 这个类是选区的唯一写入者。它读的是自己创建的对象，不是从 xterm 读回
/// 状态再写回去。旧实现里 `_onSelectionControllerChange` 从 xterm 读状态、
/// 写进 `selectionOverride`、那份 override 又被当成真相，那条环是一整类
/// 补丁的成因。
///
/// ## anchor 的所有权不在这里
///
/// [TerminalController.setSelection] 接管传入 anchor 的所有权，并在下次
/// setSelection / clearSelection 时 dispose 它们（`controller.dart:62-67`）。
/// 这里持引用**只为读** `attached` 与 `offset`，绝不自己 dispose。
class TerminalSelectionController extends ChangeNotifier {
  TerminalSelectionController(this._terminal, this._xterm);

  final Terminal _terminal;
  final TerminalController _xterm;

  _Selection? _state;
  SelectionEnd? _dragging;

  bool get isDragging => _dragging != null;

  bool get isActive => begin != null;

  /// 归一化后的起点（inclusive），选区失效时为 null。
  CellOffset? get begin => _normalized()?.$1;

  /// 归一化后的终点（exclusive），选区失效时为 null。
  CellOffset? get end => _normalized()?.$2;

  /// 当前选区的有效范围，失效返回 null。
  ///
  /// 失效判定按形态分派：
  /// - 冻结选区：只在它所属的 alt buffer 里有效。退出 TUI 后屏幕内容整个
  ///   换掉，那对坐标不再指向任何相关的东西。
  /// - anchor 选区：两个 anchor 都还 attached，**且**当前显示的仍是建立
  ///   时的那个 buffer。
  (CellOffset, CellOffset)? _normalized() {
    switch (_state) {
      case null:
        return null;
      case _Frozen(:final begin, :final end):
        if (!_terminal.buffer.isAltBuffer) return null;
        return (begin, end);
      case _Anchored(:final base, :final extent, :final buffer):
        if (!base.attached || !extent.attached) return null;
        if (!identical(_terminal.buffer, buffer)) return null;
        return _order(base.offset, extent.offset);
    }
  }

  /// 归一化在**读取侧**，不在写入侧。
  ///
  /// 写入侧保留"哪个是起点"的信息（拖拽要靠它区分固定端与移动端），
  /// 读取侧保证 begin 永远在 end 之前。
  (CellOffset, CellOffset) _order(CellOffset a, CellOffset b) {
    final aFirst = a.y < b.y || (a.y == b.y && a.x <= b.x);
    return aFirst ? (a, b) : (b, a);
  }

  /// 终端选词只把**空格和空 cell** 当分隔符。
  ///
  /// 不用 xterm 的 `defaultWordSeparators` —— 它还包含 `. : - / \ " * +`，而
  /// 终端里这些字符遍地都是：`/usr/bin/foo`、`15:28:41`、`--force`、
  /// `192.168.1.1`。按那套集合，用户点在路径中间的 `/` 上只能选中一个字符，
  /// 而"选中整条路径"恰恰是终端里最常见的复制意图。
  ///
  /// 代价是选不出"句子里的单个词"（`foo.bar` 会整个选中），但终端不是文本
  /// 编辑器，这个取舍是划算的。master 一直用的就是这个集合。
  static const _wordSeparators = {0, 32};

  /// 选中 [cell] 处的单词；点在空白上时，选中同一行最近的那个词。
  ///
  /// ## 为什么不用 [Buffer.getWordBoundary]
  ///
  /// 除了分隔符集合不合适（见 [_wordSeparators]），它落在空白上时只会返回
  /// null 或一个不含点击列的区间，调用方除了"选单格"没有别的选择。而长按
  /// 空白处选中一个空格，对用户毫无用处 —— 他要的是旁边那个词。
  ///
  /// master 的实现里有这段向外搜索的 fallback，选区重写时当成"40 行冗余
  /// 循环"删掉了，于是长按稍微点偏一点就只选中一个字符。这是那次重写的功能
  /// 退化，不是原实现啰嗦。
  void selectWordAt(CellOffset cell) {
    final safe = _clamp(cell);
    final line = _terminal.buffer.lines[safe.y];
    final vw = _terminal.viewWidth;

    // 点击处本身就是词的一部分 → 向两侧扩展。
    if (_isWordCell(line, safe.x)) {
      _selectWordContaining(safe.x, safe.y, vw, line);
      return;
    }

    // 点在空白上 → 找同一行最近的词：先向右，够不着再向左。
    for (var i = safe.x + 1; i < vw; i++) {
      if (_isWordCell(line, i)) {
        _selectWordContaining(i, safe.y, vw, line);
        return;
      }
    }
    for (var i = safe.x - 1; i >= 0; i--) {
      if (_isWordCell(line, i)) {
        _selectWordContaining(i, safe.y, vw, line);
        return;
      }
    }

    // 整行都是空白 → 只能选那一格。end 是 exclusive，所以 +1。
    _setRange(safe, CellOffset((safe.x + 1).clamp(0, vw), safe.y));
  }

  /// 第 [x] 格是不是词的一部分。
  ///
  /// ## 双宽字符的续列和空白长得一模一样
  ///
  /// CJK 占两列，第二列是 `codePoint=0, width=0`；而行尾从未写过的空白
  /// **也是** `codePoint=0, width=0`。光看这一格分不出来，得看前一格：前一格
  /// 宽度为 2，这里才是它的续列。
  ///
  /// 不做这个区分，CJK 每个字都会被当成"字+分隔符"切开。更糟的是选中范围会
  /// 漏掉续列，而 `BufferLine.getText` 要求 `i + width <= to` 才取字符 ——
  /// 选中单个汉字的范围若是 `[3,4)`，取出来是**空字符串**，用户看着高亮好好的
  /// 却复制到了空内容。
  bool _isWordCell(BufferLine line, int x) {
    final cp = line.getCodePoint(x);
    if (cp != 0) return !_wordSeparators.contains(cp);
    return x > 0 && line.getWidth(x - 1) == 2;
  }

  /// 以 [x] 为落点向两侧扩到词边界并建立选区。调用方须先确认 [x] 处是词字符。
  void _selectWordContaining(int x, int y, int viewWidth, BufferLine line) {
    var begin = x;
    var end = x + 1;
    while (begin > 0 && _isWordCell(line, begin - 1)) {
      begin--;
    }
    while (end < viewWidth && _isWordCell(line, end)) {
      end++;
    }
    _setRange(CellOffset(begin, y), CellOffset(end, y));
  }

  /// 把坐标夹进 buffer 的合法范围。
  ///
  /// y 必须夹 —— `Buffer.createAnchor` 直接 `lines[y]`（`buffer.dart:565`），
  /// 越界会抛 RangeError 而不是返回 null。x 夹到 viewWidth-1（inclusive 语义）。
  CellOffset _clamp(CellOffset o) {
    final maxY = _terminal.buffer.lines.length - 1;
    final maxX = _terminal.viewWidth - 1;
    return CellOffset(
      o.x.clamp(0, maxX < 0 ? 0 : maxX),
      o.y.clamp(0, maxY < 0 ? 0 : maxY),
    );
  }

  /// 夹终点。end 是 exclusive，x 可以等于 viewWidth（选到最后一列的右边界）。
  CellOffset _clampEnd(CellOffset o) {
    final maxY = _terminal.buffer.lines.length - 1;
    return CellOffset(
      o.x.clamp(0, _terminal.viewWidth),
      o.y.clamp(0, maxY < 0 ? 0 : maxY),
    );
  }

  /// 用两个坐标建立选区。这是**唯一**写入真相的地方。
  ///
  /// 按当前 buffer 的类型选形态：alt 冻结、primary 用 anchor。两条路各自
  /// 把对应的表示推给 xterm，而 `setSelection` / `setFixedSelection` 互斥，
  /// 所以渲染侧也只有一份。
  void _setRange(CellOffset begin, CellOffset end) {
    final b = _clamp(begin);
    final e = _clampEnd(end);
    final buf = _terminal.buffer;

    if (buf.isAltBuffer) {
      final ordered = _order(b, e);
      final range = BufferRangeLine(ordered.$1, ordered.$2);
      // 文本在这里取一次就定死了 —— 这正是"复制到的是当时看到的"的全部
      // 实现。拖拽中每次 updateDrag 都会重来一遍，因为用户是照着当前屏幕
      // 拖的，那时的屏幕才是他的意图。
      _state = _Frozen(b, e, buf.getText(range));
      _xterm.setFixedSelection(range);
    } else {
      final base = buf.createAnchorFromOffset(b);
      final ext = buf.createAnchorFromOffset(e);
      _state = _Anchored(base, ext, buf);
      _xterm.setSelection(base, ext, mode: SelectionMode.line);
    }
    notifyListeners();
  }

  /// 取选区文本。选区失效时返回 null（调用方据此提示"选区已失效"）。
  ///
  /// 冻结选区返回快照，**不回 buffer 现取** —— 现取就会拿到重绘后的新内容。
  String? readText() {
    final n = _normalized();
    if (n == null) return null;
    final s = _state;
    if (s is _Frozen) return s.text;
    return _terminal.buffer.getText(BufferRangeLine(n.$1, n.$2));
  }

  /// 开始拖拽 [which] 端。选区不活跃时不进入拖拽态。
  void beginDrag(SelectionEnd which) {
    if (!isActive) return;
    _dragging = which;
  }

  /// 拖拽中：把移动端挪到 [cell]，固定端原地不动。
  ///
  /// 固定端每次现取当前位置，不用拖拽开始时的快照 —— primary 里拖拽过程中
  /// 可能有新输出把内容整体上推，快照会让固定端相对文本漂移。
  ///
  /// 选区中途失效时整体退出，不留半截。
  void updateDrag(CellOffset cell) {
    final which = _dragging;
    if (which == null) return;
    final n = _normalized();
    if (n == null) {
      _dragging = null;
      clear();
      return;
    }
    // 拖起点就固定终点，反之亦然。越过对面端也没关系，_order 会重新排序。
    if (which == SelectionEnd.start) {
      _setRange(cell, n.$2);
    } else {
      _setRange(n.$1, cell);
    }
  }

  /// 结束拖拽。选区本身不变 —— 每次 updateDrag 都已经写进真相了。
  void endDrag() {
    _dragging = null;
  }

  /// 终端内容变动后检查选区是否还有效，失效就退出。
  ///
  /// 挂在 `Terminal` 的 ChangeNotifier 上，每次输出都会调。
  ///
  /// 各形态的结果：
  ///   • primary 追加新行（老行还在）→ anchor 存活 → 选区保持
  ///   • primary 里 scrollback 把选中的行挤出去 → detach → 退出
  ///   • primary ↔ alt 切换 → buffer 身份不符 → 退出
  ///   • alt 里 TUI 重绘（无论是替换行还是原地覆写）→ **选区保持**，
  ///     文本用的是冻结快照
  ///   • 键盘弹起收起 → primary 的 anchor 存活；alt 无 scrollback 不受影响
  void onTerminalChanged() {
    if (_state == null) return;
    if (_normalized() != null) return;
    clear();
  }

  /// 退出选区。不活跃时是空操作。
  void clear() {
    if (_state == null) return;
    _state = null;
    // clearSelection 同时清掉 anchor 与 fixed range 两种表示。
    _xterm.clearSelection();
    notifyListeners();
  }
}
