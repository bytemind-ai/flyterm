import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/transport/tmux_passthrough_unwrapper.dart';

void main() {
  group('TmuxPassthroughUnwrapper', () {
    late TmuxPassthroughUnwrapper u;
    setUp(() => u = TmuxPassthroughUnwrapper());

    test('passes through input with no DCS wrapper unchanged', () {
      expect(u.process('plain text\n'), 'plain text\n');
      expect(u.process('\x1b[31mred\x1b[0m'), '\x1b[31mred\x1b[0m');
    });

    test('unwraps a single tmux DCS, un-escaping doubled ESCs', () {
      // tmux wraps:   \x1bPtmux;<inner with each \x1b doubled>\x1b\
      // Inner SGR:    \x1b[31m foo \x1b[0m
      // Wrapped:      \x1bPtmux;\x1b\x1b[31m foo \x1b\x1b[0m\x1b\
      final input = '\x1bPtmux;\x1b\x1b[31m foo \x1b\x1b[0m\x1b\\';
      expect(u.process(input), '\x1b[31m foo \x1b[0m');
    });

    test('preserves bytes around DCS wrapper', () {
      final input = 'before\x1bPtmux;\x1b\x1b[1mB\x1b\x1b[0m\x1b\\after';
      expect(u.process(input), 'before\x1b[1mB\x1b[0mafter');
    });

    test('handles multiple DCS wrappers in one input', () {
      final a = '\x1bPtmux;\x1b\x1b[31mA\x1b\\';
      final b = '\x1bPtmux;\x1b\x1b[32mB\x1b\\';
      expect(u.process('$a-$b'), '\x1b[31mA-\x1b[32mB');
    });

    test('buffers incomplete DCS across calls', () {
      // First half: introducer + start of payload but no terminator
      final part1 = 'x\x1bPtmux;\x1b\x1b[1mhe';
      // Second half: rest of payload + terminator
      final part2 = 'llo\x1b\x1b[0m\x1b\\y';
      expect(u.process(part1), 'x'); // emit only "x"; rest buffered
      expect(u.process(part2), '\x1b[1mhello\x1b[0my');
    });

    test('buffers a partial introducer at end of chunk', () {
      // Chunk ends mid-introducer (ESC P) — should buffer, not pass to xterm
      expect(u.process('hello\x1bP'), 'hello');
      // Next chunk completes "tmux;…\x1b\\"
      expect(u.process('tmux;\x1b\x1b[31mZ\x1b\\rest'), '\x1b[31mZrest');
    });

    test('does not buffer a lone ESC at end (might be CSI start)', () {
      // A bare ESC could be start of regular CSI (ESC [ ...) — passing it
      // through lets xterm.dart accumulate the sequence normally.
      expect(u.process('hi\x1b'), 'hi\x1b');
    });

    test('does NOT confuse a non-tmux DCS with tmux', () {
      // ESC P (other DCS) without "tmux;" should pass through
      final input = 'a\x1bP1\$rsomething\x1b\\b';
      expect(u.process(input), 'a\x1bP1\$rsomething\x1b\\b');
    });

    test('OSC 8 hyperlink wrapped in tmux passthrough unwraps cleanly', () {
      // Real-world: hyperlink inside tmux → claude wraps it
      //  Inner:   ESC ]8;;https://x.com ESC \ TEXT ESC ]8;; ESC \
      //  Wrapped: ESC P tmux ; ESC ESC ]8;;... ESC ESC \ TEXT ESC ESC ]8;; ESC ESC \ ESC \
      final input =
          '\x1bPtmux;\x1b\x1b]8;;https://x.com\x1b\x1b\\TEXT\x1b\x1b]8;;\x1b\x1b\\\x1b\\';
      expect(u.process(input),
          '\x1b]8;;https://x.com\x1b\\TEXT\x1b]8;;\x1b\\');
    });

    test('SGR 4:0 (sub-param off) rewritten to SGR 24', () {
      expect(u.process('\x1b[4:0m'), '\x1b[24m');
    });

    test('SGR 4:3 (curly underline) rewritten to plain SGR 4', () {
      expect(u.process('\x1b[4:3m'), '\x1b[4m');
    });

    test('SGR 22 expanded to 21;22 (also unset bold)', () {
      expect(u.process('\x1b[22m'), '\x1b[21;22m');
    });

    test('SGR 22 inside compound list expanded', () {
      expect(u.process('\x1b[0;22;31m'), '\x1b[0;21;22;31m');
    });

    test('SGR 38:5:N (256 color colon syntax) rewritten to semicolons', () {
      expect(u.process('\x1b[38:5:239m'), '\x1b[38;5;239m');
    });

    test('SGR 38:2:R:G:B (truecolor colon syntax) rewritten', () {
      expect(u.process('\x1b[38:2:255:0:0m'), '\x1b[38;2;255;0;0m');
    });

    test('non-SGR CSI with colons is unaffected', () {
      // SGR rewrites only target \x1b[...m sequences; other CSI letters
      // pass through unchanged.
      expect(u.process('\x1b[1;2H'), '\x1b[1;2H');
    });

    test('SGR 0 (reset all) passes through', () {
      expect(u.process('\x1b[0m'), '\x1b[0m');
    });

    test('plain SGR 4 (set underline) is preserved', () {
      expect(u.process('\x1b[4m'), '\x1b[4m');
    });

    test('strips private SGR \\x1b[>4;2m (xterm modifyOtherKeys)', () {
      // xterm.dart mis-parses this as SGR 4 + SGR 2 → stuck UNDER+FAINT.
      // It is NOT styling — it is a key-modifier resource query.
      expect(u.process('\x1b[>4;2m'), '');
    });

    test('strips private SGR variants (<, =, ?)', () {
      expect(u.process('\x1b[<4m'), '');
      expect(u.process('\x1b[=4m'), '');
      expect(u.process('\x1b[?4m'), '');
    });

    test('strips private SGR but keeps surrounding text', () {
      final input = 'before\x1b[>4;2mafter';
      expect(u.process(input), 'beforeafter');
    });

    test('does NOT strip DEC private mode set/reset (h/l final)', () {
      // \x1b[?1000h is mouse-tracking enable — legitimate and handled
      // by xterm.dart's mode handler. Must NOT be stripped.
      expect(u.process('\x1b[?1000h'), '\x1b[?1000h');
      expect(u.process('\x1b[?25l'), '\x1b[?25l');
      expect(u.process('\x1b[?2004h'), '\x1b[?2004h');
    });

    test('real Claude Code init burst — strips private SGR only', () {
      // Recorded from a8.jpg: full init sequence with the offending
      // \x1b[>4;2m embedded. Everything else passes through.
      final input =
          '\x1b[?2049h\x1b[2J\x1b[H\x1b[<u\x1b[>1u\x1b[>4;2m\x1b[?1000h\x1b[?2004h';
      expect(u.process(input),
          '\x1b[?2049h\x1b[2J\x1b[H\x1b[<u\x1b[>1u\x1b[?1000h\x1b[?2004h');
    });

    test('strips standalone SGR 8 (invisible / HIDE)', () {
      expect(u.process('\x1b[8m'), '\x1b[m');
    });

    test('strips SGR 8 from compound sequences', () {
      // Mid: \x1b[1;8;31m → \x1b[1;31m
      expect(u.process('\x1b[1;8;31m'), '\x1b[1;31m');
      // Last: \x1b[31;8m → \x1b[31m
      expect(u.process('\x1b[31;8m'), '\x1b[31m');
      // First: \x1b[8;31m → \x1b[31m
      expect(u.process('\x1b[8;31m'), '\x1b[31m');
    });

    test('preserves "8" inside 256-colour SGR (color index 8)', () {
      // \x1b[38;5;8m sets fg = 256-colour index 8 (legitimate dark grey).
      expect(u.process('\x1b[38;5;8m'), '\x1b[38;5;8m');
      // \x1b[48;5;8m (bg)
      expect(u.process('\x1b[48;5;8m'), '\x1b[48;5;8m');
      // \x1b[58;5;8m (underline color)
      expect(u.process('\x1b[58;5;8m'), '\x1b[58;5;8m');
    });

    test('preserves "8" inside truecolour SGR (RGB component)', () {
      // \x1b[38;2;8;100;200m sets fg = RGB(8,100,200); the "8" is the R channel.
      expect(u.process('\x1b[38;2;8;100;200m'), '\x1b[38;2;8;100;200m');
      // RGB(255,8,100)
      expect(u.process('\x1b[38;2;255;8;100m'), '\x1b[38;2;255;8;100m');
      // RGB(255,100,8)
      expect(u.process('\x1b[38;2;255;100;8m'), '\x1b[38;2;255;100;8m');
    });

    test('strips SGR 8 even when next to a colour SGR', () {
      // \x1b[8;38;5;239m should become \x1b[38;5;239m
      expect(u.process('\x1b[8;38;5;239m'), '\x1b[38;5;239m');
      // \x1b[38;5;239;8m → \x1b[38;5;239m
      expect(u.process('\x1b[38;5;239;8m'), '\x1b[38;5;239m');
    });

    test('SGR 28 (unset invisible) passes through', () {
      // We strip 8 but NOT 28 — the unset is still valid in case any other
      // path leaked HIDE in.
      expect(u.process('\x1b[28m'), '\x1b[28m');
    });

    test('compound case with 4:0 + 22 + 8 all normalized', () {
      // \x1b[4:0;22;8m → \x1b[24;21;22m (drop 8)
      expect(u.process('\x1b[4:0;22;8m'), '\x1b[24;21;22m');
    });
  });
}
