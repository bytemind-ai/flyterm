import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/state_machine/transport_instruction.dart';
import 'package:flyterm/ssh/ssp_v2/state_machine/transport_receiver.dart';

TransportInstruction _i(int oldN, int newN, List<int> diff) =>
    TransportInstruction(
      oldNum: oldN,
      newNum: newN,
      ackNum: 0,
      throwawayNum: 0,
      diff: Uint8List.fromList(diff),
    );

void main() {
  test('apply diff when oldNum exists', () {
    final r = TransportReceiver();
    final res = r.onPacket(_i(0, 1, [72, 105]));
    expect(res.appliedHostBytes, Uint8List.fromList([72, 105]));
    expect(r.latestNum, 1);
    expect(r.receivedStates.containsKey(1), true);
  });

  test('drop diff when oldNum unknown (no apply)', () {
    final r = TransportReceiver();
    final res = r.onPacket(_i(99, 100, [1]));
    expect(res.appliedHostBytes, isNull);
    expect(r.latestNum, 0);
  });

  // 上限从 kMaxStates 现读，不写字面量。这两条原先钉的是 32，而实现早已提到
  // 128（见 kMaxStates 上的注释：32 低于 mosh-server 在弱网下的在途重传深度，
  // 每次重连都产生约 30 次 baseMissing）。钉住数字的结果是「跑 50 个包」既
  // 触发不了修剪、断言又要求已经修剪过。
  test('prunes oldest states once past kMaxStates', () {
    final r = TransportReceiver();
    const n = TransportReceiver.kMaxStates + 20;
    for (var i = 0; i < n; i++) {
      r.onPacket(_i(i, i + 1, [i & 0xff]));
    }
    expect(r.receivedStates.length,
        lessThanOrEqualTo(TransportReceiver.kMaxStates));
    expect(r.latestNum, n);
  });

  test('throwawayNum tracks oldest known state', () {
    final r = TransportReceiver();
    expect(r.throwawayNum, 0, reason: '只有初始 state 0 时最旧的就是它');

    // 没到上限就不修剪，最旧的仍是 0 —— throwawayNum 告诉服务端「我这边最老
    // 的状态是哪个」，没剪掉的东西不能谎报成剪掉了。
    for (var i = 0; i < 40; i++) {
      r.onPacket(_i(i, i + 1, [0]));
    }
    expect(r.throwawayNum, 0);

    // 越过上限之后最旧的几个被剪掉，throwawayNum 随之抬升。
    for (var i = 40; i < TransportReceiver.kMaxStates + 20; i++) {
      r.onPacket(_i(i, i + 1, [0]));
    }
    expect(r.throwawayNum, greaterThan(0));
    expect(r.throwawayNum, r.receivedStates.keys.first);
  });

  test('non-chained diff (oldNum != latestNum) does NOT emit or advance', () {
    // Server retransmits cumulative diffs rooted at the last ack it saw.
    // If our ack is in flight, server sends D(oldAck → newer) where the diff
    // body contains bytes already on screen. Re-emitting them duplicates
    // text — visible as "画面残留" when scrolling Claude's history.
    // Mirrors v1 ssp_transport.dart:1198 strict oldNum==_recvSeq gate.
    final r = TransportReceiver();
    r.onPacket(_i(0, 1, [1]));
    r.onPacket(_i(1, 2, [2]));
    final late = r.onPacket(_i(0, 5, [9]));
    expect(late.appliedHostBytes, isNull,
        reason: 'unchained diff must not be replayed to xterm');
    expect(r.latestNum, 2,
        reason: 'latestNum must NOT advance on unchained diffs — '
            'next chained D(2→N) from server (after seeing our ack) applies');
  });

  test('retransmitted diff with newNum <= latestNum returns null', () {
    // mosh-server retransmits the same diff every tick until it sees our ack.
    // The receiver must surface the bytes exactly once — re-emitting them on
    // each retransmit causes "residual characters" on input deletion (the
    // backspace echo gets replayed into xterm 4-5 times).
    final r = TransportReceiver();
    final first = r.onPacket(_i(0, 1, [42]));
    expect(first.appliedHostBytes, isNotNull);
    final retransmit = r.onPacket(_i(0, 1, [42]));
    expect(retransmit.appliedHostBytes, isNull,
        reason: 'duplicate newNum must not be replayed to xterm');
    final older = r.onPacket(_i(0, 0, [9]));
    expect(older.appliedHostBytes, isNull,
        reason: 'older newNum must not be replayed');
  });
}
