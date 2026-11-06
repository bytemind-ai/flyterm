import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:uuid/uuid.dart';

Server _makeServer() => Server(
      id: const Uuid().v4(),
      name: 'Test',
      host: 'host',
      port: 22,
      username: 'user',
      authType: 'password',
    );

void main() {
  group('TabViewMode', () {
    test('enum has terminal and sftp values', () {
      expect(TabViewMode.values, hasLength(2));
      expect(TabViewMode.values, contains(TabViewMode.terminal));
      expect(TabViewMode.values, contains(TabViewMode.sftp));
    });
  });

  group('SessionTab.viewMode', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('defaults to terminal mode', () {
      final mgr = SessionManager(prefs: prefs);
      final tab = mgr.addTab(_makeServer());
      expect(tab.viewMode, TabViewMode.terminal);
    });

    test('sftpCwd defaults to null', () {
      final mgr = SessionManager(prefs: prefs);
      final tab = mgr.addTab(_makeServer());
      expect(tab.sftpCwd, isNull);
    });
  });

  group('SessionManager.toggleViewMode', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('flips terminal → sftp and back', () {
      final mgr = SessionManager(prefs: prefs);
      final tab = mgr.addTab(_makeServer());
      expect(tab.viewMode, TabViewMode.terminal);
      mgr.toggleViewMode(tab);
      expect(tab.viewMode, TabViewMode.sftp);
      mgr.toggleViewMode(tab);
      expect(tab.viewMode, TabViewMode.terminal);
    });

    test('fires notifyListeners on each toggle', () {
      final mgr = SessionManager(prefs: prefs);
      final tab = mgr.addTab(_makeServer());
      int notifyCount = 0;
      mgr.addListener(() => notifyCount++);
      mgr.toggleViewMode(tab);
      mgr.toggleViewMode(tab);
      expect(notifyCount, 2);
    });

    test('setViewMode is no-op when already in that mode', () {
      final mgr = SessionManager(prefs: prefs);
      final tab = mgr.addTab(_makeServer());
      int notifyCount = 0;
      mgr.addListener(() => notifyCount++);
      mgr.setViewMode(tab, TabViewMode.terminal); // already terminal
      expect(notifyCount, 0);
      mgr.setViewMode(tab, TabViewMode.sftp); // changes → notifies
      expect(notifyCount, 1);
      expect(tab.viewMode, TabViewMode.sftp);
    });
  });
}
