// SPDX-License-Identifier: GPL-3.0-or-later
/// Per-tab connection health score, used to pick tight vs loose watchdog/keepalive thresholds.
///
/// score 0-100, initial 50.
/// recordOkPacket +1 (cap 100); recordMissedDeadline -30 (floor 0).
/// isStable = score >= 50. smoothedRtt EWMA α=0.2.
/// recordReconnect resets score to 30 (below stable threshold).
class NetworkStability {
  static const _kAlpha = 0.2;
  static const _kStableThreshold = 50;
  static const _kReconnectResetScore = 30;
  static const _kOkBoost = 1;
  static const _kMissedPenalty = 30;

  int _score = 50;
  Duration? _smoothedRtt;

  // Diagnostic counters — surfaced in debug overlay to identify why the
  // score is sitting below 50 (which paints the status dot orange).
  int okCount = 0;
  int missedCount = 0;
  int reconnectSuccessCount = 0;
  int reconnectResetCount = 0;
  String lastEvent = 'init';

  int get score => _score;
  Duration? get smoothedRtt => _smoothedRtt;
  bool get isStable => _score >= _kStableThreshold;

  void recordOkPacket(Duration rtt) {
    okCount++;
    lastEvent = 'ok';
    // Self-heal: if score is below stable threshold but auth packets are
    // flowing (recordOkPacket fires), force-bump to the threshold after a few
    // consecutive ok packets. Without this, a single recordMissedDeadline
    // penalty (-30) keeps the dot orange for 30 +1 ticks, even though the
    // connection is demonstrably alive.
    if (_score < _kStableThreshold) {
      _score = _kStableThreshold;
    } else {
      _score = (_score + _kOkBoost).clamp(0, 100);
    }
    final prev = _smoothedRtt;
    if (prev == null) {
      _smoothedRtt = rtt;
    } else {
      final blendedMs =
          (_kAlpha * rtt.inMilliseconds + (1 - _kAlpha) * prev.inMilliseconds)
              .round();
      _smoothedRtt = Duration(milliseconds: blendedMs);
    }
  }

  String lastMissedReason = '';

  void recordMissedDeadline([String reason = '']) {
    missedCount++;
    lastEvent = 'missed';
    if (reason.isNotEmpty) {
      lastMissedReason = reason;
    }
    _score = (_score - _kMissedPenalty).clamp(0, 100);
  }

  void recordReconnect() {
    reconnectResetCount++;
    lastEvent = 'reconReset';
    _score = _kReconnectResetScore;
  }

  void recordReconnectSuccess() {
    reconnectSuccessCount++;
    lastEvent = 'reconOk';
    _score = _kStableThreshold;
  }
}
