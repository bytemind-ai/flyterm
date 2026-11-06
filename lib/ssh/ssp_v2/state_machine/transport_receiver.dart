// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::TransportFragment / TransportReceiver apply path in
// src/network/transportfragment.cc
//
// Key invariant: receivedStates is a SplayTreeMap keyed by num, NOT a single
// _recvSeq counter. This lets the receiver apply diffs against any known
// oldNum, eliminating v1's need for a fullResync escape hatch when the server
// references a base state that has already been overtaken by a later diff.
import 'dart:collection';
import 'dart:typed_data';
import 'received_state.dart';
import 'transport_instruction.dart';

class ReceiverResult {
  /// non-null when the diff was successfully applied.
  final Uint8List? appliedHostBytes;
  ReceiverResult(this.appliedHostBytes);
}

class TransportReceiver {
  // 32 was below the typical mosh-server in-flight retransmit depth on flaky
  // mobile links — every reconnect produced ~30 bMiss as the server kept
  // referencing host states we had already pruned. 128 covers the practical
  // worst case while still bounding memory (≤ 128 × diff size on 32 kB main
  // buffer wrap = a few MB).
  static const int kMaxStates = 128;

  final SplayTreeMap<int, ReceivedState> receivedStates = SplayTreeMap();
  int latestNum = 0;

  // Diagnostic drop counters — surfaced via MoshV2Connection getters for the
  // debug overlay. Distinguishing "base missing" from "stale" from "chain
  // gate" tells us *which* invariant the server keeps tripping on first
  // connect, which determines whether the supervisor escalates to
  // hardReconnect because of OCB failures (no onPacket at all) or because
  // every packet decoded but got dropped here (onPacket fires, but the user
  // sees a blank screen).
  int onPacketCallCount = 0;
  int baseMissingDrops = 0;
  int staleDrops = 0;
  int chainGateDrops = 0;
  int appliedCount = 0;
  int lastInstOldNum = 0;
  int lastInstNewNum = 0;
  // 'init' until first onPacket runs; then one of 'baseMiss', 'stale', 'chain',
  // 'applied'. Lets the overlay see which branch the most recent onPacket call
  // took even if counters look quiescent.
  String lastBranch = 'init';

  TransportReceiver({DateTime? now}) {
    receivedStates[0] = ReceivedState(
      num: 0,
      timestamp: now ?? DateTime.now(),
    );
  }

  /// Re-anchor the receiver at [num] after a sender re-seed. Called by
  /// MoshV2Connection when TransportSender.onAck detects that ackNum jumped
  /// past all local states (soft reconnect session handoff): the server's
  /// oldest known state is [num], so the receiver must also start there or
  /// every subsequent D(num→X) will be a baseMissing drop and the screen
  /// freezes permanently.
  void seedAt(int num, {DateTime? now}) {
    receivedStates.clear();
    receivedStates[num] = ReceivedState(
      num: num,
      timestamp: now ?? DateTime.now(),
    );
    latestNum = num;
  }

  ReceiverResult onPacket(TransportInstruction inst, {DateTime? now}) {
    onPacketCallCount++;
    lastInstOldNum = inst.oldNum;
    lastInstNewNum = inst.newNum;
    final base = receivedStates[inst.oldNum];
    if (base == null) {
      baseMissingDrops++;
      lastBranch = 'baseMiss';
      return ReceiverResult(null);
    }
    if (inst.newNum <= latestNum) {
      staleDrops++;
      lastBranch = 'stale';
      return ReceiverResult(null);
    }
    // Strict chain gate (mirrors v1 ssp_transport.dart:1198 oldNum==_recvSeq):
    // mosh-server's diff body is the bytes accumulated from oldNum→newNum.
    // When our ack is in flight, server sends D(oldAck→newer) where oldAck
    // < latestNum and the diff redundantly contains bytes already on screen
    // (the "画面残留" symptom when scrolling Claude history). We must
    // neither emit those bytes NOR advance latestNum — the next packet,
    // once server sees our ack, will be re-rooted at our true latestNum
    // and the chain resumes.
    if (inst.oldNum != latestNum) {
      chainGateDrops++;
      lastBranch = 'chain';
      return ReceiverResult(null);
    }
    final ts = now ?? DateTime.now();
    final newState = base.advance(inst.newNum, ts);
    receivedStates[inst.newNum] = newState;
    latestNum = inst.newNum;
    appliedCount++;
    lastBranch = 'applied';
    while (receivedStates.length > kMaxStates) {
      receivedStates.remove(receivedStates.firstKey());
    }
    return ReceiverResult(inst.diff);
  }

  /// throwaway_num = oldest known received state's num. Per mosh semantics,
  /// this tells the server which of OUR client states it can prune.
  int get throwawayNum =>
      receivedStates.isEmpty ? 0 : receivedStates.firstKey()!;
}
