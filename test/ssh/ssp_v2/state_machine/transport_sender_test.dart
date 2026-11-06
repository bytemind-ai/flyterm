import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/state_machine/transport_sender.dart';

void main() {
  test('initial sender has one state at num 0', () {
    final s = TransportSender();
    expect(s.sentStates, hasLength(1));
    expect(s.sentStates.first.num, 0);
    expect(s.assumedReceiverStateNum, 0);
  });

  test('appendUserInput produces monotonic nums', () {
    final s = TransportSender();
    s.appendUserInput(Uint8List.fromList([1]));
    s.appendUserInput(Uint8List.fromList([2]));
    expect(s.sentStates.map((e) => e.num).toList(), [0, 1, 2]);
  });

  test('onAck trims sentStates with num < ack', () {
    final s = TransportSender();
    for (var i = 0; i < 5; i++) {
      s.appendUserInput(Uint8List.fromList([i]));
    }
    s.onAck(3);
    expect(s.sentStates.map((e) => e.num).toList(), [3, 4, 5]);
    expect(s.assumedReceiverStateNum, 3);
  });

  test('1000 inputs without ack keeps all sentStates', () {
    final s = TransportSender();
    for (var i = 0; i < 999; i++) {
      s.appendUserInput(Uint8List.fromList([i & 0xff]));
    }
    expect(s.sentStates.length, 1000);
    expect(s.shouldHardReset(now: DateTime.now()), false);
  });

  test('shouldHardReset true when pending > 1000', () {
    final s = TransportSender();
    for (var i = 0; i < 1002; i++) {
      s.appendUserInput(Uint8List.fromList([0]));
    }
    expect(s.shouldHardReset(now: DateTime.now()), true);
  });

  test('shouldHardReset true when oldest state older than kHardResetMaxAge', () {
    final t0 = DateTime(2026, 5, 10, 12, 0, 0);
    final s = TransportSender(now: t0);
    s.appendUserInput(Uint8List.fromList([1]), now: t0);
    expect(
      s.shouldHardReset(
        now: t0.add(TransportSender.kHardResetMaxAge + const Duration(seconds: 1)),
      ),
      true,
    );
  });

  test('noteBackground/noteResumed shifts timestamps so background time is excluded', () {
    final t0 = DateTime(2026, 5, 10, 12, 0, 0);
    final s = TransportSender(now: t0);
    s.appendUserInput(Uint8List.fromList([1]), now: t0);
    // Simulate 80s background starting 10s after state creation
    final pauseAt = t0.add(const Duration(seconds: 10));
    s.noteBackground(now: pauseAt);
    final resumeAt = pauseAt.add(const Duration(seconds: 80));
    s.noteResumed(now: resumeAt);
    // Effective age after resume: only 10s (before background), not 90s
    expect(
      s.shouldHardReset(now: resumeAt),
      false,
    );
    // Stall clock also reset — ackStallDuration should be ~0
    expect(s.ackStallDuration(now: resumeAt).inSeconds, 0);
  });

  test('makeDiffFromAssumed returns null when nothing new', () {
    final s = TransportSender();
    expect(s.makeDiffFromAssumed(), isNull);
  });

  test('makeDiffFromAssumed returns suffix bytes after ack', () {
    final s = TransportSender();
    s.appendUserInput(Uint8List.fromList([1, 2]));
    s.appendUserInput(Uint8List.fromList([3, 4]));
    final d = s.makeDiffFromAssumed()!;
    expect(d.oldNum, 0);
    expect(d.newNum, 2);
    expect(d.diff, Uint8List.fromList([1, 2, 3, 4]));

    s.onAck(1);
    final d2 = s.makeDiffFromAssumed()!;
    expect(d2.oldNum, 1);
    expect(d2.newNum, 2);
    expect(d2.diff, Uint8List.fromList([3, 4]));
  });
}
