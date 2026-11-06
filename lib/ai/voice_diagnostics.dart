// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import '../util/dlog.dart';

/// In-app ring buffer for the voice-input pipeline.
///
/// Voice input reaches across four layers that each fail differently —
/// Dart UI flow, `VoiceInputService`, the `speech_to_text` plugin, and the
/// system speech Activity. A failure in any of them used to surface as the
/// same thing to the user ("tapped the mic, nothing happened"), and with no
/// record of what actually ran there was nothing to reason from: every fix
/// was a guess about which layer broke.
///
/// This buffer is the record. It is deliberately in-app rather than
/// `logcat`-only, because reproducing this needs a real device with a real
/// ROM's speech stack — often not one that's plugged into a computer.
///
/// Kept small and allocation-cheap: voice input is user-initiated, so a few
/// hundred entries covers many sessions, and old entries are dropped rather
/// than growing without bound.
class VoiceDiagnostics {
  VoiceDiagnostics._();

  /// Single shared instance. A stream of diagnostics that got split across
  /// per-widget instances would defeat the point — the interesting failures
  /// span the UI layer *and* the service layer.
  static final VoiceDiagnostics instance = VoiceDiagnostics._();

  static const int _maxEntries = 240;

  final List<String> _entries = <String>[];

  /// Monotonic-ish session marker so entries from separate mic taps are
  /// visually separable in the dump.
  int _tapCounter = 0;

  /// Wall-clock is only used for relative ordering/spacing in the dump, so
  /// a coarse source is fine; what matters is that entries are ordered and
  /// timestamped consistently.
  String _stamp() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// Records one step. [layer] identifies which of the four layers spoke,
  /// so a dump reads as a trace across boundaries rather than a flat list.
  void log(String layer, String message) {
    _entries.add('${_stamp()} [$layer] $message');
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    // Mirrored to the console so `adb logcat` picks it up when a device
    // *is* attached — same trace, two ways out. Not gated on debug mode:
    // this only ever runs on a user-initiated mic tap, and release builds
    // are exactly where the interesting failures happen.
    dlog('Voice', '[voice/$layer] $message');
  }

  /// Marks the start of a new mic tap and returns its sequence number.
  int beginTap() {
    _tapCounter++;
    log('tap', '──── tap #$_tapCounter ────');
    return _tapCounter;
  }

  bool get isEmpty => _entries.isEmpty;

  /// Full buffer, oldest first, one entry per line — the payload behind
  /// the "copy diagnostics" action.
  String dump() =>
      _entries.isEmpty ? '(no voice diagnostics recorded yet)' : _entries.join('\n');

  /// Most recent [count] entries, for embedding in a dialog where the full
  /// buffer would be unreadable.
  String tail(int count) {
    if (_entries.isEmpty) return '(empty)';
    final from = _entries.length <= count ? 0 : _entries.length - count;
    return _entries.sublist(from).join('\n');
  }

  @visibleForTesting
  void clear() {
    _entries.clear();
    _tapCounter = 0;
  }
}
