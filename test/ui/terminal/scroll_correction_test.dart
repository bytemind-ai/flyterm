// test/ui/terminal/scroll_correction_test.dart
//
// Unit tests for ScrollCorrection — the pure-function decision helper used
// by TerminalWidget._shellResize to decide whether to schedule a
// post-frame jumpTo(0) after a resize event. Replicates the reactive-fix
// condition at terminal_widget.dart:2117 so the logic is testable
// independently of the widget framework.

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/scroll_correction.dart';

void main() {
  group('shouldResetAfterResize', () {
    test('returns false when offset is already 0', () {
      expect(
        ScrollCorrection.shouldResetAfterResize(
          offset: 0,
          lineCount: 5,
          viewHeight: 88,
        ),
        isFalse,
      );
    });

    test('returns false when buffer has more lines than viewport', () {
      // Real scrollback content — user might be intentionally scrolled up.
      expect(
        ScrollCorrection.shouldResetAfterResize(
          offset: 120,
          lineCount: 200,
          viewHeight: 88,
        ),
        isFalse,
      );
    });

    test('returns true when offset > 0 and lines fit in viewport', () {
      // Classic stale-scroll state: buffer was cleared/shrunk after the
      // scroll offset was set, leaving the viewport pointing into empty
      // scrollback. This is the h.jpg condition.
      expect(
        ScrollCorrection.shouldResetAfterResize(
          offset: 120,
          lineCount: 50,
          viewHeight: 88,
        ),
        isTrue,
      );
    });

    test('returns true on boundary: lineCount == viewHeight', () {
      expect(
        ScrollCorrection.shouldResetAfterResize(
          offset: 0.5,
          lineCount: 88,
          viewHeight: 88,
        ),
        isTrue,
      );
    });

    test('handles fractional offset (xterm pixels)', () {
      expect(
        ScrollCorrection.shouldResetAfterResize(
          offset: 0.001,
          lineCount: 10,
          viewHeight: 88,
        ),
        isTrue,
      );
    });
  });
}
