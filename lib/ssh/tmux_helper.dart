// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'claude_runtime_options.dart';
import 'ssh_connection.dart';
import 'terminal_env.dart';

/// Static helpers for tmux detection and command generation.
/// Uses a separate exec channel so the interactive shell is never polluted.
class TmuxHelper {
  TmuxHelper._();

  /// Returns true if `tmux` binary exists on the remote server.
  /// Runs `which tmux` via a non-interactive exec channel.
  /// Returns false on any error (null client, timeout, tmux absent).
  static Future<bool> detect(SSHConnection connection) async {
    try {
      final Uint8List result = await connection.client!.run('which tmux');
      return result.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Derives a stable tmux session name from the server ID.
  /// Keyed on server (not tab) so the same session is recovered after
  /// app restart or opening a new tab to the same server.
  static String sessionName(String serverId) =>
      'flyterm-${serverId.substring(0, 12)}';

  /// Command to send to the shell on first connection.
  /// `-A` means: attach if session exists, create new if not.
  ///
  /// `set-environment -t SESSION CLAUDE_CODE_NO_FLICKER 1`
  /// Forces Claude Code v2.1.88+ into its alternate-screen-buffer rendering
  /// mode.  Without this, Claude streams every token-by-token frame into the
  /// pane's main buffer, which then cascades into xterm's scrollback as a
  /// long sequence of near-duplicate render snapshots — historically the
  /// root cause of "tmux scrollback duplication" in this app.  In alt-buffer
  /// mode Claude redraws in place (no scrollback pollution) and exposes its
  /// own internal history view (Ctrl+O) which we navigate with mouse-wheel
  /// pass-through (mouse on, see below).  Other TUI apps (vim, less, htop)
  /// already use alt buffer; this just brings Claude in line.
  ///
  /// `set-option -g mouse on` is preserved so the swipe→SGR-mouse-wheel
  /// translation can flow through tmux into Claude's own scroll handler.
  static String attachOrCreate(String serverId, {bool isMosh = false}) {
    final s = sessionName(serverId);
    final claudeEnv = ClaudeRuntimeOptions.auto(isMosh: isMosh);
    final newSessionEnv =
        envAssignments(claudeEnv, isMosh: isMosh).map((e) => ' -e $e').join();
    final setEnv = tmuxSetEnvironmentArgs(s, claudeEnv, isMosh: isMosh);
    // `-e CLAUDE_CODE_NO_FLICKER=1` BEFORE the chained set-options. tmux
    // applies env vars during new-session BEFORE forking the pane's shell,
    // so the first bash inherits NO_FLICKER. `set-environment` after the
    // fact only updates session-level env — bash and any process it has
    // already forked don't see it. The trailing `set-environment` is kept
    // as a belt-and-braces for the `-A` attach path, where -e is ignored
    // because the session already exists; future `Ctrl+B c` panes will
    // then still pick it up.
    return 'tmux new-session -A -s $s$newSessionEnv'
        r' \; set-option -g status off'
        r' \; set-option -g mouse on'
        r' \; set-option -g focus-events on'
        r' \; set-option -g history-limit 10000'
        '$setEnv'
        '${isMosh ? '' : kTmuxRgbOverride}';
  }

  /// Command to send on reconnect when session already exists.
  /// Re-applies CLAUDE_CODE_NO_FLICKER so even sessions created by an
  /// older app version pick it up on next attach (existing claude
  /// processes won't see the change until next launch — that's fine,
  /// the user just exits and re-runs `claude`).
  static String attach(String serverId, {bool isMosh = false}) {
    final s = sessionName(serverId);
    final setEnv = tmuxSetEnvironmentArgs(
      s,
      ClaudeRuntimeOptions.auto(isMosh: isMosh),
      isMosh: isMosh,
    );
    return 'tmux attach-session -t $s'
        r' \; set-option -g status off'
        r' \; set-option -g mouse on'
        r' \; set-option -g focus-events on'
        r' \; set-option -g history-limit 10000'
        '$setEnv'
        '${isMosh ? '' : kTmuxRgbOverride}';
  }

  /// tmux 会话要带的环境变量赋值（`KEY=VALUE`）。
  ///
  /// [kColorTermAssignment] 排在 Claude 那几个之前，是为了让它先落进
  /// `new-session -e`，语义上「终端能力」比「应用开关」更靠底层。mosh 上整个
  /// 跳过 —— 理由见 [kColorTermValue] 的 dartdoc。
  static List<String> envAssignments(
    ClaudeRuntimeOptions options, {
    required bool isMosh,
  }) => [
    if (!isMosh) kColorTermAssignment,
    ...options.toEnvAssignments(),
  ];

  static String tmuxSetEnvironmentArgs(
    String sessionName,
    ClaudeRuntimeOptions options, {
    bool isMosh = false,
  }) {
    return envAssignments(options, isMosh: isMosh).map((assignment) {
      final index = assignment.indexOf('=');
      final key = assignment.substring(0, index);
      final value = assignment.substring(index + 1);
      return ' \\; set-environment -t $sessionName $key $value';
    }).join();
  }

  /// Scrolls up [lines] lines in tmux copy-mode via exec channel.
  /// Enters copy-mode atomically if not already in it.
  /// [sessionKey] is used to derive the target session name so the command
  /// always acts on the correct session regardless of which session tmux
  /// considers "most recently active" (important when multiple tabs are open).
  /// Callers may fire-and-forget (do not need to await).
  static Future<void> scrollUp(
    SSHConnection connection,
    String sessionKey,
    int lines,
  ) async {
    final t = sessionName(sessionKey);
    try {
      await connection.client?.run(
        'tmux copy-mode -t $t \\; send-keys -t $t -X -N $lines scroll-up',
      );
    } catch (_) {}
  }

  /// Scrolls down [lines] lines in tmux copy-mode via exec channel.
  /// Callers may fire-and-forget (do not need to await).
  static Future<void> scrollDown(
    SSHConnection connection,
    String sessionKey,
    int lines,
  ) async {
    final t = sessionName(sessionKey);
    try {
      await connection.client?.run(
        'tmux send-keys -t $t -X -N $lines scroll-down',
      );
    } catch (_) {}
  }

  /// Exits tmux copy-mode via exec channel.
  /// Uses `send-keys -X cancel` which is a no-op when not in copy-mode,
  /// so this is safe to call unconditionally.
  static Future<void> exitCopyMode(
    SSHConnection connection,
    String sessionKey,
  ) async {
    final t = sessionName(sessionKey);
    try {
      await connection.client?.run('tmux send-keys -t $t -X cancel');
    } catch (_) {}
  }

  /// Exits copy-mode AND forces a full non-differential redraw for every
  /// tmux client attached to the session.
  ///
  /// Why not resize-pane (previous approach):
  ///   `resize-pane` causes tmux to redraw at the new size, but still uses
  ///   differential rendering: rows whose cells appear identical between the
  ///   post-cancel live view and the copy-mode view are silently skipped,
  ///   leaving column-0 stale characters in place.
  ///
  /// Why refresh-client works:
  ///   `tmux refresh-client` calls server_redraw_client() which sets
  ///   CLIENT_REDRAWWINDOW, causing tty_draw_client_screen() to reset the
  ///   tty draw state to empty and repaint every cell from scratch.  No cell
  ///   is ever "the same as last time" — guaranteed full repaint.
  ///   This works for BOTH SSH PTY clients AND mosh PTY clients without
  ///   requiring SIGWINCH delivery or the mosh UDP socket to be reachable.
  ///
  /// Implementation: two sequential exec-channel calls so the cancel is
  /// fully processed by tmux before the refresh fires.
  static Future<void> exitCopyModeAndRefresh(
    SSHConnection connection,
    String sessionKey,
  ) async {
    final t = sessionName(sessionKey);
    try {
      await connection.client?.run('tmux send-keys -t $t -X cancel');
      // refresh-client resets the tty draw state → full non-differential
      // repaint for every client (SSH PTY and mosh PTY) on this session.
      await connection.client?.run(
        "tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null"
        " | grep ' $t\$'"
        r" | awk '{print $1}'"
        r" | while IFS= read -r _c; do tmux refresh-client -t"
        r' "$_c" 2>/dev/null; done',
      );
    } catch (_) {}
  }

  /// Ensures mouse mode is enabled on the running tmux server.
  ///
  /// The `\; set-option -g mouse on` in [attachOrCreate]/[attach] is sent
  /// through the interactive shell, which may silently fail on non-bash
  /// shells (fish, csh, dash) that handle `\;` differently.  This method
  /// uses a dedicated exec channel — the same mechanism as [detect] — so it
  /// is shell-independent and does not produce any visible terminal output.
  ///
  /// Retries up to 3 times with short backoff because the call site fires
  /// shortly after the interactive shell receives the attach command — if
  /// tmux server isn't fully up yet, the first attempt sees
  /// "no server running on /tmp/tmux-NNN/default". Each retry is one SSH
  /// exec channel round-trip (~50-200 ms locally, ~RTT on cellular), so
  /// at most 3 attempts ≈ 600 ms even on slow links. The shorter callsite
  /// pre-delay + this retry combined remains conservative on stability.
  static Future<void> enableMouse(SSHConnection connection) async {
    final client = connection.client;
    if (client == null) return;
    for (var i = 0; i < 3; i++) {
      try {
        final out = await client.run('tmux set -g mouse on 2>&1');
        // Empty stdout means success on tmux. Non-empty stdout typically
        // contains "no server running ..." which means tmux isn't ready yet
        // — retry. Other errors (e.g. permission denied) also retry but
        // unlikely to recover; the final exception bubbles up.
        final text = utf8.decode(out, allowMalformed: true);
        if (text.trim().isEmpty) return;
      } catch (_) {
        // Network or channel error — fall through to retry.
      }
      if (i < 2) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  /// Force a full repaint for all tmux clients on [sessionKey] via the pipe.
  /// Fixes CJK wide-char residuals caused by tmux differential rendering
  /// skipping cells it considers "unchanged" that xterm-dart still shows stale.
  ///
  /// Fast path: when [pipe] has a cached client name (set after [TmuxControlPipe.init]
  /// queries it), emits a single `tmux refresh-client -t CLIENT` command — no
  /// pipeline, no forks beyond the one tmux process.
  ///
  /// Slow path (cache not yet warm): falls back to the list-clients | awk pipeline.
  /// Fire-and-forget — no exec-channel overhead.
  static void refreshClientFast(TmuxControlPipe pipe, String sessionKey) {
    final clientName = pipe.cachedClientName;
    if (clientName != null) {
      pipe.send('tmux refresh-client -t $clientName 2>/dev/null');
      return;
    }
    // Fallback: enumerate clients by session name (version-agnostic; -t SESSION
    // for list-clients is not supported by older tmux builds). Single awk
    // replaces the previous grep+awk pipeline, saving one subprocess per call.
    final t = sessionName(sessionKey);
    pipe.send(
      "tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null"
      " | awk '/ $t\$/{print \$1}'"
      r" | while IFS= read -r _c; do tmux refresh-client -t"
      r' "$_c" 2>/dev/null; done',
    );
  }

  /// Exit copy-mode and force a full repaint via the persistent pipe.
  /// Replaces [exitCopyModeAndRefresh] (exec-channel) with the pipe path,
  /// eliminating 2×2 RTTs of SSH channel setup overhead.
  /// sh processes the two commands sequentially: cancel fires before refresh.
  /// Fire-and-forget — callers do not need to await.
  ///
  /// Uses [pipe.cachedClientName] when available (single tmux call, no pipeline).
  static void exitCopyModeAndRefreshFast(
    TmuxControlPipe pipe,
    String sessionKey,
  ) {
    final t = sessionName(sessionKey);
    pipe.send('tmux send-keys -t $t -X cancel');
    final clientName = pipe.cachedClientName;
    if (clientName != null) {
      pipe.send('tmux refresh-client -t $clientName 2>/dev/null');
      return;
    }
    pipe.send(
      "tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null"
      " | awk '/ $t\$/{print \$1}'"
      r" | while IFS= read -r _c; do tmux refresh-client -t"
      r' "$_c" 2>/dev/null; done',
    );
  }

  /// Fast scroll: writes the command to a persistent pipe instead of opening
  /// a new exec channel. Call [TmuxControlPipe.init] after inTmux is set.
  static void scrollUpFast(TmuxControlPipe pipe, String sessionKey, int lines) {
    final t = sessionName(sessionKey);
    pipe.send(
      'tmux copy-mode -t $t \\; send-keys -t $t -X -N $lines scroll-up',
    );
  }

  static void scrollDownFast(
    TmuxControlPipe pipe,
    String sessionKey,
    int lines,
  ) {
    final t = sessionName(sessionKey);
    pipe.send('tmux send-keys -t $t -X -N $lines scroll-down');
  }
}

/// Persistent SSH shell channel for zero-overhead tmux command delivery.
///
/// Normal [TmuxHelper.scrollUp/Down] open a new SSH exec channel per call,
/// costing 2 RTTs. This class keeps a single `sh -s` channel open and writes
/// commands to its stdin — latency drops to one network RTT (command bytes
/// travel with the next TCP segment, no channel setup handshake).
///
/// Usage:
///   1. Call [init] after `inTmux = true` and after each SSH reconnect,
///      passing the tmux session key so the pipe can cache the PTY client name.
///   2. Call [send] to deliver a shell command line (no trailing newline needed).
///   3. Call [close] when the session tab is destroyed.
///
/// Client name caching:
///   After [init], the pipe queries `tmux list-clients` once to resolve the
///   PTY client name (e.g. `/dev/pts/1`) and caches it in [cachedClientName].
///   Callers (e.g. [TmuxHelper.refreshClientFast]) use the cached name to emit
///   a bare `tmux refresh-client -t CLIENT` instead of the list-clients pipeline,
///   saving 2–3 process forks per call on the remote server.
class TmuxControlPipe {
  SSHSession? _pipe;
  SSHClient? _client;
  bool _opening = false;
  final List<String> _buffer = [];
  static const _kBufferCap = 200;

  /// Cached PTY client name (e.g. `/dev/pts/1`).
  /// Queried once after [init] via a background exec channel.
  /// Null until the query completes or if the query fails.
  String? _cachedClientName;

  /// Session name used to look up the client name in `tmux list-clients`.
  String? _sessionName;

  /// Returns the cached tmux client name, or null if not yet resolved.
  String? get cachedClientName => _cachedClientName;

  /// Open (or reopen) the persistent shell channel with [client].
  /// Safe to call multiple times — re-opens only when the client changes or
  /// the previous pipe died.
  ///
  /// [sessionName] is the tmux session name (derive via [TmuxHelper.sessionName]).
  /// Providing it enables client-name caching so [refreshClientFast] can skip
  /// the list-clients pipeline.  Omit only when the session name is unavailable;
  /// the previous value is preserved across reconnects.
  void init(SSHClient client, {String? sessionName}) {
    if (identical(_client, client) && _pipe != null) return;
    _pipe?.close();
    _pipe = null;
    _client = client;
    _cachedClientName = null;
    // Preserve session name across reconnects (it never changes for a tab).
    if (sessionName != null) _sessionName = sessionName;
    _opening = false;
    _buffer.clear();
    _doOpen();
  }

  /// Send a shell command (no trailing newline required).
  /// Fire-and-forget; on pipe failure, buffers the command and reopens.
  void send(String cmd) {
    final pipe = _pipe;
    if (pipe != null) {
      try {
        pipe.stdin.add(utf8.encode('$cmd\n'));
        return;
      } catch (_) {
        _pipe = null;
      }
    }
    if (_buffer.length < _kBufferCap) _buffer.add(cmd);
    final client = _client;
    if (client != null && !_opening) _doOpen();
  }

  /// True when this pipe needs a fresh SSH client — the old one died or was
  /// never set.  [ReconnectService] checks this to decide whether to reconnect
  /// SSH for an active mosh tab so that tmux scroll commands keep working.
  bool get needsReinit => _client == null || (_client?.isClosed ?? true);

  Future<void> _doOpen() async {
    final client = _client;
    if (client == null || _opening) return;
    _opening = true;
    try {
      // sh -s: reads commands from stdin, no PTY, no echo, no interactive prompts.
      // stderr redirected to /dev/null so tmux error messages don't accumulate.
      final s = await client.execute('sh -s 2>/dev/null');
      // Drain output in background — we never parse responses.
      s.stdout.drain<void>().ignore();
      s.stderr.drain<void>().ignore();
      // Auto-reopen lazily on unexpected close (e.g. remote sh crash).
      s.done.then((_) {
        if (identical(_pipe, s)) _pipe = null;
      }).ignore();
      _pipe = s;
      for (final cmd in _buffer) {
        s.stdin.add(utf8.encode('$cmd\n'));
      }
      _buffer.clear();
      // Resolve client name in the background so subsequent refreshClientFast
      // calls can skip the list-clients pipeline entirely.
      final sn = _sessionName;
      if (sn != null) _queryClientName(sn, client).ignore();
    } catch (_) {
      // SSH client is dead — clear it so needsReinit returns true and callers
      // (ReconnectService) know to provide a fresh client on next periodic check.
      if (client.isClosed) _client = null;
    } finally {
      _opening = false;
    }
  }

  /// Queries `tmux list-clients` via a background exec channel to resolve our
  /// PTY client name (e.g. `/dev/pts/1`) for the given [sessionName].
  /// Stores the result in [_cachedClientName].  Silent on any error.
  Future<void> _queryClientName(String sessionName, SSHClient client) async {
    try {
      final result = await client.run(
        "tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null"
        " | awk '/ $sessionName\$/{print \$1; exit}'",
      );
      final name = utf8.decode(result).trim();
      if (name.isNotEmpty) _cachedClientName = name;
    } catch (_) {}
  }

  Future<void> close() async {
    _buffer.clear();
    _client = null;
    _sessionName = null;
    _cachedClientName = null;
    final p = _pipe;
    _pipe = null;
    p?.close();
  }
}
