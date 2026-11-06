// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../util/dlog.dart';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'claude_runtime_options.dart';
import 'ssh_connection.dart' show sshConnectForExec;
import 'ssp_interface.dart' as v2iface;
import 'ssp_v2/mosh_shell_v2.dart';
import 'ssp_v2/moshv2_shell.dart';

class MoshHandshakeException implements Exception {
  final String message;
  const MoshHandshakeException(this.message);
  @override
  String toString() => 'MoshHandshakeException: $message';
}

/// Performs the SSH→mosh handshake and returns a [MoshShellV2].
///
/// Flow:
///   1. SSH exec "mosh-server new -s -c 256 -l LANG=UTF-8 -p <portRange>"
///   2. Parse stdout: "MOSH CONNECT <port> <key>"
///   3. Establish SSP v2 transport over UDP
///
/// On failure throws [MoshHandshakeException] — callers should fall back to SSH.
class MoshHandshake {
  /// SSH into [host] and kill [pid].
  /// Used at startup to clean up mosh-server processes that survived a
  /// previous app crash or force-quit.
  static Future<bool> killOrphanedPid({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    required int pid,
  }) async {
    SSHClient? client;
    try {
      client = await sshConnectForExec(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKeyPem: privateKeyPem,
        timeout: const Duration(seconds: 8),
      );
      final s = await client.execute('kill $pid 2>/dev/null; true');
      await s.stdout.drain<void>();
      await s.done.timeout(const Duration(seconds: 3));
      return true;
    } catch (e) {
      dlog('MoshHandshake', 'failed to kill orphan pid=$pid: $e');
      return false;
    } finally {
      client?.close();
    }
  }

  static final _connectRe = RegExp(
    r'MOSH CONNECT (\d+) ([A-Za-z0-9+/=]{22,24})',
  );
  // mosh-server writes "[mosh-server detached, pid = XXXXX]" to stderr.
  static final _stderrPidRe = RegExp(r'pid\s*=\s*(\d+)');

  /// Returns a [MoshShellV2] on success.
  /// Throws [MoshHandshakeException] if mosh-server is not found or times out.
  ///
  /// [reuseClient]: pass the already-authenticated [SSHClient] from
  /// [SSHConnection.client] to skip a full SSH re-authentication (~5-8 RTTs).
  /// When provided, the caller owns the client lifecycle — it is NOT closed
  /// on success or failure. When null, a fresh SSH connection is created and
  /// closed after the UDP handshake completes.
  static Future<MoshShellV2> run({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String portRange = '60000:61000',
    Duration timeout = const Duration(seconds: 10),
    SSHClient? reuseClient,
    int terminalWidth = 80,
    int terminalHeight = 24,
    String addressFamily = 'auto',
    bool sshCompression = true,
    String? flytermSessionId,
    String? flytermServerId,
    // PIDs to kill before starting the new mosh-server, batched into the same
    // SSH exec channel so we save ~2 RTTs vs a separate kill exec beforehand.
    List<int> prependKillPids = const [],
    Future<void> Function(int pid, int udpPort)? onServerStarted,
    Future<void> Function(int pid)? onServerKilled,
  }) async {
    // If a reuse client is provided, skip SSH authentication entirely — the
    // caller already authenticated and we only need an exec channel.
    SSHClient? ownedClient; // non-null only when we created the connection
    SSHClient? client;
    // Declared here for cleanup in the catch block if we throw before the
    // subscriptions are cancelled through the normal code path.
    StreamSubscription<dynamic>? stdoutSub;
    StreamSubscription<dynamic>? stderrSub;
    try {
      if (reuseClient != null) {
        client = reuseClient;
      } else {
        // Authenticate over SSH without opening a shell channel.
        // Opening a PTY shell wastes ~3 RTTs on channel-open + pty-req + shell.
        ownedClient = await sshConnectForExec(
          host: host,
          port: port,
          username: username,
          password: password,
          privateKeyPem: privateKeyPem,
          timeout: timeout,
          sshCompression: sshCompression,
        );
        client = ownedClient;
      }

      // CLAUDE_CODE_NO_FLICKER=1 prefixed onto the command line: bash
      // (which is what `client.execute` runs the string through) treats
      // that as a per-command env var assignment. mosh-server inherits
      // it at exec time, putenv-survives the fork, and the bash spawned
      // for the user's shell session inherits it too. From there any
      // `claude` invocation enters alt buffer mode (NF-1 design).
      //
      // Why not mosh-server's own -l flag: it only putenvs the value
      // inside an `if (!is_utf8_locale())` branch in upstream mosh
      // (mosh-server.cc:332), so on UTF-8 systems -l vars are silently
      // dropped. Verified empirically on the local server.
      final appEnv = [
        ...ClaudeRuntimeOptions.auto(isMosh: true).toEnvAssignments(),
        if (flytermSessionId != null) 'FLYTERM_SESSION_ID=$flytermSessionId',
        if (flytermServerId != null) 'FLYTERM_SERVER_ID=$flytermServerId',
      ].join(' ');
      // Prepend kill commands for stale PIDs into the same exec channel so
      // kill + mosh-server new complete in a single SSH round-trip.
      final killPrefix = prependKillPids.isEmpty
          ? ''
          : 'kill ${prependKillPids.join(' ')} 2>/dev/null; ';
      final session = await client.execute(
        '$killPrefix$appEnv mosh-server new -s -c 256 -l LANG=UTF-8 -l MOSH_SERVER_NETWORK_TMOUT=1800 -p $portRange -w $terminalWidth -t $terminalHeight',
      );

      // Stream-parse stdout + stderr with listeners so we can act on the
      // "MOSH CONNECT port key" line the moment it arrives — without waiting
      // for the exec channel to close (fork + parent-exit, ~50–200 ms extra).
      // Both lines are written by mosh-server BEFORE it forks, so they
      // typically arrive in the same network packet as each other.
      final stdoutAccum = StringBuffer();
      final stderrAccum = StringBuffer();
      final connectCompleter = Completer<RegExpMatch>();
      final pidCompleter = Completer<int?>();

      stdoutSub = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
        (chunk) {
          stdoutAccum.write(chunk);
          if (!connectCompleter.isCompleted) {
            final m = _connectRe.firstMatch(stdoutAccum.toString());
            if (m != null) connectCompleter.complete(m);
          }
        },
        onError: (Object e) {
          if (!connectCompleter.isCompleted) connectCompleter.completeError(e);
        },
        onDone: () {
          if (!connectCompleter.isCompleted) {
            final s = stdoutAccum.toString();
            connectCompleter.completeError(
              MoshHandshakeException(
                'mosh-server 未返回连接信息，输出: ${s.length > 200 ? s.substring(0, 200) : s}',
              ),
            );
          }
        },
      );

      stderrSub = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
        (chunk) {
          stderrAccum.write(chunk);
          if (!pidCompleter.isCompleted) {
            final m = _stderrPidRe.firstMatch(stderrAccum.toString());
            if (m != null) pidCompleter.complete(int.tryParse(m.group(1)!));
          }
        },
        onDone: () {
          if (!pidCompleter.isCompleted) {
            final m = _stderrPidRe.firstMatch(stderrAccum.toString());
            pidCompleter.complete(m != null ? int.tryParse(m.group(1)!) : null);
          }
        },
      );

      // Wait for "MOSH CONNECT port key" — arrives before mosh-server forks.
      RegExpMatch connectMatch;
      try {
        connectMatch = await connectCompleter.future.timeout(
          timeout,
          onTimeout: () {
            throw const MoshHandshakeException('mosh-server 启动超时，可能未安装');
          },
        );
      } finally {
        await stdoutSub.cancel();
        stdoutSub = null;
      }

      final udpPort = int.parse(connectMatch.group(1)!);
      final keyB64 = connectMatch.group(2)!;
      final key = base64.decode(_padBase64(keyB64));
      if (key.length != 16) {
        await stderrSub.cancel();
        stderrSub = null;
        throw const MoshHandshakeException('mosh key 长度不是 16 字节');
      }

      // Wait for PID line — typically arrives in the same packet as CONNECT.
      // PID source: stderr "[mosh-server detached, pid = XXXXX]".
      // Reliable because mosh-server writes it synchronously before forking.
      // pgrep fallback removed — it races against fork and can return a sibling
      // tab's mosh-server PID when multiple tabs connect to the same server.
      final serverPid = await pidCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null, // proceed without PID if unusually delayed
      );
      await stderrSub.cancel();
      stderrSub = null;
      if (serverPid != null) {
        dlog('MoshHandshake', 'mosh-server PID=$serverPid on $host:$udpPort');
      }

      // Fire DB write now — runs concurrently with UDP bind below.
      // Neither operation depends on the exec channel having closed.
      final dbFuture = serverPid != null
          ? onServerStarted?.call(serverPid, udpPort)
          : null;

      // Establish SSP v2 transport — keep SSH client alive until UDP succeeds
      // so we can kill the orphaned mosh-server on failure.
      v2iface.SspTransport v2Transport;
      try {
        v2Transport = await createMoshV2Transport(
          host: host,
          port: udpPort,
          sessionKey: key,
          initialCols: terminalWidth,
          initialRows: terminalHeight,
        );
        try {
          await dbFuture; // ensure DB write finishes after UDP succeeds
        } catch (_) {}
      } catch (e) {
        try { await dbFuture; } catch (_) {} // let DB write finish before kill
        if (serverPid != null) {
          var killed = false;
          try {
            final s = await client
                .execute('kill $serverPid 2>/dev/null; true')
                .timeout(const Duration(seconds: 3));
            await s.stdout.drain<void>();
            killed = true;
          } catch (_) {}
          if (killed) await onServerKilled?.call(serverPid);
        }
        throw MoshHandshakeException('Mosh v2 UDP 绑定失败: $e');
      }
      ownedClient?.close();
      ownedClient = null;
      return MoshShellV2(
        v2Transport,
        host: host,
        sshPort: port,
        username: username,
        password: password,
        privateKeyPem: privateKeyPem,
        serverPid: serverPid,
        udpHost: host,
        udpPort: udpPort,
        moshKey: key,
      );
    } catch (e) {
      await stdoutSub?.cancel(); // cancel if we threw before the normal path
      await stderrSub?.cancel();
      ownedClient?.close(); // never close a caller-supplied reuseClient
      if (e is MoshHandshakeException) rethrow;
      throw MoshHandshakeException('握手失败: $e');
    }
  }

  static String _padBase64(String s) {
    while (s.length % 4 != 0) {
      s += '=';
    }
    return s;
  }
}
