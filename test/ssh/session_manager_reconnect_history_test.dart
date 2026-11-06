import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/ssh_connection.dart';
import 'package:flyterm/ssh/session_manager.dart';

Future<SessionTab> _makeTab() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return SessionTab(
    server: Server(
        id: 'test', name: 'test', host: '127.0.0.1', port: 22, username: 'u',
        authType: 'password'),
    connection: SSHConnection(),
    terminal: Terminal(),
    sessionKey: 'test',
    aiEngine: AIEngine(prefs, serverId: 'test'),
  );
}

void main() {
  group('SessionTab.appendReconnect', () {
    test('records event into reconnectHistory', () async {
      final tab = await _makeTab();
      tab.appendReconnect(ReconnectEvent(
          DateTime.now(), ReconnectCause.watchdogTimeout,
          ReconnectKind.soft, true));
      expect(tab.reconnectHistory.length, 1);
      expect(tab.reconnectHistory.first.cause, ReconnectCause.watchdogTimeout);
    });

    test('trims entries older than 5 minutes on every append', () async {
      final tab = await _makeTab();
      final old = DateTime.now().subtract(const Duration(minutes: 6));
      final recent = DateTime.now().subtract(const Duration(minutes: 2));
      tab.reconnectHistory.add(ReconnectEvent(
          old, ReconnectCause.sendError, ReconnectKind.hard, false));
      tab.reconnectHistory.add(ReconnectEvent(
          recent, ReconnectCause.sendError, ReconnectKind.hard, false));
      tab.appendReconnect(ReconnectEvent(
          DateTime.now(), ReconnectCause.fullReconnect,
          ReconnectKind.soft, true));
      expect(tab.reconnectHistory.length, 2);
      expect(
          tab.reconnectHistory.any((e) =>
              e.at.isBefore(DateTime.now().subtract(const Duration(minutes: 5)))),
          isFalse);
    });
  });
}
