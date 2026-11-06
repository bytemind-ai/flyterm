// SPDX-License-Identifier: GPL-3.0-or-later
/// Sanitizes terminal byte streams before they reach xterm: unwraps
/// tmux DCS passthrough and strips OSC 8 hyperlink markers.
///
/// **tmux DCS unwrap** — apps running inside tmux emit the form
///
///   `ESC P tmux ; <inner with ESC doubled> ESC \`
///
/// Modern direct terminals (iTerm2, kitty, alacritty, wezterm) understand
/// this and treat `<inner>` as if emitted directly. Without unwrap, our
/// xterm parser discards the entire DCS payload (or worse, mis-parses it),
/// so colors and other styling are lost or rendered as garbled escapes.
///
/// **OSC 8 hyperlink strip** — apps like Claude Code mark every file path
/// in a diff with an OSC 8 hyperlink: `ESC ] 8 ; ; URI <ST> TEXT ESC ] 8 ;
/// ; <ST>`. xterm renders these as underlined clickable text — visually
/// noisy in dense terminal output. Removing the markers keeps the text
/// while dropping the underline rendering.
///
/// Cross-flush handling: a DCS sequence may straddle the boundary between
/// two stream chunks. `process` buffers a trailing partial introducer or
/// in-progress sequence in `_partial`, prepending it to the next call.
class TmuxPassthroughUnwrapper {
  static const _esc = 0x1B;
  static const _backslash = 0x5C; // '\'
  // Full introducer: ESC P t m u x ;
  static const _intro = '\x1bPtmux;';

  /// In-progress DCS sequence held over from the previous `process` call.
  String _partial = '';

  /// Hard cap on the partial buffer — guards against malformed input.
  /// In practice, a full Claude Code diff fragment is well under this.
  static const _maxPartialBytes = 64 * 1024;

  /// Strip tmux DCS passthrough wrappers from [input]. Returns the
  /// unwrapped text ready for `terminal.write()`. Carries any trailing
  /// incomplete DCS sequence to the next call via [_partial].
  String process(String input) {
    if (_partial.isNotEmpty) {
      input = _partial + input;
      _partial = '';
    }
    if (input.length > _maxPartialBytes && _partial.isNotEmpty) {
      // Defensive: don't let a malformed/orphaned sequence balloon forever.
      _partial = '';
    }

    final buf = StringBuffer();
    int pos = 0;
    while (pos < input.length) {
      final s = input.indexOf(_intro, pos);
      if (s < 0) break;
      // Emit everything before the DCS introducer untouched.
      if (s > pos) buf.write(input.substring(pos, s));
      // Scan for the DCS terminator (ESC \), treating doubled ESCs as
      // escaped data — that's how the inner ESC bytes are encoded.
      int e = s + _intro.length;
      bool foundEnd = false;
      while (e < input.length - 1) {
        if (input.codeUnitAt(e) == _esc) {
          final next = input.codeUnitAt(e + 1);
          if (next == _backslash) {
            foundEnd = true;
            break;
          }
          if (next == _esc) {
            // Escaped ESC inside passthrough payload — skip both.
            e += 2;
            continue;
          }
        }
        e++;
      }
      if (!foundEnd) {
        // Buffer the in-progress DCS — wait for the rest in the next flush.
        _partial = input.substring(s);
        return buf.toString();
      }
      // Inner payload: un-escape doubled ESCs and emit as if direct.
      final inner = input.substring(s + _intro.length, e);
      buf.write(inner.replaceAll('\x1b\x1b', '\x1b'));
      pos = e + 2; // step past ESC \
    }

    // Tail handling: hold a trailing partial introducer (ESC alone, ESC P,
    // ESC P t, ...) so we don't ship a half-DCS to the terminal parser.
    final rest = input.substring(pos);
    final partialFrom = _findIncompleteIntroducer(rest);
    if (partialFrom < 0) {
      buf.write(rest);
    } else {
      buf.write(rest.substring(0, partialFrom));
      _partial = rest.substring(partialFrom);
    }
    // Last step: normalize SGR sequences so xterm.dart 4.x handles them
    // even when modern CLIs (Claude Code) use sub-parameter syntax or
    // when xterm.dart's SGR-22 implementation is incomplete.
    return _normalizeSgr(buf.toString());
  }

  /// Rewrite SGR sequences to forms that xterm.dart 4.x parses correctly.
  ///
  /// Targets three upstream bugs / mis-parses:
  ///
  ///   0. `\x1b[>...m`, `\x1b[?...m`, `\x1b[<...m`, `\x1b[=...m` are DEC
  ///      *private* CSI sequences (xterm's modifyOtherKeys, key resource
  ///      queries, etc.). xterm.dart's _csiHandleSgr ignores `_csi.prefix`
  ///      and processes the params as if they were SGR — so `\x1b[>4;2m`
  ///      ends up calling setCursorUnderline()+setCursorFaint(), leaving
  ///      UNDER stuck for every subsequent glyph. **Strip these outright.**
  ///
  ///   1. `\x1b[4:0m` (sub-param: no underline) → xterm.dart drops the colon,
  ///      reads digits as `40` → SGR 40 = black background; the intended
  ///      underline-off is lost and UNDER stays stuck. Rewrite to `\x1b[24m`.
  ///
  ///   2. `\x1b[22m` (normal intensity → unset BOLD and FAINT) → xterm.dart
  ///      only unsets FAINT, leaving BOLD stuck. Rewrite to `\x1b[21;22m`
  ///      (xterm.dart treats 21 as "unset bold").
  ///
  ///   3. Generic CSI colon sub-params: `\x1b[<a>:<b>...m` → replace remaining
  ///      colons with semicolons so the parameters are parsed individually
  ///      instead of being merged into one wrong integer.
  static final _privateCsiSgrRe = RegExp(r'\x1b\[[<>?=][0-9;:]*m');
  static final _csiSgrRe = RegExp(r'\x1b\[([0-9;:?]*)m');
  String _normalizeSgr(String input) {
    // Step 0: drop private CSI sequences with `m` final byte entirely. They
    // are not SGR and xterm.dart mis-parses them as SGR.
    if (input.contains('\x1b[')) {
      input = input.replaceAll(_privateCsiSgrRe, '');
    }
    // Step 0.5: strip SGR 8 (invisible / HIDE). Almost no interactive terminal
    // session needs to hide visible content this way (its historic use was
    // password-prompt entry, which Claude Code does not do). When SGR 8 is
    // emitted without a paired SGR 28 — which we have observed in the wild —
    // every cell written afterwards inherits the HIDE bit and renders blank,
    // looking exactly like "scroll-up shows corrupted/missing bytes". Filter
    // it out while preserving 38/48/58 colour sub-parameters where a "8" is
    // legitimately a 256-colour index or RGB component.
    if (!input.contains('\x1b[')) return input;
    return input.replaceAllMapped(_csiSgrRe, (m) {
      var params = m.group(1) ?? '';
      // 1. \x1b[4:0m  → \x1b[24m  (underline off)
      //    \x1b[4:Nm → \x1b[4m   (any styled underline → single)
      params = params.replaceAllMapped(
        RegExp(r'(^|;)4:(\d+)'),
        (mm) {
          final prefix = mm.group(1)!;
          final sub = int.tryParse(mm.group(2)!) ?? 0;
          return sub == 0 ? '${prefix}24' : '${prefix}4';
        },
      );
      // 2. \x1b[22m (or part of a list) → also unset bold via 21
      //    Be careful not to double-inject; require exact param token.
      params = params.replaceAllMapped(
        RegExp(r'(^|;)22(?=;|$)'),
        (mm) => '${mm.group(1)}21;22',
      );
      // 3. Any remaining colons → semicolons. Extended SGR 38:2:R:G:B or
      //    38:5:N keeps the same semantics with semicolons in xterm.dart.
      params = params.replaceAll(':', ';');
      // 4. Strip standalone SGR 8 (invisible).
      params = _stripSgr8Params(params);
      // If filtering left no params at all, emit a no-op CSI m so we don't
      // accidentally remove the sequence entirely (an empty `\x1b[m` is the
      // legitimate "reset all" form in xterm.dart and is preserved).
      return '\x1b[${params}m';
    });
  }

  /// Drop standalone SGR 8 (invisible) from a semicolon-joined parameter
  /// list, while leaving the `8`s that are colour sub-parameters inside an
  /// `\x1b[38;…m` / `\x1b[48;…m` / `\x1b[58;…m` sequence untouched. We need
  /// to mini-parse the SGR list because a `;5;8` after `38` is a 256-colour
  /// index 8 (legitimate), not SGR 8 (invisible).
  static String _stripSgr8Params(String params) {
    if (!params.contains('8')) return params;
    final list = params.split(';');
    final out = <String>[];
    var i = 0;
    while (i < list.length) {
      final p = list[i];
      // Colour SGR with sub-params: 38/48/58 followed by mode + values.
      if (p == '38' || p == '48' || p == '58') {
        out.add(p);
        if (i + 1 < list.length) {
          final mode = list[i + 1];
          if (mode == '5' && i + 2 < list.length) {
            // 256-colour: keep <SGR>;5;<index>
            out.add(list[i + 1]);
            out.add(list[i + 2]);
            i += 3;
            continue;
          }
          if (mode == '2' && i + 4 < list.length) {
            // truecolour: keep <SGR>;2;<R>;<G>;<B>
            out.add(list[i + 1]);
            out.add(list[i + 2]);
            out.add(list[i + 3]);
            out.add(list[i + 4]);
            i += 5;
            continue;
          }
        }
        i++;
        continue;
      }
      // Standalone SGR 8 = invisible → drop.
      if (p == '8') {
        i++;
        continue;
      }
      out.add(p);
      i++;
    }
    return out.join(';');
  }

  /// Returns the index in [s] where an incomplete `\x1bPtmux;` introducer
  /// begins (so it can be deferred to the next flush), or -1 if no such
  /// prefix is present. Requires at least 2 chars (ESC P) to avoid
  /// withholding plain ESC bytes that begin regular CSI sequences.
  int _findIncompleteIntroducer(String s) {
    // Scan only the last (intro.length - 1) chars — any earlier ESC has
    // already been confirmed non-matching by the main loop's indexOf.
    final scanFrom = s.length >= _intro.length ? s.length - _intro.length + 1 : 0;
    for (int i = scanFrom; i < s.length; i++) {
      final tail = s.substring(i);
      if (tail.length >= 2 && _intro.startsWith(tail)) {
        return i;
      }
    }
    return -1;
  }
}
