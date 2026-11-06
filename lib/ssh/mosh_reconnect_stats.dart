// SPDX-License-Identifier: GPL-3.0-or-later
// Per-tab mosh reconnect statistics. Centralises every reconnect-related
// counter so the debug overlay can show a single, structured picture instead
// of N scattered fields. Used to diagnose "动不动重连" and tune watchdog
// thresholds in production.
//
// Lifecycle is per-tab — counters reset only when the tab is recreated.
// The recent-event ring buffer is bounded to avoid unbounded growth on long
// sessions; older entries are dropped silently.
//
// Reason strings are free-form so v2 paths can attach details like
// "pending=N, oldestAgeS=M" or "no auth packet for 47s" without growing
// the enum. Keep them under ~60 chars so the overlay row stays readable.

import 'dart:math' as math;

enum MoshReconnectStage {
  /// LivenessSupervisor / sender-backlog / lifecycle emitted hardReconnectNeeded.
  hardTrigger,

  /// _reconnect() began (full SSH+mosh re-handshake).
  attemptStart,

  /// _reconnect() finished and recordReconnectSuccess() ran.
  attemptOk,

  /// _reconnect() threw and recordMissedDeadline() ran.
  attemptFail,
}

class MoshReconnectEvent {
  final DateTime at;
  final MoshReconnectStage stage;
  final String reason;
  final Duration? elapsed;

  const MoshReconnectEvent({
    required this.at,
    required this.stage,
    required this.reason,
    this.elapsed,
  });

  String get stageLabel {
    switch (stage) {
      case MoshReconnectStage.hardTrigger:
        return 'TRIG';
      case MoshReconnectStage.attemptStart:
        return 'TRY';
      case MoshReconnectStage.attemptOk:
        return 'OK';
      case MoshReconnectStage.attemptFail:
        return 'FAIL';
    }
  }
}

class MoshReconnectStats {
  static const int kMaxEvents = 20;

  // Lifetime counters.
  int hardTriggerCount = 0;
  int attemptStartCount = 0;
  int attemptOkCount = 0;
  int attemptFailCount = 0;

  // Buckets keyed by a short tag derived from the free-form reason. Tag
  // extraction lives in [_tagOf]; non-matching reasons fall into "other".
  final Map<String, int> triggerReasonCounts = {};
  final Map<String, int> failureReasonCounts = {};

  // Cumulative time spent in reconnect attempts (sum of attempt elapsed).
  Duration totalAttemptElapsed = Duration.zero;
  Duration? lastAttemptElapsed;

  // First/last absolute timestamps — useful for "X reconnects in N minutes".
  DateTime? firstEventAt;
  DateTime? lastEventAt;

  // Active attempt tracking — non-null between attemptStart and attemptOk/Fail.
  DateTime? _attemptStartedAt;

  // Bounded ring of recent events (newest at index 0).
  final List<MoshReconnectEvent> recentEvents = [];

  void noteHardTrigger(String reason) {
    final now = DateTime.now();
    hardTriggerCount++;
    _bumpTag(triggerReasonCounts, _tagOf(reason));
    _push(MoshReconnectEvent(
      at: now,
      stage: MoshReconnectStage.hardTrigger,
      reason: reason,
    ));
    firstEventAt ??= now;
    lastEventAt = now;
  }

  void noteAttemptStart(String trigger) {
    final now = DateTime.now();
    attemptStartCount++;
    _attemptStartedAt = now;
    _push(MoshReconnectEvent(
      at: now,
      stage: MoshReconnectStage.attemptStart,
      reason: trigger,
    ));
    firstEventAt ??= now;
    lastEventAt = now;
  }

  void noteAttemptOk() {
    final now = DateTime.now();
    final started = _attemptStartedAt;
    final elapsed = started == null ? null : now.difference(started);
    _attemptStartedAt = null;
    attemptOkCount++;
    if (elapsed != null) {
      totalAttemptElapsed += elapsed;
      lastAttemptElapsed = elapsed;
    }
    _push(MoshReconnectEvent(
      at: now,
      stage: MoshReconnectStage.attemptOk,
      reason: '',
      elapsed: elapsed,
    ));
    lastEventAt = now;
  }

  void noteAttemptFail(String errorSummary) {
    final now = DateTime.now();
    final started = _attemptStartedAt;
    final elapsed = started == null ? null : now.difference(started);
    _attemptStartedAt = null;
    attemptFailCount++;
    if (elapsed != null) {
      totalAttemptElapsed += elapsed;
      lastAttemptElapsed = elapsed;
    }
    _bumpTag(failureReasonCounts, _tagOf(errorSummary));
    _push(MoshReconnectEvent(
      at: now,
      stage: MoshReconnectStage.attemptFail,
      reason: errorSummary,
      elapsed: elapsed,
    ));
    lastEventAt = now;
  }

  /// Compact single-line overview used in the debug overlay.
  /// Format: `trig=N ok=M fail=K avgT=...s triggers=sup:A,snd:B fails=to:X,hs:Y`
  String compactSummary() {
    final avgMs = (attemptOkCount + attemptFailCount) == 0
        ? 0
        : (totalAttemptElapsed.inMilliseconds /
                (attemptOkCount + attemptFailCount))
            .round();
    final trigParts = triggerReasonCounts.entries
        .map((e) => '${e.key}:${e.value}')
        .join(',');
    final failParts = failureReasonCounts.entries
        .map((e) => '${e.key}:${e.value}')
        .join(',');
    final parts = <String>[
      'trig=$hardTriggerCount',
      'ok=$attemptOkCount',
      'fail=$attemptFailCount',
      if (avgMs > 0) 'avgT=${(avgMs / 1000).toStringAsFixed(1)}s',
      if (trigParts.isNotEmpty) 'src=$trigParts',
      if (failParts.isNotEmpty) 'err=$failParts',
    ];
    return parts.join(' ');
  }

  /// Recent N events as short strings: "hh:mm:ss STAGE reason".
  List<String> recentLines({int n = 5}) {
    final take = math.min(n, recentEvents.length);
    return recentEvents.take(take).map((e) {
      final hms = e.at.toIso8601String().substring(11, 19);
      final tail = e.reason.isEmpty
          ? ''
          : ' ${e.reason.length > 40 ? "${e.reason.substring(0, 40)}…" : e.reason}';
      final elapsed = e.elapsed == null
          ? ''
          : ' (${e.elapsed!.inMilliseconds}ms)';
      return '$hms ${e.stageLabel}$tail$elapsed';
    }).toList();
  }

  // ── helpers ─────────────────────────────────────────────────────────────

  void _push(MoshReconnectEvent e) {
    recentEvents.insert(0, e);
    if (recentEvents.length > kMaxEvents) {
      recentEvents.removeRange(kMaxEvents, recentEvents.length);
    }
  }

  void _bumpTag(Map<String, int> bucket, String tag) {
    bucket[tag] = (bucket[tag] ?? 0) + 1;
  }

  /// Reduce a free-form reason string to a short bucket tag. Pattern matching
  /// is intentionally permissive — adding new server-side reasons later won't
  /// break the overlay, they just fall into "other" until a tag is added here.
  static String _tagOf(String reason) {
    final lower = reason.toLowerCase();
    // Supervisor: "no auth packet for Ns"
    if (lower.contains('no auth packet')) return 'sup';
    // Sender backlog: "sender backlog pending=..., oldestAgeS=..."
    if (lower.contains('sender backlog') || lower.contains('pending=')) {
      return 'snd';
    }
    // Lifecycle resume: "app backgrounded > 60s"
    if (lower.contains('backgrounded')) return 'life';
    // Reconnect attempt failure modes
    if (lower.contains('timeout')) return 'to';
    if (lower.contains('handshake') ||
        lower.contains('moshhandshakeexception') ||
        lower.contains('mosh-server')) {
      return 'hs';
    }
    if (lower.contains('ssh') || lower.contains('socketexception')) {
      return 'ssh';
    }
    if (lower.contains('typeerror') || lower.contains('caster')) {
      return 'type';
    }
    if (lower.contains('statemissmatch') || lower.contains('stateerror')) {
      return 'state';
    }
    return 'other';
  }
}
