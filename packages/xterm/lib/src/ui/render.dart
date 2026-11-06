import 'dart:async';
import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_debug.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';

typedef EditableRectCallback = void Function(Rect rect, Rect caretRect);

class RenderTerminal extends RenderBox with RelayoutWhenSystemFontsChangeMixin {
  RenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool autoResize,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    required bool cursorBlink,
    required bool forceAppCursor,
    required bool legacyCursor,
    required bool alwaysShowCursor,
    EditableRectCallback? onEditableRect,
    String? composingText,
  })  : _terminal = terminal,
        _controller = controller,
        _offset = offset,
        _padding = padding,
        _autoResize = autoResize,
        _focusNode = focusNode,
        _cursorType = cursorType,
        _cursorBlink = cursorBlink,
        _forceAppCursor = forceAppCursor,
        _legacyCursor = legacyCursor,
        _alwaysShowCursor = alwaysShowCursor,
        _onEditableRect = onEditableRect,
        _composingText = composingText,
        _painter = TerminalPainter(
          theme: theme,
          textStyle: textStyle,
          textScaler: textScaler,
        );

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _resizeTerminalIfNeeded();
    markNeedsLayout();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    _resetCursorBlink();
    markNeedsPaint();
  }

  bool _cursorBlink;
  set cursorBlink(bool value) {
    if (value == _cursorBlink) return;
    _cursorBlink = value;
    _resetCursorBlink();
    markNeedsPaint();
  }

  bool _forceAppCursor;
  set forceAppCursor(bool value) {
    if (value == _forceAppCursor) return;
    _forceAppCursor = value;
    _resetCursorBlink();
    markNeedsPaint();
  }

  bool _legacyCursor;
  set legacyCursor(bool value) {
    if (value == _legacyCursor) return;
    _legacyCursor = value;
    _resetCursorBlink();
    markNeedsPaint();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    markNeedsPaint();
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    markNeedsLayout();
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    _resetCursorBlink();
    markNeedsPaint();
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  Timer? _cursorBlinkTimer;
  bool _cursorBlinkVisible = true;
  CellOffset? _lastBlinkCursorOffset;
  bool? _lastBlinkCursorVisibleMode;
  CellOffset? _lastForcedCursorCell;
  DateTime? _lastForcedCursorUntil;
  double? _lastLayoutHeight;
  DateTime? _resizeForceVisibleUntil;
  DateTime? _heightGrewScanUntil;

  var _stickToBottom = true;

  void _onScroll() {
    _stickToBottom = _scrollOffset >= _maxScrollExtent;
    // Scroll position changes only need a repaint: _paint() reads _offset.pixels
    // directly, so the new offset is visible at next paint without re-layout.
    // markNeedsLayout() here was costing ~3-8ms per jumpTo() call — 180-480ms/s
    // wasted on full layout passes during 60Hz scroll gestures.
    markNeedsPaint();
    _notifyEditableRect();
  }

  void _onFocusChange() {
    _resetCursorBlink();
    markNeedsPaint();
  }

  void _onTerminalChange() {
    final cursorOffset = CellOffset(
      _terminal.buffer.cursorX,
      _terminal.buffer.absoluteCursorY,
    );
    if (_lastBlinkCursorOffset != cursorOffset ||
        _lastBlinkCursorVisibleMode != _terminal.cursorVisibleMode) {
      _lastBlinkCursorOffset = cursorOffset;
      _lastBlinkCursorVisibleMode = _terminal.cursorVisibleMode;
      _resetCursorBlink();
    } else {
      _updateCursorBlinkTimer();
    }
    if (hasSize) {
      // Content-only change: update scroll extents directly instead of
      // triggering a full layout pass. performLayout() also calls
      // _updateViewportSize() (resizes terminal rows/cols) which is only
      // needed when the *widget size* changes — not when new lines arrive.
      // For mosh at 30fps this saves ~90-240ms/s of unnecessary layout work.
      final wasSticky = _stickToBottom;
      _updateScrollOffset();
      if (wasSticky) {
        _offset.correctBy(_maxScrollExtent - _scrollOffset);
        // correctBy is a layout-phase correction that does NOT fire _onScroll,
        // whereas the applyContentDimensions() inside _updateScrollOffset() may
        // have synchronously set _stickToBottom = false (old offset < new max).
        // We just pinned back to the bottom, so keep the flag in sync — else
        // the NEXT output batch reads a stale false and no longer follows the
        // live region (blank/"no output" after pinch-zoom resize).
        _stickToBottom = true;
      }
      markNeedsPaint();
    } else {
      markNeedsLayout();
    }
    _notifyEditableRect();
  }

  void _onControllerUpdate() {
    markNeedsLayout();
  }

  bool get _shouldBlinkCursor {
    if (!_cursorBlink) return false;
    if (_isComposingText) return false;
    if (!_terminal.cursorVisibleMode && !_usesAppCursorOverlay) return false;
    return _focusNode.hasFocus || _alwaysShowCursor;
  }

  bool get _usesAppCursorOverlay {
    return _forceAppCursor && _effectiveForcedCursorCell != null;
  }

  bool get _usesLegacyHiddenCursorFallback {
    return _legacyCursor &&
        !_forceAppCursor &&
        !_terminal.cursorVisibleMode &&
        _legacyHiddenCursorFallbackCell != null;
  }

  CellOffset? get _legacyHiddenCursorFallbackCell {
    if (!_legacyCursor || _forceAppCursor || _terminal.cursorVisibleMode) return null;
    if (_isLikelyClaudeInputCaret) {
      return CellOffset(_terminal.buffer.cursorX, _terminal.buffer.absoluteCursorY);
    }
    if (_isLikelyClaudeMenuActive) return null;
    final recovery = _heightGrewRecoveryCandidate;
    if (recovery != null) return recovery;
    if (_isResizeForceVisibleActive || _isHeightGrewScanActive) {
      final fallback = CellOffset(
        _terminal.buffer.cursorX,
        _terminal.buffer.absoluteCursorY,
      );
      if (_isCellInBuffer(fallback)) return fallback;
    }
    return _hiddenCaretCandidateNearPrompt;
  }

  bool get _blockBypassesBlink {
    return _cursorType == TerminalCursorType.block &&
        _usesAppCursorOverlay &&
        !_isLikelyClaudeMenuActive;
  }

  CellOffset? get _effectiveForcedCursorCell {
    final current = _forcedCursorCell;
    if (current != null) return current;
    if (_isResizeForceVisibleActive || _isHeightGrewScanActive) {
      final y = _terminal.buffer.absoluteCursorY;
      final x = _terminal.buffer.cursorX;
      if (_isCursorLikeCell(x, y)) return CellOffset(x, y);
    }
    if (!_forceAppCursor || _isLikelyClaudeMenuActive) return null;
    final recovery = _heightGrewRecoveryCandidate;
    if (recovery != null) return recovery;
    if (_isResizeForceVisibleActive) {
      final y = _terminal.buffer.absoluteCursorY;
      final x = _terminal.buffer.cursorX;
      final fallback = CellOffset(x, y);
      if (_isCellInBuffer(fallback)) return fallback;
    }
    final last = _lastForcedCursorCell;
    final until = _lastForcedCursorUntil;
    if (last == null || until == null || DateTime.now().isAfter(until)) return null;
    if (!_isCellInBuffer(last)) return null;
    return last;
  }

  bool get _isResizeForceVisibleActive {
    final until = _resizeForceVisibleUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  bool get _isHeightGrewScanActive {
    final until = _heightGrewScanUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  CellOffset? get _forcedCursorCell {
    if (!_forceAppCursor) return null;
    if (_isResizeForceVisibleActive || _isHeightGrewScanActive) {
      final y = _terminal.buffer.absoluteCursorY;
      final x = _terminal.buffer.cursorX;
      if (_isCursorLikeCell(x, y)) return CellOffset(x, y);
    }
    if (_terminal.cursorVisibleMode) {
      final y = _terminal.buffer.absoluteCursorY;
      final x = _terminal.buffer.cursorX;
      if (_isCursorLikeCell(x, y)) return CellOffset(x, y);
      return null;
    }
    if (_isLikelyClaudeInputCaret) {
      return CellOffset(_terminal.buffer.cursorX, _terminal.buffer.absoluteCursorY);
    }
    if (_isLikelyClaudeMenuActive) return null;
    return _hiddenCaretCandidateNearPrompt;
  }

  CellOffset? get _heightGrewRecoveryCandidate {
    final until = _heightGrewScanUntil;
    if (until == null || DateTime.now().isAfter(until)) return null;
    if (_terminal.cursorVisibleMode || _isLikelyClaudeMenuActive) return null;
    final lines = _terminal.buffer.lines;
    if (lines.length == 0) return null;

    final bottom = (_scrollOffset + size.height + _padding.bottom) ~/ _painter.cellSize.height;
    final lastRow = bottom.clamp(0, lines.length - 1);
    final firstRow = (lastRow - 20).clamp(0, lastRow);
    CellOffset? fallback;

    for (var row = lastRow; row >= firstRow; row--) {
      final line = lines[row];
      var runStart = -1;
      var runLength = 0;
      void flushRun() {
        if (runLength == 1 || runLength == 2) {
          fallback ??= CellOffset(runStart, row);
        }
        runStart = -1;
        runLength = 0;
      }

      for (var col = 0; col < line.length; col++) {
        final isCandidate = _isCursorLikeCell(col, row) &&
            !_isHighlightedMenuArrow(line, col);
        if (isCandidate) {
          if (runStart == -1) runStart = col;
          runLength++;
        } else if (runStart != -1) {
          flushRun();
        }
      }
      if (runStart != -1) flushRun();
      if (fallback != null) return fallback;
    }
    return null;
  }

  bool _isCursorLikeCell(int x, int y) {
    final lines = _terminal.buffer.lines;
    if (y < 0 || y >= lines.length || x < 0) return false;
    final line = lines[y];
    if (x >= line.length) return false;
    final attrs = line.getAttributes(x);
    final backgroundType = line.getBackground(x) & CellColor.typeMask;
    return attrs & CellAttr.inverse != 0 || backgroundType != CellColor.normal;
  }

  bool _isCellInBuffer(CellOffset cell) {
    final lines = _terminal.buffer.lines;
    if (cell.y < 0 || cell.y >= lines.length || cell.x < 0) return false;
    return cell.x < lines[cell.y].length;
  }

  void _rememberForcedCursorCell(CellOffset? cell, {Duration? ttl}) {
    if (cell == null || !_isCellInBuffer(cell)) return;
    _lastForcedCursorCell = cell;
    _lastForcedCursorUntil = DateTime.now().add(ttl ?? const Duration(milliseconds: 220));
  }

  /// Claude hides the terminal cursor for many transient UI states, not only
  /// the text input caret.  Drawing our app cursor whenever DECTCEM is hidden
  /// makes it appear on menus, arrows, and internal focus markers.  Only force
  /// the Flutter cursor when the hidden cursor is very likely Claude's input
  /// caret: an inverse cell on the bottom prompt line, with no highlighted menu
  /// arrow nearby.  Claude sometimes draws the block caret over a space and
  /// sometimes over the character under the editing cursor, so requiring an
  /// empty cell is too strict and lets the large block cursor leak through.
  bool get _isLikelyClaudeInputCaret {
    if (_terminal.cursorVisibleMode) return false;
    final y = _terminal.buffer.absoluteCursorY;
    final x = _terminal.buffer.cursorX;
    if (y < 0 || y >= _terminal.buffer.lines.length || x < 0) return false;
    // Claude's editable prompt sits at the bottom of the viewport.  Menus and
    // other transient focus markers can move the hidden cursor elsewhere.
    final bottom = _terminal.buffer.absoluteCursorY +
        (_terminal.viewHeight - _terminal.buffer.cursorY - 1);
    if (bottom - y > 2) return false;

    final line = _terminal.buffer.lines[y];
    if (x >= line.length) return false;
    final flags = line.getAttributes(x);
    final backgroundType = line.getBackground(x) & CellColor.typeMask;
    return flags & CellAttr.inverse != 0 || backgroundType != CellColor.normal;
  }

  Map<int, Set<int>> _cursorSuppressColumnsByLine(CellOffset? forcedCell) {
    final result = <int, Set<int>>{};
    if (forcedCell == null) return result;
    final lines = _terminal.buffer.lines;
    if (forcedCell.y < 0 || forcedCell.y >= lines.length) return result;
    final line = lines[forcedCell.y];
    if (forcedCell.x < 0 || forcedCell.x >= line.length) return result;
    final cols = result.putIfAbsent(forcedCell.y, () => <int>{});
    cols.add(forcedCell.x);
    if (line.getWidth(forcedCell.x) == 0 && forcedCell.x > 0) cols.add(forcedCell.x - 1);
    if (line.getWidth(forcedCell.x) == 2 && forcedCell.x + 1 < line.length) {
      cols.add(forcedCell.x + 1);
    }
    return result;
  }

  String _cursorDebugCellInfo(CellOffset cell) {
    final lines = _terminal.buffer.lines;
    if (cell.y < 0 || cell.y >= lines.length || cell.x < 0) return 'out';
    final line = lines[cell.y];
    if (cell.x >= line.length) return 'out';
    final attrs = line.getAttributes(cell.x);
    final bg = line.getBackground(cell.x) & CellColor.typeMask;
    final code = line.getCodePoint(cell.x);
    final width = line.getWidth(cell.x);
    final inv = attrs & CellAttr.inverse != 0 ? 'I' : '-';
    return 'c:$code w:$width a:$attrs $inv bg:$bg';
  }

  CellOffset? get _hiddenCaretCandidateNearPrompt {
    if (_terminal.cursorVisibleMode) return null;
    if (_isLikelyClaudeMenuActive) return null;
    final lines = _terminal.buffer.lines;
    if (lines.length == 0) return null;

    final y = _terminal.buffer.absoluteCursorY;
    if (y < 0 || y >= lines.length) return null;
    final bottom = _terminal.buffer.absoluteCursorY +
        (_terminal.viewHeight - _terminal.buffer.cursorY - 1);
    final lastRow = bottom.clamp(0, lines.length - 1);
    final firstRow = (lastRow - 4).clamp(0, lastRow);

    for (var row = firstRow; row <= lastRow; row++) {
      final line = lines[row];
      for (var col = 0; col < line.length; col++) {
        final attrs = line.getAttributes(col);
        final backgroundType = line.getBackground(col) & CellColor.typeMask;
        final hasBlockBackground = attrs & CellAttr.inverse != 0 ||
            backgroundType != CellColor.normal;
        if (!hasBlockBackground) continue;
        if (_isHighlightedMenuArrow(line, col)) continue;
        return CellOffset(col, row);
      }
    }
    return null;
  }

  /// Detect Claude-style option menus around the cursor.  While active, do not
  /// overlay the app cursor; Claude's highlighted arrow is the focus indicator.
  bool get _isLikelyClaudeMenuActive {
    final y = _terminal.buffer.absoluteCursorY;
    final x = _terminal.buffer.cursorX;
    if (y < 0 || y >= _terminal.buffer.lines.length || x < 0) return false;

    final firstLine = (y - 6).clamp(0, _terminal.buffer.lines.length - 1);
    final lastLine = (y + 6).clamp(0, _terminal.buffer.lines.length - 1);
    for (var row = firstLine; row <= lastLine; row++) {
      final line = _terminal.buffer.lines[row];
      final maxCol = line.length < 12 ? line.length : 12;
      for (var col = 0; col < maxCol; col++) {
        if (_isHighlightedMenuArrow(line, col)) return true;
      }
    }
    return false;
  }

  bool _isHighlightedMenuArrow(dynamic line, int x) {
    final code = line.getCodePoint(x);
    if (code != 0x203A && // ›
        code != 0x25B6 && // ▶
        code != 0x25B8 && // ▸
        code != 0x276F && // ❯
        code != 0x3E) { // >
      return false;
    }
    final flags = line.getAttributes(x);
    final backgroundType = line.getBackground(x) & CellColor.typeMask;
    return flags & CellAttr.inverse != 0 || backgroundType != CellColor.normal;
  }

  void _resetCursorBlink() {
    _cursorBlinkVisible = true;
    _updateCursorBlinkTimer();
  }

  void _updateCursorBlinkTimer() {
    _cursorBlinkTimer?.cancel();
    _cursorBlinkTimer = null;
    if (!attached || !_shouldBlinkCursor) {
      _cursorBlinkVisible = true;
      return;
    }
    _cursorBlinkTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!attached || !_shouldBlinkCursor) {
        _cursorBlinkTimer?.cancel();
        _cursorBlinkTimer = null;
        _cursorBlinkVisible = true;
        if (attached) markNeedsPaint();
        return;
      }
      _cursorBlinkVisible = !_cursorBlinkVisible;
      markNeedsPaint();
    });
  }

  @override
  final isRepaintBoundary = true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
    _resetCursorBlink();
  }

  @override
  void detach() {
    _cursorBlinkTimer?.cancel();
    _cursorBlinkTimer = null;
    _cursorBlinkVisible = true;
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    final previousHeight = _lastLayoutHeight;
    if (previousHeight != null && (previousHeight - size.height).abs() > 1) {
      _lastForcedCursorUntil = DateTime.now().add(const Duration(milliseconds: 450));
      _resizeForceVisibleUntil = DateTime.now().add(const Duration(milliseconds: 180));
      _cursorBlinkVisible = true;
      if (size.height > previousHeight) {
        _heightGrewScanUntil = DateTime.now().add(const Duration(milliseconds: 450));
      }
    }
    _lastLayoutHeight = size.height;

    _updateViewportSize();

    // Capture _stickToBottom before _updateScrollOffset, because
    // applyContentDimensions can fire notifyListeners → _onScroll synchronously
    // inside performLayout, setting _stickToBottom = false (old offset < new max)
    // before correctBy executes. Saving the pre-call value avoids the race.
    final wasSticky = _stickToBottom;
    _updateScrollOffset();

    if (wasSticky) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
      // Keep the sticky flag consistent with the offset we just pinned to the
      // bottom. correctBy does not fire _onScroll, and applyContentDimensions()
      // above may have flipped _stickToBottom to false (old offset < new max
      // when the font/viewport grew). Leaving it false detaches the viewport
      // from the live region on the next output → "no output" after resize.
      _stickToBottom = true;
    }
  }

  /// Total height of the terminal in pixels. Includes scrollback buffer.
  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  /// The distance from the top of the terminal to the top of the viewport.
  // double get _scrollOffset => _offset.pixels;
  double get _scrollOffset {
    // return _offset.pixels ~/ _painter.cellSize.height * _painter.cellSize.height;
    return _offset.pixels;
  }

  /// The height of a terminal line in pixels. This includes the line spacing.
  /// Height of the entire terminal is expected to be a multiple of this value.
  double get lineHeight => _painter.cellSize.height;

  /// Get the top-left corner of the cell at [cellOffset] in pixels.
  Offset getOffset(CellOffset cellOffset) {
    final row = cellOffset.y;
    final col = cellOffset.x;
    final x = col * _painter.cellSize.width;
    final y = row * _painter.cellSize.height;
    return Offset(x + _padding.left, y + _padding.top - _scrollOffset);
  }

  /// Get the [CellOffset] of the cell that [offset] is in.
  CellOffset getCellOffset(Offset offset) {
    final x = offset.dx - _padding.left;
    final y = offset.dy - _padding.top + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  /// Get a selection extent boundary for [offset].
  ///
  /// Unlike [getCellOffset], the x coordinate may be equal to
  /// [_terminal.viewWidth]. Selection ranges use an exclusive end boundary, so
  /// allowing this value is required to select through the last visible column.
  CellOffset getSelectionEndOffset(Offset offset) {
    final x = offset.dx - _padding.left;
    final y = offset.dy - _padding.top + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = (x / _painter.cellSize.width).ceil();
    return CellOffset(
      col.clamp(0, _terminal.viewWidth),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  /// Selects entire words in the terminal that contains [from] and [to].
  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = getCellOffset(from);
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = getCellOffset(to);
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  void selectCharacters(Offset from, [Offset? to]) {
    final fromPosition = getCellOffset(from);
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(fromPosition),
      );
    } else {
      var toPosition = getCellOffset(to);
      if (toPosition.x >= fromPosition.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(toPosition),
      );
    }
  }

  /// Send a mouse event at [offset] with [button] being currently in [buttonState].
  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset,
  ) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(button, buttonState, position);
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  /// Update the viewport size in cells based on the current widget size in
  /// pixels.
  void _updateViewportSize() {
    if (size <= _painter.cellSize) {
      return;
    }

    final viewportSize = TerminalSize(
      size.width ~/ _painter.cellSize.width,
      _viewportHeight ~/ _painter.cellSize.height,
    );

    if (_viewportSize != viewportSize) {
      _viewportSize = viewportSize;
      _resizeTerminalIfNeeded();
    }
  }

  /// Notify the underlying terminal that the viewport size has changed.
  void _resizeTerminalIfNeeded() {
    if (_autoResize && _viewportSize != null) {
      _terminal.resize(
        _viewportSize!.width,
        _viewportSize!.height,
        _painter.cellSize.width.round(),
        _painter.cellSize.height.round(),
      );
    }
  }

  /// Update the scroll offset based on the current terminal state. This should
  /// be called in [performLayout] after the viewport size has been updated.
  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText {
    return _composingText != null && _composingText!.isNotEmpty;
  }

  bool get _shouldShowCursor {
    if (!(_terminal.cursorVisibleMode ||
        _usesAppCursorOverlay ||
        _usesLegacyHiddenCursorFallback ||
        _alwaysShowCursor ||
        _isComposingText)) {
      return false;
    }
    if (_blockBypassesBlink) {
      return true;
    }
    return !_shouldBlinkCursor || _cursorBlinkVisible;
  }

  double get _viewportHeight {
    return size.height - _padding.vertical;
  }

  double get _maxScrollExtent {
    return max(_terminalHeight - _viewportHeight, 0.0);
  }

  double get _lineOffset {
    return -_scrollOffset + _padding.top;
  }

  /// The offset of the cursor from the top left corner of this render object.
  Offset get cursorOffset {
    return Offset(
      _terminal.buffer.cursorX * _painter.cellSize.width,
      _terminal.buffer.absoluteCursorY * _painter.cellSize.height + _lineOffset,
    );
  }

  Size get cellSize {
    return _painter.cellSize;
  }

  /// Current scroll offset in pixels (for diagnostic use).
  double get scrollPixels => _scrollOffset;

  /// Last known viewport in cells.  Updated whenever the widget receives a
  /// new layout constraint via `_updateViewportSize`.  Hosts that disable
  /// `autoResize` use this to drive their own `terminal.resize(...)` calls.
  TerminalSize? get viewportSize => _viewportSize;

  @override
  void paint(PaintingContext context, Offset offset) {
    _paint(context, offset);
    context.setWillChangeHint();
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;

    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;

    final firstLineOffset = _scrollOffset - _padding.top;
    final lastLineOffset = _scrollOffset + size.height + _padding.bottom;

    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;

    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);

    // Claude's no-flicker mode hides the real terminal cursor and paints a
    // block cursor as an inverse cell.  Keep suppressing that inverse cell even
    // while our Flutter cursor is in its blink-off phase; otherwise the blink
    // alternates between our thin cursor and Claude's wide block cursor.
    final currentForcedCursorCell = _forcedCursorCell;
    final recoveryCursorCell = _heightGrewRecoveryCandidate;
    final legacyFallbackCell = _legacyHiddenCursorFallbackCell;
    if (_isLikelyClaudeMenuActive) {
      _lastForcedCursorCell = null;
      _lastForcedCursorUntil = null;
    } else {
      _rememberForcedCursorCell(currentForcedCursorCell);
    }
    final forcedCursorCell = _effectiveForcedCursorCell;
    final suppressInverseColumnsByLine = _cursorSuppressColumnsByLine(forcedCursorCell);
    final suppressCellCount = suppressInverseColumnsByLine.values
        .fold<int>(0, (sum, cols) => sum + cols.length);

    cursorDebug
      ..type = _cursorType
      ..cursorVisibleMode = _terminal.cursorVisibleMode
      ..forceAppCursor = _forceAppCursor
      ..legacyCursor = _legacyCursor
      ..usesOverlay = _usesAppCursorOverlay
      ..shouldShow = _shouldShowCursor
      ..blinkVisible = _cursorBlinkVisible
      ..menuActive = _isLikelyClaudeMenuActive
      ..resizeForce = _isResizeForceVisibleActive
      ..heightGrewScan = _isHeightGrewScanActive
      ..blockBypassBlink = _blockBypassesBlink
      ..composing = _isComposingText
      ..hasFocus = _focusNode.hasFocus
      ..cursorX = _terminal.buffer.cursorX
      ..cursorY = _terminal.buffer.cursorY
      ..absoluteCursorY = _terminal.buffer.absoluteCursorY
      // For defaultStyle/legacyCursor this field shows the fallback cell too,
      // so screenshots can prove whether the default-only hidden-cursor path is
      // active. Custom styles still use forcedCursorCell above.
      ..forcedCell = forcedCursorCell ?? legacyFallbackCell
      ..currentCell = currentForcedCursorCell
      ..recoveryCell = recoveryCursorCell
      ..lastCell = _lastForcedCursorCell
      ..source = forcedCursorCell != null
          ? forcedCursorCell == currentForcedCursorCell
              ? 'current'
              : forcedCursorCell == recoveryCursorCell
                  ? 'recovery'
                  : forcedCursorCell == _lastForcedCursorCell
                      ? 'last'
                      : 'fallback'
          : legacyFallbackCell != null
              ? 'legacy'
              : '--'
      ..terminalCellInfo = _cursorDebugCellInfo(
        CellOffset(_terminal.buffer.cursorX, _terminal.buffer.absoluteCursorY),
      )
      ..forcedCellInfo = (forcedCursorCell ?? legacyFallbackCell) == null
          ? '--'
          : _cursorDebugCellInfo((forcedCursorCell ?? legacyFallbackCell)!)
      ..currentCellInfo = currentForcedCursorCell == null
          ? '--'
          : _cursorDebugCellInfo(currentForcedCursorCell)
      ..recoveryCellInfo = recoveryCursorCell == null
          ? '--'
          : _cursorDebugCellInfo(recoveryCursorCell)
      ..lastCellInfo = _lastForcedCursorCell == null
          ? '--'
          : _cursorDebugCellInfo(_lastForcedCursorCell!)
      ..suppressLineCount = suppressInverseColumnsByLine.length
      ..suppressCellCount = suppressCellCount;

    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLine(
        canvas,
        offset.translate(0, (i * charHeight + _lineOffset).truncateToDouble()),
        lines[i],
        suppressInverseColumns: suppressInverseColumnsByLine[i],
      );
    }

    final visualCursorCell = forcedCursorCell ?? legacyFallbackCell;
    final visualCursorY = visualCursorCell?.y ?? _terminal.buffer.absoluteCursorY;
    if (visualCursorY >= effectFirstLine && visualCursorY <= effectLastLine) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + cursorOffset);
      }

      if (_shouldShowCursor) {
        final paintCursorOffset = visualCursorCell != null
            ? Offset(
                visualCursorCell.x * _painter.cellSize.width,
                visualCursorCell.y * _painter.cellSize.height + _lineOffset,
              )
            : cursorOffset;
        if (_legacyCursor) {
          final legacyCell = visualCursorCell ??
              CellOffset(_terminal.buffer.cursorX, _terminal.buffer.absoluteCursorY);
          _painter.paintLegacyCursor(
            canvas,
            offset + paintCursorOffset,
            line: legacyCell.y >= 0 && legacyCell.y < lines.length
                ? lines[legacyCell.y]
                : null,
            column: legacyCell.x,
            hasFocus: _focusNode.hasFocus,
          );
        } else {
          _painter.paintCursor(
            canvas,
            offset + paintCursorOffset,
            cursorType: _cursorType,
            hasFocus: _focusNode.hasFocus,
          );
        }
      }
    }

    _paintHighlights(
      canvas,
      offset,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );

    if (_controller.selection != null) {
      _paintSelection(
        canvas,
        offset,
        _controller.selection!,
        effectFirstLine,
        effectLastLine,
      );
    }
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(
      style.getTextStyle(textScaler: _painter.textScaler),
    );
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: size.width));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
  }

  void _paintSelection(
    Canvas canvas,
    Offset paintOffset,
    BufferRange selection,
    int firstLine,
    int lastLine,
  ) {
    for (final segment in selection.toSegments()) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }

      if (segment.line < firstLine) {
        continue;
      }

      if (segment.line > lastLine) {
        break;
      }

      _paintSegment(canvas, paintOffset, segment, _painter.theme.selection);
    }
  }

  void _paintHighlights(
    Canvas canvas,
    Offset paintOffset,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (var highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (var segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(canvas, paintOffset, segment, highlight.color);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _paintSegment(
    Canvas canvas,
    Offset paintOffset,
    BufferSegment segment,
    Color color,
  ) {
    final start = segment.start ?? 0;
    final end = segment.end ?? _terminal.viewWidth;

    final startOffset = paintOffset +
        Offset(
          start * _painter.cellSize.width,
          segment.line * _painter.cellSize.height + _lineOffset,
        );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }
}
