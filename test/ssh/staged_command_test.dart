import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ssh/session_manager.dart';

void main() {
  late SessionManager mgr;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mgr = SessionManager(prefs: await SharedPreferences.getInstance());
  });

  test('take 之后槽就空了（一次性）', () {
    mgr.stageCommand('srv-1', 'ls -la');

    expect(mgr.takeStagedCommand('srv-1'), 'ls -la');
    expect(mgr.takeStagedCommand('srv-1'), isNull);
  });

  test('按 serverId 分槽，互不干扰', () {
    mgr.stageCommand('srv-1', 'uptime');
    mgr.stageCommand('srv-2', 'df -h');

    expect(mgr.takeStagedCommand('srv-2'), 'df -h');
    expect(mgr.takeStagedCommand('srv-1'), 'uptime');
  });

  test('同一台机器重复 stage，后一条覆盖前一条', () {
    mgr.stageCommand('srv-1', 'first');
    mgr.stageCommand('srv-1', 'second');

    expect(mgr.takeStagedCommand('srv-1'), 'second');
    expect(mgr.takeStagedCommand('srv-1'), isNull);
  });

  test('没 stage 过的机器 take 到 null', () {
    expect(mgr.takeStagedCommand('nobody'), isNull);
  });
}
