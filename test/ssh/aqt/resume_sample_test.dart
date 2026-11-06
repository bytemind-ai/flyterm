import 'package:flyterm/ssh/aqt/resume_sample.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bucketFor', () {
    test('按后台时长分档', () {
      expect(bucketFor(10 * 1000), BackgroundBucket.under30s);
      expect(bucketFor(60 * 1000), BackgroundBucket.under90s);
      expect(bucketFor(120 * 1000), BackgroundBucket.under3min);
      expect(bucketFor(10 * 60 * 1000), BackgroundBucket.under30min);
      expect(bucketFor(60 * 60 * 1000), BackgroundBucket.over30min);
    });

    test('边界值归属下一档', () {
      expect(bucketFor(30 * 1000), BackgroundBucket.under90s);
      expect(bucketFor(90 * 1000), BackgroundBucket.under3min);
    });

    test('非前台触发没有档位', () {
      expect(bucketFor(null), isNull);
    });
  });

  group('ResumeSpan', () {
    test('五段首尾相接，加总等于端到端', () {
      final span = ResumeSpan(
        trigger: ResumeTrigger.foreground,
        backgroundMs: 5 * 60 * 1000,
        t0: 1000,
      );
      span.markFirstAttempt(1050);
      span.markSent(1200);
      span.markAck(1260);
      span.markTransferDone(1400);
      final sample = span.close(t5: 1500, outcome: ResumeOutcomeKind.ok);

      expect(sample.decideMs, 50);
      expect(sample.retryMs, 150);
      expect(sample.handshakeMs, 60);
      expect(sample.transferMs, 140);
      expect(sample.applyMs, 100);
      expect(sample.totalMs, 500, reason: 't5 - t0 必须等于五段之和');
    });

    test('无重试时 retryMs 为 0', () {
      final span = ResumeSpan(
        trigger: ResumeTrigger.connectivity,
        backgroundMs: null,
        t0: 0,
      );
      span.markFirstAttempt(100);
      span.markSent(100);
      span.markAck(150);
      span.markTransferDone(200);
      final sample = span.close(t5: 250, outcome: ResumeOutcomeKind.ok);
      expect(sample.retryMs, 0);
    });

    test('未闭合的段记为 abandoned，不悬挂', () {
      final span = ResumeSpan(
        trigger: ResumeTrigger.foreground,
        backgroundMs: 1000,
        t0: 0,
      );
      span.markFirstAttempt(10);
      final sample = span.close(t5: 500, outcome: ResumeOutcomeKind.abandoned);
      expect(sample.outcome, ResumeOutcomeKind.abandoned);
      expect(sample.handshakeMs, 0, reason: '没走到的段记 0 而非 null');
      expect(sample.applyMs, 490,
          reason: '兜底把剩余时间全堆进最后一段 —— 这是已知失真，'
              '所以 abandoned 样本不参与分段统计');
      expect(sample.totalMs, 500, reason: '总和仍然等于 t5 - t0');
    });

    test('markFirstAttempt 幂等 —— 重试循环里每轮都调，只有第一次生效', () {
      final span = ResumeSpan(
        trigger: ResumeTrigger.foreground,
        backgroundMs: 1000,
        t0: 0,
      );
      span.markFirstAttempt(100);
      span.markFirstAttempt(300); // 第二轮重试
      span.markFirstAttempt(700); // 第三轮重试
      span.markSent(700);
      span.markAck(800);
      span.markTransferDone(900);
      final sample = span.close(t5: 1000, outcome: ResumeOutcomeKind.ok);
      expect(sample.decideMs, 100,
          reason: '① 段的终点必须是**首次**尝试，不能被后续重试覆盖');
      expect(sample.retryMs, 600, reason: '② 段 = 首次发起到最终成功那次');
    });

    test('失败尝试记进 attempts，不占主时间轴', () {
      final span = ResumeSpan(
        trigger: ResumeTrigger.foreground,
        backgroundMs: 1000,
        t0: 0,
      );
      span.markFirstAttempt(0);
      span.recordAttempt(reason: 'networkTimeout', elapsedMs: 30);
      span.recordAttempt(reason: 'networkTimeout', elapsedMs: 25);
      span.markSent(600);
      span.markAck(700);
      span.markTransferDone(800);
      final sample = span.close(t5: 900, outcome: ResumeOutcomeKind.ok);
      expect(sample.attempts.length, 2);
      expect(sample.retryMs, 600);
      expect(sample.totalMs, 900);
    });
  });
}
