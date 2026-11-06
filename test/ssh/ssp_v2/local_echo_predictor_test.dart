import 'dart:convert' show utf8;
import 'dart:typed_data';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/local_echo_predictor.dart';

void main() {
  late LocalEchoPredictor predictor;

  setUp(() => predictor = LocalEchoPredictor());
  tearDown(() => predictor.dispose());

  // ── Basic echo eligibility ─────────────────────────────────────────────────

  group('shouldEcho — printable ASCII', () {
    test('space (0x20) is echoed', () {
      expect(predictor.shouldEcho([0x20]), isTrue);
    });

    test('tilde (0x7E) is echoed', () {
      expect(predictor.shouldEcho([0x7E]), isTrue);
    });

    test('letter a is echoed', () {
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('digit 0 is echoed', () {
      expect(predictor.shouldEcho([0x30]), isTrue);
    });
  });

  group('shouldEcho — not echoed', () {
    test('carriage return (0x0D) is not echoed', () {
      expect(predictor.shouldEcho([0x0D]), isFalse);
    });

    test('newline (0x0A) is not echoed', () {
      expect(predictor.shouldEcho([0x0A]), isFalse);
    });

    test('DEL / backspace (0x7F) is not echoed', () {
      expect(predictor.shouldEcho([0x7F]), isFalse);
    });

    test('ESC (0x1B) is not echoed', () {
      expect(predictor.shouldEcho([0x1B]), isFalse);
    });

    test('Ctrl-C (0x03) is not echoed', () {
      expect(predictor.shouldEcho([0x03]), isFalse);
    });

    test('multi-byte sequence is not echoed', () {
      expect(predictor.shouldEcho([0x1B, 0x5B, 0x41]), isFalse);
    });

    test('multi-byte UTF-8 codepoint is not echoed', () {
      expect(predictor.shouldEcho([0xE4, 0xB8, 0xAD]), isFalse);
    });

    test('empty list is not echoed', () {
      expect(predictor.shouldEcho([]), isFalse);
    });
  });

  // ── Password suppression ───────────────────────────────────────────────────

  group('password suppression', () {
    test('suppressed after "Password: " in server output', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('[sudo] Password: '.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('suppressed after "password:" in server output', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('Enter password:'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('suppressed after "Enter passphrase" in server output', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('Enter passphrase for key:'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('suppressed after "PIN:" in server output', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('Enter PIN: '.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('suppressed after "password for user:" (sudo style)', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('[sudo] password for user: '.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('suppressed after "Authentication required"', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('Authentication required\n'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('suppressed after Chinese password prompt 密码：', () {
      predictor.notifyServerOutput(
          Uint8List.fromList(utf8.encode('密码：')));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('not suppressed by unrelated server output', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('root@host:~# '.codeUnits));
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('suppression expires after 3 seconds', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('Password: '.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);

      final p2 = LocalEchoPredictor.withSuppressUntil(
          DateTime.now().subtract(const Duration(seconds: 1)));
      expect(p2.shouldEcho([0x61]), isTrue);
      p2.dispose();
    });

    test('empty server output does not crash', () {
      expect(
          () => predictor.notifyServerOutput(Uint8List(0)), returnsNormally);
    });
  });

  // ── Alt buffer suppression (B2 / L2) ──────────────────────────────────────

  group('alt buffer suppression', () {
    test('shouldEcho returns false after ESC[?1049h (xterm alt screen)', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?1049h'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('shouldEcho re-enabled after ESC[?1049l (xterm alt screen exit)', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?1049h'.codeUnits));
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?1049l'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('ESC[?1047h also enters alt buffer', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?1047h'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('ESC[?1047l exits alt buffer', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?1047h'.codeUnits));
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?1047l'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('alt buffer sequence embedded in larger output is detected', () {
      // Simulate a real vim startup: prompt + alt-buffer entry in one chunk
      final buf = Uint8List.fromList(
          'some output\x1b[?1049hmore content'.codeUnits);
      predictor.notifyServerOutput(buf);
      expect(predictor.shouldEcho([0x61]), isFalse);
    });
  });

  // ── Multi-char prediction queue (B2) ──────────────────────────────────────

  group('multi-char prediction queue', () {
    test('pendingCount starts at 0', () {
      expect(predictor.pendingCount, 0);
    });

    test('notifyPredicted increments pendingCount', () {
      predictor.notifyPredicted(1);
      expect(predictor.pendingCount, 1);
      predictor.notifyPredicted(1);
      expect(predictor.pendingCount, 2);
    });

    test('first keystroke is echoed (max pending cols = 1)', () {
      expect(predictor.shouldEcho([0x61]), isTrue,
          reason: 'should echo at count 0');
      predictor.notifyPredicted(1);
      expect(predictor.shouldEcho([0x61]), isFalse,
          reason: 'should NOT echo at count 1 — max pending cols is 1');
    });

    test('shouldEcho returns false when max predictions (1) reached', () {
      predictor.notifyPredicted(1);
      expect(predictor.pendingCount, 1);
      expect(predictor.shouldEcho([0x61]), isFalse);
    });

    test('notifyServerOutput resets pendingCount to 0', () {
      predictor.notifyPredicted(1);
      predictor.notifyPredicted(1);
      expect(predictor.pendingCount, 2);
      predictor.notifyServerOutput(Uint8List.fromList('he'.codeUnits));
      expect(predictor.pendingCount, 0);
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('empty server output also clears predictions', () {
      predictor.notifyPredicted(1);
      predictor.notifyServerOutput(Uint8List(0));
      expect(predictor.pendingCount, 0);
      expect(predictor.shouldEcho([0x61]), isTrue);
    });
  });

  // ── Prediction timeout (B3) ───────────────────────────────────────────────

  group('prediction timeout', () {
    test('pending state clears after 2 seconds without server response', () {
      fakeAsync((async) {
        // Fill up to max so shouldEcho returns false
        for (var i = 0; i < 8; i++) {
          predictor.notifyPredicted(1);
        }
        expect(predictor.shouldEcho([0x61]), isFalse);

        // Advance time past the 2 s timeout
        async.elapse(const Duration(seconds: 2, milliseconds: 100));

        expect(predictor.pendingCount, 0);
        expect(predictor.shouldEcho([0x61]), isTrue);
      });
    });

    test('timeout resets on each notifyPredicted call', () {
      fakeAsync((async) {
        // First prediction at t=0
        predictor.notifyPredicted(1);
        // Advance almost to 2 s
        async.elapse(const Duration(milliseconds: 1900));
        // Second prediction resets timer
        predictor.notifyPredicted(1);
        // Advance another 1.9 s (would have fired if not reset)
        async.elapse(const Duration(milliseconds: 1900));
        expect(predictor.pendingCount, 2); // timer not yet fired

        // Advance past the new 2 s window
        async.elapse(const Duration(milliseconds: 200));
        expect(predictor.pendingCount, 0);
      });
    });
  });

  // ── buildEcho ─────────────────────────────────────────────────────────────

  group('buildEcho', () {
    test('narrow ASCII: emits ESC[4m + char + ESC[24m + ESC[1D', () {
      final echo = predictor.buildEcho([0x61]); // 'a'
      expect(echo, equals([
        0x1B, 0x5B, 0x34, 0x6D,        // ESC[4m
        0x61,                            // 'a'
        0x1B, 0x5B, 0x32, 0x34, 0x6D,  // ESC[24m
        0x1B, 0x5B, 0x31, 0x44,         // ESC[1D
      ]));
    });

    test('wide CJK: cursor-back uses 2', () {
      final zhong = [0xE4, 0xB8, 0xAD]; // UTF-8 for 中 (width=2)
      final echo = predictor.buildEcho(zhong);
      // ESC[4m + 中 + ESC[24m + ESC[2D
      // Last byte is 0x44 ('D'), second-to-last digit is 0x32 ('2')
      expect(echo.last, equals(0x44));
      expect(echo[echo.length - 2], equals(0x32)); // '2'
    });

    test('increments pendingCount and pendingWidth', () {
      predictor.buildEcho([0x62]); // 'b'
      expect(predictor.pendingCount, equals(1));
      expect(predictor.pendingWidth, equals(1));
    });

    test('wide CJK increments pendingWidth by 2', () {
      predictor.buildEcho([0xE4, 0xB8, 0xAD]); // 中
      expect(predictor.pendingCount, equals(1));
      expect(predictor.pendingWidth, equals(2));
    });
  });

  // ── onTimeout callback ────────────────────────────────────────────────────

  group('onTimeout callback', () {
    test('dispose() before timeout fires: onTimeout not called', () {
      List<int>? received;
      predictor.onTimeout = (seq) => received = seq;
      predictor.buildEcho([0x61]);
      predictor.dispose();
      expect(received, isNull);
    });

    test('notifyServerOutput clears prediction without firing onTimeout', () {
      bool fired = false;
      predictor.onTimeout = (_) => fired = true;
      predictor.buildEcho([0x61]);
      predictor.notifyServerOutput(Uint8List.fromList([0x61]));
      expect(predictor.pendingCount, equals(0));
      expect(fired, isFalse);
    });

    test('timeout fires with correct erase seq for width=1', () {
      fakeAsync((async) {
        List<int>? received;
        predictor.onTimeout = (seq) => received = seq;
        predictor.buildEcho([0x61]); // width=1
        async.elapse(const Duration(seconds: 2, milliseconds: 100));
        // erase: ESC[1D + space + ESC[1D
        expect(received, equals([
          0x1B, 0x5B, 0x31, 0x44, // ESC[1D
          0x20,                    // space
          0x1B, 0x5B, 0x31, 0x44, // ESC[1D
        ]));
        expect(predictor.pendingCount, equals(0));
      });
    });

    test('timeout fires with correct erase seq for width=2 (CJK)', () {
      fakeAsync((async) {
        List<int>? received;
        predictor.onTimeout = (seq) => received = seq;
        predictor.buildEcho([0xE4, 0xB8, 0xAD]); // 中, width=2
        async.elapse(const Duration(seconds: 2, milliseconds: 100));
        // erase: ESC[2D + space + space + ESC[2D
        expect(received, equals([
          0x1B, 0x5B, 0x32, 0x44, // ESC[2D
          0x20, 0x20,              // 2 spaces
          0x1B, 0x5B, 0x32, 0x44, // ESC[2D
        ]));
      });
    });

    test('timeout with no prediction: onTimeout not called', () {
      fakeAsync((async) {
        bool fired = false;
        predictor.onTimeout = (_) => fired = true;
        // notifyPredicted without buildEcho: _predictedBytes stays null
        predictor.notifyPredicted(1);
        async.elapse(const Duration(seconds: 2, milliseconds: 100));
        expect(fired, isFalse); // no _predictedBytes so callback not called
        expect(predictor.pendingCount, equals(0));
      });
    });
  });

  // ── tmux mode ─────────────────────────────────────────────────────────────

  group('tmux mode', () {
    test('suppressAll() enables tmux mode: shouldEcho returns true (shell mode)', () {
      predictor.suppressAll();
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('ESC[?25l alone: cursor-visibility ignored, echo stays active', () {
      // TUI detection via cursor visibility is disabled: CLAUDE_CODE_NO_FLICKER=1
      // keeps cursor hidden at the input prompt, making ESC[?25l/h indistinguishable
      // from TUI apps. Echo is allowed unconditionally in tmux mode.
      fakeAsync((async) {
        predictor.suppressAll();
        predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25l'.codeUnits));
        expect(predictor.shouldEcho([0x61]), isTrue);
        async.elapse(const Duration(milliseconds: 600));
        expect(predictor.shouldEcho([0x61]), isTrue);
      });
    });

    test('ESC[?25l + ESC[?25h in same packet: cursor-visibility ignored', () {
      predictor.suppressAll();
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?25l some content \x1b[?25h'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('ESC[?25h alone: cursor-visibility ignored, echo stays active', () {
      fakeAsync((async) {
        predictor.suppressAll();
        predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25l'.codeUnits));
        async.elapse(const Duration(milliseconds: 600));
        expect(predictor.shouldEcho([0x61]), isTrue); // still active

        predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25h'.codeUnits));
        async.elapse(const Duration(milliseconds: 300));
        expect(predictor.shouldEcho([0x61]), isTrue); // still active
      });
    });

    test('multiple cursor-visibility sequences: echo always active in tmux mode', () {
      fakeAsync((async) {
        predictor.suppressAll();
        for (var i = 0; i < 5; i++) {
          predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25l'.codeUnits));
          async.elapse(const Duration(milliseconds: 600));
          expect(predictor.shouldEcho([0x61]), isTrue);
        }
      });
    });

    test('non-tmux mode: ESC[?25l does not change state', () {
      predictor.notifyServerOutput(
          Uint8List.fromList('\x1b[?25l'.codeUnits));
      expect(predictor.shouldEcho([0x61]), isTrue);
    });

    test('dispose() during recovery timer does not crash', () {
      fakeAsync((async) {
        predictor.suppressAll();
        predictor.notifyServerOutput(
            Uint8List.fromList('\x1b[?25l'.codeUnits));
        predictor.notifyServerOutput(
            Uint8List.fromList('\x1b[?25h'.codeUnits));
        expect(() => predictor.dispose(), returnsNormally);
        async.elapse(const Duration(milliseconds: 300));
      });
    });

    test('isSuppressed always false in tmux mode (no TUI detection)', () {
      predictor.suppressAll();
      expect(predictor.isSuppressed, isFalse);
      predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25l'.codeUnits));
      expect(predictor.isSuppressed, isFalse); // cursor-visibility ignored
    });

    test('ESC[?25h then ESC[?25l in same packet: cursor-visibility ignored', () {
      fakeAsync((async) {
        predictor.suppressAll();
        predictor.notifyServerOutput(
            Uint8List.fromList('\x1b[?25h prefix \x1b[?25l'.codeUnits));
        expect(predictor.shouldEcho([0x61]), isTrue);
        async.elapse(const Duration(milliseconds: 600));
        expect(predictor.shouldEcho([0x61]), isTrue);
      });
    });

    test('rapid hide+show within 500ms: entry cancelled, echo stays active (Claude streaming)', () {
      fakeAsync((async) {
        predictor.suppressAll();
        // Simulate Claude CLI streaming: many rapid hide/show render cycles
        for (var i = 0; i < 5; i++) {
          predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25l'.codeUnits));
          async.elapse(const Duration(milliseconds: 50));
          predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25h'.codeUnits));
          async.elapse(const Duration(milliseconds: 50));
        }
        // Echo must still be active — entry timer never fired
        expect(predictor.shouldEcho([0x61]), isTrue);
        // Even after 600ms with no further signals, still active
        async.elapse(const Duration(milliseconds: 600));
        expect(predictor.shouldEcho([0x61]), isTrue);
      });
    });

    test('dispose() during entry timer does not crash', () {
      fakeAsync((async) {
        predictor.suppressAll();
        predictor.notifyServerOutput(Uint8List.fromList('\x1b[?25l'.codeUnits));
        // entry timer is now pending
        expect(() => predictor.dispose(), returnsNormally);
        async.elapse(const Duration(milliseconds: 600)); // timer would have fired
      });
    });
  });
}
