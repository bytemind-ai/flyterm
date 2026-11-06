// SPDX-License-Identifier: GPL-3.0-or-later
// Detects long real-time gaps caused by iOS app suspend / Android doze.
// When the wall-clock advances by much more than expectedInterval between
// ticks, fires onSuspectedSuspend so the connection layer can reset its
// liveness deadlines instead of treating the suspension as "no packets =
// network dead".
class ClockDriftDetector {
  Duration expectedInterval;
  DateTime Function() now;
  final void Function(Duration actualGap) onSuspectedSuspend;
  DateTime? _last;

  ClockDriftDetector({
    required this.expectedInterval,
    required this.onSuspectedSuspend,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  void onTick() {
    final t = now();
    final last = _last;
    _last = t;
    if (last == null) return;
    final gap = t.difference(last);
    if (gap > expectedInterval * 5) onSuspectedSuspend(gap);
  }
}
