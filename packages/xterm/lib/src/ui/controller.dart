import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:xterm/src/base/disposable.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_block.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalController with ChangeNotifier {
  TerminalController({
    SelectionMode selectionMode = SelectionMode.line,
    PointerInputs pointerInputs = const PointerInputs({PointerInput.tap}),
    bool suspendPointerInput = false,
  })  : _selectionMode = selectionMode,
        _pointerInputs = pointerInputs,
        _suspendPointerInputs = suspendPointerInput;

  CellAnchor? _selectionBase;
  CellAnchor? _selectionExtent;

  SelectionMode get selectionMode => _selectionMode;
  SelectionMode _selectionMode;

  /// The set of pointer events which will be used as mouse input for the terminal.
  PointerInputs get pointerInput => _pointerInputs;
  PointerInputs _pointerInputs;

  /// True if sending pointer events to the terminal is suspended.
  bool get suspendedPointerInputs => _suspendPointerInputs;
  bool _suspendPointerInputs;

  List<TerminalHighlight> get highlights => _highlights;
  final _highlights = <TerminalHighlight>[];

  BufferRange? _fixedSelection;

  /// A selection whose truth IS its coordinates, not a pair of anchors.
  ///
  /// Needed for the alternate buffer: there is no scrollback there, the screen
  /// is a fixed N rows, so a cell coordinate is stable by construction — while
  /// the *content* at that coordinate is repainted constantly by whatever TUI
  /// is running. Anchors are the wrong tool for that shape: they survive
  /// content changes only when the line objects survive, and a full-screen
  /// redraw replaces them, which would drop the selection several times a
  /// second.
  ///
  /// Callers must treat this and [setSelection] as **mutually exclusive** —
  /// setting either one clears the other. This is the discipline that the
  /// earlier `selectionOverride` field lacked: that one coexisted with live
  /// anchors as a "fallback", so the same selection had two representations
  /// and they drifted apart. Here there is exactly one representation at any
  /// moment, chosen by which buffer the selection lives in.
  void setFixedSelection(BufferRange? range) {
    if (range != null) {
      _selectionBase?.dispose();
      _selectionBase = null;
      _selectionExtent?.dispose();
      _selectionExtent = null;
    }
    _fixedSelection = range;
    notifyListeners();
  }

  BufferRange? get selection {
    final fixed = _fixedSelection;
    if (fixed != null) return fixed;

    final base = _selectionBase;
    final extent = _selectionExtent;

    if (base == null || extent == null) {
      return null;
    }

    if (!base.attached || !extent.attached) {
      return null;
    }

    return _createRange(base.offset, extent.offset);
  }

  /// Set selection on the terminal from [base] to [extent]. This method takes
  /// the ownership of [base] and [extent] and will dispose them when the
  /// selection is cleared or changed.
  ///
  /// Clears any [setFixedSelection] range — the two are mutually exclusive.
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    _fixedSelection = null;
    _selectionBase?.dispose();
    _selectionBase = base;

    _selectionExtent?.dispose();
    _selectionExtent = extent;

    if (mode != null) {
      _selectionMode = mode;
    }

    notifyListeners();
  }

  BufferRange _createRange(CellOffset begin, CellOffset end) {
    switch (selectionMode) {
      case SelectionMode.line:
        return BufferRangeLine(begin, end);
      case SelectionMode.block:
        return BufferRangeBlock(begin, end);
    }
  }

  /// Controls how the terminal behaves when the user selects a range of text.
  /// The default is [SelectionMode.line]. Setting this to [SelectionMode.block]
  /// enables block selection mode.
  void setSelectionMode(SelectionMode newSelectionMode) {
    // If the new mode is the same as the old mode,
    // nothing has to be changed.
    if (_selectionMode == newSelectionMode) {
      return;
    }
    // Set the new mode.
    _selectionMode = newSelectionMode;
    notifyListeners();
  }

  /// Clears the current selection, whichever representation it uses.
  void clearSelection() {
    _fixedSelection = null;
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;
    notifyListeners();
  }

  // Select which type of pointer events are send to the terminal.
  void setPointerInputs(PointerInputs pointerInput) {
    _pointerInputs = pointerInput;
    notifyListeners();
  }

  // Toggle sending pointer events to the terminal.
  void setSuspendPointerInput(bool suspend) {
    _suspendPointerInputs = suspend;
    notifyListeners();
  }

  // Returns true if this type of PointerInput should be send to the Terminal.
  @internal
  bool shouldSendPointerInput(PointerInput pointerInput) {
    // Always return false if pointer input is suspended.
    return _suspendPointerInputs
        ? false
        : _pointerInputs.inputs.contains(pointerInput);
  }

  /// Creates a new highlight on the terminal from [p1] to [p2] with the given
  /// [color]. The highlight will be removed when the returned object is
  /// disposed.
  TerminalHighlight highlight({
    required CellAnchor p1,
    required CellAnchor p2,
    required Color color,
  }) {
    final highlight = TerminalHighlight(
      this,
      p1: p1,
      p2: p2,
      color: color,
    );

    _highlights.add(highlight);
    notifyListeners();

    highlight.registerCallback(() {
      _highlights.remove(highlight);
      notifyListeners();
    });

    return highlight;
  }

  /// 释放选区 anchor。
  ///
  /// `ChangeNotifier.dispose()` 只清 listener —— 两个 anchor 会原样留在
  /// `BufferLine._anchors` 里（`line.dart:357` 加入，只有显式 dispose 才
  /// 摘得掉，`:406`）。而 buffer 属于会话、跨 widget 生命周期存活：tab 切换、
  /// 浮窗提升、split 布局变化都会重建 TerminalWidget，每次带着活跃选区销毁
  /// 就留下两个僵尸 anchor。
  ///
  /// super.dispose() 必须放在最后 —— ChangeNotifier 被 dispose 之后再碰它的
  /// 状态会在 debug 模式下触发断言。
  @override
  void dispose() {
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;
    super.dispose();
  }
}

class TerminalHighlight with Disposable {
  final TerminalController owner;

  final CellAnchor p1;

  final CellAnchor p2;

  final Color color;

  TerminalHighlight(
    this.owner, {
    required this.p1,
    required this.p2,
    required this.color,
  });

  /// Returns the range of the highlight. May be null if the anchors that
  /// define the highlight are not attached to the terminal.
  BufferRange? get range {
    if (!p1.attached || !p2.attached) {
      return null;
    }
    return BufferRangeLine(p1.offset, p2.offset);
  }
}
