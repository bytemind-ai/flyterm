// SPDX-License-Identifier: GPL-3.0-or-later
// Detects whether a TUI app (opencode / claude CLI / vim / less / htop) is
// currently active on the remote side based on VT100 patterns in the host
// byte stream. Ports v1 SspTransport._updateTuiState verbatim so v2's
// `moshTuiActive` signal matches v1 behaviour — required for the scroll path
// in TerminalWidget._flushSgr to forward SGR mouse-wheel events to the
// foreground TUI instead of routing them into xterm's local scrollback.
//
// Signals tracked per host-byte chunk:
//   * ESC[r            — full-state marker (DECSTBM no params)
//   * ESC[?25l         — cursor hide
//   * ESC[H / ESC[N;MH — absolute cursor positioning (counts distinct rows)
//
// Activation rule:
//   manyRows (≥4 distinct rows)                              → TUI on (immediate)
//   fullState && !cursorHide && fewRows (≥2 consecutive)    → TUI off (debounced)
//   otherwise                                               → state unchanged (latched)
//
// The deactivation debounce (2 consecutive qualifying frames) guards against
// false deactivation from TUI apps that don't hide the cursor (e.g. opencode).
// Such apps can send partial updates with ESC[r and only 1-2 cursor moves
// (e.g. refreshing a status bar), which would otherwise look like a bash
// prompt and flip _active to false mid-session.
import 'dart:typed_data';

class TuiDetector {
  static const int _kTuiRowThreshold = 4;
  // Consecutive bash-like full-state frames required before deactivating.
  // Prevents a single TUI partial-update frame (ESC[r + few rows + no
  // cursor-hide) from incorrectly clearing the active flag.
  static const int _kDeactivateFrames = 2;

  bool _active = false;
  bool get active => _active;

  int _bashLikeFrameCount = 0;
  int get bashLikeFrameCount => _bashLikeFrameCount;

  void onHostBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;
    bool isFullStateFrame = false;
    bool hasCursorHide = false;
    final rows = <int>{};
    for (var i = 0; i < bytes.length; i++) {
      // ESC[r — full-state marker (3 bytes)
      if (!isFullStateFrame &&
          i + 2 < bytes.length &&
          bytes[i] == 0x1b &&
          bytes[i + 1] == 0x5b &&
          bytes[i + 2] == 0x72) {
        isFullStateFrame = true;
        i += 2;
        continue;
      }
      // ESC[?25l — cursor hide (6 bytes)
      if (!hasCursorHide &&
          i + 5 < bytes.length &&
          bytes[i] == 0x1b &&
          bytes[i + 1] == 0x5b &&
          bytes[i + 2] == 0x3f &&
          bytes[i + 3] == 0x32 &&
          bytes[i + 4] == 0x35 &&
          bytes[i + 5] == 0x6c) {
        hasCursorHide = true;
        i += 5;
        continue;
      }
      // ESC[H — cursor home (1,1)
      if (i + 2 < bytes.length &&
          bytes[i] == 0x1b &&
          bytes[i + 1] == 0x5b) {
        if (bytes[i + 2] == 0x48) {
          rows.add(1);
          i += 2;
          continue;
        }
        // ESC[N;MH — parse row N
        var j = i + 2;
        var row = 0;
        while (j < bytes.length && bytes[j] >= 0x30 && bytes[j] <= 0x39) {
          row = row * 10 + (bytes[j] - 0x30);
          j++;
        }
        if (j < bytes.length && bytes[j] == 0x3b) {
          final r = row > 0 ? row : 1;
          var k = j + 1;
          while (k < bytes.length && bytes[k] >= 0x30 && bytes[k] <= 0x39) {
            k++;
          }
          if (k < bytes.length && bytes[k] == 0x48) {
            rows.add(r);
            i = k;
            continue;
          }
        }
      }
    }
    if (rows.length >= _kTuiRowThreshold) {
      // Many distinct cursor rows → TUI is active. Reset the bash-like counter
      // so a brief partial frame doesn't accumulate toward deactivation.
      _active = true;
      _bashLikeFrameCount = 0;
    } else if (isFullStateFrame && !hasCursorHide) {
      // ESC[r + few rows + cursor visible = looks like a bash/simple prompt.
      // Require _kDeactivateFrames consecutive such frames before deactivating
      // to avoid false triggers from TUI apps (e.g. opencode) that do not hide
      // the cursor and occasionally send partial updates with ESC[r.
      _bashLikeFrameCount++;
      if (_bashLikeFrameCount >= _kDeactivateFrames) {
        _active = false;
      }
    } else {
      // Incremental TUI frame (few rows, no ESC[r): latch persists. Also
      // reset the bash-like counter — the frame is not a shell-prompt signal.
      _bashLikeFrameCount = 0;
    }
  }
}
