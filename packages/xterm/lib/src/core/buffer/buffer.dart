import 'dart:math' show max, min;

import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/charset.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/core/reflow.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/utils/circular_buffer.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

class Buffer {
  final TerminalState terminal;

  final int maxLines;

  final bool isAltBuffer;

  /// Characters that break selection when calling [getWordBoundary]. If null,
  /// defaults to [defaultWordSeparators].
  final Set<int>? wordSeparators;

  Buffer(
    this.terminal, {
    required this.maxLines,
    required this.isAltBuffer,
    this.wordSeparators,
  }) {
    for (int i = 0; i < terminal.viewHeight; i++) {
      lines.push(_newEmptyLine());
    }

    resetVerticalMargins();
  }

  int _cursorX = 0;

  int _cursorY = 0;

  late int _marginTop;

  late int _marginBottom;

  var _savedCursorX = 0;

  var _savedCursorY = 0;

  /// 上一次 CUU（光标上移）想上移、却被视口顶部挡住的行数。
  ///
  /// ink / Claude Code 这类 TUI 重绘一帧的动作是：`CUU(帧高−1)` 回到帧首 →
  /// `\x1b[J` 擦到屏幕末尾 → 重画整帧。而 [setCursorY] 是
  /// `clamp(0, viewHeight−1)` —— 光标上移到视口第 0 行就停住，不会退进
  /// scrollback。这是正确的 VT 行为，真实终端也一样。
  ///
  /// 于是当**帧高超过视口高**时（手机上键盘一弹，视口只剩二十来行，一条带
  /// 表格代码块的长回复必然超过）：应用少上移了「帧高 − 视口高」行，以为回
  /// 到了帧首、实际停在帧中间；`\x1b[J` 只擦得到光标以下，帧的上半截原样留
  /// 着；应用又完整重画一遍，那一截就成了重复，且每次 SIGWINCH 累积一份。
  ///
  /// 这个字段记下那个差额，由 [eraseDisplayFromCursor] 消费：擦除前把紧邻视
  /// 口上方的这些行删掉 —— 那正是应用以为自己会擦掉、实际没擦到的部分。
  ///
  /// **这是协议层的意图信号，不是文本比对**，所以不会把用户真实的重复内容
  /// （连着敲两次同样的命令、刷屏日志里相邻的相同行）误删。
  ///
  /// 只要 CUU 与 ED 之间插进任何写入或绝对定位，就说明这不是一次全帧重绘，
  /// 欠账立即作废。
  int _cuuDebt = 0;

  final _savedCursorStyle = CursorStyle();

  final charset = Charset();

  /// Width of the viewport in columns. Also the index of the last column.
  int get viewWidth => terminal.viewWidth;

  /// Height of the viewport in rows. Also the index of the last line.
  int get viewHeight => terminal.viewHeight;

  /// lines of the buffer. the length of [lines] should always be equal or
  /// greater than [viewHeight].
  late final lines = IndexAwareCircularBuffer<BufferLine>(maxLines);

  /// Total number of lines in the buffer. Always equal or greater than
  /// [viewHeight].
  int get height => lines.length;

  /// Horizontal position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorX => _cursorX.clamp(0, terminal.viewWidth - 1);

  /// Vertical position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorY => _cursorY;

  /// Index of the first line in the scroll region.
  int get marginTop => _marginTop;

  /// Index of the last line in the scroll region.
  int get marginBottom => _marginBottom;

  /// The number of lines above the viewport.
  int get scrollBack => height - viewHeight;

  /// Vertical position of the cursor relative to the top of the buffer,
  /// starting from 0.
  int get absoluteCursorY => _cursorY + scrollBack;

  /// Absolute index of the first line in the scroll region.
  int get absoluteMarginTop => _marginTop + scrollBack;

  /// Absolute index of the last line in the scroll region.
  int get absoluteMarginBottom => _marginBottom + scrollBack;

  /// Inserts [extraLines] directly into the scrollback region, just above the
  /// viewport.  Use this to inject pre-rendered content without writing blank
  /// separator lines between the injected content and the live viewport.
  void insertScrollbackLines(List<BufferLine> extraLines) {
    lines.insertAll(scrollBack, extraLines);
  }

  /// Writes data to the _terminal. Terminal sequences or special characters are
  /// not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.write]
  void write(String text) {
    for (var char in text.runes) {
      writeChar(char);
    }
  }

  /// Writes a single character to the _terminal. Escape sequences or special
  /// characters are not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.writeChar]
  void writeChar(int codePoint) {
    // 写入意味着这不是「CUU 紧跟 ED」的全帧重绘模式，欠账作废。
    _cuuDebt = 0;
    codePoint = charset.translate(codePoint);

    final cellWidth = unicodeV11.wcwidth(codePoint);
    if (_cursorX >= terminal.viewWidth) {
      index();
      setCursorX(0);
      if (terminal.autoWrapMode) {
        currentLine.isWrapped = true;
      }
    }

    final line = currentLine;
    line.setCell(_cursorX, codePoint, cellWidth, terminal.cursor);

    if (_cursorX < viewWidth) {
      _cursorX++;
    }

    if (cellWidth == 2) {
      writeChar(0);
    }
  }

  /// The line at the current cursor position.
  BufferLine get currentLine {
    return lines[absoluteCursorY];
  }

  void backspace() {
    if (_cursorX == 0 && currentLine.isWrapped) {
      currentLine.isWrapped = false;
      moveCursor(viewWidth - 1, -1);
    } else if (_cursorX == viewWidth) {
      moveCursor(-2, 0);
    } else {
      moveCursor(-1, 0);
    }
  }

  /// Erases the viewport from the cursor position to the end of the buffer,
  /// including the cursor position.
  void eraseDisplayFromCursor() {
    // 紧跟在越界 CUU 之后的 ED，就是「回帧首 → 擦干净 → 重画」这个重绘模式。
    // 应用以为自己擦掉了整帧，实际漏掉了滚出视口的那一截 —— 在这里替它擦掉。
    _consumeCuuDebt();
    eraseLineFromCursor();

    for (var i = absoluteCursorY + 1; i < height; i++) {
      final line = lines[i];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
  }

  /// Erases the viewport from the top-left corner to the cursor, including the
  /// cursor.
  void eraseDisplayToCursor() {
    eraseLineToCursor();

    for (var i = 0; i < _cursorY; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
  }

  /// Erases the whole viewport.
  void eraseDisplay() {
    for (var i = 0; i < viewHeight; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
  }

  /// Erases the line from the cursor to the end of the line, including the
  /// cursor position.
  void eraseLineFromCursor() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(_cursorX, viewWidth, terminal.cursor);
  }

  /// Erases the line from the start of the line to the cursor, including the
  /// cursor.
  void eraseLineToCursor() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(0, _cursorX, terminal.cursor);
  }

  /// Erases the line at the current cursor position.
  void eraseLine() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(0, viewWidth, terminal.cursor);
  }

  /// Erases [count] cells starting at the cursor position.
  void eraseChars(int count) {
    final start = _cursorX;
    currentLine.eraseRange(start, start + count, terminal.cursor);
  }

  void scrollDown(int lines) {
    for (var i = absoluteMarginBottom; i >= absoluteMarginTop; i--) {
      if (i >= absoluteMarginTop + lines) {
        this.lines[i] = this.lines[i - lines];
      } else {
        this.lines[i] = _newEmptyLine();
      }
    }
  }

  void scrollUp(int lines) {
    // Main buffer with full-screen scroll region: use push() so that scrolled-off
    // lines accumulate in the scrollback buffer (same as index() does for \n).
    // This makes CSI-S-based scrolling (e.g. mosh) behave identically to
    // linefeed-based scrolling for the purpose of user scrollback.
    if (!isAltBuffer && marginTop == 0 && marginBottom == viewHeight - 1) {
      for (var i = 0; i < lines; i++) {
        _pushNewBottomAndDedup();
      }
      return;
    }
    // Alt buffer or custom scroll region: in-place shift (no scrollback).
    for (var i = absoluteMarginTop; i <= absoluteMarginBottom; i++) {
      if (i <= absoluteMarginBottom - lines) {
        this.lines[i] = this.lines[i + lines];
      } else {
        this.lines[i] = _newEmptyLine();
      }
    }
  }

  /// Push a fresh empty line at the bottom of the buffer (the standard "scroll
  /// up by one and grow scrollback" operation), then optionally drop the line
  /// that just transitioned from the top of the viewport into scrollback if it
  /// is a duplicate of one of the most recent scrollback lines.
  ///
  /// Dedup is gated by [TerminalState.dedupRecentPushes] (the public flag on
  /// [Terminal]); when 0 (the default), this is just a plain `lines.push` of a
  /// new empty line. The actual comparison window is the current viewport
  /// height — this catches same-snapshot rerenders (e.g. Claude Code rewriting
  /// its visible chat each token) without removing genuinely older content. As
  /// new content appends and the chat grows past the viewport, the earlier
  /// overflow lines fall outside the window and remain in scrollback, so the
  /// user has unique history to scroll into.
  ///
  /// Only the primary buffer participates — the alt buffer never reaches this
  /// path because [scrollUp] uses an in-place shift there and [index]'s push
  /// branch is only taken when `!isAltBuffer`.
  void _pushNewBottomAndDedup() {
    lines.push(_newEmptyLine());
    final dedupN = terminal.dedupRecentPushes;
    if (dedupN <= 0) return;
    if (isAltBuffer) return; // safety — alt buffer should never reach here
    final sb = scrollBack;
    if (sb < 2) return; // need at least one prior scrollback line to compare
    // The line that just transitioned into scrollback sits at index sb-1.
    final transitioned = lines[sb - 1];
    final transitionedText = transitioned.getText();
    // Comparison window = current viewport height. dedupRecentPushes acts as a
    // simple on/off gate (0 = disabled, >0 = enabled). This way unique chat
    // history accumulates in scrollback even when a TUI app rerenders its
    // visible portion every frame: only lines within the most recent viewport
    // worth of scrollback are eligible for dedup against the new push.
    final dedupWindow = viewHeight;
    final start = (sb - 1 - dedupWindow).clamp(0, sb - 1);
    // Blank lines: only dedup against the IMMEDIATELY preceding scrollback
    // line.  This preserves intentional paragraph spacing (blank between
    // distinct sections) while collapsing the runs of blanks that Claude's
    // per-token frame redraws push out — every frame of a tall-but-mostly-
    // empty Claude UI ends up shoving the same blank padding rows into
    // scrollback, and without this the user's history grows by hundreds of
    // identical blanks per minute of streaming.
    if (transitionedText.trim().isEmpty) {
      if (lines[sb - 2].getText().trim().isEmpty) {
        lines.remove(sb - 1);
      }
      return;
    }
    for (int i = sb - 2; i >= start; i--) {
      if (lines[i].getText() == transitionedText) {
        // Drop the just-added duplicate from scrollback. lines.remove shifts
        // viewport lines (sb..height-1) up by one; cursor uses viewport-
        // relative _cursorY so it stays correct.
        lines.remove(sb - 1);
        return;
      }
    }
  }

  /// https://vt100.net/docs/vt100-ug/chapter3.html#IND IND – Index
  ///
  /// ESC D
  ///
  /// [index] causes the active position to move downward one line without
  /// changing the column position. If the active position is at the bottom
  /// margin, a scroll up is performed.
  void index() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginBottom) {
        if (marginTop == 0 && !isAltBuffer) {
          // marginTop==0 with full-bottom margin => insert at end is push().
          // When the configured margin extends to viewHeight-1 we route through
          // the dedup helper; for partial margins (rare) keep the legacy insert
          // so the in-place semantics remain undisturbed.
          if (marginBottom == viewHeight - 1) {
            _pushNewBottomAndDedup();
          } else {
            lines.insert(absoluteMarginBottom + 1, _newEmptyLine());
          }
        } else {
          scrollUp(1);
        }
      } else {
        moveCursorY(1);
      }
      return;
    }

    // the cursor is not in the scrollable region
    if (_cursorY >= viewHeight - 1) {
      // we are at the bottom
      if (isAltBuffer) {
        scrollUp(1);
      } else {
        _pushNewBottomAndDedup();
      }
    } else {
      // there're still lines so we simply move cursor down.
      moveCursorY(1);
    }
  }

  void lineFeed() {
    index();
    if (terminal.lineFeedMode) {
      setCursorX(0);
    }
  }

  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  void reverseIndex() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginTop) {
        scrollDown(1);
      } else {
        moveCursorY(-1);
      }
    } else {
      moveCursorY(-1);
    }
  }

  void cursorGoForward() {
    _cursorX = min(_cursorX + 1, viewWidth);
  }

  void setCursorX(int cursorX) {
    _cursorX = cursorX.clamp(0, viewWidth - 1);
  }

  void setCursorY(int cursorY) {
    _cursorY = cursorY.clamp(0, viewHeight - 1);
  }

  void moveCursorX(int offset) {
    setCursorX(_cursorX + offset);
  }

  void moveCursorY(int offset) {
    // 只有向上移动才可能被视口顶部挡住。alt buffer 没有 scrollback，被挡住
    // 是它的正常语义，不记欠账。
    if (offset < 0 && !isAltBuffer) {
      final target = _cursorY + offset;
      _cuuDebt = target < 0 ? -target : 0;
    } else {
      _cuuDebt = 0;
    }
    setCursorY(_cursorY + offset);
  }

  /// 消费 [_cuuDebt]：把紧邻视口上方的欠账行从缓冲区删掉。
  ///
  /// 删除而不是清空内容 —— 应用接下来会把它们重新画出来，清空只会留下一段
  /// 空行。
  ///
  /// [isAltBuffer] 那个判断是**冗余的第二道闸**：alt 的 [index] 走
  /// `scrollUp(1)`，而 alt 下 [scrollUp] 是原地平移不 push，所以 alt 的
  /// `lines.length` 恒等于 `viewHeight`、[scrollBack] 恒为 0，下面的
  /// `sb <= 0` 已经拦住了。保留它是为了让「alt 不参与补擦」这个意图显式，
  /// 万一哪天 alt 允许了 scrollback，这里的语义不会跟着悄悄改变。
  void _consumeCuuDebt() {
    final debt = _cuuDebt;
    _cuuDebt = 0;
    if (debt <= 0 || isAltBuffer) return;
    final sb = scrollBack;
    if (sb <= 0) return;
    final count = debt < sb ? debt : sb;
    lines.remove(sb - count, count);
  }

  void setCursor(int cursorX, int cursorY) {
    // 绝对定位（CUP/HVP）不是相对重绘，欠账作废。注意不要在 [setCursorY] 里
    // 清 —— 那会把 [moveCursorY] 刚记下的欠账立刻抹掉。
    _cuuDebt = 0;
    var maxCursorY = viewHeight - 1;

    if (terminal.originMode) {
      cursorY += _marginTop;
      maxCursorY = _marginBottom;
    }

    _cursorX = cursorX.clamp(0, viewWidth - 1);
    _cursorY = cursorY.clamp(0, maxCursorY);
  }

  void moveCursor(int offsetX, int offsetY) {
    final cursorX = _cursorX + offsetX;
    final cursorY = _cursorY + offsetY;
    setCursor(cursorX, cursorY);
  }

  /// Save cursor position, charmap and text attributes.
  void saveCursor() {
    _savedCursorX = _cursorX;
    _savedCursorY = _cursorY;
    _savedCursorStyle.foreground = terminal.cursor.foreground;
    _savedCursorStyle.background = terminal.cursor.background;
    _savedCursorStyle.attrs = terminal.cursor.attrs;
    charset.save();
  }

  /// Restore cursor position, charmap and text attributes.
  void restoreCursor() {
    _cursorX = _savedCursorX;
    _cursorY = _savedCursorY;
    terminal.cursor.foreground = _savedCursorStyle.foreground;
    terminal.cursor.background = _savedCursorStyle.background;
    terminal.cursor.attrs = _savedCursorStyle.attrs;
    charset.restore();
  }

  /// Sets the vertical scrolling margin to [top] and [bottom].
  /// Both values must be between 0 and [viewHeight] - 1.
  void setVerticalMargins(int top, int bottom) {
    _marginTop = top.clamp(0, viewHeight - 1);
    _marginBottom = bottom.clamp(0, viewHeight - 1);

    _marginTop = min(_marginTop, _marginBottom);
    _marginBottom = max(_marginTop, _marginBottom);
  }

  bool get isInVerticalMargin {
    return _cursorY >= _marginTop && _cursorY <= _marginBottom;
  }

  void resetVerticalMargins() {
    setVerticalMargins(0, viewHeight - 1);
  }

  void deleteChars(int count) {
    final start = _cursorX.clamp(0, viewWidth);
    count = min(count, viewWidth - start);
    currentLine.removeCells(start, count, terminal.cursor);
  }

  /// Remove all lines above the top of the viewport.
  void clearScrollback() {
    if (height <= viewHeight) {
      return;
    }

    lines.trimStart(scrollBack);
  }

  /// Clears the viewport and scrollback buffer. Then fill with empty lines.
  void clear() {
    lines.clear();
    for (int i = 0; i < viewHeight; i++) {
      lines.push(_newEmptyLine());
    }
  }

  void insertBlankChars(int count) {
    currentLine.insertCells(_cursorX, count, terminal.cursor);
  }

  void insertLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    // Number of lines from the cursor to the bottom of the scrollable region
    // including the cursor itself.
    final linesBelow = absoluteMarginBottom - absoluteCursorY + 1;

    // Number of empty lines to insert.
    final linesToInsert = min(count, linesBelow);

    // Number of lines to move up.
    final linesToMove = linesBelow - linesToInsert;

    for (var i = 0; i < linesToMove; i++) {
      final index = absoluteMarginBottom - i;
      lines[index] = lines.swap(index - linesToInsert, _newEmptyLine());
    }

    for (var i = linesToMove; i < linesToInsert; i++) {
      lines[absoluteCursorY + i] = _newEmptyLine();
    }
  }

  /// Remove [count] lines starting at the current cursor position. Lines below
  /// the removed lines are shifted up. This only affects the scrollable region.
  /// Lines outside the scrollable region are not affected.
  void deleteLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    count = min(count, absoluteMarginBottom - absoluteCursorY + 1);

    final linesToMove = absoluteMarginBottom - absoluteCursorY + 1 - count;

    for (var i = 0; i < linesToMove; i++) {
      final index = absoluteCursorY + i;
      lines[index] = lines[index + count];
    }

    for (var i = 0; i < count; i++) {
      lines[absoluteMarginBottom - i] = _newEmptyLine();
    }
  }

  void resize(int oldWidth, int oldHeight, int newWidth, int newHeight) {
    // 1. Adjust the height.
    if (newHeight > oldHeight) {
      // Grow larger
      for (var i = 0; i < newHeight - oldHeight; i++) {
        if (newHeight > lines.length) {
          lines.push(_newEmptyLine(newWidth));
        } else {
          _cursorY++;
        }
      }
    } else {
      // Shrink smaller
      for (var i = 0; i < oldHeight - newHeight; i++) {
        final canYield =
            isAltBuffer ? (_cursorY > newHeight - 1) : (_cursorY > 0);
        if (canYield) {
          _cursorY--;
        } else {
          lines.pop();
        }
      }
    }

    // Ensure cursor is within the screen.
    _cursorX = _cursorX.clamp(0, newWidth - 1);
    _cursorY = _cursorY.clamp(0, newHeight - 1);

    // 2. Adjust the width.
    if (newWidth != oldWidth) {
      if (terminal.reflowEnabled && !isAltBuffer) {
        final reflowResult = reflow(lines, oldWidth, newWidth);

        while (reflowResult.length < newHeight) {
          reflowResult.add(_newEmptyLine(newWidth));
        }

        lines.replaceWith(reflowResult);
      } else {
        lines.forEach((item) => item.resize(newWidth));
      }
    }
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchor(int x, int y) {
    return lines[y].createAnchor(x);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchorFromOffset(CellOffset offset) {
    return lines[offset.y].createAnchor(offset.x);
  }

  CellAnchor createAnchorFromCursor() {
    return createAnchor(cursorX, absoluteCursorY);
  }

  /// Create a new empty [BufferLine] with the current [viewWidth] if [width]
  /// is not specified.
  BufferLine _newEmptyLine([int? width]) {
    final line = BufferLine(width ?? viewWidth);
    return line;
  }

  static final defaultWordSeparators = <int>{
    0,
    r' '.codeUnitAt(0),
    r'.'.codeUnitAt(0),
    r':'.codeUnitAt(0),
    r'-'.codeUnitAt(0),
    r'\'.codeUnitAt(0),
    r'"'.codeUnitAt(0),
    r'*'.codeUnitAt(0),
    r'+'.codeUnitAt(0),
    r'/'.codeUnitAt(0),
    r'\'.codeUnitAt(0),
  };

  BufferRangeLine? getWordBoundary(CellOffset position) {
    var separators = wordSeparators ?? defaultWordSeparators;
    if (position.y >= lines.length) {
      return null;
    }

    var line = lines[position.y];
    var start = position.x;
    var end = position.x;

    do {
      if (start == 0) {
        break;
      }
      final char = line.getCodePoint(start - 1);
      if (separators.contains(char)) {
        break;
      }
      start--;
    } while (true);

    do {
      if (end >= viewWidth) {
        break;
      }
      final char = line.getCodePoint(end);
      if (separators.contains(char)) {
        break;
      }
      end++;
    } while (true);

    if (start == end) {
      return null;
    }

    return BufferRangeLine(
      CellOffset(start, position.y),
      CellOffset(end, position.y),
    );
  }

  /// Get the plain text content of the buffer including the scrollback.
  /// Accepts an optional [range] to get a specific part of the buffer.
  String getText([BufferRange? range]) {
    range ??= BufferRangeLine(
      CellOffset(0, 0),
      CellOffset(viewWidth - 1, height - 1),
    );

    range = range.normalized;

    final builder = StringBuffer();

    for (var segment in range.toSegments()) {
      if (segment.line < 0 || segment.line >= height) {
        continue;
      }
      final line = lines[segment.line];
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          line.isWrapped)) {
        builder.write("\n");
      }
      builder.write(line.getText(segment.start, segment.end));
    }

    return builder.toString();
  }

  /// Returns a debug representation of the buffer.
  @override
  String toString() {
    final builder = StringBuffer();
    final lineNumberLength = lines.length.toString().length;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      builder.write('${i.toString().padLeft(lineNumberLength)}: |${lines[i]}|');

      if (line.isWrapped) {
        builder.write(' (⏎)');
      }

      builder.write('\n');
    }

    return builder.toString();
  }
}
