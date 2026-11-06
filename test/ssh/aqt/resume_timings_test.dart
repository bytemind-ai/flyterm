// test/ssh/aqt/resume_timings_test.dart
//
// Unit tests for ResumeTimings model (debug overlay `res` row).

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';

void main() {
  group('ResumeTimings', () {
    final t0 = DateTime(2026, 5, 30, 0, 0, 0);
    final t1 = t0.add(const Duration(milliseconds: 250));
    final t2 = t1.add(const Duration(milliseconds: 1200));

    test('default constructor is all null', () {
      const r = ResumeTimings();
      expect(r.sentAt, isNull);
      expect(r.ackAt, isNull);
      expect(r.replayCompleteAt, isNull);
      expect(r.screenBytes, 0);
      expect(r.ackRttMs, isNull);
      expect(r.replayMs, isNull);
      expect(r.ageSec, isNull);
    });

    test('ackRttMs computed from sentAt + ackAt', () {
      final r = ResumeTimings(sentAt: t0, ackAt: t1);
      expect(r.ackRttMs, 250);
    });

    test('ackRttMs null when ackAt missing', () {
      final r = ResumeTimings(sentAt: t0);
      expect(r.ackRttMs, isNull);
    });

    test('ackRttMs null when sentAt missing', () {
      final r = ResumeTimings(ackAt: t1);
      expect(r.ackRttMs, isNull);
    });

    test('replayMs computed from ackAt + replayCompleteAt', () {
      final r = ResumeTimings(ackAt: t1, replayCompleteAt: t2);
      expect(r.replayMs, 1200);
    });

    test('replayMs null when only one of the two timestamps set', () {
      final r1 = ResumeTimings(ackAt: t1);
      final r2 = ResumeTimings(replayCompleteAt: t2);
      expect(r1.replayMs, isNull);
      expect(r2.replayMs, isNull);
    });

    test('ageSec measured against now', () {
      final past = DateTime.now().subtract(const Duration(seconds: 5));
      final r = ResumeTimings(replayCompleteAt: past);
      // Allow ±1s wiggle for test scheduler.
      expect(r.ageSec, inInclusiveRange(4, 6));
    });

    test('ageSec null when replayCompleteAt missing', () {
      final r = ResumeTimings(sentAt: t0, ackAt: t1);
      expect(r.ageSec, isNull);
    });

    test('screenBytes preserved verbatim', () {
      const r = ResumeTimings(screenBytes: 65536);
      expect(r.screenBytes, 65536);
    });

    test('all stages set computes both rtt and replay durations', () {
      final r = ResumeTimings(sentAt: t0, ackAt: t1, replayCompleteAt: t2, screenBytes: 1024);
      expect(r.ackRttMs, 250);
      expect(r.replayMs, 1200);
      expect(r.screenBytes, 1024);
    });
  });

  group('preludeReplayRemaining 接线', () {
    test('recordReplayComplete 之后 replayMs 不再为 null', () {
      final t = AqtTransport.testStub();
      t.recordResumeSent();
      t.recordResumeAck();
      expect(t.lastResumeTimings.replayMs, isNull,
          reason: 'replayComplete 之前应为 null');
      t.recordReplayComplete();
      expect(t.lastResumeTimings.replayMs, isNotNull,
          reason: '这正是 F8 断链修复后要恢复的能力');
      expect(t.lastResumeTimings.replayMs, greaterThanOrEqualTo(0));
    });
  });
}
