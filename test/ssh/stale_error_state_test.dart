// 「连上了但圆点一直红」。
//
// tab 上那个红点只有一个来源（terminal_screen 的 `isDisconnected`）：
//
//     isDisconnected: tab.connectionError != null
//
// 而在这个修复之前，`connectionError` 的所有清除点都在**开始重连时**
// （`_reconnect` 入口、重试倒计时中），目的都是让 UI 显示 spinner 而不是错误
// 屏 —— 没有一处是「恢复成功时」。QUIC 的 proactive resume 完全绕过
// `_reconnect()`，于是真机上出现了这个状态：
//
//     qstate:connected  dead:false  pathDied:false  RESUMED✓
//     [e526] OK 291ms   INSTALL src=proactiveResume wasResumed=true
//     path rtt:159  loss:8.8%  mphase:live  age:17s
//     ...而圆点是红的，err:TimeoutException 还挂着
//
// Mosh v2 早就有这条清理（`onAuthenticatedPacket` 里），它的注释写的是同一个
// 症状：「Without this the tab dot can stay red-blinking for tens of seconds
// while real bytes are landing」。QUIC 缺的就是那个对等物。
//
// ## 为什么这个 bug 能活到真机上
//
// 整个 test/ 目录里没有任何地方构造过 `ReconnectService`，也没有任何地方碰过
// `connectionError`。这条不变量此前零覆盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/reconnect_service.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ssh/ssh_connection.dart';

Future<SessionTab> _makeTab() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return SessionTab(
    server: const Server(
      id: 'srv-red-dot',
      name: 'dk',
      host: '127.0.0.1',
      port: 22,
      username: 'u',
      authType: 'password',
    ),
    connection: SSHConnection(),
    terminal: Terminal(),
    sessionKey: 'k',
    aiEngine: AIEngine(prefs, serverId: 'srv-red-dot'),
  );
}

/// 红点的判据，与 terminal_screen 的 `isDisconnected` 同源。
bool _dotIsRed(SessionTab tab) => tab.connectionError != null;

void main() {
  test('装上 transport 之后错误态被清掉 —— 圆点不该继续红', () async {
    final tab = await _makeTab();
    // 一次连接超时留下的（reconnect_service 里 `tab.connectionError =
    // e.toString()` 那处）。
    tab.connectionError = 'TimeoutException: SSH connection timed out';
    expect(_dotIsRed(tab), isTrue, reason: '前提：此刻确实是红的');

    final cleared = ReconnectService.clearStaleErrorState(tab);

    expect(cleared, isTrue, reason: '返回 true 才会触发 notifyTabChanged');
    expect(_dotIsRed(tab), isFalse);
  });

  test('isReconnecting 一并清掉', () async {
    final tab = await _makeTab();
    tab.isReconnecting = true;

    expect(ReconnectService.clearStaleErrorState(tab), isTrue);
    expect(tab.isReconnecting, isFalse);
  });

  test('两个都残留时一次清完', () async {
    final tab = await _makeTab();
    tab.connectionError = 'TimeoutException: SSH connection timed out';
    tab.isReconnecting = true;

    expect(ReconnectService.clearStaleErrorState(tab), isTrue);
    expect(tab.connectionError, isNull);
    expect(tab.isReconnecting, isFalse);
  });

  test('本来就干净时返回 false —— 不白刷一次 UI', () async {
    // 装配是每次恢复都会走的路径，而绝大多数恢复并没有留下错误态。
    // 无条件 notify 等于每次恢复都多一次全局重建。
    final tab = await _makeTab();

    expect(ReconnectService.clearStaleErrorState(tab), isFalse);
    expect(tab.connectionError, isNull);
    expect(tab.isReconnecting, isFalse);
  });

  test('幂等 —— 连着调两次，第二次报告「没东西可清」', () async {
    final tab = await _makeTab();
    tab.connectionError = 'boom';

    expect(ReconnectService.clearStaleErrorState(tab), isTrue);
    expect(ReconnectService.clearStaleErrorState(tab), isFalse);
  });

  test('不碰其他状态 —— 它只负责错误态', () async {
    // 这个函数在 _installAqtTransport 末尾被调用，那时 transport 与终端都
    // 已经装好了。它越界去动别的字段会很难查。
    final tab = await _makeTab();
    tab.connectionError = 'boom';
    tab.customName = '我的机器';
    tab.isMosh = true;
    tab.preludeReplayRemaining = 4096;

    ReconnectService.clearStaleErrorState(tab);

    expect(tab.customName, '我的机器');
    expect(tab.isMosh, isTrue);
    expect(tab.preludeReplayRemaining, 4096);
  });
}
