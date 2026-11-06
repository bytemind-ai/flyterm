// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::TransportSender<UserStream> in src/network/transportsender.cc
//
// Key invariant: sentStates is NEVER silently dropped. It is trimmed only when
// onAck advances assumedReceiverStateNum. v1's "drop oldest when over limit"
// behaviour broke the state chain on long disconnects -- v2 instead surfaces a
// hard-reset signal once the backlog exceeds mobile-friendly bounds.
import 'dart:typed_data';
import 'sent_state.dart';

class TransportSender {
  /// DEVIATION (mobile): mosh has no upper bound on sent_states size.
  /// We cap to avoid unbounded memory growth on extended offline scenarios.
  static const int kHardResetMaxPending = 1000;
  // 120s gives the 75s supervisor watchdog (which runs roam at 45s and hard
  // reset at 75s) a chance to escalate first. Previously 90s — sender backlog
  // would beat supervisor to the hard-reset, skipping the roam attempt that
  // might have refreshed NAT mapping in the unidirectional-loss case.
  static const Duration kHardResetMaxAge = Duration(seconds: 120);

  final List<SentState> sentStates = [];
  int assumedReceiverStateNum = 0;
  int _nextNum = 0;
  DateTime _lastAckAdvanceAt;

  TransportSender({DateTime? now})
      : _lastAckAdvanceAt = now ?? DateTime.now() {
    sentStates.add(SentState(
      num: _nextNum++,
      timestamp: now ?? DateTime.now(),
      userInput: Uint8List(0),
    ));
  }

  void appendUserInput(Uint8List bytes, {DateTime? now}) {
    final last = sentStates.last;
    final merged = Uint8List(last.userInput.length + bytes.length)
      ..setRange(0, last.userInput.length, last.userInput)
      ..setRange(last.userInput.length, last.userInput.length + bytes.length, bytes);
    sentStates.add(SentState(
      num: _nextNum++,
      timestamp: now ?? DateTime.now(),
      userInput: merged,
    ));
  }

  // Diagnostic counters surfaced via debug overlay.
  int onAckCallCount = 0;
  int onAckTrimmedCount = 0;
  int lastSeenAckNum = 0;
  // Last N ack values + their arrival timestamps so the overlay (and the
  // sender-backlog reason string) can show whether the server stopped
  // advancing ack or kept oscillating in a small range.
  static const int _kRecentAcksCap = 8;
  final List<({DateTime at, int ackNum})> recentAcks = [];

  /// Last time [assumedReceiverStateNum] strictly increased. Stays at
  /// construction time until the first server packet bumps the ack number.
  DateTime get lastAckAdvanceAt => _lastAckAdvanceAt;

  Duration ackStallDuration({required DateTime now}) =>
      now.difference(_lastAckAdvanceAt);

  // Timestamp of when the app entered background, used by noteResumed to
  // shift sentState timestamps forward by the background duration so that
  // background time is not counted toward shouldHardReset's kHardResetMaxAge.
  DateTime? _suspendedAt;

  /// Called when the app goes to background. Resets the stall clock so the
  /// background period is not counted as an ACK stall; records entry time so
  /// [noteResumed] can shift sentState timestamps forward on return.
  void noteBackground({DateTime? now}) {
    final t = now ?? DateTime.now();
    _lastAckAdvanceAt = t;
    _suspendedAt = t;
  }

  /// Called when the app returns to foreground. Shifts all sentState timestamps
  /// forward by the background duration so [shouldHardReset]'s age check does
  /// not count background time. Without this, a state created 10 s before
  /// backgrounding + 80 s background = 90 s effective age at resume, which
  /// fires shouldHardReset (threshold 120 s) within 30 s of normal use.
  void noteResumed({DateTime? now}) {
    final t = now ?? DateTime.now();
    if (_suspendedAt != null) {
      final delta = t.difference(_suspendedAt!);
      if (delta.inMilliseconds > 0) {
        final shifted = sentStates
            .map((s) => SentState(
                  num: s.num,
                  timestamp: s.timestamp.add(delta),
                  userInput: s.userInput,
                ))
            .toList();
        sentStates
          ..clear()
          ..addAll(shifted);
      }
      _suspendedAt = null;
    }
    _lastAckAdvanceAt = t;
  }

  /// Returns true when a re-seed occurred (ackNum jumped past all local
  /// states). Caller should then also seed the receiver at the same num so
  /// the chain gate accepts the server's next D(ackNum→X).
  bool onAck(int ackNum, {DateTime? now}) {
    onAckCallCount++;
    lastSeenAckNum = ackNum;
    final t = now ?? DateTime.now();
    recentAcks.add((at: t, ackNum: ackNum));
    if (recentAcks.length > _kRecentAcksCap) {
      recentAcks.removeAt(0);
    }
    final before = sentStates.length;
    sentStates.removeWhere((s) => s.num < ackNum);
    onAckTrimmedCount += (before - sentStates.length);
    bool reseeded = false;
    if (sentStates.isEmpty) {
      // ackNum jumped past all local states — happens on soft reconnect when the
      // server still has ack history from the previous session (e.g. ackNum=151
      // while fresh sender only has states 0–1). Re-seed at ackNum so the server
      // has a matching base in its received_states and keystrokes resume without
      // needing a full hard reconnect.
      sentStates.add(SentState(
        num: ackNum,
        timestamp: t,
        userInput: Uint8List(0),
      ));
      _nextNum = ackNum + 1;
      reseeded = true;
    }
    if (ackNum > assumedReceiverStateNum) {
      assumedReceiverStateNum = ackNum;
      _lastAckAdvanceAt = t;
    }
    return reseeded;
  }

  bool shouldHardReset({required DateTime now}) {
    if (sentStates.length > kHardResetMaxPending) return true;
    if (sentStates.length > 1) {
      final oldest = sentStates.first;
      if (now.difference(oldest.timestamp) > kHardResetMaxAge) return true;
    }
    return false;
  }

  /// Compact representation of the recent ack stream: "[N@ms,...]" where ms
  /// is the age relative to [now]. Empty list when no acks observed yet.
  String recentAcksDump({required DateTime now}) {
    if (recentAcks.isEmpty) return '[]';
    final parts = recentAcks
        .map((a) =>
            '${a.ackNum}@${now.difference(a.at).inMilliseconds ~/ 100}d')
        .join(',');
    return '[$parts]';
  }

  /// Computes the diff from assumedReceiverStateNum to the latest state.
  /// Returns null when there is nothing new to send.
  ({int oldNum, int newNum, Uint8List diff})? makeDiffFromAssumed() {
    final base = sentStates.firstWhere(
      (s) => s.num == assumedReceiverStateNum,
      orElse: () => sentStates.first,
    );
    final cur = sentStates.last;
    if (base.num == cur.num) return null;
    final diff = Uint8List(cur.userInput.length - base.userInput.length);
    diff.setRange(0, diff.length, cur.userInput, base.userInput.length);
    return (oldNum: base.num, newNum: cur.num, diff: diff);
  }
}
