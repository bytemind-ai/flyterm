// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::TimestampedState<TerminalComplete> in src/network/transportstate.h.
//
// We only need each state's num + timestamp to drive the receiver chain
// gate (oldNum == latestNum) and bMiss detection (oldNum in receivedStates).
// Earlier versions also accumulated the cumulative host_bytes — but that
// value was never read out: ReceiverResult emits inst.diff directly. With
// kMaxStates raised to 128 the accumulation was quadratic in memory and a
// GC hot-spot for no functional benefit.
import 'dart:typed_data';

class ReceivedState {
  final int num;
  final DateTime timestamp;

  ReceivedState({
    required this.num,
    required this.timestamp,
  });

  ReceivedState advance(int newNum, DateTime ts) =>
      ReceivedState(num: newNum, timestamp: ts);

  // Kept for ABI compatibility with the prior signature (TransportReceiver
  // calls applyDiff). The diff bytes are ignored — see class header.
  ReceivedState applyDiff(Uint8List diff, int newNum, DateTime ts) =>
      advance(newNum, ts);
}
