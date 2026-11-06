// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/terminal/scroll_correction.dart
//
// Pure-function decision helper for xterm scroll offset correction.
//
// Why a separate file: TerminalWidget._shellResize and TerminalScreen
// (post-RESUME callback) both need this decision; widget tests are
// hard for the touch-/scroll-heavy TerminalWidget, but a static pure
// function is trivially unit-tested.

class ScrollCorrection {
  /// Decide whether a viewport scroll offset is "stale" — that is, the
  /// offset is non-zero but the underlying terminal buffer has fewer
  /// lines than the viewport can display, so the offset points into
  /// scrollback that no longer exists.
  ///
  /// Returns `true` when the caller should `scrollController.jumpTo(0)`.
  ///
  /// This mirrors the reactive fix at `terminal_widget.dart:2117` and
  /// `:2384`, exposed as a pure function so resize callbacks can apply
  /// it proactively without waiting for the user to start a selection.
  static bool shouldResetAfterResize({
    required double offset,
    required int lineCount,
    required int viewHeight,
  }) {
    if (offset == 0) return false;
    return lineCount <= viewHeight;
  }
}
