// SPDX-License-Identifier: GPL-3.0-or-later
import '../ssh_connection.dart';

/// PTY backend persistence option.
/// shpool was removed (DB v22): its mobile-friendly advantages
/// (no copy-mode hijack, no scrollback takeover) are now covered by QUIC
/// transport's own ring buffer; its only remaining value over tmux was
/// process persistence, which tmux does equally well with far wider
/// distro coverage. Existing servers with multiplexer_type='shpool' are
/// migrated to 'none' via DB v22.
enum MultiplexerType { none, tmux }

class MultiplexerCapabilities {
  final bool copyModeScroll;
  final bool mousePassthrough;
  final bool persistSession;
  const MultiplexerCapabilities({
    required this.copyModeScroll,
    required this.mousePassthrough,
    required this.persistSession,
  });
}

abstract class MultiplexerBackend {
  MultiplexerCapabilities get capabilities;

  bool get isActive;
  bool get needsControlPipeReinit;

  static String sessionName(MultiplexerType type, String serverId) {
    final prefix = switch (type) {
      MultiplexerType.none => '',
      MultiplexerType.tmux => 't',
    };
    if (prefix.isEmpty) return '';
    final suffix = serverId.length >= 8 ? serverId.substring(0, 8) : serverId;
    return '$prefix-$suffix';
  }

  Future<bool> detect(SSHConnection? connection);
  Future<bool> onNotFound(SSHConnection? connection, void Function(String)? notify);
  String attachOrCreateCommand(String sessionKey, {bool isMosh = false});
  Future<void> initControlPipe(SSHConnection connection, String sessionKey);
  Future<void> reinitControlPipe(SSHConnection connection, String sessionKey);
  void scrollUp(int lines);
  void scrollDown(int lines);
  void exitScrollMode();
  Future<void> enableMouse(SSHConnection connection);
  void refreshClient();
  Future<String?> getSessionCwd(SSHConnection connection, String sessionKey);

  /// 抓取 tmux 窗格历史（iTerm2 同款策略）。
  /// 返回带 ANSI 颜色的纯文本行，可直接写入 xterm 作为 scrollback。
  /// NoneBackend 返回空字符串；TmuxBackend 通过 exec channel 执行
  /// `tmux capture-pane -S -[lines] -J -e -p`。
  Future<String> capturePane(
      SSHConnection connection, String sessionKey, {int lines = 3000});

  void dispose();
}
