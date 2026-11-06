// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Decides whether a keystroke should be locally echoed before the mosh server
/// confirms it, and detects contexts that require suppression.
///
/// Strategy: predict printable single-byte ASCII and valid UTF-8 multi-byte
/// characters (CJK, emoji, etc.) by default. Wide characters (CJK, emoji)
/// occupy 2 terminal columns; narrow characters occupy 1. Up to
/// [_maxPendingCols] pending columns are allowed at once so fast typists see
/// predictions without waiting for RTT.
///
/// Suppression cases:
///   - Password-like prompt detected in server output (3 s window)
///   - Alternate screen active: vim, less, htop, etc. (ESC[?1049h / ESC[?1047h)
///   - Prediction timeout: if server is silent for 2 s, state resets so the
///     gate can never be permanently locked by a dropped connection
class LocalEchoPredictor {
  // Expanded to cover common authentication prompts across tools and locales.
  static final _passwordRe = RegExp(
    r'[Pp]assword[:\s]|[Pp]assphrase[:\s]|PIN[:\s]|Enter pass'
    r'|password for |Authentication required'
    '|\u5bc6\u7801[\uff1a: ]', // 密码：/ 密码:
    unicode: true,
  );

  static const _suppressDuration = Duration(seconds: 3);

  /// Maximum pending columns allowed at once.
  /// Kept at 1 so only the last typed character is in a "predicted" state;
  /// subsequent keystrokes wait for server confirmation. Combined with direct
  /// write (no cursor dance), this prevents multi-char visual overlap.
  static const _maxPendingCols = 1;

  /// If the server has not sent any output within this window after a
  /// prediction, automatically clear the pending state.  Prevents the
  /// predictor from being stuck when the connection drops silently.
  static const _predictionTimeout = Duration(seconds: 2);

  DateTime? _suppressUntil;
  int _pendingCount = 0;
  int _pendingWidth = 0; // total columns occupied by pending predictions
  Timer? _predictionTimer;
  bool _inAltBuffer = false;
  bool _suppressNext = false;

  // ── tmux state ────────────────────────────────────────────────────────────
  bool _tmuxMode = false;
  // _tmuxTuiActive intentionally always false: cursor-visibility detection
  // does not work with CLAUDE_CODE_NO_FLICKER=1 because Claude CLI keeps the
  // cursor hidden at the input prompt, making cursor-hide indistinguishable
  // from TUI apps.  Echo is allowed unconditionally in tmux mode; the brief
  // 1-RTT ghost character in vim/htop is an acceptable trade-off.
  final bool _tmuxTuiActive = false;

  // ── Underline prediction state ─────────────────────────────────────────────
  Uint8List? _predictedBytes;
  int _predictedCols = 0;
  void Function(List<int>)? onTimeout;

  LocalEchoPredictor();

  /// Named constructor for testing — allows injecting a pre-set suppressUntil.
  LocalEchoPredictor.withSuppressUntil(DateTime suppressUntil)
      : _suppressUntil = suppressUntil;

  /// Number of locally echoed characters not yet confirmed by server output.
  int get pendingCount => _pendingCount;

  /// Total column width of pending predictions (wide chars count as 2).
  int get pendingWidth => _pendingWidth;

  /// True when tmux cursor-visibility TUI detection has suppressed echo.
  bool get tmuxTuiActive => _tmuxTuiActive;

  /// One-line state for the debug overlay.
  /// "active" | "off(alt)" | "off(pwd)" | "off(1shot)"
  String get stateDiag {
    if (_inAltBuffer) return 'off(alt)';
    final sup = _suppressUntil;
    if (sup != null && DateTime.now().isBefore(sup)) return 'off(pwd)';
    if (_suppressNext) return 'off(1shot)';
    return 'active';
  }

  /// True if prediction is currently suppressed (password window or alt-buffer).
  bool get isSuppressed {
    if (_inAltBuffer) return true;
    if (_tmuxMode && _tmuxTuiActive) return true;
    final sup = _suppressUntil;
    return sup != null && DateTime.now().isBefore(sup);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Switch to tmux-aware echo mode.
  /// Allows echo unconditionally (cursor-visibility TUI detection disabled;
  /// see field comment on _tmuxTuiActive for rationale).
  void suppressAll() {
    _tmuxMode = true;
  }

  /// Suppress local echo for the NEXT keystroke only (one-shot).
  /// Call before forwarding the first key after mosh TUI scroll mode exits:
  /// xterm's cursor is at a history row until the server sends a corrective
  /// frame, so a local echo there would orphan a character at the wrong row.
  void suppressNext() => _suppressNext = true;

  /// Emits: ESC[4m + data + ESC[24m + ESC[{W}D
  /// Records prediction state and calls notifyPredicted.
  /// Must only be called when shouldEcho returns true.
  List<int> buildEcho(List<int> data) {
    final charW = charWidth(data);
    _predictedBytes = Uint8List.fromList(data);
    _predictedCols = charW;
    notifyPredicted(charW);
    return [
      0x1B, 0x5B, 0x34, 0x6D,                         // ESC[4m (underline on)
      ...data,
      0x1B, 0x5B, 0x32, 0x34, 0x6D,                   // ESC[24m (underline off)
      0x1B, 0x5B, ...charW.toString().codeUnits, 0x44, // ESC[{W}D (cursor back)
    ];
  }

  /// Returns true if [data] should be immediately echoed to the terminal.
  ///
  /// Accepts:
  ///   - Printable single-byte ASCII (0x20–0x7E)
  ///   - Complete UTF-8 multi-byte sequences (CJK, emoji, accented chars)
  ///
  /// Rejects control bytes, combining characters, zero-width characters, and
  /// any input while suppression is active.
  bool shouldEcho(List<int> data) {
    if (_tmuxMode && _tmuxTuiActive) return false;
    if (_inAltBuffer) return false;
    if (_suppressNext) { _suppressNext = false; return false; }
    final sup = _suppressUntil;
    if (sup != null && DateTime.now().isBefore(sup)) return false;

    // Single-byte ASCII printable
    if (data.length == 1) {
      final b = data[0];
      if (b < 0x20 || b > 0x7E) return false;
      return _pendingWidth < _maxPendingCols;
    }

    // Multi-byte UTF-8: accept well-formed sequences for printable characters
    if (data.length >= 2) {
      try {
        final s = utf8.decode(data, allowMalformed: false);
        final runes = s.runes.toList();
        if (runes.length != 1) return false; // must be exactly one codepoint
        final cp = runes[0];
        if (_isControlOrCombining(cp)) return false;
        final w = charWidth(data);
        return _pendingWidth + w <= _maxPendingCols;
      } catch (_) {
        return false; // malformed UTF-8
      }
    }
    return false;
  }

  /// Call immediately after emitting a local echo.
  ///
  /// Increments the pending count/width and (re)starts the 2-second safety timer.
  void notifyPredicted(int colWidth) {
    _pendingCount++;
    _pendingWidth += colWidth;
    // Reset the timer on each prediction so it fires [_predictionTimeout]
    // after the LAST echoed character, giving the server the full window.
    _predictionTimer?.cancel();
    _predictionTimer = Timer(_predictionTimeout, _onTimeoutFire);
  }

  void _onTimeoutFire() {
    final predicted = _predictedBytes;
    if (predicted != null) {
      final cols = _predictedCols;
      final eraseSeq = <int>[
        0x1B, 0x5B, ...cols.toString().codeUnits, 0x44, // ESC[{cols}D
        ...List.filled(cols, 0x20),                       // cols spaces
        0x1B, 0x5B, ...cols.toString().codeUnits, 0x44, // ESC[{cols}D
      ];
      onTimeout?.call(eraseSeq);
    }
    _clearPredictions();
  }

  /// Explicitly clear all pending predictions.
  /// Called on Enter to reset cursor state before newline prediction.
  void clearPredictions() => _clearPredictions();

  /// Returns the terminal column width of [data] (1 for ASCII/narrow, 2 for wide).
  static int charWidth(List<int> data) {
    if (data.length == 1) return 1;
    try {
      final cp = utf8.decode(data, allowMalformed: false).runes.first;
      return _isWide(cp) ? 2 : 1;
    } catch (_) {
      return 1;
    }
  }

  static bool _isWide(int cp) {
    if (cp >= 0x1100 && cp <= 0x115F) return true; // Hangul Jamo
    if (cp >= 0x2E80 && cp <= 0x303E) return true; // CJK radicals, Kangxi
    if (cp >= 0x3041 && cp <= 0x33FF) return true; // Hiragana, Katakana, CJK compat
    if (cp >= 0x3400 && cp <= 0x4DBF) return true; // CJK Ext A
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true; // CJK Unified
    if (cp >= 0xA000 && cp <= 0xA4CF) return true; // Yi
    if (cp >= 0xAC00 && cp <= 0xD7AF) return true; // Hangul syllables
    if (cp >= 0xF900 && cp <= 0xFAFF) return true; // CJK compat ideographs
    if (cp >= 0xFE10 && cp <= 0xFE6F) return true; // CJK compat forms, small forms
    if (cp >= 0xFF01 && cp <= 0xFF60) return true; // Fullwidth ASCII
    if (cp >= 0x1B000 && cp <= 0x1B2FF) return true; // Kana supplement
    if (cp >= 0x1F004 && cp <= 0x1FAFF) return true; // Emoji, mahjong, etc.
    if (cp >= 0x20000 && cp <= 0x3FFFD) return true; // CJK Ext B–F
    return false;
  }

  static bool _isControlOrCombining(int cp) {
    if (cp < 0x20) return true; // C0 control
    if (cp >= 0x7F && cp < 0xA0) return true; // DEL + C1 control
    if (cp >= 0x0300 && cp <= 0x036F) return true; // Combining diacritics
    if (cp == 0x200B || cp == 0x200C || cp == 0x200D) return true; // ZWS, ZWNJ, ZWJ
    if (cp >= 0xFE00 && cp <= 0xFE0F) return true; // Variation selectors
    if (cp == 0xFEFF) return true; // BOM / ZWNBSP
    return false;
  }

  /// Call with every chunk of server output.
  ///
  /// - Resets the pending-prediction count (server confirmed or corrected)
  /// - Detects alternate-buffer entry/exit escape sequences
  /// - Scans the last 64 bytes for password-prompt patterns
  void notifyServerOutput(Uint8List bytes) {
    _clearPredictions();
    if (bytes.isEmpty) return;
    _detectAltBuffer(bytes);
    // Scan the last 64 bytes only — large VT100 frames rarely end with
    // a password prompt, so a suffix scan is sufficient and cheap.
    final tail = bytes.length > 64 ? bytes.sublist(bytes.length - 64) : bytes;
    final text = utf8.decode(tail, allowMalformed: true);
    if (_passwordRe.hasMatch(text)) {
      _suppressUntil = DateTime.now().add(_suppressDuration);
    }
  }

  /// Cancel any pending timer.  Call from [TerminalStateSync.close].
  void dispose() {
    _predictionTimer?.cancel();
    _predictionTimer = null;
  }

  // ── Private ────────────────────────────────────────────────────────────────

  void _clearPredictions() {
    _pendingCount = 0;
    _pendingWidth = 0;
    _predictedBytes = null;
    _predictedCols = 0;
    _predictionTimer?.cancel();
    _predictionTimer = null;
  }

  /// Detect ESC[?1049h/l (xterm alternate screen) and ESC[?1047h/l (older).
  /// Sets [_inAltBuffer] so prediction is disabled while full-screen apps
  /// like vim, less, or htop are active.
  void _detectAltBuffer(Uint8List bytes) {
    // Map to Latin-1 string for ASCII escape-sequence matching — safe because
    // the sequences we look for are all ASCII (< 0x80).
    final s = String.fromCharCodes(bytes);
    if (s.contains('\x1b[?1049h') || s.contains('\x1b[?1047h')) {
      _inAltBuffer = true;
    }
    if (s.contains('\x1b[?1049l') || s.contains('\x1b[?1047l')) {
      _inAltBuffer = false;
    }
  }
}
