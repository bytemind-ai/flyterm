// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';

import '../legacy_path_migration.dart';
import 'aqt_port_spec.dart';

/// Parsed info from flyterm-server bootstrap stdout.
class AqtBootstrapInfo {
  final int version;
  final int port;
  final Uint8List spki;
  final Uint8List token;

  /// daemon 当前的活跃会话数（`--status` 的 `AQT_SESSIONS`）。旧版服务端
  /// 不报这个数，或 once 模式，都是 null。只用于「重启会中断几个会话」的提示。
  final int? sessions;

  const AqtBootstrapInfo({
    required this.version,
    required this.port,
    required this.spki,
    required this.token,
    this.sessions,
  });
}

/// Bootstrap result: holds the parsed info AND (optionally) the SSH session.
///
/// In once mode the SSH session keeps the flyterm-server process alive — call
/// [close] after QUIC is established or failed.
///
/// In daemon mode [_session] is null and [close] is a no-op.
class AqtBootstrapResult {
  final AqtBootstrapInfo info;

  /// Whether this result came from a pre-running daemon (no SSH session owned).
  final bool isDaemon;

  final SSHSession? _session; // null when isDaemon == true

  AqtBootstrapResult._(this.info, this._session, {required this.isDaemon});

  /// Release the SSH exec channel. Call after QUIC is established or failed.
  /// No-op in daemon mode (no session to close).
  void close() { _session?.close(); }
}

/// 拉起 server 时指定的拥塞控制算法，拼进两条启动命令。
///
/// 换成 BBR 是为了治「恢复要卡几秒」：CUBIC 这类 loss-based 算法的吞吐上限约
/// 等于 `MSS / (RTT × √p)`，真机现场 RTT 82 ms、丢包 1.1%、MTU 1200 B 代入得
/// ≈139 KB/s，而实测恢复快照 267993 B 花了 1827 ms ≈ 147 KB/s —— 差 5% 以内。
/// 也就是说瓶颈不是路径带宽，是 CUBIC 把移动网络的**随机**丢包当拥塞信号在
/// 砍窗（现场 cwnd 只有 8 KB）。BBR 不看丢包，正好绕开这个上限。
///
/// **这是个待验证的假设，不是已知的改进。** quinn-proto 0.10.6 的 BBR 自带
/// `Experimental! Use at your own risk.` 标注，是 Chromium quiche 的 BBRv1；
/// 它的 ProbeRTT 每约 10 s 把 cwnd 压到 4 个包、持续 200 ms，在交互式终端上
/// 可能表现成周期性的小顿挫。要回退就把这里改回 `'cubic'`。
///
/// 旧版 server 二进制不认这个 flag，但它的 CLI 是手写解析、不校验未知参数，
/// 多出来的 `--congestion bbr` 会被静默忽略 —— 所以推新 App 配旧 server 不会
/// 把连接搞坏，只是没有 BBR。是否真的生效以远端
/// `~/.flyterm-server/state/daemon.log` 里那行 `congestion control: bbr` 为准。
const String kAqtCongestion = 'bbr';

class AqtBootstrapException implements Exception {
  final String message;
  const AqtBootstrapException(this.message);
  @override
  String toString() => 'AqtBootstrapException: $message';
}

/// Specific signal that the remote doesn't have flyterm-server binary.
/// Caller (transport factory in task 7) catches this to trigger install dialog
/// and retry bootstrap.
class AqtServerNotInstalledException implements Exception {
  const AqtServerNotInstalledException();
  @override
  String toString() =>
      'AqtServerNotInstalledException: flyterm-server not found on remote';
}

/// Daemon-strict bootstrap failed to bring up `flyterm-server --listen`.
/// Strict mode: caller surfaces this to the user — no silent fall-back to once.
class AqtDaemonStartFailedException implements Exception {
  final String reason;
  const AqtDaemonStartFailedException(this.reason);
  @override
  String toString() => 'AqtDaemonStartFailedException: $reason';
}

/// Once-mode bootstrap — shorthand alias for [bootstrapAqtServer].
///
/// Used when `Server.useDaemon == false` (the default). Skips daemon probe
/// entirely to avoid the 5s --status wait when the user has explicitly chosen
/// once mode.
Future<AqtBootstrapResult> bootstrapOnce(
  SSHClient client, {
  String term = 'xterm-256color',
  AqtPortSpec ports = AqtPortSpec.defaults,
}) =>
    bootstrapAqtServer(client, term: term, ports: ports);

/// Daemon-strict bootstrap.
///
/// Used when `Server.useDaemon == true`. Flow:
/// 1. Probe `flyterm-server --status` (5s budget). If daemon already running,
///    reuse its port + spki.
/// 2. Otherwise exec `nohup flyterm-server --listen <ports> …` to start daemon,
///    then poll via `--status` which reads `~/.flyterm-server/daemon.info` (5s
///    budget, 250 ms interval).
/// 3. If daemon.info never appears, throw [AqtDaemonStartFailedException] —
///    strict mode does NOT fall back to once. Caller (UI) surfaces the error
///    and asks user to either unblock UDP or uncheck Daemon mode.
///
/// [ports]: the UDP port range the daemon should listen on. A daemon that is
/// already running outside that range (the setting changed after it started)
/// can only move by restarting, which ends every AQT session on the host —
/// including other devices'. So [confirmRestart] asks the user first, given
/// the running daemon (its port and live session count); declining (or no
/// callback, e.g. background reconnects) keeps using it on its old port.
Future<AqtBootstrapResult> bootstrapDaemonStrict(
  SSHClient client, {
  String term = 'xterm-256color',
  AqtPortSpec ports = AqtPortSpec.defaults,
  Future<bool> Function(AqtBootstrapInfo running)? confirmRestart,
}) async {
  // ── Step 1: probe existing daemon ──
  final existing = await _probeDaemon(client);
  if (existing != null) {
    final restart = daemonPortMismatch(existing, ports) &&
        confirmRestart != null &&
        await confirmRestart(existing);
    if (!restart) {
      return AqtBootstrapResult._(existing, null, isDaemon: true);
    }
    await killDaemon(client);
  }

  // ── Step 2: start daemon via setsid + nohup ──
  // setsid creates a new session, detaching the daemon from the SSH shell's
  // session group. On hosts with systemd-logind `KillUserProcesses=yes`
  // (Debian/Ubuntu default), all processes in the SSH session's cgroup are
  // killed when the SSH channel closes — nohup + disown alone is NOT enough,
  // setsid is required to actually survive SSH disconnect.
  // < /dev/null redirects stdin (safer than 0<&- which fully closes fd 0;
  // closed fd 0 can be reused by libc opens, redirecting unexpected writes
  // into the wrong file).
  // disown removes from the SSH shell's job table.
  // --listen <ports>: the server picks a free port in the range and writes
  // it to daemon.info. See buildDaemonSpawnCommand for the old-binary
  // fallback.
  //
  // unset TMUX*/TERM_PROGRAM*: SSH exec runs under the user's login shell,
  // which may auto-attach tmux in ~/.bashrc. Without scrubbing, the daemon
  // inherits TMUX/TMUX_PANE/TERM_PROGRAM=tmux; every PTY it spawns hands
  // those vars to the child shell, and tools that sniff $TMUX (Claude CLI,
  // various TUI status lines) switch into a tmux-compat rendering path
  // even though no tmux wraps this PTY — producing duplicate cursors and
  // reflow artifacts after keyboard show/hide. The server-side pty_task
  // strips these too (defense in depth), but cleaning at daemon spawn is
  // the right primary fix so `flyterm-server --status` etc. also see a
  // clean env.
  // G3 (k9.jpg): wrap the spawn exec with an 8 s timeout. Without it,
  // a half-dead SSH client (MaxSessions limit, half-open TCP) leaves
  // this await hanging forever — the outer _reconnect / _connectServer
  // also have no overarching timeout for daemon-mode bootstrap, so the
  // entire reconnect loop wedges and the periodic ticker can't help
  // (the _reconnecting lock stays held).
  await client
      .execute(buildDaemonSpawnCommand(ports: ports, congestion: kAqtCongestion))
      .timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw AqtBootstrapException(
          'daemon spawn exec hung > 8s (SSH half-dead?)',
        ),
      );

  // ── Step 3: poll daemon.info (true 5 s budget) ──
  // G3: previous loop did `20 × (250ms delay + 5s _probeDaemon timeout)`
  // = up to 105 s worst case when daemon never appears and _probeDaemon
  // hits its own timeout every iteration. Doc-stated "5 s budget" was a
  // lie. Use a real wall-clock deadline so total bootstrap stays bounded.
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 250));
    if (!DateTime.now().isBefore(deadline)) break;
    final info = await _probeDaemon(client);
    if (info != null) {
      return AqtBootstrapResult._(info, null, isDaemon: true);
    }
  }

  // Fetch tail of daemon.log to help the user diagnose.
  String detail = '';
  try {
    final logSession = await client
        .execute(
          r'tail -n 5 "$HOME/.flyterm-server/state/daemon.log" 2>/dev/null || true',
        )
        .timeout(const Duration(seconds: 3));
    final logOut = StringBuffer();
    await for (final chunk in logSession.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .timeout(const Duration(seconds: 3), onTimeout: (_) {})) {
      logOut.write(chunk);
    }
    final trimmed = logOut.toString().trim();
    if (trimmed.isNotEmpty) detail = ' (log tail: $trimmed)';
  } catch (_) {
    // Log fetch is best-effort; don't mask the primary error.
  }

  throw AqtDaemonStartFailedException(
    'daemon.info not written within 5s$detail',
  );
}

/// Try daemon mode first, fall back to once mode.
///
/// **Deprecated path — kept for legacy call sites until they migrate to the
/// `Server.useDaemon`-aware dispatch.** New code should use [bootstrapOnce]
/// (when useDaemon=false) or [bootstrapDaemonStrict] (when useDaemon=true).
///
/// 1. SSH → exec `flyterm-server --status 2>/dev/null`
/// 2. If response contains AQT_PORT + AQT_PUBKEY → daemon is running; return
///    immediately (no new server process, no SSH session to keep alive).
/// 3. Otherwise → start a new once-mode server via [bootstrapAqtServer].
Future<AqtBootstrapResult> bootstrapDaemonOrOnce(
  SSHClient client, {
  String term = 'xterm-256color',
}) async {
  final daemonInfo = await _probeDaemon(client);
  if (daemonInfo != null) {
    return AqtBootstrapResult._(daemonInfo, null, isDaemon: true);
  }
  // Daemon not running → fall back to once mode.
  return bootstrapAqtServer(client, term: term);
}

/// Public wrapper around the daemon-info probe. Returns
/// [AqtBootstrapInfo] if a daemon is currently running on the remote
/// host (reads ~/.flyterm-server/daemon.info via SSH), or null. Used
/// by the QUIC refresh path so a once-mode tab can still RESUME if
/// the user happens to have started a daemon manually (or a previous
/// app run left one running).
Future<AqtBootstrapInfo?> probeExistingDaemon(SSHClient client) =>
    _probeDaemon(client);

/// Execute `flyterm-server --status` and parse the output. Returns null if the
/// daemon is not running, the output is malformed, or the probe times out.
///
/// 5s 兜底：SSH channel 半开 / 远端 flyterm-server --status 假死时,
/// client.execute 或 await for chunk 都可能不返回，让整个 daemon 探测
/// 无限挂起。5s 内拿不到 status 就当 daemon 没在跑。
Future<AqtBootstrapInfo?> _probeDaemon(SSHClient client) async {
  SSHSession? session;
  try {
    return await (() async {
      session = await client.execute(
        // Try user-local install first, fall back to system path (legacy).
        //
        // Defense-in-depth against a STALE daemon.info: a dead daemon can
        // leave daemon.info behind (SIGKILL/OOM/crash/reboot), and an old
        // server binary's --status prints it verbatim — sending us to a dead
        // QUIC port that just times out after 5s. So we verify AQT_PID is
        // alive (kill -0) here in the shell, regardless of server version, and
        // wipe the stale file if not. This mirrors the server-side liveness
        // check but also protects hosts still running an un-upgraded binary.
        // If no AQT_PID line (legacy daemon), fall through and trust it.
        //
        // 前缀那段迁移：这里是 daemon 与 once 两种模式共同的第一次探测，
        // 把改名前的 ~/.aiterm-server/ 搬到新路径必须赶在这次 --status 之前，
        // 否则旧安装会被判成「没装过」而去走重新上传。见 kLegacyRemoteMigration。
        kLegacyRemoteMigration +
        r'BIN="$HOME/.flyterm-server/bin/flyterm-server"; '
        r'[ -x "$BIN" ] || BIN=/usr/local/bin/flyterm-server; '
        r'OUT=$("$BIN" --status 2>/dev/null || true); '
        r'PID=$(printf "%s\n" "$OUT" | sed -n "s/^AQT_PID=//p"); '
        r'if [ -z "$PID" ] || kill -0 "$PID" 2>/dev/null; then '
        r'printf "%s" "$OUT"; '
        r'else rm -f "$HOME/.flyterm-server/daemon.info" 2>/dev/null; fi',
      );
      final out = StringBuffer();
      await for (final chunk
          in session!.stdout.cast<List<int>>().transform(utf8.decoder)) {
        out.write(chunk);
      }
      return parseDaemonInfo(out.toString());
    })().timeout(const Duration(seconds: 5));
  } on TimeoutException {
    return null;
  } finally {
    session?.close();
  }
}

/// Parse `AQT_PORT=<n>\nAQT_PUBKEY=<b64>` from daemon.info / --status output.
/// The shell command that starts the daemon on [ports].
///
/// The range is only passed if the remote binary understands it: an older
/// binary (an upgrade that failed is logged and swallowed, so this can happen)
/// would not parse `61001-61999` and would silently start in once mode, which
/// never writes daemon.info. The `--help` text of range-aware binaries
/// documents `START-END`; anything else gets `--listen 0` (random port), the
/// behaviour it had before.
String buildDaemonSpawnCommand({
  required AqtPortSpec ports,
  required String congestion,
}) =>
    r'BIN="$HOME/.flyterm-server/bin/flyterm-server"; '
    r'[ -x "$BIN" ] || BIN=/usr/local/bin/flyterm-server; '
    r'STATE="$HOME/.flyterm-server/state"; mkdir -p "$STATE"; '
    r'unset TMUX TMUX_PANE TERM_PROGRAM TERM_PROGRAM_VERSION; '
    'if "\$BIN" --help 2>&1 | grep -q START-END; then P=${ports.arg}; '
    'else P=0; fi; '
    'setsid nohup "\$BIN" --listen "\$P" --congestion $congestion < /dev/null '
    r'> "$STATE/daemon.log" 2>&1 & disown';

/// Whether a running daemon listens outside the configured [ports].
bool daemonPortMismatch(AqtBootstrapInfo running, AqtPortSpec ports) =>
    !ports.contains(running.port);

/// The `--listen` argument for `flyterm-server --install`: the binary
/// restarts the daemon itself, so the range has to be given here too.
String installListenArg(AqtPortSpec ports) => '--listen ${ports.arg}';

/// Stops the running daemon (SIGTERM, then SIGKILL after ~2 s) and removes
/// its daemon.info so the next probe starts a fresh one.
Future<void> killDaemon(SSHClient client) async {
  try {
    final kill = await client.execute(
      r'pkill -f "flyterm-server --listen" 2>/dev/null; '
      r'for i in 1 2 3 4 5 6 7 8 9 10; do '
      r'pgrep -f "flyterm-server --listen" >/dev/null 2>&1 || break; '
      r'sleep 0.2; '
      r'done; '
      r'pkill -KILL -f "flyterm-server --listen" 2>/dev/null; '
      r'rm -f ~/.flyterm-server/daemon.info; true',
    );
    await kill.done;
  } catch (_) {}
}

AqtBootstrapInfo? parseDaemonInfo(String output) {
  final portMatch =
      RegExp(r'^AQT_PORT=(\d+)$', multiLine: true).firstMatch(output);
  final pubkeyMatch =
      RegExp(r'^AQT_PUBKEY=([A-Za-z0-9+/=._-]+)$', multiLine: true)
          .firstMatch(output);
  if (portMatch == null || pubkeyMatch == null) return null;
  final port = int.tryParse(portMatch.group(1)!);
  if (port == null) return null;
  final sessionsMatch =
      RegExp(r'^AQT_SESSIONS=(\d+)$', multiLine: true).firstMatch(output);
  final sessions =
      sessionsMatch == null ? null : int.tryParse(sessionsMatch.group(1)!);
  try {
    final spki = base64.decode(_pad(pubkeyMatch.group(1)!));
    // Daemon mode: token is unused at connect time — the server issues a fresh
    // session token in the HELLO_ACK frame. Use a zero placeholder.
    return AqtBootstrapInfo(
      version: 1,
      port: port,
      spki: spki,
      token: Uint8List(32),
      sessions: sessions,
    );
  } catch (_) {
    return null;
  }
}

/// Execute `flyterm-server --once` via SSH and parse the AQT_* lines.
/// Returns [AqtBootstrapResult] — caller MUST call [AqtBootstrapResult.close]
/// after the QUIC connection is established (or failed) to release the session.
Future<AqtBootstrapResult> bootstrapAqtServer(
  SSHClient client, {
  String term = 'xterm-256color',
  Duration timeout = const Duration(seconds: 3),
  AqtPortSpec ports = AqtPortSpec.defaults,
}) async {
  // Kill only STALE once-mode servers (those without an active QUIC client).
  // Once mode: process exits on SIGHUP when SSH channel closes, so survivors
  // are orphans from a crashed/dropped session — safe to kill.
  // NOTE: In multi-tab scenarios use daemon mode (--listen PORT) instead;
  // once mode is single-session by design.
  // Kill stale once-mode orphans and wait up to 200ms for them to exit.
  // Using `sleep 0.2` inside the remote shell avoids a local Future.delayed
  // that blocks the Dart event loop — the wait runs server-side concurrently
  // with any other work the App does before starting the QUIC connect.
  // Guard against SSH channel stalls on slow networks.
  await client
      .execute('pkill -f "flyterm-server --once" 2>/dev/null; sleep 0.15; true')
      .timeout(const Duration(seconds: 5),
          onTimeout: () => throw AqtBootstrapException(
              'pkill/sleep exec timed out after 5s'));

  final session = await client
      .execute(
        // Resolve binary path: prefer user-local install, fall back to system.
        // unset TMUX*: see comment in bootstrapDaemonStrict — keeps PTY children
        // free of tmux env leakage from the user's login shell.
        r'BIN="$HOME/.flyterm-server/bin/flyterm-server"; '
        r'[ -x "$BIN" ] || BIN=/usr/local/bin/flyterm-server; '
        r'unset TMUX TMUX_PANE TERM_PROGRAM TERM_PROGRAM_VERSION; '
        // --once-port <range>: an old binary that can't parse the range
        // ignores it and binds a random port, as before.
        'exec "\$BIN" --once --bind 0.0.0.0 --term $term '
        '--once-port ${ports.arg} --congestion $kAqtCongestion',
      )
      .timeout(const Duration(seconds: 8),
          onTimeout: () =>
              throw AqtBootstrapException('server exec timed out after 8s'));

  final lineRe =
      RegExp(r'^AQT_(VER|PORT|PUBKEY|TOKEN)=([A-Za-z0-9+/=._-]+)$');
  final values = <String, String>{};
  final completer = Completer<AqtBootstrapInfo>();
  final buf = StringBuffer();

  // Collect stderr + watch for "binary missing" signals so we can fail fast
  // (raise AqtServerNotInstalledException) instead of timing out at 3 s.
  final stderrBuf = StringBuffer();
  final missingBinaryCompleter = Completer<void>();
  session.stderr.cast<List<int>>().transform(utf8.decoder).listen(
    (chunk) {
      stderrBuf.write(chunk);
      final s = stderrBuf.toString();
      if (!missingBinaryCompleter.isCompleted &&
          (s.contains('No such file or directory') ||
           s.contains('command not found') ||
           s.contains('not found'))) {
        missingBinaryCompleter.complete();
      }
    },
    cancelOnError: false,
  );

  StreamSubscription<String>? sub;
  sub = session.stdout
      .cast<List<int>>()
      .transform(utf8.decoder)
      .listen((chunk) {
    buf.write(chunk);
    while (true) {
      final s = buf.toString();
      final nl = s.indexOf('\n');
      if (nl < 0) break;
      final line = s.substring(0, nl).trimRight();
      buf.clear();
      buf.write(s.substring(nl + 1));

      final m = lineRe.firstMatch(line);
      if (m == null) {
        if (!completer.isCompleted) {
          completer.completeError(
            AqtBootstrapException(
                'unexpected line from flyterm-server: $line'),
          );
          sub?.cancel();
        }
        return;
      }
      values[m.group(1)!] = m.group(2)!;

      if (values.length >= 4) {
        try {
          final info = AqtBootstrapInfo(
            version: int.parse(values['VER']!),
            port: int.parse(values['PORT']!),
            spki: base64.decode(_pad(values['PUBKEY']!)),
            token: base64.decode(_pad(values['TOKEN']!)),
          );
          if (info.token.length != 32) {
            throw const AqtBootstrapException('token must be 32 bytes');
          }
          if (!completer.isCompleted) completer.complete(info);
        } catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(AqtBootstrapException('parse: $e'));
          }
        }
        // Do NOT cancel sub or close session here — keep it alive so
        // flyterm-server stays running until QUIC connects.
        return;
      }
    }
  }, onError: (e) {
    if (!completer.isCompleted) {
      completer.completeError(AqtBootstrapException('stream error: $e'));
    }
  });

  // Race AQT_* completion against early binary-missing detection.
  late final AqtBootstrapInfo info;
  try {
    info = await Future.any<AqtBootstrapInfo>([
      completer.future,
      missingBinaryCompleter.future.then<AqtBootstrapInfo>(
        (_) => throw const AqtServerNotInstalledException(),
      ),
    ]).timeout(timeout, onTimeout: () {
      sub?.cancel();
      session.close();
      final stderr = stderrBuf.toString().trim();
      final detail = stderr.isNotEmpty ? ' (stderr: $stderr)' : '';
      throw AqtBootstrapException('timeout waiting for AQT_* lines$detail');
    });
  } catch (e) {
    // ignore: invalid_null_aware_operator
    sub?.cancel();
    session.close();
    rethrow;
  }

  // Return both info and session — caller must call result.close() later.
  return AqtBootstrapResult._(info, session, isDaemon: false);
}

String _pad(String s) {
  final mod = s.length % 4;
  return mod == 0 ? s : s + '=' * (4 - mod);
}
