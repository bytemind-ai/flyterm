// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/session_manager.dart';

/// SessionTab.resizeOutputTick：远端 resize 之后，每次把远端输出真正写进
/// 终端（flush）就 +1。TerminalWidget 的键盘冻结层靠它判断「tmux 的重绘
/// 已经落屏」，好在下一帧撤掉冻结快照。
void main() {
  Server makeServer() => const Server(
        id: 's1',
        name: 'test',
        host: '127.0.0.1',
        port: 22,
        username: 'u',
        authType: 'password',
      );

  testWidgets('没有 resize 时输出不触发', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mgr = SessionManager(prefs: await SharedPreferences.getInstance());
    final tab = mgr.addTab(makeServer());
    tab.testWriteAndFlush('hello');
    await tester.pump();
    expect(tab.testPendingOutputEmpty, isTrue);
    expect(tab.resizeOutputTick.value, 0);
  });

  testWidgets('onTransportResized 之后的落屏触发，且在 write 之后', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mgr = SessionManager(prefs: await SharedPreferences.getInstance());
    final tab = mgr.addTab(makeServer());
    var sawText = false;
    tab.resizeOutputTick.addListener(() {
      sawText = tab.terminal.buffer.lines[0].toString().contains('redraw');
    });
    tab.onTransportResized();
    tab.testWriteAndFlush('redraw');
    expect(tab.resizeOutputTick.value, 0, reason: '还没落屏');
    await tester.pump();
    expect(tab.resizeOutputTick.value, 1);
    expect(sawText, isTrue, reason: '通知时输出必须已写进终端');
  });
}
