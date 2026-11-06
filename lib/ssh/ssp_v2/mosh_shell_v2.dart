// SPDX-License-Identifier: GPL-3.0-or-later
// MoshShellV2 — duck-type SSHSession-compatible shell backed by the v2 SSP
// implementation in `lib/ssh/ssp_v2/`. Mirrors the public surface of
// `MoshShell` (v1) for runtime-critical operations only: stdin/stdout/done,
// resize, close, kill server PID. v1-specific telemetry getters return safe
// defaults until P5–P7 add v2-native diagnostics + watchdog/roaming.
//
// TerminalWidget treats its shell field as `dynamic`, so MoshShellV2 does
// not need to extend or implement MoshShell — duck typing on the public
// methods is sufficient.
import 'dart:async';
import '../../util/dlog.dart';
import 'dart:io' show InternetAddress;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../ssh_connection.dart' show sshConnectForExec;
import 'local_echo_predictor.dart';
import '../ssp_interface.dart';
import 'transport/connection.dart';

class MoshShellV2 {
  final SspTransport _transport;
  final _stdinController = StreamController<List<int>>();
  StreamSubscription<Uint8List>? _hostSub;
  StreamSubscription<Duration>? _authSub;
  int _authPacketCount = 0;
  int _lastAuthRttMs = 0;
  final _stdoutCtrl = StreamController<Uint8List>.broadcast();
  final _predictor = LocalEchoPredictor();

  final String _host;
  final int _sshPort;
  final String _username;
  final String? _password;
  final String? _privateKeyPem;
  final int? _serverPid;
  final String _udpHost;
  final int _udpPort;
  final Uint8List _moshKey;

  MoshShellV2(
    this._transport, {
    required String host,
    required int sshPort,
    required String username,
    String? password,
    String? privateKeyPem,
    int? serverPid,
    required String udpHost,
    required int udpPort,
    required Uint8List moshKey,
  })  : _host = host,
        _sshPort = sshPort,
        _username = username,
        _password = password,
        _privateKeyPem = privateKeyPem,
        _serverPid = serverPid,
        _udpHost = udpHost,
        _udpPort = udpPort,
        _moshKey = Uint8List.fromList(moshKey) {
    // Erase orphaned local-echo predictions when the server takes > 2s to reply.
    _predictor.onTimeout = (eraseSeq) {
      if (!_stdoutCtrl.isClosed) {
        _stdoutCtrl.add(Uint8List.fromList(eraseSeq));
      }
    };
    _hostSub = _transport.hostBytes.listen((bytes) {
      // Notify predictor so it can clear pending predictions and detect
      // alt-buffer / password-prompt suppression from server output.
      _predictor.notifyServerOutput(bytes);
      _stdoutCtrl.add(bytes);
    });
    // Forward authenticated-packet events to the v1-compatible callback so
    // terminal_screen.dart's NetworkStability.recordOkPacket sees real traffic.
    // Without this, the status dot drops to orange (looks red on small dots)
    // on the first missedDeadline and never recovers.
    final t = _transport;
    if (t is MoshV2Connection) {
      _authSub = t.authenticatedPackets.listen((rtt) {
        _authPacketCount++;
        _lastAuthRttMs = rtt.inMilliseconds;
        final cb = onAuthenticatedPacket;
        if (cb != null) cb(rtt);
      });
    }
    _stdinController.stream.listen((data) {
      try {
        // Local echo: emit underlined prediction immediately before sending to
        // the server, eliminating 1-RTT perceived latency on each keystroke.
        // Predictor gates this on printable ASCII / valid UTF-8, suppressing
        // during alt-buffer, password prompts, and tmux mode.
        if (_predictor.shouldEcho(data) && !_stdoutCtrl.isClosed) {
          _stdoutCtrl.add(Uint8List.fromList(_predictor.buildEcho(data)));
        }
        _transport.write(Uint8List.fromList(data));
      } catch (e) {
        dlog('MoshShellV2', 'write error: $e');
      }
    }, cancelOnError: false);
  }

  String get implVersion => _transport.implVersion;
  int? get serverPid => _serverPid;
  String get udpHost => _udpHost;
  int get udpPort => _udpPort;
  Uint8List get moshKey => Uint8List.fromList(_moshKey);

  /// The already-resolved peer address from the current transport's UDP socket.
  /// Passed to [createMoshV2Transport] on soft reconnect so DNS is skipped.
  InternetAddress? get resolvedPeerAddress => _v2?.resolvedPeerAddress;

  /// Probes whether the existing transport can still receive diffs from the
  /// server. Fires an immediate heartbeat and waits up to [timeout] for the
  /// next applied diff. Returns true if the server responds in time.
  ///
  /// On timeout, cancels the internal completer so stale state does not
  /// falsely satisfy a future probe — avoiding phantom "alive" reads.
  Future<bool> probeAlive({
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final v2 = _v2;
    if (v2 == null || v2.isClosed) return false;
    try {
      final next = v2.nextApplied;
      v2.noteConnectivityTransition();
      await next.timeout(timeout);
      return true;
    } on TimeoutException {
      v2.cancelNextApplied();
      return false;
    } catch (_) {
      return false;
    }
  }

  // v2 auth-packet diagnostics — surfaced via debug overlay so we can see
  // whether MoshV2Connection's authenticated stream is firing and whether
  // terminal_screen's NetworkStability callback has actually been wired up.
  int get authPktCount => _authPacketCount;
  int get lastAuthRttMs => _lastAuthRttMs;
  bool get hasAuthPktCallback => onAuthenticatedPacket != null;

  // v2 per-stage decode fail counts — surfaced via debug overlay so we can
  // identify which pipeline stage (OCB/frag/zlib/proto) is dropping packets.
  int get ocbFailCount =>
      (_transport is MoshV2Connection) ? (_transport as MoshV2Connection).debugOcbFailCount : 0;
  int get zlibFailCount =>
      (_transport is MoshV2Connection) ? (_transport as MoshV2Connection).debugZlibFailCount : 0;
  int get protoFailCount =>
      (_transport is MoshV2Connection) ? (_transport as MoshV2Connection).debugProtoFailCount : 0;
  int get otherFailCount =>
      (_transport is MoshV2Connection) ? (_transport as MoshV2Connection).debugOtherFailCount : 0;

  // Live transport state — only meaningful when wrapping MoshV2Connection.
  MoshV2Connection? get _v2 =>
      _transport is MoshV2Connection ? _transport as MoshV2Connection : null;

  int get udpRxCount => _v2?.debugUdpRxCount ?? 0;
  int get udpTxCount => _v2?.debugUdpTxCount ?? 0;
  int get receiverBaseMissing => _v2?.debugReceiverBaseMissing ?? 0;
  int get receiverStaleDrops => _v2?.debugReceiverStaleDrops ?? 0;
  int get receiverChainDrops => _v2?.debugReceiverChainDrops ?? 0;
  int get receiverLatestNum => _v2?.debugReceiverLatestNum ?? 0;
  int get receiverLastOldNum => _v2?.debugReceiverLastOld ?? 0;
  int get receiverLastNewNum => _v2?.debugReceiverLastNew ?? 0;
  int get senderPending => _v2?.debugSenderPending ?? 0;
  int get senderAssumedRx => _v2?.debugSenderAssumedRx ?? 0;
  bool get isBackgrounded => _v2?.debugBackgrounded ?? false;
  String get supervisorState => _v2?.debugSupervisorState ?? '?';
  int get supervisorLastInboundAgeMs => _v2?.debugSupervisorLastInboundAgeMs ?? 0;
  String? get lastLivenessKind => _v2?.debugLastLivenessKind;
  String? get lastLivenessReason => _v2?.debugLastLivenessReason;
  int? get lastLivenessAgeMs => _v2?.debugLastLivenessAgeMs;
  int? get firstAuthAgeMs => _v2?.debugFirstAuthAgeMs;
  int get fragmentsReceived => _v2?.debugFragmentsReceived ?? 0;
  int get assembliesCompleted => _v2?.debugAssembliesCompleted ?? 0;
  int get assembliesPending => _v2?.debugAssembliesPending ?? 0;
  String? get firstInstDump => _v2?.debugFirstInstDump;
  int get lastInstAckNum => _v2?.debugLastInstAckNum ?? 0;
  int get senderOnAckCalls => _v2?.debugSenderOnAckCalls ?? 0;
  int get senderOnAckTrimmed => _v2?.debugSenderOnAckTrimmed ?? 0;
  int get senderLastSeenAck => _v2?.debugSenderLastSeenAck ?? 0;
  int get senderAckStallSec => _v2?.debugSenderAckStallSec ?? 0;
  String get senderRecentAcks => _v2?.debugSenderRecentAcks ?? '[]';
  bool get stallRoamScheduled => _v2?.debugStallRoamScheduled ?? false;
  int get receiverOnPacketCalls => _v2?.debugReceiverOnPacketCalls ?? 0;
  int get receiverAppliedCount => _v2?.debugReceiverApplied ?? 0;
  String get receiverLastBranch => _v2?.debugReceiverLastBranch ?? '-';
  int get hostBytesEmitted => _v2?.debugHostBytesEmitted ?? 0;
  int get extractEmptyCount => _v2?.debugExtractEmptyCount ?? 0;
  int get lastVtLen => _v2?.debugLastVtLen ?? 0;
  int get receivedStatesCount => _v2?.debugReceivedStatesCount ?? 0;
  String? get stage4LastError => _v2?.debugStage4LastError;

  Stream<Uint8List> get stdout => _stdoutCtrl.stream;
  Stream<Uint8List> get stderr => const Stream.empty();
  StreamSink<List<int>> get stdin => _stdinController.sink;

  /// v2 liveness stream — ReconnectService listens for hardReconnectNeeded.
  Stream<SspLivenessEvent> get liveness => _transport.liveness;

  // done completes when the underlying transport closes its host stream.
  Future<void> get done => _stdoutCtrl.done;

  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    _transport.resize(width, height);
  }

  // v1-compatible runtime hooks — ReconnectService calls these on connectivity
  // changes, app resume, etc. v2 forwards to MoshV2Connection so the supervisor
  // baseline is reset and the socket is rebound immediately rather than waiting
  // for the 30/45/75 s timeout cascade.
  void setForeground(bool active) {
    if (active) {
      _v2?.noteResumed();
      _v2?.noteConnectivityTransition();
    } else {
      _v2?.notePaused();
    }
  }
  void roam() => _v2?.triggerRoam();
  void heartbeat() => _v2?.triggerHeartbeat();
  void suppressLocalEcho() => _predictor.suppressAll();
  void suppressNextLocalEcho() => _predictor.suppressNext();
  void enterGracePeriodNow() {
    // v2 doesn't surface grace-period entry directly — the supervisor's
    // 30 s threshold is the canonical signal. Reset the baseline so any
    // probe from outside (e.g. _auditMoshAfterTypeChange) starts measuring
    // from "now" instead of a stale lastInbound that crossed the threshold
    // mid-network-change.
    _v2?.noteConnectivityTransition();
  }
  void fullResync() {}

  // Telemetry stubs — debug overlay reads these. Returning sentinels so
  // it's clear the data is v2 (and not yet wired). pendingStateCount is
  // the only real signal v2 exposes today.
  int get pendingDiffsCount => _transport.pendingStateCount;
  int get maxPendingDiffs => 0;
  int get pendingFragBytes => 0;
  int get pendingFragSets => 0;
  int get cwnd => 0;
  int get inFlight => 0;
  int get consecutiveSkippedDiffs => 0;
  int get recvSeq => _v2?.debugReceiverLatestNum ?? 0;
  int get staleSkipCount => _v2?.debugReceiverStaleDrops ?? 0;
  int get gapSkipCount => _v2?.debugReceiverBaseMissing ?? 0;
  int get resyncMismatchCount => _v2?.debugReceiverChainDrops ?? 0;
  int get resyncAckAttempts => 0;
  int get lastInstOldNum => _v2?.debugReceiverLastOld ?? 0;
  int get lastInstNewNum => _v2?.debugReceiverLastNew ?? 0;
  bool get awaitingFullResyncFrame => false;
  int get secondsSinceResyncStarted => 0;
  int get secondsSinceLastInput => 0;
  int get secondsSinceLastHostBytes => 0;
  int get secondsSinceLastInteractiveHostBytes => 0;
  int get secondsSinceLastRecvSeqAdvance => 0;
  int get secondsSinceLastFullResync => 0;
  int get oldestPendingDiffAgeSeconds => 0;
  int get secondsSinceLastRx => 0;
  // v2 TUI activity flag — driven by TuiDetector inside MoshV2Connection
  // (ports v1's _updateTuiState verbatim). TerminalWidget._flushSgr reads
  // this through shell?.moshTuiActive to decide whether scroll gestures
  // should forward SGR mouse-wheel events to the remote app.
  bool get moshTuiActive => _v2?.debugTuiActive ?? false;
  int get tuiBashLikeFrames => _v2?.debugTuiBashLikeFrames ?? 0;
  String get firstFrameDiag => '';

  // Soft-reconnect callback hook — v2 watchdog (P5) will own this.
  void Function(Duration rtt)? onAuthenticatedPacket;

  /// Create a replacement [MoshShellV2] using [newTransport] but preserving
  /// all credentials from this shell. Mirrors v1's MoshShell.recreate().
  ///
  /// Caller must [closeTransport] this shell AFTER recreate returns so the
  /// old UDP socket is torn down without SSH-killing the still-running server.
  MoshShellV2 recreate(SspTransport newTransport) {
    final shell = MoshShellV2(
      newTransport,
      host: _host,
      sshPort: _sshPort,
      username: _username,
      password: _password,
      privateKeyPem: _privateKeyPem,
      serverPid: _serverPid,
      udpHost: _udpHost,
      udpPort: _udpPort,
      moshKey: _moshKey,
    );
    // Carry over the auth-packet callback so post-soft-reconnect packets
    // continue feeding NetworkStability without re-wiring at the call site.
    shell.onAuthenticatedPacket = onAuthenticatedPacket;
    return shell;
  }

  Future<bool> kill() => _killServer();

  Future<void> closeTransport() async {
    _predictor.dispose();
    await _hostSub?.cancel();
    await _authSub?.cancel();
    await _stdinController.close();
    await _transport.close();
    if (!_stdoutCtrl.isClosed) await _stdoutCtrl.close();
  }

  Future<bool> close() async {
    await closeTransport();
    return _killServer();
  }

  Future<bool> _killServer() async {
    final pid = _serverPid;
    if (pid == null) return true;
    SSHClient? client;
    try {
      client = await sshConnectForExec(
        host: _host,
        port: _sshPort,
        username: _username,
        password: _password,
        privateKeyPem: _privateKeyPem,
        timeout: const Duration(seconds: 5),
      );
      final s = await client.execute('kill $pid 2>/dev/null; true');
      await s.stdout.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
      await s.done.timeout(const Duration(seconds: 3));
      return true;
    } catch (e) {
      dlog('MoshShellV2', 'failed to kill mosh-server pid=$pid: $e');
      return false;
    } finally {
      client?.close();
    }
  }
}
