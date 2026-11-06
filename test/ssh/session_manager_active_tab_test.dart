import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ssh/ssh_connection.dart';

SessionTab _tab(String id, String serverId, SharedPreferences prefs,
        {String? cwd}) =>
    SessionTab(
      id: id,
      server: Server(
        id: serverId,
        name: serverId,
        host: 'h',
        port: 22,
        username: 'u',
        authType: 'password',
      ),
      connection: SSHConnection(),
      terminal: Terminal(),
      sessionKey: id,
      aiEngine: AIEngine(prefs, serverId: serverId),
    )..cwd = cwd;

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('resolveActiveTabForServer', () {
    test('活动 tab 就属于这台服务器时，返回它', () {
      final a = _tab('t1', 'srv-A', prefs, cwd: '/var/log');
      final b = _tab('t2', 'srv-A', prefs, cwd: '/etc/nginx');

      expect(
        resolveActiveTabForServer([a, b], b, 'srv-A')?.cwd,
        equals('/etc/nginx'),
      );
    });

    // 这条是这个函数存在的理由：agent 会话绑服务器，而用户此刻在看哪个
    // tab 决定了「当前目录」应该是什么。同一台机器上开两个 tab 分别待在
    // 不同目录，是排查时最常见的用法。
    test('同一服务器多个 tab 时，跟随活动的那个而不是第一个', () {
      final first = _tab('t1', 'srv-A', prefs, cwd: '/var/log');
      final second = _tab('t2', 'srv-A', prefs, cwd: '/etc/nginx');

      expect(
        resolveActiveTabForServer([first, second], second, 'srv-A')?.id,
        equals('t2'),
      );
      expect(
        resolveActiveTabForServer([first, second], first, 'srv-A')?.id,
        equals('t1'),
      );
    });

    // 面板可以在切到别的服务器之后再打开（会话绑服务器，不绑 tab）。此时
    // 没有「属于这台机器的活动 tab」，退回它最早的那个——总比拿一个属于
    // 别的机器的目录去 cd 强。
    test('活动 tab 属于别的服务器时，退回该服务器最早的 tab', () {
      final a = _tab('t1', 'srv-A', prefs, cwd: '/var/log');
      final other = _tab('t2', 'srv-B', prefs, cwd: '/home/u');

      final got = resolveActiveTabForServer([a, other], other, 'srv-A');
      expect(got?.id, equals('t1'));
      expect(got?.cwd, equals('/var/log'));
    });

    test('这台服务器一个 tab 都没有时返回 null', () {
      final other = _tab('t2', 'srv-B', prefs);
      expect(resolveActiveTabForServer([other], other, 'srv-A'), isNull);
    });

    test('tab 列表为空时返回 null，不抛', () {
      expect(resolveActiveTabForServer([], null, 'srv-A'), isNull);
    });

    test('activeTab 为 null 时仍能按 serverId 找到 tab', () {
      final a = _tab('t1', 'srv-A', prefs, cwd: '/opt');
      expect(resolveActiveTabForServer([a], null, 'srv-A')?.cwd, equals('/opt'));
    });

    // 关掉正在用的那个 tab 之后，解析必须落到同一台机器剩下的 tab 上，
    // 而不是继续指向那个已经不在列表里的对象。
    test('活动 tab 已从列表中移除时，落到该服务器剩下的 tab', () {
      final closed = _tab('t1', 'srv-A', prefs, cwd: '/var/log');
      final alive = _tab('t2', 'srv-A', prefs, cwd: '/etc');

      // closed 已经不在列表里，但调用方可能还持有它的引用
      expect(
        resolveActiveTabForServer([alive], closed, 'srv-A')?.id,
        equals('t2'),
      );
    });
  });
}
