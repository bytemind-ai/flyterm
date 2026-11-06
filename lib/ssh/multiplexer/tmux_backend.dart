// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import '../../util/dlog.dart';
import 'multiplexer_backend.dart';
import '../ssh_connection.dart';
import '../tmux_helper.dart';
import '../claude_runtime_options.dart';
import '../terminal_env.dart';

/// TmuxBackend wraps [TmuxHelper] and [TmuxControlPipe] to provide
/// tmux-based multiplexing.
///
/// Key design note: [MultiplexerBackend.sessionName] produces keys like
/// `t-abcd1234` (new format). These keys are used DIRECTLY as tmux session
/// names — we deliberately do NOT call [TmuxHelper.sessionName] which would
/// prepend `flyterm-` and produce a double-prefixed name like `flyterm-t-abcd1234`.
/// All tmux commands in this class use [_sessionKey] verbatim.
class TmuxBackend extends MultiplexerBackend {
  final TmuxControlPipe _pipe = TmuxControlPipe();
  bool _isActive = false;
  String? _sessionKey;

  @override
  MultiplexerCapabilities get capabilities => const MultiplexerCapabilities(
        copyModeScroll: true,
        mousePassthrough: true,
        persistSession: true,
      );

  @override
  bool get isActive => _isActive;

  @override
  bool get needsControlPipeReinit => _pipe.needsReinit;

  /// Provides access to the underlying control pipe for callers that need
  /// to wire up scroll commands directly.
  TmuxControlPipe get controlPipe => _pipe;

  @override
  Future<bool> detect(SSHConnection? connection) async {
    if (connection == null) return false;
    final found = await TmuxHelper.detect(connection);
    if (found) _isActive = true;
    return found;
  }

  @override
  Future<bool> onNotFound(SSHConnection? connection, void Function(String)? notify) async {
    _isActive = false;
    return false;
  }

  /// Builds the `tmux new-session -A ...` command string.
  ///
  /// [sessionKey] is already the formatted name (e.g. `t-abcd1234`) from
  /// [sessionKey] is the server/tab ID used to derive the tmux session name
  /// via [TmuxHelper.sessionName] (`flyterm-{key[:12]}`), keeping backward
  /// compat with sessions created by older builds.
  @override
  String attachOrCreateCommand(String sessionKey, {bool isMosh = false}) {
    // Derive the actual tmux session name using TmuxHelper's stable format
    // (flyterm-{key[:12]}) so that sessions created by older builds are
    // reattached instead of creating a parallel fresh session.
    final tmuxName = TmuxHelper.sessionName(sessionKey);
    _sessionKey = tmuxName;
    final claudeEnv = ClaudeRuntimeOptions.auto(isMosh: isMosh);
    // -e flags: injected BEFORE the chained set-options so first pane shell
    // inherits the env on create. set-environment after the fact handles
    // the -A attach path where -e is ignored.
    final newSessionEnv = TmuxHelper.envAssignments(claudeEnv, isMosh: isMosh)
        .map((e) => ' -e $e')
        .join();
    final setEnv =
        TmuxHelper.tmuxSetEnvironmentArgs(tmuxName, claudeEnv, isMosh: isMosh);
    return 'tmux new-session -A -s $tmuxName$newSessionEnv'
        r' \; set-option -g status off'
        r' \; set-option -g mouse on'
        r' \; set-option -g focus-events on'
        r' \; set-option -g history-limit 10000'
        '$setEnv'
        '${isMosh ? '' : kTmuxRgbOverride}';
  }

  /// Initialises the persistent control pipe for this session.
  /// [sessionKey] is the server/tab ID; the actual tmux session name is
  /// derived via [TmuxHelper.sessionName] inside [attachOrCreateCommand].
  @override
  Future<void> initControlPipe(SSHConnection connection, String sessionKey) async {
    final tmuxName = TmuxHelper.sessionName(sessionKey);
    _sessionKey = tmuxName;
    final client = connection.client;
    if (client == null) return;
    _pipe.init(client, sessionName: tmuxName);
  }

  @override
  Future<void> reinitControlPipe(SSHConnection connection, String sessionKey) async {
    await initControlPipe(connection, sessionKey);
  }

  @override
  void scrollUp(int lines) {
    final key = _sessionKey;
    if (key == null) return;
    _pipe.send(
      'tmux copy-mode -t $key \\; send-keys -t $key -X -N $lines scroll-up',
    );
  }

  @override
  void scrollDown(int lines) {
    final key = _sessionKey;
    if (key == null) return;
    _pipe.send('tmux send-keys -t $key -X -N $lines scroll-down');
  }

  @override
  void exitScrollMode() {
    final key = _sessionKey;
    if (key == null) return;
    _pipe.send('tmux send-keys -t $key -X cancel');
    _sendRefreshClientCmd(key);
  }

  @override
  Future<void> enableMouse(SSHConnection connection) =>
      TmuxHelper.enableMouse(connection);

  @override
  void refreshClient() {
    final key = _sessionKey;
    if (key == null) return;
    _sendRefreshClientCmd(key);
  }

  @override
  Future<String?> getSessionCwd(
    SSHConnection connection,
    String sessionKey,
  ) async {
    final client = connection.client;
    if (client == null) return null;
    try {
      final bytes = await client
          .run("tmux display-message -t $sessionKey -p '#{pane_current_path}'")
          .timeout(const Duration(seconds: 3));
      final path = utf8.decode(bytes, allowMalformed: true).trim();
      if (path.startsWith('/')) return path;
    } catch (e) {
      dlog('TmuxBackend', 'getSessionCwd failed: $e');
    }
    return null;
  }

  @override
  Future<String> capturePane(
    SSHConnection connection,
    String sessionKey, {
    int lines = 3000,
  }) async {
    final client = connection.client;
    if (client == null) return '';
    try {
      // -S -N : 从当前可视区向上 N 行开始
      // -J    : 合并折行（保持内容完整）
      // -e    : 保留 ANSI 颜色转义序列
      // -p    : 输出到 stdout
      final bytes = await client
          .run('tmux capture-pane -t $sessionKey -S -$lines -J -e -p 2>/dev/null')
          .timeout(const Duration(seconds: 5));
      return utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      dlog('TmuxBackend', 'capturePane failed: $e');
      return '';
    }
  }

  @override
  void dispose() => _pipe.close();

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Sends `tmux refresh-client` for all clients on [sessionKey].
  /// Uses the cached client name fast-path when available.
  void _sendRefreshClientCmd(String sessionKey) {
    final clientName = _pipe.cachedClientName;
    if (clientName != null) {
      _pipe.send('tmux refresh-client -t $clientName 2>/dev/null');
      return;
    }
    _pipe.send(
      "tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null"
      " | awk '/ $sessionKey\$/{print \$1}'"
      r" | while IFS= read -r _c; do tmux refresh-client -t"
      r' "$_c" 2>/dev/null; done',
    );
  }
}