// SPDX-License-Identifier: GPL-3.0-or-later
import 'multiplexer_backend.dart';
import '../ssh_connection.dart';

class NoneBackend extends MultiplexerBackend {
  @override
  MultiplexerCapabilities get capabilities => const MultiplexerCapabilities(
        copyModeScroll: false,
        mousePassthrough: false,
        persistSession: false,
      );

  @override
  bool get isActive => false;

  @override
  bool get needsControlPipeReinit => false;

  @override
  Future<bool> detect(SSHConnection? connection) async => true;

  @override
  Future<bool> onNotFound(SSHConnection? connection, void Function(String)? notify) async => true;

  @override
  String attachOrCreateCommand(String sessionKey, {bool isMosh = false}) => '';

  @override
  Future<void> initControlPipe(SSHConnection connection, String sessionKey) async {}

  @override
  Future<void> reinitControlPipe(SSHConnection connection, String sessionKey) async {}

  @override
  void scrollUp(int lines) {}

  @override
  void scrollDown(int lines) {}

  @override
  void exitScrollMode() {}

  @override
  Future<void> enableMouse(SSHConnection connection) async {}

  @override
  void refreshClient() {}

  @override
  Future<String?> getSessionCwd(SSHConnection connection, String sessionKey) async => null;

  @override
  Future<String> capturePane(SSHConnection connection, String sessionKey,
      {int lines = 3000}) async => '';

  @override
  void dispose() {}
}
