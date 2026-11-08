// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/material.dart' show ScaffoldMessenger, SnackBar, Text;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:package_info_plus/package_info_plus.dart';

import 'package:dartssh2/dartssh2.dart' show SSHClient;

import '../../data/models/server.dart';
import '../../l10n/l10n.dart';
import '../ssh_connection.dart' show sshConnectForExec;
import '../transport/remote_transport.dart';
import '../transport/transport_factory.dart';
import 'aqt_bootstrap.dart';
import 'aqt_ffi.dart';
import 'aqt_install_dialog.dart';
import 'aqt_port_restart_dialog.dart';
import 'aqt_port_spec.dart';
import 'aqt_route.dart';
import 'aqt_ssh_relay.dart';
import 'aqt_server_installer.dart';
import 'aqt_transport.dart';

/// 分类 RESUME 失败原因。调用方据此决定是否清掉持久化 session 元数据。
enum AqtResumeFailReason {
  /// 12s budget 内未收到 Connected/TabOpened —— 通常是网络问题
  /// (UDP 丢包、NAT rebind、远端假死)。session 可能还活，保留 store。
  networkTimeout,
  /// 服务端 RESUME_ACK 明确返回 new_pty_stream_id=0 —— session 已死/过期
  /// (server 重启、tab 已关闭、TTL 过期)。清掉 store 避免下次浪费时间。
  sessionNotFound,
  /// 握手协议错误 (TLS、SPKI mismatch、解码失败)。保留 store —— 可能是
  /// 客户端 transient 故障，重试可能成功。
  handshakeFailed,
  /// 兜底分类。保留 store。
  unknownError,
}

/// RESUME 尝试结果。
sealed class AqtResumeResult {
  const AqtResumeResult();
}

class AqtResumeSuccess extends AqtResumeResult {
  final AqtTransport transport;
  const AqtResumeSuccess(this.transport);
}

class AqtResumeFailed extends AqtResumeResult {
  final AqtResumeFailReason reason;
  final String? detail;

  /// 这次尝试有没有走到 [TransportState.connected]，即 **QUIC 握手通没通**。
  ///
  /// 只对 [AqtResumeFailReason.networkTimeout] 有诊断价值，因为只有它对两种
  /// 完全不同的故障一视同仁：
  ///
  ///   握手就没通  → 出向路径不通，或客户端那条共享的单线程 tokio runtime
  ///                （`aqt_client_ffi/src/runtime.rs` 是 `new_current_thread()`，
  ///                 全 App 所有 QUIC 连接共用一条线程）被别的任务占住了
  ///   握手通了    → 服务端收下了连接却没回 ResumeAck
  ///
  /// 客户端在 `*h.conn_state = ConnState::Connected` 时才发 connected 事件，
  /// 而那一行紧跟在 `connect_0rtt` 之后 —— 所以这个 bool 就是「握手通没通」。
  ///
  /// 缺省 false = 「没有证据说握手通了」。反过来默认 true 会让未改造的构造点
  /// 凭空报告握手成功，把埋点变成噪声源。
  final bool reachedConnected;

  // detail 从 positional 改成 named 是为了让 reachedConnected 也能具名：Dart
  // 不允许 optional-positional 与 named 混用，而 positional 的裸 bool
  // （`AqtResumeFailed(reason, null, true)`）在调用点完全读不出含义。
  const AqtResumeFailed(this.reason,
      {this.detail, this.reachedConnected = false});
}

/// Factory that establishes an AQT (QUIC) transport by:
///   1. SSH-connecting to the server to run `flyterm-server --once`.
///   2. Parsing the AQT_* bootstrap lines.
///   3. Opening a QUIC connection using the advertised port/SPKI/token.
///
/// Credentials (password / privateKeyPem) must be supplied by the caller
/// (typically CompositeTransportFactory, which has access to
/// SecureStorageService). The factory itself is stateless.
class AqtTransportFactory implements TransportFactory {
  /// Default RESUME budget — tightened from 8s (C2: 5s budget lets backup
  /// bootstrap start at 3s and still have 2s head-room before RESUME gives up).
  ///
  /// 这个 5s 只对**有竞速伙伴**的路径成立，即工厂层的 [_reconnectRace]：那里
  /// [kBootstrapBackupDelay] 会在 3s 处并行拉起 bootstrap，5s 是「3s + 2s 余量」。
  /// proactive 路径没有竞速伙伴，但收紧它的 budget 是错的解法 —— 见下面那段墓志铭。
  static const Duration kDefaultResumeTimeout = Duration(seconds: 5);

  // 这里一度有过一个 kProactiveResumeTimeout = 3s。删掉了，理由值得留下 ——
  //
  // 出发点是对的：proactive 路径没有竞速伙伴，等满 budget 是纯呆滞（见上面
  // 那段）。错在取值的依据是**单张截图**里的 `seg hs:360`。
  //
  // `hs` 段（markAck - markSent）里含着服务端序列化 240KB 快照的耗时 ——
  // `serialize_resume` 在 `write_frame(ResumeAck)` 之前执行。而 daemon 通常
  // 部署在用户自己的开发机上，那是天然的 CPU 争抢环境：实测同一台机器运行
  // 队列 14–28（12 核）时，`hs` 从 360ms 涨到 1273ms，3s 的余量从以为的 8 倍
  // 缩到 2.2 倍。再紧一点就会开始砍掉本来能成功的 RESUME，转 SSH 全量链 ——
  // 正好退回收紧 budget 想解决的那个问题。
  //
  // 结论：budget 不是该收紧的东西。要缩短 proactive 的呆滞时间，正确的做法是
  // 给它一个竞速伙伴（像工厂层的 kBootstrapBackupDelay 那样），而不是让它更
  // 早地判失败。护栏见 test/ssh/budget_selector_test.dart。

  /// Weak-network RESUME budget — selected when PathStats.rttMs > 200 ms.
  ///
  /// **已知盲区**：判据是 rtt，而 rtt 看不见服务端有多忙。真机现场 rtt 97ms
  /// （比平时还好）而 `hs` 段 1273ms —— 慢的是服务端 CPU 与快照序列化，链路
  /// 毫无问题。这一档在那种场景下永远不会被选中。
  static const Duration kWeakNetworkResumeTimeout = Duration(seconds: 14);

  /// Foreground fast-path budget — first attempt right after the app
  /// returns to foreground. Single shot, fall through to normal RWR on
  /// failure.
  static const Duration kForegroundFastResumeTimeout = Duration(seconds: 3);

  /// Back-compat alias — old callers default to the new default.
  static const Duration kResumeTimeout = kDefaultResumeTimeout;

  /// C2 — Master switch for RESUME ↔ bootstrap race.
  static const bool kResumeRaceBootstrap = true;

  /// C2 — Delay before backup bootstrap kicks off. RESUME has this window
  /// to finish before the race begins.
  static const Duration kBootstrapBackupDelay = Duration(seconds: 3);

  /// Connect using AQT bootstrap.
  ///
  /// [password] and [privateKeyPem] are mutually exclusive — supply whichever
  /// matches [server.authType].
  /// [reuseClient] — if provided and not closed, skips SSH auth (saves ~5-8 RTTs).
  Future<RemoteTransport> connectWithCredentials(
    Server server, {
    String? password,
    String? privateKeyPem,
    SSHClient? reuseClient,
    /// Optional — required to show install dialog on first-time deploy.
    /// If null, install path is bypassed (caller handles declined).
    BuildContext? dialogContext,
  }) async {
    // ConnectTimings capture — surfaced on the resulting AqtTransport for
    // the `conn` row in debug overlay.
    int tcpMs = 0;
    int authMs = 0;
    int bootMs = 0;
    int handshakeMs = 0;

    // 1) SSH connect (bootstrap only — no PTY shell needed).
    //    Reuse existing authenticated client when available.
    final SSHClient client;
    final bool clientOwned; // true = we created it and must close it
    if (reuseClient != null && !reuseClient.isClosed) {
      client = reuseClient;
      clientOwned = false;
    } else {
      final sshSw = Stopwatch()..start();
      client = await sshConnectForExec(
        host: server.host,
        port: server.port,
        username: server.username,
        password: password,
        privateKeyPem: privateKeyPem,
        onTcpConnected: (ms) => tcpMs = ms,
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () =>
            throw TransportConnectException('SSH bootstrap timed out'),
      );
      authMs = (sshSw.elapsedMilliseconds - tcpMs).clamp(0, 1 << 30);
      clientOwned = true;
    }

    try {
      // 2) Version check + silent upgrade before bootstrap.
      //    Compares remote binary version against APK bundled VERSION asset.
      //    If mismatch (e.g. server lacks compression, new features, bug fixes)
      //    the new binary is uploaded silently (no dialog). If upgrade fails the
      //    old binary is still used — failure is logged and not surfaced.
      await maybeUpgrade(
        client,
        dialogContext,
        useDaemon: server.useDaemon,
        ports: AqtPortSpec.forServer(server.aqtPorts),
      );

      var triedInstall = false;
      var triedStaleDaemonClean = false;
      while (true) {
        try {
          // 3) Bootstrap flyterm-server.
          //    server.useDaemon=true  → daemon-strict (probe → start → poll;
          //                              never silently falls back to once)
          //    server.useDaemon=false → once mode (default; lightweight)
          final bootSw = Stopwatch()..start();
          final bootstrapResult = await bootstrapFor(
            server,
            client,
            confirmContext: dialogContext,
          );
          bootMs = bootSw.elapsedMilliseconds;

          // 4) QUIC connect — keep bootstrapResult alive until connected.
          //    Close bootstrap channel in ALL exit paths to avoid SSH session leak.
          //
          //    Route (see AqtRoute): direct UDP first (4 s), then QUIC over
          //    an SSH exec channel on this same SSH connection — unless the
          //    server is set to always use the SSH channel, or this run
          //    already found UDP blocked for it.
          AqtTransport? transport;
          AqtRouteOutcome<AqtTransport>? routed;
          Object? quicError;
          final hsSw = Stopwatch()..start();
          final info = bootstrapResult.info;
          try {
            routed = await connectRouted(
              server: server,
              client: client,
              info: info,
              // The relay rides this SSH connection: when we opened it, the
              // transport now owns it (closed with the transport, not below).
              ownsClient: clientOwned,
            );
            transport = routed.value;
            handshakeMs = hsSw.elapsedMilliseconds;
          } catch (e) {
            quicError = e;
          } finally {
            bootstrapResult.close();
          }

          // 5) If QUIC failed with a probe result, daemon.info may be stale
          //    (process died via kill -9 / remote reboot without orderly cleanup).
          //    Delete the file and retry once — next probe returns null →
          //    bootstrapDaemonStrict starts a fresh daemon automatically.
          //    Not when the SSH relay is what failed (old binary, ForceCommand):
          //    the daemon is alive, and deleting its info would start a
          //    second one and orphan every session on the first.
          if (quicError != null) {
            if (server.useDaemon &&
                bootstrapResult.isDaemon &&
                !triedStaleDaemonClean &&
                relayFailureOf(quicError) == null) {
              triedStaleDaemonClean = true;
              debugPrint(
                '[AQT] QUIC failed after daemon probe ($quicError) — '
                'clearing stale daemon.info and retrying',
              );
              try {
                final rm = await client.execute(
                  r'rm -f ~/.flyterm-server/daemon.info',
                );
                await rm.done;
              } catch (_) {}
              continue; // retry → probe returns null → fresh daemon start
            }
            // ignore: only_throw_errors
            throw quicError;
          }

          // 6) Close SSH only if we opened it (reused clients managed by caller).
          //    Agent tool execution does NOT reuse this connection — it opens
          //    its own lazily on first tool call (see AgentExecChannel), so that
          //    sessions which never use the AI panel don't carry an idle SSH
          //    connection for their whole lifetime.
          if (clientOwned && routed!.route == AqtRoute.direct) client.close();
          transport!.lastConnectTimings = ConnectTimings(
            tcpMs: tcpMs,
            authMs: authMs,
            bootMs: bootMs,
            handshakeMs: handshakeMs,
          );
          return transport;
        } on AqtServerNotInstalledException {
          if (triedInstall) {
            // Already retried install once — give up.
            rethrow;
          }
          if (dialogContext == null) {
            debugPrint('[AQT] no dialogContext, cannot prompt install');
            rethrow;
          }
          triedInstall = true;
          // runInstallFlow guards against unmounted context internally.
          final result = await runInstallFlow(
            client: client,
            server: server,
            // ignore: use_build_context_synchronously
            dialogContext: dialogContext,
          );
          if (result.status != AqtInstallStatus.success) {
            // Install failed/declined — propagate as not-installed. Strict
            // mode: caller surfaces error, no silent SSH fallback.
            throw const AqtServerNotInstalledException();
          }
          // Successful install — loop and retry bootstrap.
          continue;
        }
      }
    } catch (e) {
      if (clientOwned) client.close();
      if (e is TransportConnectException) rethrow;
      if (e is AqtServerNotInstalledException) {
        // Allow this specific exception to propagate — caller (UI) decides
        // how to surface the error. Strict mode: no silent SSH fallback.
        rethrow;
      }
      if (e is AqtDaemonStartFailedException) {
        // Daemon-strict mode start failed — surface a clear message to the
        // user via TransportConnectException. Strict mode: no fallback.
        throw TransportConnectException(
          'Daemon mode failed to start: ${e.reason}. '
          'Uncheck Daemon mode to use once mode, or check the remote UDP port.',
          e,
        );
      }
      throw TransportConnectException('AQT connect failed: $e', e);
    }
  }

  /// Test seam — instance wrapper around [connectWithCredentials]. Tests
  /// override this to inject controlled bootstrap timing/result. Production
  /// `reconnect` paths call this method, not the original.
  @visibleForTesting
  Future<RemoteTransport> connectWithCredentialsForTest(
    Server server, {
    String? password,
    String? privateKeyPem,
    SSHClient? reuseClient,
    BuildContext? dialogContext,
  }) =>
      connectWithCredentials(
        server,
        password: password,
        privateKeyPem: privateKeyPem,
        reuseClient: reuseClient,
        dialogContext: dialogContext,
      );

  /// Complete install flow: show dialog → detect arch → upload → verify → persist.
  /// Returns an AqtInstallResult; never throws (catches Exception internally).
  ///
  /// Exposed as `static` so UI bootstrap paths (terminal_screen.dart) that
  /// run their own bootstrap (once or daemon-strict) outside the factory can
  /// still trigger the install flow when `AqtServerNotInstalledException` is
  /// raised.
  static Future<AqtInstallResult> runInstallFlow({
    required SSHClient client,
    required Server server,
    required BuildContext dialogContext,
    /// When true (upgrade path): skip the confirmation dialog and upload
    /// silently. The caller should show a brief SnackBar before calling.
    bool silent = false,
  }) async {
    // 1) Detect arch FIRST — fail fast before disturbing user with a dialog
    // they can't act on (e.g. riscv64 / mips remotes that have no asset).
    final arch = await AqtServerInstaller.detectArch(client);
    if (arch == null) {
      return const AqtInstallResult.error(
        'unsupported architecture (only x86_64 and aarch64 Linux supported)',
      );
    }

    // 2) Load the matching binary now (so dialog can show exact size and
    // upload reuses these bytes — no double-load from rootBundle).
    final Uint8List bytes;
    try {
      bytes = await AqtServerInstaller.loadBinaryAsset(arch);
    } catch (e) {
      return AqtInstallResult.error(
        'asset missing for arch=$arch (APK may be incomplete): $e',
      );
    }

    // 3) Show dialog with arch + precise size (skipped in silent/upgrade mode).
    if (!silent) {
      if (!dialogContext.mounted) {
        return const AqtInstallResult.declined();
      }
      final choice = await showAqtInstallDialog(
        dialogContext,
        archInfo: arch,
        packageBytes: bytes.lengthInBytes,
      );
      switch (choice) {
        case AqtInstallChoice.postpone:
          return const AqtInstallResult.declined();
        case AqtInstallChoice.install:
          break;
      }
    }

    // 4) Upload (reuse already-loaded bytes)
    final pkgInfo = await PackageInfo.fromPlatform();
    final binaryVersion = await AqtServerInstaller.loadVersionString();
    try {
      await AqtServerInstaller.uploadBinary(
        client,
        bytes,
        arch,
        flytermVersion: pkgInfo.version,
        binaryVersion: binaryVersion,
      );
    } catch (e) {
      return AqtInstallResult.error('upload failed: $e');
    }

    // 5) Verify
    final verifyVersion = await AqtServerInstaller.verifyInstall(client);
    if (verifyVersion == null) {
      return const AqtInstallResult.error(
        'binary verification failed (--version did not exit 0)',
      );
    }

    return const AqtInstallResult.success();
  }

  /// [TransportFactory.connect] — no credentials; delegates to
  /// [connectWithCredentials] with null creds (password-less / key-agent).
  /// CompositeTransportFactory should call [connectWithCredentials] directly
  /// once credential loading is wired.
  @override
  Future<RemoteTransport> connect(
    Server server, {
    BuildContext? dialogContext,
  }) async {
    return connectWithCredentials(
      server,
      dialogContext: dialogContext,
    );
  }

  /// Test seam — instance wrapper around the static [tryResumeWithInfoDetailed].
  /// Tests override this to inject a stubbed result; production calls the
  /// static method via this wrapper (so the wrapper is the only call site
  /// from inside [reconnect]).
  @visibleForTesting
  Future<AqtResumeResult> tryResumeWithInfoDetailedForTest({
    required String host,
    required int port,
    required Uint8List spki,
    required Uint8List sessionToken,
    required int tabId,
    Duration? budget,
  }) =>
      AqtTransportFactory.tryResumeWithInfoDetailed(
        host: host,
        port: port,
        spki: spki,
        sessionToken: sessionToken,
        tabId: tabId,
        budget: budget ?? kDefaultResumeTimeout,
      );

  @override
  Future<RemoteTransport> reconnect({
    required Server server,
    required ReconnectCredentials creds,
    RemoteTransport? previous,
    BuildContext? dialogContext,
    Future<void> Function()? onPurgeSession,
  }) async {
    if (kResumeRaceBootstrap) {
      return _reconnectRace(
        server: server,
        creds: creds,
        previous: previous,
        dialogContext: dialogContext,
        onPurgeSession: onPurgeSession,
      );
    }
    return _reconnectSerial(
      server: server,
      creds: creds,
      previous: previous,
      dialogContext: dialogContext,
      onPurgeSession: onPurgeSession,
    );
  }

  Future<RemoteTransport> _reconnectSerial({
    required Server server,
    required ReconnectCredentials creds,
    RemoteTransport? previous,
    BuildContext? dialogContext,
    Future<void> Function()? onPurgeSession,
  }) async {
    if (previous is AqtTransport) {
      if (previous.lastPort == null ||
          previous.lastSpki == null ||
          previous.sessionToken == null ||
          previous.lastTabId == null) {
        debugPrint(
          '[RESUME] skip: missing metadata in previous transport '
          '(port=${previous.lastPort} tab=${previous.lastTabId})',
        );
      } else {
        final result = previous.route == AqtRoute.viaSsh
            ? await tryResumeWithInfoDetailed(
                host: server.host,
                port: previous.lastPort!,
                spki: previous.lastSpki!,
                sessionToken: previous.sessionToken!,
                tabId: previous.lastTabId!,
                route: AqtRoute.viaSsh,
                openRelay: (p) => _relayFromCreds(server, creds, p),
              )
            : await tryResumeWithInfoDetailedForTest(
                host: server.host,
                port: previous.lastPort!,
                spki: previous.lastSpki!,
                sessionToken: previous.sessionToken!,
                tabId: previous.lastTabId!,
              );
        if (result is AqtResumeSuccess) return result.transport;
        if (result is AqtResumeFailed &&
            (result.reason == AqtResumeFailReason.sessionNotFound ||
                result.reason == AqtResumeFailReason.handshakeFailed)) {
          await onPurgeSession?.call();
        }
      }
    }
    return connectWithCredentialsForTest(
      server,
      password: creds.password,
      privateKeyPem: creds.privateKeyPem,
      reuseClient: creds.reuseClient,
      // ignore: use_build_context_synchronously
      dialogContext: dialogContext,
    );
  }

  /// An SSH relay for RESUME on the reconnect path: over the caller's live
  /// SSH connection when there is one, else over a connection opened just
  /// for it (owned by the relay, closed with it).
  Future<AqtSshRelay> _relayFromCreds(
    Server server,
    ReconnectCredentials creds,
    int daemonPort,
  ) async {
    final reuse = creds.reuseClient;
    if (reuse != null && !reuse.isClosed) {
      return AqtSshRelay.start(reuse, daemonPort: daemonPort);
    }
    final client = await sshConnectForExec(
      host: server.host,
      port: server.port,
      username: server.username,
      password: creds.password,
      privateKeyPem: creds.privateKeyPem,
      keyPairs: creds.keyPairs,
    );
    try {
      return await AqtSshRelay.start(client,
          daemonPort: daemonPort, onClose: client.close);
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  Future<RemoteTransport> _reconnectRace({
    required Server server,
    required ReconnectCredentials creds,
    RemoteTransport? previous,
    BuildContext? dialogContext,
    Future<void> Function()? onPurgeSession,
  }) async {
    // Relayed sessions need an SSH connection before RESUME can even start,
    // so racing RESUME against the SSH bootstrap buys nothing: serial.
    if (previous is AqtTransport && previous.route == AqtRoute.viaSsh) {
      return _reconnectSerial(
        server: server,
        creds: creds,
        previous: previous,
        dialogContext: dialogContext,
        onPurgeSession: onPurgeSession,
      );
    }
    // No metadata → race makes no sense; go straight to bootstrap.
    if (previous is! AqtTransport ||
        previous.lastPort == null ||
        previous.lastSpki == null ||
        previous.sessionToken == null ||
        previous.lastTabId == null) {
      if (previous is AqtTransport) {
        debugPrint(
          '[RESUME] skip: missing metadata in previous transport '
          '(port=${previous.lastPort} tab=${previous.lastTabId})',
        );
      }
      return connectWithCredentialsForTest(
        server,
        password: creds.password,
        privateKeyPem: creds.privateKeyPem,
        reuseClient: creds.reuseClient,
        // ignore: use_build_context_synchronously
        dialogContext: dialogContext,
      );
    }

    final resumeFuture = tryResumeWithInfoDetailedForTest(
      host: server.host,
      port: previous.lastPort!,
      spki: previous.lastSpki!,
      sessionToken: previous.sessionToken!,
      tabId: previous.lastTabId!,
    );

    // Wait kBootstrapBackupDelay. If RESUME completes first, the timeout
    // future never resolves before we return.
    final raceResult = await Future.any<_RaceTagged>([
      resumeFuture.then((r) => _RaceTagged.resume(r)),
      Future.delayed(kBootstrapBackupDelay).then((_) => _RaceTagged.timeout()),
    ]);

    if (raceResult.isResume) {
      final r = raceResult.resume!;
      if (r is AqtResumeSuccess) return r.transport;
      if (r is AqtResumeFailed &&
          (r.reason == AqtResumeFailReason.sessionNotFound ||
              r.reason == AqtResumeFailReason.handshakeFailed)) {
        await onPurgeSession?.call();
      }
      return connectWithCredentialsForTest(
        server,
        password: creds.password,
        privateKeyPem: creds.privateKeyPem,
        reuseClient: creds.reuseClient,
        // ignore: use_build_context_synchronously
        dialogContext: dialogContext,
      );
    }

    // 3s elapsed, RESUME still pending. Start bootstrap as backup.
    debugPrint('[RACE] RESUME stalled >3s → launching bootstrap backup');
    final bootstrapFuture = connectWithCredentialsForTest(
      server,
      password: creds.password,
      privateKeyPem: creds.privateKeyPem,
      reuseClient: creds.reuseClient,
      // ignore: use_build_context_synchronously
      dialogContext: dialogContext,
    );

    return _raceWinners(
      resumeFuture: resumeFuture,
      bootstrapFuture: bootstrapFuture,
      onPurgeSession: onPurgeSession,
    );
  }

  Future<RemoteTransport> _raceWinners({
    required Future<AqtResumeResult> resumeFuture,
    required Future<RemoteTransport> bootstrapFuture,
    required Future<void> Function()? onPurgeSession,
  }) async {
    final completer = Completer<RemoteTransport>();

    // RESUME branch.
    resumeFuture.then((r) async {
      if (r is AqtResumeSuccess) {
        if (completer.isCompleted) {
          debugPrint('[RACE] RESUME late, bootstrap already won — closing RESUME transport');
          await r.transport.close();
          return;
        }
        debugPrint('[RACE] RESUME won');
        completer.complete(r.transport);
        // Close bootstrap if/when it produces a transport.
        bootstrapFuture.then((t) async {
          debugPrint('[RACE] bootstrap arrived too late — closing');
          await t.close();
        }).catchError((_) {/* bootstrap late-fail: ignore */});
      } else if (r is AqtResumeFailed) {
        if (r.reason == AqtResumeFailReason.sessionNotFound ||
            r.reason == AqtResumeFailReason.handshakeFailed) {
          await onPurgeSession?.call();
        }
        debugPrint('[RACE] RESUME failed, awaiting bootstrap');
      }
    }).catchError((e) {
      debugPrint('[RACE] RESUME threw: $e — awaiting bootstrap');
    });

    // Bootstrap branch.
    bootstrapFuture.then((t) {
      if (completer.isCompleted) {
        debugPrint('[RACE] bootstrap late, RESUME already won — closing bootstrap transport');
        t.close();
        return;
      }
      debugPrint('[RACE] bootstrap won');
      completer.complete(t);
    }).catchError((e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    });

    return completer.future;
  }

  /// Attempt 0-RTT reconnect using a stored session token from [previous].
  ///
  /// Returns a ready [AqtTransport] if RESUME succeeded, or null if:
  ///   - Session info is missing (first connect, or token not yet in .so).
  ///   - The RESUME handshake times out or fails.
  /// The caller must fall back to full SSH bootstrap on null.
  ///
  /// NOTE: aqt_resume() creates a FRESH handle internally — do NOT call
  /// aqt_connect() first; that would start a conflicting HELLO handshake.
  static Future<AqtTransport?> tryResume(
    AqtTransport previous,
    String host, {
    int ringTailHash = 0, // FNV-1a hash of last 8 raw bytes for server verification
    Duration budget = kDefaultResumeTimeout,
    Future<AqtSshRelay> Function(int daemonPort)? openRelay,
  }) async {
    final port = previous.lastPort;
    final spki = previous.lastSpki;
    final token = previous.sessionToken;
    final tabId = previous.lastTabId;
    if (port == null || spki == null || token == null || tabId == null) {
      debugPrint('[RESUME] skip: missing info port=$port tok=${token != null ? _hex4(token) : "null"} tab=$tabId');
      return null;
    }
    return tryResumeWithInfo(
      host: host,
      port: port,
      spki: spki,
      sessionToken: token,
      tabId: tabId,
      budget: budget,
      route: previous.route,
      openRelay: openRelay,
    );
  }

  /// 直接用持久化的元数据（不依赖 AqtTransport 对象）尝试 RESUME。
  /// 用于冷启动场景：app 重启后 AqtTransport 对象已销毁，从 SecureStorage
  /// 加载元数据后直接发起 RESUME。
  ///
  /// 返回 nullable 的简化形式，丢弃失败原因。调用方若需要根据失败类型决策
  /// (例如冷启动 RESUME 失败时是否清 store) 改用 [tryResumeWithInfoDetailed]。
  static Future<AqtTransport?> tryResumeWithInfo({
    required String host,
    required int port,
    required Uint8List spki,
    required Uint8List sessionToken,
    required int tabId,
    Duration budget = kDefaultResumeTimeout,
    AqtRoute route = AqtRoute.direct,
    Future<AqtSshRelay> Function(int daemonPort)? openRelay,
  }) async {
    final result = await tryResumeWithInfoDetailed(
      host: host,
      port: port,
      spki: spki,
      sessionToken: sessionToken,
      tabId: tabId,
      budget: budget,
      route: route,
      openRelay: openRelay,
    );
    return switch (result) {
      AqtResumeSuccess(:final transport) => transport,
      AqtResumeFailed() => null,
    };
  }

  /// Detailed 版本：返回 [AqtResumeResult] 让调用方区分失败原因。
  /// Test hook replacing the FFI RESUME against one endpoint (host:port).
  @visibleForTesting
  static Future<AqtResumeResult> Function({
    required String host,
    required int port,
    required Uint8List spki,
    required Uint8List sessionToken,
    required int tabId,
    required Duration budget,
  })? resumeEndpointOverride;

  /// RESUME every path funnels through.
  ///
  /// [route] is the session's persisted route. For [AqtRoute.viaSsh],
  /// [openRelay] opens an SSH relay towards the daemon on [port] (the
  /// caller knows which SSH connection to use); RESUME then dials the
  /// relay's local port, and the transport takes the relay over. Opening
  /// the relay has its own 8 s budget, separate from [budget], so a cold
  /// auxiliary SSH connection gets time to come up. A relay that cannot be
  /// opened is a failed RESUME, and the caller falls back to a full
  /// reconnect as for any other failure.
  static Future<AqtResumeResult> tryResumeWithInfoDetailed({
    required String host,
    required int port,
    required Uint8List spki,
    required Uint8List sessionToken,
    required int tabId,
    Duration budget = kDefaultResumeTimeout,
    AqtRoute route = AqtRoute.direct,
    Future<AqtSshRelay> Function(int daemonPort)? openRelay,
    @visibleForTesting Duration relayBudget = const Duration(seconds: 8),
  }) async {
    if (route == AqtRoute.direct) {
      final r =
          await _resumeEndpoint(host, port, spki, sessionToken, tabId, budget);
      // 直连 RESUME 因网络类原因失败（§4.6）：直连本身可能被墙/丢包，会话
      // 却还在 —— 用中继再试一次，预算另计。sessionNotFound / handshakeFailed
      // 换路也没用，不重试。
      if (openRelay != null &&
          r is AqtResumeFailed &&
          (r.reason == AqtResumeFailReason.networkTimeout ||
              r.reason == AqtResumeFailReason.unknownError)) {
        debugPrint('[RESUME] direct failed (${r.reason.name}), retrying over relay');
        return _resumeViaRelay(host, port, spki, sessionToken, tabId, budget,
            openRelay, relayBudget);
      }
      return r;
    }
    return _resumeViaRelay(host, port, spki, sessionToken, tabId, budget,
        openRelay, relayBudget);
  }

  static Future<AqtResumeResult> _resumeViaRelay(
    String host,
    int port,
    Uint8List spki,
    Uint8List sessionToken,
    int tabId,
    Duration budget,
    Future<AqtSshRelay> Function(int daemonPort)? openRelay,
    Duration relayBudget,
  ) async {
    if (openRelay == null) {
      return const AqtResumeFailed(AqtResumeFailReason.unknownError,
          detail: 'relayed session but no relay opener');
    }
    final AqtSshRelay relay;
    try {
      // closeIfLate: a relay that opens after the budget has no owner — RESUME
      // already failed — so it is closed instead of left running.
      relay = await closeIfLate(openRelay(port), relayBudget,
          onLate: (r) => r.close(), timeoutMessage: 'ssh relay timed out');
    } catch (e) {
      debugPrint('[RESUME] FAIL: ssh relay: $e');
      return AqtResumeFailed(AqtResumeFailReason.networkTimeout,
          detail: 'ssh relay: $e');
    }
    final r = await _resumeEndpoint(
        '127.0.0.1', relay.localPort, spki, sessionToken, tabId, budget);
    if (r is AqtResumeSuccess) {
      r.transport
        ..attachRelay(route: AqtRoute.viaSsh, relay: relay, daemonPort: port)
        ..lastHost = host;
    } else {
      await relay.close();
    }
    return r;
  }

  static Future<AqtResumeResult> _resumeEndpoint(
    String host,
    int port,
    Uint8List spki,
    Uint8List sessionToken,
    int tabId,
    Duration budget,
  ) async {
    final override = resumeEndpointOverride;
    if (override != null) {
      return override(
        host: host,
        port: port,
        spki: spki,
        sessionToken: sessionToken,
        tabId: tabId,
        budget: budget,
      );
    }
    final tokHex = _hex4(sessionToken);
    debugPrint('[RESUME] attempt host=$host port=$port tab=$tabId tok=$tokHex');

    // aqt_resume() creates a NEW handle (fresh SessionHandle + RESUME flow).
    final Pointer<Void>? handle = AqtFfi.resume(
      host: host,
      port: port,
      spki: spki,
      sessionToken: sessionToken,
      tabId: tabId,
      lastInOff: 0,
    );
    if (handle == null || handle == nullptr) {
      debugPrint('[RESUME] FAIL: aqt_resume() returned null handle (FFI unavailable?)');
      return const AqtResumeFailed(AqtResumeFailReason.unknownError,
          detail: 'aqt_resume returned null handle');
    }

    final t = AqtTransport.withHandle(handle);
    // P2: ResumeTimings — sentAt = right after aqt_resume() returns a
    // handle; ackAt = state == connected; replayCompleteAt = set later
    // in SessionTab.startStreaming() listener.
    t.recordResumeSent();
    try {
      // 共享 budget，两段 await 合用一个 deadline：连接就绪 + TabOpened。
      // 取值分三档（proactive 3s / default 5s / 弱网 14s），由调用方选，
      // 理由见各自常量的文档。提前超时是为了让 SSH bootstrap 更早启动。
      final deadline = DateTime.now().add(budget);
      Duration remaining() {
        final d = deadline.difference(DateTime.now());
        return d.isNegative ? Duration.zero : d;
      }
      await t.stateStream
          .where((s) =>
              s == TransportState.connected || s == TransportState.failed)
          .first
          .timeout(remaining());
      if (t.currentState == TransportState.failed) {
        final err = t.failureReason ?? 'unknown';
        debugPrint('[RESUME] FAIL: transport failed: $err');
        await t.close();
        return AqtResumeFailed(_classifyFailureReason(err), detail: err);
      }
      t.recordResumeAck();
      final newTabId = await t.tabOpenedFuture.timeout(remaining());
      t.tabId = newTabId;
      debugPrint('[RESUME] SUCCESS tok=$tokHex newTab=$newTabId');

      // 写元数据给后续 resume 用
      t.lastHost = host;
      t.lastPort = port;
      t.lastSpki = spki;
      t.sessionToken = sessionToken;
      t.wasResumed = true;
      return AqtResumeSuccess(t);
    } on TimeoutException catch (e) {
      // 握手通没通 —— 见 AqtResumeFailed.reachedConnected。
      //
      // 判据用 `lastResumeTimings.ackAt` 而不是 `currentState == connected`：
      // ackAt 由上面的 recordResumeAck() 一次性写入、不会回滚，而 currentState
      // 是活的 —— 卡在 tabOpenedFuture 期间连接若转 failed，读 currentState 就
      // 会把一次「握手通了但没等到 ResumeAck」误报成「握手没通」，正好抹掉这个
      // 埋点唯一想区分的那件事。
      //
      // 必须在 close() **之前**取值。
      final reachedConnected = t.lastResumeTimings.ackAt != null;
      debugPrint('[RESUME] FAIL: timeout '
          'hs=${reachedConnected ? "ok" : "--"}: $e');
      await t.close();
      return AqtResumeFailed(AqtResumeFailReason.networkTimeout,
          detail: e.toString(), reachedConnected: reachedConnected);
    } catch (e) {
      final reachedConnected = t.lastResumeTimings.ackAt != null;
      debugPrint('[RESUME] FAIL: exception: $e');
      await t.close();
      return AqtResumeFailed(AqtResumeFailReason.unknownError,
          detail: e.toString(), reachedConnected: reachedConnected);
    }
  }

  /// 根据 Rust 侧 failureReason 字符串分类 RESUME 失败。
  ///
  /// Rust 侧约定的前缀：
  ///   AQT_ERR_SNF: → session-not-found (ffi.rs do_quic_resume:1147-1152)
  ///   (其他错误暂未加前缀，统一归 handshakeFailed)
  ///
  /// 同时保留 contains 兜底匹配旧版 Rust 库（未加前缀的旧 .so 仍能识别）。
  static AqtResumeFailReason _classifyFailureReason(String reason) {
    if (reason.startsWith('AQT_ERR_SNF') ||
        reason.contains('not found on server')) {
      return AqtResumeFailReason.sessionNotFound;
    }
    // TLS / SPKI / 解码错误统一归为握手失败
    return AqtResumeFailReason.handshakeFailed;
  }

  static String _hex4(List<int> bytes) =>
      bytes.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

  /// QUIC to the daemon described by [info], picking the route (see
  /// [AqtRoute]): direct UDP (4 s) raced against QUIC over an SSH exec
  /// channel on [client] (started after a 300 ms head start; first success
  /// wins) — unless [server] is set to always use the SSH channel. The result is cached per
  /// server for this run. With [ownsClient], a relayed transport takes
  /// [client] over and closes it with itself.
  static Future<AqtRouteOutcome<AqtTransport>> connectRouted({
    required Server server,
    required SSHClient client,
    required AqtBootstrapInfo info,
    required bool ownsClient,
    int cols = 80,
    int rows = 24,
  }) async {
    final ports = AqtPortSpec.forServer(server.aqtPorts);
    final routed = await connectWithRoute<AqtTransport>(
      forceViaSsh: server.aqtViaSsh,
      cached: AqtRouteCache.instance.get(server.id),
      discard: (t) => t.close(),
      direct: () => closeIfLate(
        AqtTransport.connect(
            host: server.host, bootstrap: info, cols: cols, rows: rows),
        const Duration(seconds: 4),
        onLate: (t) => t.close(),
        timeoutMessage: 'QUIC connect timed out — UDP port ${info.port} '
            'unreachable? Allow UDP $ports in the server firewall / '
            'security group',
      ),
      viaSsh: () async {
        final relay = await AqtSshRelay.start(client, daemonPort: info.port);
        try {
          final t = await closeIfLate(
            AqtTransport.connect(
              host: '127.0.0.1',
              bootstrap: info.withPort(relay.localPort),
              cols: cols,
              rows: rows,
            ),
            const Duration(seconds: 8),
            onLate: (t) => t.close(),
            timeoutMessage: 'QUIC over the SSH relay timed out',
          );
          t.attachRelay(
            route: AqtRoute.viaSsh,
            relay: relay,
            ownedSshClient: ownsClient ? client : null,
            daemonPort: info.port,
          );
          return t;
        } catch (_) {
          await relay.close();
          rethrow;
        }
      },
    );
    AqtRouteCache.instance.set(server.id, routed.route);
    return routed;
  }

  /// The SSH-relay failure inside [e] — unwrapping [TransportConnectException]
  /// and [AqtRouteException] — or null when the relay is not what failed.
  /// These failures are deterministic: retrying will not help.
  @visibleForTesting
  static Exception? relayFailureOf(Object? e) => switch (e) {
        AqtRelayUnsupportedException() || AqtRelayStartException() =>
          e as Exception,
        AqtRouteException(:final viaSsh) => relayFailureOf(viaSsh),
        TransportConnectException(:final cause) => relayFailureOf(cause),
        _ => null,
      };

  /// A user-facing message for a QUIC connect failure: the SSH-relay
  /// failures get their own copy, everything else its own text.
  static String describeConnectError(BuildContext context, Object e) {
    final l = context.l10n;
    return switch (relayFailureOf(e)) {
      AqtRelayUnsupportedException() => l.aqtRelayUnsupported,
      AqtRelayStartException(:final stderr) => l.aqtRelayStartFailed(stderr),
      _ => '$e',
    };
  }

  /// Bootstraps flyterm-server for [server]: daemon or once mode, on the
  /// server's configured UDP port range.
  ///
  /// [confirmContext] is the interactive context, if any. Only then can a
  /// daemon running outside the configured range be restarted, after the
  /// user agrees (it ends every AQT session on the host). Background
  /// reconnects pass null and keep using the running daemon.
  static Future<AqtBootstrapResult> bootstrapFor(
    Server server,
    SSHClient client, {
    BuildContext? confirmContext,
  }) {
    final ports = AqtPortSpec.forServer(server.aqtPorts);
    if (!server.useDaemon) return bootstrapOnce(client, ports: ports);
    final ctx = confirmContext;
    return bootstrapDaemonStrict(
      client,
      ports: ports,
      confirmRestart: ctx == null
          ? null
          : (running) async {
              if (!ctx.mounted) return false;
              return showAqtPortRestartDialog(
                ctx,
                currentPort: running.port,
                ports: ports,
                sessions: running.sessions,
              );
            },
    );
  }

  /// Check remote binary version against APK-bundled VERSION asset.
  /// If they differ, silently upload the new binary.
  /// A brief SnackBar is shown via [dialogContext] if available.
  /// All errors are swallowed — the bootstrap loop handles "not installed" cases.
  ///
  /// Exposed as public static so terminal_screen.dart's direct bootstrap path
  /// can call it (that path bypasses connectWithCredentials entirely).
  static Future<void> maybeUpgrade(
    SSHClient client,
    BuildContext? dialogContext, {
    bool useDaemon = false,
    AqtPortSpec ports = AqtPortSpec.defaults,
  }) async {
    try {
      final assetVersion = await AqtServerInstaller.loadVersionString();
      final remoteVersion = await AqtServerInstaller.checkRemoteVersion(client);

      if (remoteVersion == null) {
        // Binary not found — bootstrap loop catches AqtServerNotInstalledException.
        return;
      }

      // All version strings use "cargo_ver-git_sha" format:
      //   asset VERSION  = "0.2.0-f376984"  (from build-server-assets.sh)
      //   AQT_VERSION    = "0.2.0-f376984"  (GIT_SHA embedded at compile)
      //   sidecar file   = "0.2.0-f376984"  (written by uploadBinary)
      //   legacy sentinel= "legacy"          (always upgrade)
      //
      // Multi-user policy: upgrade-only, never downgrade.
      // Skip only when the server's semver is STRICTLY higher than ours —
      // another user may have already upgraded it.
      // Same semver with a different git-SHA still upgrades: within one
      // release cycle the SHA is the only thing that moves, and skipping on
      // it would mean server-side fixes never reach hosts that are already
      // on the current semver.  (See _serverVersionSufficient — it returns
      // false in that case.)
      if (_serverVersionSufficient(remoteVersion, assetVersion)) {
        debugPrint('[AQT] server version OK: $remoteVersion (client: $assetVersion)');
        return;
      }

      debugPrint(
        '[AQT] upgrading server: $remoteVersion → $assetVersion',
      );

      if (dialogContext != null && dialogContext.mounted) {
        ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(
          content: Text(
            '正在更新 FlyTerm Server $remoteVersion → $assetVersion...',
          ),
          duration: const Duration(seconds: 5),
        ));
      }

      // Detect arch + load binary from APK assets.
      final arch = await AqtServerInstaller.detectArch(client);
      if (arch == null) {
        debugPrint('[AQT] upgrade skipped: unsupported arch');
        return;
      }
      final bytes = await AqtServerInstaller.loadBinaryAsset(arch);
      final pkgInfo = await PackageInfo.fromPlatform();

      // New flow: upload as .new.gz and let the binary self-install via
      // its --install subcommand. Falls back to the legacy shell-orchestrated
      // flow if --install is unsupported by the binary being uploaded (this
      // shouldn't happen given the APK ships the latest binary, but is a
      // safety net for the early N+1 migration window).
      final outcome = await AqtServerInstaller.uploadAndSelfInstall(
        client, bytes, arch,
        flytermVersion: pkgInfo.version,
        binaryVersion: assetVersion,
        ports: ports,
      );
      if (outcome.success) {
        debugPrint(
          '[AQT] self-install OK: version=${outcome.version} '
          'port=${outcome.port} pid=${outcome.pid}',
        );
      } else if (outcome.exitCode == 127 ||
                 (outcome.errorReason?.contains('command not found') ?? false) ||
                 (outcome.errorReason?.contains('unknown') ?? false)) {
        // Remote binary doesn't understand --install (very old version).
        // Fall back to the legacy upload-orchestrate flow. This branch
        // disappears in a follow-up cleanup commit ~6 months later.
        debugPrint('[AQT] --install not supported by remote; using legacy flow');
        await AqtServerInstaller.uploadBinary(
          client, bytes, arch,
          flytermVersion: pkgInfo.version,
          binaryVersion: assetVersion,
        );
        final newVer = await AqtServerInstaller.verifyInstall(client);
        if (newVer == null) {
          debugPrint('[AQT] legacy upgrade verify failed — using old binary');
        } else {
          await killDaemon(client);
          if (useDaemon) {
            try {
              await bootstrapDaemonStrict(client, ports: ports);
            } catch (e) {
              debugPrint('[AQT] legacy post-upgrade daemon spawn failed: $e');
            }
          }
        }
      } else {
        debugPrint(
          '[AQT] self-install FAILED: exit=${outcome.exitCode} '
          'reason=${outcome.errorReason}',
        );
        // Do NOT fall back — the binary IS the latest, so if --install
        // reported INSTALL_ERR the issue is environmental (permission,
        // disk, kill failure). Falling back to shell would hit the same
        // environmental failure. Surface to user instead.
      }

      if (dialogContext != null && dialogContext.mounted) {
        ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(
          content: Text(outcome.success
              ? 'FlyTerm Server 已更新至 ${outcome.version}'
              : 'FlyTerm Server 更新失败：${outcome.errorReason}'),
          duration: Duration(seconds: outcome.success ? 2 : 4),
        ));
      }
    } catch (e) {
      debugPrint('[AQT] _maybeUpgrade error (swallowed): $e');
    }
  }

  /// Returns true when the server's version is sufficient — no upgrade needed.
  ///
  /// Rules (multi-user, upgrade-only policy):
  ///   1. Exact match (semver + SHA identical) → skip.
  ///   2. Server semver STRICTLY HIGHER than client → skip (don't downgrade;
  ///      another user may have already upgraded it to a newer release).
  ///   3. Everything else → upgrade.  This covers:
  ///      • same semver, different SHA  (bug-fix rebuild within same version)
  ///      • server semver older than client
  ///
  /// Special cases:
  ///   "legacy"    → always upgrade (old format without semver prefix)
  ///   unparseable → fall back to exact-match
  static bool _serverVersionSufficient(String remote, String asset) {
    if (remote == 'legacy') return false;        // always upgrade legacy
    if (remote == asset) return true;             // exact match, fast path
    final rv = _parseSemver(remote);
    final av = _parseSemver(asset);
    if (rv == null || av == null) return remote == asset; // unparseable → exact
    // Skip only if server semver is STRICTLY higher (no downgrade).
    // Same semver with different SHA: fall through → upgrade.
    if (rv[0] != av[0]) return rv[0] > av[0];
    if (rv[1] != av[1]) return rv[1] > av[1];
    if (rv[2] != av[2]) return rv[2] > av[2];
    return false; // same semver, different SHA → upgrade
  }

  /// Parses "MAJOR.MINOR.PATCH[-anything]" → [major, minor, patch] or null.
  static List<int>? _parseSemver(String version) {
    final core = version.split('-').first;
    final parts = core.split('.');
    if (parts.length < 3) return null;
    final nums = parts.take(3).map(int.tryParse).toList();
    if (nums.any((n) => n == null)) return null;
    return nums.cast<int>();
  }
}

/// Internal tag for racing RESUME against a delay timer in
/// [AqtTransportFactory._reconnectRace].
class _RaceTagged {
  final AqtResumeResult? resume;
  final bool isTimeout;
  _RaceTagged.resume(this.resume) : isTimeout = false;
  _RaceTagged.timeout()
      : resume = null,
        isTimeout = true;
  bool get isResume => !isTimeout;
}
