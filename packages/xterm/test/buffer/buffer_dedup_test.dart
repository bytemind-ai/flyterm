import 'package:flutter_test/flutter_test.dart';

import 'package:xterm/xterm.dart';

void main() {
  group('Buffer.dedupRecentPushes', () {
    test('disabled by default — duplicates retained', () {
      final t = Terminal(maxLines: 200);
      // Default 80x24 viewport.
      // Push 5 identical lines + 5 unique fillers so they all transition into
      // scrollback (push 24 fillers below to ensure transitions occur).
      _writeLines(t, [
        'duplicate-line',
        'duplicate-line',
        'duplicate-line',
        'duplicate-line',
        'duplicate-line',
      ]);
      // Force scrollback: write 30 lines total so the first 6 leave the viewport.
      for (var i = 0; i < 30; i++) {
        t.write('filler-$i\r\n');
      }
      // All five "duplicate-line" copies should be present in scrollback.
      final text = t.buffer.getText();
      final occurrences = 'duplicate-line'.allMatches(text).length;
      expect(occurrences, 5);
    });

    test('enabled — duplicates dropped within window', () {
      final t = Terminal(maxLines: 200)..dedupRecentPushes = 50;
      _writeLines(t, [
        'duplicate-line',
        'duplicate-line',
        'duplicate-line',
        'duplicate-line',
        'duplicate-line',
      ]);
      for (var i = 0; i < 30; i++) {
        t.write('filler-$i\r\n');
      }
      final text = t.buffer.getText();
      final occurrences = 'duplicate-line'.allMatches(text).length;
      expect(occurrences, 1);
    });

    test('window size = viewport height — older duplicates are NOT deduped',
        () {
      // Default 80x24 viewport, so the dedup window is 24 lines.
      final t = Terminal(maxLines: 1000)..dedupRecentPushes = 1;
      // Push the duplicate first, then push enough unique lines so the
      // duplicate is OUTSIDE the viewport-sized dedup window when we push
      // it again.
      _writeLines(t, ['target']);
      // Push more than viewHeight (24) unique lines to ensure "target" has
      // fallen past the dedup window before we write the second "target".
      for (var i = 0; i < 60; i++) {
        t.write('unique-$i\r\n');
      }
      // Now write target again — should NOT dedup against the original
      // because the original is more than viewHeight lines back.
      t.write('target\r\n');
      for (var i = 0; i < 60; i++) {
        t.write('filler-$i\r\n');
      }
      final text = t.buffer.getText();
      final occurrences = 'target'.allMatches(text).length;
      expect(occurrences, 2);
    });

    test('unique content accumulates in scrollback (not over-dedup)', () {
      // Regression: with a fixed N=50 window, per-token rerenders of a TUI
      // app would collapse scrollback to ~viewport size. With the
      // viewport-sized window, genuinely unique appended content stays.
      final t = Terminal(maxLines: 1000)..dedupRecentPushes = 1;
      // Write 200 unique lines — none should be deduped.
      for (var i = 0; i < 200; i++) {
        t.write('unique-line-$i\r\n');
      }
      // Scrollback should contain ~200 - viewHeight unique lines plus
      // viewport. Assert at least 150 distinct unique-line markers exist.
      final text = t.buffer.getText();
      final occurrences = RegExp(r'unique-line-').allMatches(text).length;
      expect(occurrences, greaterThanOrEqualTo(150));
    });

    test('blank lines never dedup (paragraph spacing preserved)', () {
      final t = Terminal(maxLines: 200)..dedupRecentPushes = 50;
      // 3 blank lines back-to-back.
      t.write('\r\n\r\n\r\n');
      for (var i = 0; i < 30; i++) {
        t.write('filler-$i\r\n');
      }
      // Total height should reflect that no blank lines were dropped.
      // 3 blanks + 30 fillers + initial viewport setup. We just assert blanks
      // remain by checking there are at least 3 empty lines in scrollback.
      var blankCount = 0;
      for (var i = 0; i < t.buffer.lines.length; i++) {
        if (t.buffer.lines[i].getText().trim().isEmpty) blankCount++;
      }
      // 3 explicit blanks + the viewport's empty bottom area; expect at least 3.
      expect(blankCount, greaterThanOrEqualTo(3));
    });

    test('alt buffer never dedups (vim/less etc unaffected)', () {
      final t = Terminal(maxLines: 200)..dedupRecentPushes = 50;
      // Switch to alt buffer (DECSET 1049).
      t.write('\x1b[?1049h');
      // Write duplicate lines in alt buffer + scroll past 24 rows.
      for (var i = 0; i < 5; i++) {
        t.write('duplicate-line\r\n');
      }
      for (var i = 0; i < 30; i++) {
        t.write('filler-$i\r\n');
      }
      // Alt buffer has no scrollback — but more importantly we should not
      // trigger dedup logic. Switch back to primary; the alt-buffer activity
      // must not have polluted primary scrollback.
      t.write('\x1b[?1049l');
      final primaryText = t.buffer.getText();
      expect(primaryText.contains('duplicate-line'), isFalse);
    });
  });
}

void _writeLines(Terminal t, List<String> lines) {
  for (final line in lines) {
    t.write('$line\r\n');
  }
}
