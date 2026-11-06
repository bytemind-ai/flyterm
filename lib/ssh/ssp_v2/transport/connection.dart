// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::Connection in src/network/network.cc (client side).
//
// Composes the network layer (UDP + OCB + Packet + Nonce) with the state
// machine (TransportSender + TransportReceiver) into a single object that
// implements the project's SspTransport interface.
//
// Mobile-specific guards (P5):
//   * LivenessSupervisor      — 30/40/45s watchdog, drives liveness stream.
//   * Roamer                  — rebinds UDP source port on roaming event.
//   * ClockDriftDetector      — distinguishes OS suspend from real silence.
//   * MoshLifecycleHook       — 60s background -> hard reconnect signal.
import 'dart:async';
import '../../../util/dlog.dart';
import 'dart:io' show InternetAddress, ZLibCodec;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../transport_message.dart' as v1msg;
import '../../ssp_interface.dart';
import '../network/nonce.dart';
import '../network/ocb_cipher.dart';
import '../network/packet.dart';
import '../network/udp_socket.dart';
import '../state_machine/fragmenter.dart';
import '../state_machine/transport_instruction.dart';
import '../state_machine/transport_receiver.dart';
import '../state_machine/tui_detector.dart';
import '../state_machine/transport_sender.dart';
import 'app_lifecycle_hook.dart';
import 'clock_drift_detector.dart';
import 'heartbeat.dart';
import 'liveness_supervisor.dart';
import 'roaming.dart';

class MoshV2Connection implements SspTransport {
  final Uint8List _sessionKey;
  final OcbCipher _txCipher;
  final OcbCipher _rxCipher;
  final NonceGenerator _txNonce =
      NonceGenerator(direction: NonceDirection.client);
  final TransportSender _sender = TransportSender();
  final TransportReceiver _receiver = TransportReceiver();
  final TuiDetector _tuiDetector = TuiDetector();
  final Heartbeat _hb = Heartbeat();
  final LivenessSupervisor _supervisor = LivenessSupervisor();
  late final Roamer _roamer;
  late final ClockDriftDetector _drift;
  MoshLifecycleHook? _lifecycle;

  final _hostBytesCtrl = StreamController<Uint8List>.broadcast();
  final _livenessCtrl = StreamController<SspLivenessEvent>.broadcast();
  // Fires once per Stage-4-decoded packet. MoshShellV2 forwards to its
  // onAuthenticatedPacket hook so terminal_screen's NetworkStability sees
  // real packet flow — otherwise the status dot stays orange (looks red)
  // after any reconnect bump, since recordOkPacket is never called.
  final _authPacketCtrl = StreamController<Duration>.broadcast();

  Timer? _sendTick;
  Timer? _ackTick;
  StreamSubscription<Uint8List>? _udpSub;
  bool _closed = false;
  bool _roamInFlight = false;
  // True while the app is in the background (AppLifecycleState.paused).
  // Suppresses hardReconnectNeeded emission so the supervisor and ackSkew probe
  // do not trigger a reconnect behind the user's back.  Cleared on resume.
  bool _backgrounded = false;

  // Reassembles server-sent diffs that exceed the 500B fragment MTU.
  // mosh-server fragments any diff larger than that — TUI refreshes,
  // tmux pane redraws, even single-frame `clear; ls /usr/bin` output.
  // Without reassembly we permanently drop everything but the last
  // fragment and the user sees a "frozen" terminal even though new
  // packets arrive at the OS layer (e7/e8 follow-up).
  final FragmentAssembler _rxAssembler = FragmentAssembler();

  // Decode-failure counters. _onWire used to swallow every exception in a
  // single catch(_); when packets stop applying we had no way to tell which
  // stage was failing. Counters are surfaced via getters for the debug
  // overlay.
  int _ocbFailCount = 0;
  int _zlibFailCount = 0;
  int _protoFailCount = 0;
  int _otherFailCount = 0;

  // UDP datagrams received (Stage-0 — before OCB). Together with _ocbFailCount
  // this distinguishes "UDP packets arriving but cipher mismatch" from "UDP
  // silence" — only the latter is a real network problem.
  int _udpRxCount = 0;
  int _udpTxCount = 0;

  // Last liveness event we emitted — handy when the dot flips to orange and
  // we want to know whether it was grace/roaming/hardReconnect and the reason
  // string the supervisor or sender attached.
  SspLivenessEvent? _lastLivenessEvent;
  DateTime? _lastLivenessAt;
  DateTime? _firstAuthAt;
  Timer? _postResumeProbeTimer;
  // Monotonic count of inbound packets that passed OCB decryption. Used as a
  // per-probe baseline: each probe snapshots this value and re-checks after
  // its window — strictly increases on any server response, so it cannot be
  // spoofed by a sibling probe manually resetting supervisor.lastInbound.
  int _ocbPassCount = 0;
  // Wall-clock timestamp of the previous _onAckTick. Used to detect OS timer
  // freezes (Doze, app suspend): if the gap between consecutive ticks far
  // exceeds the scheduled interval, the OS held us in standby and the NAT
  // mapping is likely dead — trigger an immediate roam + probe.
  DateTime? _lastAckTickAt;
  Timer? _ackSkewProbeTimer;
  // Completes the first time the receiver successfully applies a diff from the
  // server (appliedCount increments). Used as the soft-reconnect success gate
  // instead of authenticatedPackets.first: OCB decrypt passes on every server
  // packet, but only an applied diff proves the state machines are aligned and
  // the session is actually usable.
  final _firstAppliedCompleter = Completer<void>();
  // One-shot completer for the *next* applied diff after the caller arms it.
  // Unlike _firstAppliedCompleter, this is reset after each use so it can be
  // re-armed for subsequent probes.
  Completer<void>? _nextAppliedCompleter;
  // Unified receiver-stuck detection. The session is "stuck" iff:
  //   (a) appliedCount has not advanced — i.e. no diff has been applied to
  //       the screen since the last check, AND
  //   (b) baseMiss + chainGate drops have grown by >=5 since the last
  //       progress point.
  //
  // Critically, we deliberately EXCLUDE staleDrops from (b). Stale drops
  // are the normal way a mosh-server heartbeat with oldNum==newNum is
  // received by an in-sync receiver — counting them as "bad" would make
  // every idle session with 3 s heartbeats trigger a false reconnect
  // after ~25 s. baseMiss and chain are the genuine state-divergence
  // signals (server's diff base unknown / not chained to our latest);
  // either climbing without any apply progress for 10 s is the
  // "v2 transport broken" pattern that f19.jpg captured.
  DateTime? _stuckSince;
  int _lastAppliedAtStuck = 0;
  int _lastBadDropsAtStuck = 0;
  String? _firstInstDump;
  int _lastInstAckNum = 0;
  String? _stage4LastError;
  int _hostBytesEmitted = 0;
  int _extractEmptyCount = 0;
  int _lastVtLen = 0;

  // Fragment + timestamp header state. Mirrors v1 ssp_transport.dart:
  //   plaintext = [ts 2B BE | ts_reply 2B BE | instrId 8B BE | combinedFrag 2B BE | zlib(inst)]
  // mosh-server treats packets without these headers as malformed and silently
  // drops them — exactly the symptom that produced "blank screen, no sentinel".
  // We always send one fragment (isFinal=1, fragNum=0). v2 payloads are far
  // below the 500B MTU; multi-fragment splitting can be added if needed.
  int _instrIdCounter = 0;
  int _savedTimestamp = 0xFFFF;

  // mosh-server zlib-compresses the Instruction protobuf at level 1
  // before OCB encryption, and zlib-decompresses on receive. v2 must
  // do the same or the server treats every packet as malformed and
  // never sends an ack — exactly what produced the "pending pile-up,
  // blank screen" symptom.
  static final _zlib = ZLibCodec(level: 1);

  MoshV2Connection({
    required MoshUdpSocket udp,
    required Uint8List sessionKey,
    bool installLifecycleHook = true,
    int? initialCols,
    int? initialRows,
  })  : _sessionKey = sessionKey,
        _txCipher = OcbCipher(sessionKey),
        _rxCipher = OcbCipher(sessionKey) {
    _roamer = Roamer(
      peerAddr: udp.peerAddress,
      peerPort: udp.peerPort,
      initial: udp,
    );
    _drift = ClockDriftDetector(
      expectedInterval: _hb.currentInterval,
      onSuspectedSuspend: _onSuspectedSuspend,
    );
    _attachUdp(udp);
    // Two timers, mirroring mosh::TransportSender::tick semantics:
    //   * _sendTick (50ms) — drains pending state diffs as soon as user input
    //     or resize lands. Empty on idle.
    //   * _ackTick (3000ms) — sends an empty heartbeat so the server keeps
    //     the NAT mapping warm and our liveness watchdog doesn't escalate.
    // Previously a single 20ms periodic timer fired _sendCurrentDiff on every
    // wakeup — 50 packets/s of empty diffs that drained mobile battery and,
    // worse, crowded out genuine retransmits when the link was congested.
    _sendTick = Timer.periodic(
        const Duration(milliseconds: 50), (_) => _onSendTick());
    _ackTick = Timer.periodic(
        Heartbeat.kAckInterval, (_) => _onAckTick());
    if (installLifecycleHook) {
      _lifecycle = MoshLifecycleHook(
        onResumedQuick: _onResumedQuick,
        onResumedHardReconnect: _onResumedHard,
      )..start();
    }
    // Mirror v1's initial resize ping: mosh-server defaults to 80x24 and
    // never asks for the real terminal size — we must tell it on the first
    // packet, otherwise the framebuffer stays clipped (e8.jpg) until the
    // first onResize callback fires from the UI (which only happens when
    // dimensions *change*).
    if (initialCols != null && initialRows != null &&
        initialCols > 0 && initialRows > 0) {
      final encoded =
          v1msg.MoshUserMessage.encodeResize(initialCols, initialRows);
      _sender.appendUserInput(encoded);
      _sendCurrentDiff();
    }
  }

  @override
  String get implVersion => 'v2';

  @override
  int get pendingStateCount => _sender.sentStates.length;

  @override
  Stream<Uint8List> get hostBytes => _hostBytesCtrl.stream;

  @override
  Stream<SspLivenessEvent> get liveness => _livenessCtrl.stream;

  /// One event per successfully decoded inbound packet. `rtt` is derived from
  /// the timestamp echo (ts_reply) the server bounces back: we sent `ts_reply`
  /// = our last-saved server timestamp; on the way back the server's `ts_reply`
  /// field carries our previous outbound ts, so (now - that) ≈ round trip.
  Stream<Duration> get authenticatedPackets => _authPacketCtrl.stream;

  @override
  void write(Uint8List bytes) {
    if (_closed) return;
    // mosh-server expects a UserMessage protobuf, not raw bytes.
    // Reuse v1's encoder — the wire format is the same.
    final encoded = v1msg.MoshUserMessage.encodeKeystrokes(bytes);
    _sender.appendUserInput(encoded);
  }

  @override
  void resize(int cols, int rows) {
    if (_closed) return;
    final encoded = v1msg.MoshUserMessage.encodeResize(cols, rows);
    _sender.appendUserInput(encoded);
    // Flush immediately — keyboard show/hide animations must reflow the TUI
    // within a frame, not after the next 20–250ms heartbeat tick. Without
    // this, the server's framebuffer stays at the previous size for hundreds
    // of milliseconds, leaving the visible region clipped (e8.jpg).
    _sendCurrentDiff();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _postResumeProbeTimer?.cancel();
    _postResumeProbeTimer = null;
    _ackSkewProbeTimer?.cancel();
    _ackSkewProbeTimer = null;
    _sendTick?.cancel();
    _ackTick?.cancel();
    _lifecycle?.stop();
    await _udpSub?.cancel();
    await _roamer.socket.close();
    await _hostBytesCtrl.close();
    await _livenessCtrl.close();
    await _authPacketCtrl.close();
  }

  void _attachUdp(MoshUdpSocket sock) {
    _udpSub = sock.incoming.listen(_onWire);
  }

  // True between scheduling the stall-roam and its first ack-advance, so we
  // only fire the roam attempt once per stall episode instead of every 50ms.
  bool _stallRoamScheduled = false;

  void _onSendTick() {
    if (_closed) return;
    _drift.onTick();
    final now = DateTime.now();
    if (_sender.shouldHardReset(now: now)) {
      final ageS = _sender.sentStates.isEmpty
          ? 0
          : now.difference(_sender.sentStates.first.timestamp).inSeconds;
      final stallS = _sender.ackStallDuration(now: now).inSeconds;
      _emit(SspLivenessEvent(
        SspLivenessKind.hardReconnectNeeded,
        reason:
            'sender backlog pending=${_sender.sentStates.length}, oldestAgeS=$ageS, ackStallS=$stallS, aRx=${_sender.assumedReceiverStateNum}, lastAcks=${_sender.recentAcksDump(now: now)}',
      ));
      return;
    }
    // Stall-roam: server packets may still be arriving (supervisor healthy)
    // while our outbound packets never reach the server — typical of cellular
    // NAT mapping aging out from one side only. When assumedReceiverStateNum
    // hasn't advanced for >30s AND we have pending state, rebind UDP source
    // port to refresh the NAT entry. v1 has no analogue; this is what
    // explains the "sender backlog" reconnects in c1.jpg.
    if (!_stallRoamScheduled &&
        !_roamInFlight &&
        _sender.sentStates.length > 1 &&
        _sender.ackStallDuration(now: now) > const Duration(seconds: 30)) {
      dlog('MoshV2Connection',
        'ack stall ${_sender.ackStallDuration(now: now).inSeconds}s → roam to refresh NAT',
      );
      _stallRoamScheduled = true;
      _scheduleRoam();
    }
    // Clear the stall-roam latch once the server starts advancing again.
    if (_stallRoamScheduled &&
        _sender.ackStallDuration(now: now) < const Duration(seconds: 5)) {
      _stallRoamScheduled = false;
    }
    final ev = _supervisor.evaluate(now);
    if (ev != null) {
      _emit(ev);
      if (ev.kind == SspLivenessKind.roaming) {
        _scheduleRoam();
      }
    }
    // Only send when there is genuinely new state. Empty heartbeats are the
    // ack-tick's job — sending them on every 50ms wakeup is what produced the
    // 50pps storm that congested the link and produced "frozen" sessions
    // when the server's framebuffer diff also went into flight.
    if (_sender.makeDiffFromAssumed() != null) {
      _sendCurrentDiff();
    }
  }

  void _onAckTick() {
    if (_closed) return;
    final now = DateTime.now();
    // Timer skew detection: when wall-clock advances far more than the
    // scheduled ack interval between consecutive ticks, the OS has frozen us
    // (Android Doze, iOS app suspend, JS task starvation). NAT mappings on the
    // path likely expired during the freeze; without intervention the user
    // sees ~30 s of "silence" before the supervisor escalates to roam.
    final lastTick = _lastAckTickAt;
    _lastAckTickAt = now;
    if (lastTick != null) {
      final gap = now.difference(lastTick);
      if (gap > Heartbeat.kAckInterval * 3) {
        _handleAckTickSkew(now, gap);
      }
    }
    // Empty-ack heartbeat. mosh's ACK_INTERVAL is 3000ms — long enough not to
    // burn battery, short enough to keep typical NAT UDP mappings (30s) alive
    // and to feed our 30/40/45s liveness watchdog with a steady inbound
    // signal in return (the server replies to every packet with at least an
    // ack of its own).
    _sendCurrentDiff();
    _checkReceiverStuck();
  }

  // Tick gap > 3× kAckInterval → likely OS freeze (Doze / suspend). NAT is
  // probably dead; rebind UDP and verify within 5 s that a packet round-trips.
  // Uses _ocbPassCount as the probe baseline so sibling probes (e.g.
  // _postResumeProbeTimer fired by MoshLifecycleHook) cannot falsely satisfy
  // this probe's "alive" check by resetting supervisor.lastInbound.
  void _handleAckTickSkew(DateTime now, Duration gap) {
    _supervisor.lastInbound = now;
    _supervisor.state = SspLivenessKind.healthy;
    _scheduleRoam();
    // _postResumeProbeTimer is already running with the same _ocbPassCount
    // baseline (it was created by _onResumedHard just before the awakened
    // _onAckTick fires this method). Creating a second probe here would emit
    // hardReconnectNeeded twice when no packet arrives — let the existing
    // probe own the decision.
    if (_postResumeProbeTimer != null) return;
    final baseline = _ocbPassCount;
    _ackSkewProbeTimer?.cancel();
    _ackSkewProbeTimer = Timer(const Duration(seconds: 5), () {
      _ackSkewProbeTimer = null;
      if (_closed) return;
      if (_ocbPassCount == baseline) {
        _emit(SspLivenessEvent(
          SspLivenessKind.hardReconnectNeeded,
          reason: 'ackTick skew ${gap.inSeconds}s (no probe response)',
        ));
      }
    });
  }

  // Unified stuck detection — emits hardReconnectNeeded when the receiver
  // hasn't applied a single diff AND state-divergence drops are growing.
  //
  // Two signals tracked, combined under a single 10 s clock:
  //   • appliedCount   — increments only when a diff actually lands on
  //                       latestNum. Reset point for the clock.
  //   • baseMiss+chain — "bad drops": server's diff base is missing from
  //                       our receivedStates (state machines diverged) or
  //                       its oldNum doesn't chain to our latest. These
  //                       are the true stuck signals.
  //
  // staleDrops are deliberately NOT in the bad-drops count: mosh-server's
  // 3 s heartbeat with oldNum==newNum is a normal in-sync ack-only packet
  // that the receiver classifies as stale (newNum <= latestNum). Counting
  // those would falsely fire on every idle session within ~25 s.
  //
  // The supervisor's [lastInbound] timer is refreshed by every OCB success
  // (including those that subsequently chain-drop), so without this net
  // a v2 session can stay sup:healthy while the user sees a frozen screen
  // — exactly the f19.jpg pattern.
  void _checkReceiverStuck() {
    final now = DateTime.now();
    final applied = _receiver.appliedCount;
    final badDrops =
        _receiver.baseMissingDrops + _receiver.chainGateDrops;

    if (applied != _lastAppliedAtStuck) {
      // Apply progress — session is making forward motion, reset clock.
      _lastAppliedAtStuck = applied;
      _stuckSince = null;
      _lastBadDropsAtStuck = badDrops;
      return;
    }
    if (badDrops <= _lastBadDropsAtStuck + 5) {
      // No apply, but also no accumulating state-divergence — this is a
      // healthy idle session (heartbeats arriving as stale drops). Do not
      // arm the clock.
      return;
    }
    _stuckSince ??= now;
    if (now.difference(_stuckSince!) > const Duration(seconds: 10)) {
      _emit(SspLivenessEvent(
        SspLivenessKind.hardReconnectNeeded,
        reason:
            'receiver stuck: applied=$applied bMiss=${_receiver.baseMissingDrops}'
            ' chain=${_receiver.chainGateDrops}'
            ' stale=${_receiver.staleDrops} (ignored)'
            ' for ${now.difference(_stuckSince!).inSeconds}s',
      ));
    }
  }

  void _sendCurrentDiff() {
    final diff = _sender.makeDiffFromAssumed();
    final base = diff?.oldNum ?? _sender.assumedReceiverStateNum;
    final newN = diff?.newNum ?? _sender.assumedReceiverStateNum;
    final body = diff?.diff ?? Uint8List(0);
    final inst = TransportInstruction(
      oldNum: base,
      newNum: newN,
      ackNum: _receiver.latestNum,
      // throwawayNum is client-side state, NOT server-side. Sending
      // _receiver.throwawayNum triggers mosh-server's fatal_assert in
      // process_throwaway_until and kills the session — pending diffs pile
      // up and the user sees a frozen terminal. Use our oldNum (oldest
      // unACKed client state) instead. Matches v1's _sendDiff and the
      // mosh::TransportSender::send_to_receiver invariant.
      throwawayNum: base,
      diff: body,
    );
    final compressed = _zlib.encode(inst.encode());
    // Build [ts 2B | ts_reply 2B | instrId 8B | combinedFrag 2B | zlib(inst)]
    final plaintext = Uint8List(4 + 10 + compressed.length);
    final pbd = ByteData.sublistView(plaintext);
    final ts = DateTime.now().millisecondsSinceEpoch & 0xFFFF;
    pbd.setUint16(0, ts, Endian.big);
    pbd.setUint16(2, _savedTimestamp, Endian.big);
    pbd.setUint64(4, _instrIdCounter++, Endian.big);
    pbd.setUint16(12, 0x8000, Endian.big); // isFinal=1, fragNum=0
    plaintext.setRange(14, plaintext.length, compressed);
    final wire = MoshPacket.encode(
      nonce: _txNonce.next(),
      plaintext: plaintext,
      cipher: _txCipher,
    );
    try {
      _roamer.socket.send(wire);
      _udpTxCount++;
    } catch (e) {
      dlog('MoshV2Connection', 'send error: $e');
    }
  }

  void _onWire(Uint8List wire) {
    if (_closed) return;
    _udpRxCount++;

    // Stage 1 — OCB decrypt.
    final Uint8List plain;
    try {
      plain = MoshPacket.decode(wire, cipher: _rxCipher).plaintext;
    } catch (e) {
      if (_ocbFailCount++ == 0) {
        dlog('MoshV2Connection', 'OCB decrypt failed (first occurrence): $e');
      } else if (_ocbFailCount % 100 == 0) {
        dlog('MoshV2Connection', 'OCB decrypt failed: $_ocbFailCount total');
      }
      return;
    }

    // OCB passed → server is alive. Reset supervisor now, before fragment
    // reassembly and protobuf decode (both of which can fail without implying
    // the server is gone). Previously onPacket lived inside the Stage-4 try,
    // so a proto decode exception prevented it from being called at all —
    // supervisor would escalate to hardReconnectNeeded after 45s of "silence"
    // even while real packets were arriving from the server.
    _supervisor.onPacket(DateTime.now());
    _ocbPassCount++;

    if (plain.length < 14) return;
    final pbd = ByteData.sublistView(plain);
    _savedTimestamp = pbd.getUint16(0, Endian.big);
    final tsReply = pbd.getUint16(2, Endian.big);
    final instrId = pbd.getUint64(4, Endian.big);
    final combinedFrag = pbd.getUint16(12, Endian.big);
    final fragmentBody = Uint8List.sublistView(plain, 14);

    // Stage 2 — fragment reassembly.
    // mosh-server fragments any diff > ~500B (TUI refreshes, tmux pane
    // redraws, large `ls` output). Previously we dropped non-final fragments
    // outright — the user saw a frozen terminal until either (a) the diff
    // happened to fit in one packet on the next tick or (b) the watchdog
    // forced a hard reconnect 30s later.
    final Uint8List? reassembled;
    try {
      reassembled = _rxAssembler.feed(
        Fragment(instrId, combinedFrag, fragmentBody),
      );
    } catch (e) {
      if (_otherFailCount++ == 0) {
        dlog('MoshV2Connection', 'fragment feed failed (first): $e');
      }
      return;
    }
    if (reassembled == null) return; // wait for remaining fragments

    // Stage 3 — zlib inflate.
    final Uint8List protoBytes;
    try {
      protoBytes = Uint8List.fromList(_zlib.decode(reassembled));
    } catch (e) {
      if (_zlibFailCount++ == 0) {
        dlog('MoshV2Connection', 'zlib decode failed (first): $e');
      } else if (_zlibFailCount % 100 == 0) {
        dlog('MoshV2Connection', 'zlib decode failed: $_zlibFailCount total');
      }
      return;
    }

    // Stage 4 — protobuf decode + apply.
    try {
      final inst = TransportInstruction.decode(protoBytes);
      // First-packet diagnostic: dump all fields so we can see whether the
      // server is sending real state or just (0,0,0) heartbeats. mosh-server
      // *should* respond to our resize ping with a non-zero newNum within
      // the first second; persistent (0,0,0) means it isn't accepting our
      // packets (key mismatch, version mismatch, source-address probe?).
      _firstInstDump ??=
          'pv=${inst.protocolVersion} old=${inst.oldNum} new=${inst.newNum} '
          'ack=${inst.ackNum} thr=${inst.throwawayNum} '
          'diffLen=${inst.diff.length}';
      _lastInstAckNum = inst.ackNum;
      final senderReseeded = _sender.onAck(inst.ackNum);
      if (senderReseeded) {
        // Sender jumped past its local states (soft reconnect session handoff).
        // The server's oldest known state is now inst.ackNum; bootstrap the
        // receiver to the same base so the chain gate accepts D(inst.ackNum→X)
        // instead of baseMissing-dropping every subsequent packet and freezing
        // the screen permanently.
        _receiver.seedAt(inst.ackNum);
        _stuckSince = null; // re-seed breaks any prior stuck window
        _lastAppliedAtStuck = _receiver.appliedCount;
        _lastBadDropsAtStuck =
            _receiver.baseMissingDrops + _receiver.chainGateDrops;
        // Tell the server our new ackNum immediately so it sends D(ackNum→X)
        // instead of D(0→X). Without this, server keeps sending the wrong base
        // and receiver gets baseMiss drops for ~3s until the next _ackTick,
        // which trips _checkReceiverStuck and causes a spurious hard reconnect.
        _sendCurrentDiff();
      }
      // Surface RTT from the server's ts_reply echo (16-bit ms clock wraps
      // every 65.5s; gap is computed mod 2^16 so wrap is harmless for typical
      // RTTs ≪ 60s). 0xFFFF is the "no reply" sentinel — skip those.
      if (tsReply != 0xFFFF) {
        final nowMs = DateTime.now().millisecondsSinceEpoch & 0xFFFF;
        final rttMs = (nowMs - tsReply) & 0xFFFF;
        if (!_authPacketCtrl.isClosed) {
          _authPacketCtrl.add(Duration(milliseconds: rttMs));
        }
      } else if (!_authPacketCtrl.isClosed) {
        _authPacketCtrl.add(Duration.zero);
      }
      _firstAuthAt ??= DateTime.now();
      final r = _receiver.onPacket(inst);
      if (r.appliedHostBytes != null && !_firstAppliedCompleter.isCompleted) {
        _firstAppliedCompleter.complete();
      }
      if (r.appliedHostBytes != null) {
        final nc = _nextAppliedCompleter;
        if (nc != null && !nc.isCompleted) {
          _nextAppliedCompleter = null;
          nc.complete();
        }
      }
      if (r.appliedHostBytes != null && r.appliedHostBytes!.isNotEmpty) {
        final vt = v1msg.MoshHostMessage.extractHostBytes(r.appliedHostBytes!);
        _lastVtLen = vt.length;
        if (vt.isNotEmpty) {
          // Feed the TUI detector BEFORE emitting so getters reflect the new
          // state by the time TerminalWidget reads moshTuiActive on the next
          // pointer event. Without this v2's moshTuiActive stayed false and
          // SGR mouse-wheel events never reached opencode / claude CLI.
          _tuiDetector.onHostBytes(vt);
          _hostBytesCtrl.add(vt);
          _hostBytesEmitted++;
        } else {
          _extractEmptyCount++;
        }
        // Echo an ack immediately whenever we ADVANCED our latestNum so the
        // server can re-root its next diff at our true ackNum. Without this,
        // v2's 3000ms ack-tick is the only ack pacing — the server keeps
        // sending cumulative D(oldAck → newer) packets where the body
        // contains bytes already on screen, the chain gate refuses to emit
        // them, and the user sees a frozen / residual terminal until 3s
        // ack catches up. Gated on "diff applied" (not "diff received") so
        // unchained retransmits don't trigger a flood — server stops
        // retransmitting old diffs as soon as it sees a higher ackNum from
        // us, which is exactly when we send.
        _sendCurrentDiff();
      }
    } catch (e, st) {
      _stage4LastError = '${e.runtimeType}: ${e.toString().split('\n').first}';
      if (_protoFailCount++ == 0) {
        dlog('MoshV2Connection', 'proto decode failed (first): $e\n$st');
      } else if (_protoFailCount % 100 == 0) {
        dlog('MoshV2Connection', 'proto decode failed: $_protoFailCount total');
      }
    }
  }

  void _emit(SspLivenessEvent ev) {
    if (_livenessCtrl.isClosed) return;
    // Suppress hard-reconnect while backgrounded: the app's lifecycle hook
    // (MoshLifecycleHook) owns the reconnect decision after resume.  Firing
    // hardReconnectNeeded in the background kills the mosh-server (via SSH)
    // before the user even sees the session, forcing a full re-handshake on
    // return that wastes 3–10 s and loses scrollback.
    if (_backgrounded && ev.kind == SspLivenessKind.hardReconnectNeeded) return;
    _lastLivenessEvent = ev;
    _lastLivenessAt = DateTime.now();
    _livenessCtrl.add(ev);
  }

  void _scheduleRoam() {
    if (_roamInFlight) return;
    _roamInFlight = true;
    () async {
      try {
        final oldSub = _udpSub;
        await _roamer.roam();
        await oldSub?.cancel();
        _attachUdp(_roamer.socket);
        // Critical: send an immediate heartbeat on the new socket so the
        // server learns our new source IP/port AND responds. Without this we
        // wait up to 3s (next _ackTick) before any traffic flows, by which
        // time the 45s supervisor often escalates to hardReconnect — exactly
        // the "动不动重连" symptom on flaky mobile networks.
        _sendCurrentDiff();
      } catch (e) {
        dlog('MoshV2Connection', 'roam error: $e');
      } finally {
        _roamInFlight = false;
      }
    }();
  }

  void _onSuspectedSuspend(Duration gap) {
    // OS suspended us; reset the supervisor baseline so we don't
    // immediately escalate to hardReconnect on the very next tick.
    _supervisor.lastInbound = DateTime.now();
    _supervisor.state = SspLivenessKind.healthy;
  }

  /// Send an immediate heartbeat (empty-diff ack packet) on the current
  /// socket. Used by ReconnectService when connectivity_plus reports a
  /// network type change (e.g. 4G→WiFi). The send may fail silently if the
  /// OS routing table hasn't switched yet, but successive calls at
  /// 0/500/1500/3000 ms give the new interface time to settle.
  void triggerHeartbeat() {
    if (_closed) return;
    _sendCurrentDiff();
  }

  /// Rebind the UDP socket to a fresh ephemeral port and immediately send
  /// a heartbeat on the new socket. Called by ReconnectService at t=5 s
  /// after a connectivity type change as a safety net: if the old socket
  /// was silently killed by the OS when the cellular interface dropped
  /// (no onDone event — common on Android deep-sleep / cellular handoff),
  /// the rebind forces the kernel to pick the now-stable WiFi interface.
  /// Also resets the supervisor's lastInbound so a stale 30 s gap from
  /// the pre-roam silence doesn't immediately escalate to grace.
  void triggerRoam() {
    if (_closed) return;
    _supervisor.lastInbound = DateTime.now();
    _supervisor.state = SspLivenessKind.healthy;
    _scheduleRoam();
  }

  /// Reset the supervisor to healthy without rebinding. Called when the OS
  /// reports a network type change so the 30/45/75 s timers restart from
  /// "now" rather than from the last packet on the now-dying interface.
  ///
  /// Also emits an immediate ACK so the server learns our current latestNum
  /// before the next diff arrives. Mirrors v1's setForeground:_sendAck flow.
  /// Without this, a tab focus / connectivity transition leaves up to one
  /// ack-tick interval (3 s) where the server's diffs are rooted at a stale
  /// ackNum and chain-drop on our side — visible as a brief "frozen"
  /// terminal right after the user returns to the tab.
  /// Called when the app enters background (AppLifecycleState.paused).
  /// Resets the supervisor baseline so the 75 s hard-reconnect clock starts
  /// from pause time, and sets _backgrounded to suppress any hard-reconnect
  /// event that fires during the background period (before the user returns).
  void notePaused() {
    if (_closed) return;
    _backgrounded = true;
    final now = DateTime.now();
    _supervisor.lastInbound = now;
    _supervisor.state = SspLivenessKind.healthy;
    // Clear stuck window so any divergence that was building before the app
    // went to background doesn't age through the background period and fire
    // hardReconnectNeeded immediately on resume (before _backgrounded is
    // cleared). The stuck clock starts fresh once the server realigns state.
    _stuckSince = null;
    _lastAppliedAtStuck = _receiver.appliedCount;
    _lastBadDropsAtStuck = _receiver.baseMissingDrops + _receiver.chainGateDrops;
    _postResumeProbeTimer?.cancel();
    _postResumeProbeTimer = null;
    _ackSkewProbeTimer?.cancel();
    _ackSkewProbeTimer = null;
    // Reset sender stall clock and record suspension time so background
    // duration is not counted as an ACK stall on resume.
    _sender.noteBackground(now: now);
    _stallRoamScheduled = false;
  }

  /// Called when the app returns to foreground before noteConnectivityTransition.
  /// Clears the background flag so the next hardReconnectNeeded event (if any)
  /// is forwarded to ReconnectService as usual.
  void noteResumed() {
    _backgrounded = false;
  }

  void noteConnectivityTransition() {
    if (_closed) return;
    _backgrounded = false;
    final now = DateTime.now();
    _supervisor.lastInbound = now;
    _supervisor.state = SspLivenessKind.healthy;
    // Defense-in-depth: clear any stuck window that wasn't cleared in
    // notePaused (e.g. noteConnectivityTransition called without a prior
    // notePaused on a carrier-switch event).
    _stuckSince = null;
    _lastAppliedAtStuck = _receiver.appliedCount;
    _lastBadDropsAtStuck = _receiver.baseMissingDrops + _receiver.chainGateDrops;
    // Shift sender timestamps forward by the time spent in background/inactive
    // state so shouldHardReset does not count tab-inactive or connectivity-gap
    // time as stall age. Mirrors _onResumedQuick/_onResumedHard. Safe to call
    // unconditionally: noteResumed is a no-op when noteBackground was never
    // called (suspendedAt == null), but still resets the stall clock.
    _sender.noteResumed(now: now);
    _sendCurrentDiff();
  }

  void _onResumedQuick() {
    _backgrounded = false;
    final now = DateTime.now();
    _supervisor.lastInbound = now;
    _supervisor.state = SspLivenessKind.healthy;
    _stuckSince = null;
    _lastAppliedAtStuck = _receiver.appliedCount;
    _lastBadDropsAtStuck = _receiver.baseMissingDrops + _receiver.chainGateDrops;
    // Shift sentState timestamps forward by background duration so
    // shouldHardReset does not immediately fire on resume.
    _sender.noteResumed(now: now);
    _stallRoamScheduled = false;
    _scheduleRoam();
  }

  void _onResumedHard() {
    // Give the server a 5s window to respond before triggering hard reconnect.
    // ReconnectService.setForeground(true) already reset the supervisor, but
    // we do it again here defensively since lifecycle observer order isn't
    // contractual. _scheduleRoam() sends a heartbeat on the new socket so the
    // server has something to reply to. Use _ocbPassCount (not
    // supervisor.lastInbound) as the probe baseline so a concurrent
    // _ackSkewProbeTimer cannot falsely satisfy this probe.
    _backgrounded = false;
    final now = DateTime.now();
    _supervisor.lastInbound = now;
    _supervisor.state = SspLivenessKind.healthy;
    _stuckSince = null;
    _lastAppliedAtStuck = _receiver.appliedCount;
    _lastBadDropsAtStuck = _receiver.baseMissingDrops + _receiver.chainGateDrops;
    // Shift sentState timestamps forward by background duration so
    // shouldHardReset does not immediately fire on resume.
    _sender.noteResumed(now: now);
    _stallRoamScheduled = false;
    _scheduleRoam();
    final baseline = _ocbPassCount;
    _postResumeProbeTimer?.cancel();
    _postResumeProbeTimer = Timer(const Duration(seconds: 5), () {
      _postResumeProbeTimer = null;
      if (_closed) return;
      if (_ocbPassCount == baseline) {
        _emit(const SspLivenessEvent(
          SspLivenessKind.hardReconnectNeeded,
          reason: 'app backgrounded > 60s (no probe response)',
        ));
      }
    });
  }

  /// Completes the first time the receiver applies a server diff.
  /// Use as the soft-reconnect success gate (proves state machines are aligned).
  Future<void> get firstAppliedPacket => _firstAppliedCompleter.future;

  /// Arms and returns a one-shot future that completes on the *next* applied
  /// diff. Each call (re-)arms the completer, so it can be used for repeated
  /// probes. Call [cancelNextApplied] after a timeout to avoid a stale
  /// completer falsely satisfying the next probe.
  Future<void> get nextApplied {
    _nextAppliedCompleter ??= Completer<void>();
    return _nextAppliedCompleter!.future;
  }

  /// Clears any pending [nextApplied] completer. Call after a probe timeout.
  void cancelNextApplied() => _nextAppliedCompleter = null;

  /// Whether this connection has been closed.
  bool get isClosed => _closed;

  /// The already-resolved peer [InternetAddress]. Avoids repeated DNS lookups
  /// on soft reconnect — the roamer caches it from the initial [bind] call.
  InternetAddress get resolvedPeerAddress => _roamer.socket.peerAddress;

  @visibleForTesting
  Uint8List get debugSessionKey => _sessionKey;

  @visibleForTesting
  int get debugOcbFailCount => _ocbFailCount;
  @visibleForTesting
  int get debugZlibFailCount => _zlibFailCount;
  @visibleForTesting
  int get debugProtoFailCount => _protoFailCount;
  @visibleForTesting
  int get debugOtherFailCount => _otherFailCount;

  // Live transport-level diagnostics — read by MoshShellV2 pass-through
  // getters so the debug overlay can show them without leaking v2 types.
  int get debugUdpRxCount => _udpRxCount;
  int get debugUdpTxCount => _udpTxCount;
  int get debugReceiverBaseMissing => _receiver.baseMissingDrops;
  int get debugReceiverStaleDrops => _receiver.staleDrops;
  int get debugReceiverChainDrops => _receiver.chainGateDrops;
  int get debugReceiverLatestNum => _receiver.latestNum;
  int get debugReceiverLastOld => _receiver.lastInstOldNum;
  int get debugReceiverLastNew => _receiver.lastInstNewNum;
  int get debugSenderPending => _sender.sentStates.length;
  int get debugSenderAssumedRx => _sender.assumedReceiverStateNum;
  bool get debugBackgrounded => _backgrounded;
  String get debugSupervisorState => _supervisor.state.toString().split('.').last;
  int get debugSupervisorLastInboundAgeMs =>
      DateTime.now().difference(_supervisor.lastInbound).inMilliseconds;
  String? get debugLastLivenessKind =>
      _lastLivenessEvent?.kind.toString().split('.').last;
  String? get debugLastLivenessReason => _lastLivenessEvent?.reason;
  int? get debugLastLivenessAgeMs => _lastLivenessAt == null
      ? null
      : DateTime.now().difference(_lastLivenessAt!).inMilliseconds;
  int? get debugFirstAuthAgeMs => _firstAuthAt == null
      ? null
      : DateTime.now().difference(_firstAuthAt!).inMilliseconds;
  int get debugFragmentsReceived => _rxAssembler.fragmentsReceived;
  int get debugAssembliesCompleted => _rxAssembler.assembliesCompleted;
  int get debugAssembliesPending => _rxAssembler.assembliesPending;
  String? get debugFirstInstDump => _firstInstDump;
  int get debugLastInstAckNum => _lastInstAckNum;
  int get debugSenderOnAckCalls => _sender.onAckCallCount;
  int get debugSenderOnAckTrimmed => _sender.onAckTrimmedCount;
  int get debugSenderLastSeenAck => _sender.lastSeenAckNum;
  int get debugSenderAckStallSec =>
      _sender.ackStallDuration(now: DateTime.now()).inSeconds;
  String get debugSenderRecentAcks =>
      _sender.recentAcksDump(now: DateTime.now());
  bool get debugStallRoamScheduled => _stallRoamScheduled;
  bool get debugTuiActive => _tuiDetector.active;
  int get debugTuiBashLikeFrames => _tuiDetector.bashLikeFrameCount;
  int get debugReceiverOnPacketCalls => _receiver.onPacketCallCount;
  int get debugReceiverApplied => _receiver.appliedCount;
  String get debugReceiverLastBranch => _receiver.lastBranch;
  int get debugHostBytesEmitted => _hostBytesEmitted;
  int get debugExtractEmptyCount => _extractEmptyCount;
  int get debugLastVtLen => _lastVtLen;
  int get debugReceivedStatesCount => _receiver.receivedStates.length;
  String? get debugStage4LastError => _stage4LastError;
}
