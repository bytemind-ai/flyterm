// 这个文件曾经复刻 `_reconnect()` 冷启动分支里的一段三步时序（scenario 7/8）：
//   (1) 对每个"非首次连接"的 tab 无条件写 5 条复位序列，
//   (2) 紧接着 `_installAqtTransport`/`_applyResumeReplay` 自己的
//       `\x1b[3J...` 清屏，
//   (3) 再等 prelude 自己的 `\x1b[?1049h` 重进 alt 屏，
// 并验证这三次连续切 buffer-mode 时 xterm 的可见 buffer 会不会跟
// `preludeReplayRemaining` / `preludeCaptureRemaining` 等计数器失步。
//
// 重构后这套时序在结构上不存在了，不是签名变了要跟着改参数：
//   - 复位不再无条件跑。`_installAqtTransport` 只在 `!next.wasResumed`
//     （即 HELLO，开新会话）时才调用 `_resetTerminalForNewSession`；RESUME
//     续传完全不经过它，理由见 reconnect_service.dart
//     `_resetTerminalForNewSession` 文档注释——续传时远端 PTY 还在原状态里
//     跑，复位会把 TUI 那一屏丢掉且没有东西能重画。
//   - RESUME 拿到的历史不再通过 `next.output` 流、被
//     `preludeReplayRemaining` / `preludeCaptureRemaining` 等计数器逐字节
//     过滤——它是服务端通过 `takeResumeDisposition()`（同步 FFI take）整段
//     拿到的 `AqtRestored.screen`，由 `_applyResumeDisposition` 一次
//     `terminal.write()` 写完，跟 `tab.startStreaming()` 监听的那条流完全
//     不相交（见 lib/ssh/aqt/aqt_transport.dart、
//     reconnect_service.dart `_installAqtTransport` / `_applyResumeDisposition`）。
// 也就是说 scenario 7/8 想验证的"两条时序赛跑会不会失步"根本没有赛道了：
// 不存在"prelude 字节流经过 startStreaming() 监听器"这一步。
// `test/ssh/aqt_transport_install_test.dart` 已经用新模型验证了同一批意图
// （Restored 单次 write、幂等、只有 NewSession 才复位终端）。
//
// 下面只保留一段仍然成立、且原文件的两个 scenario 没有单独覆盖到的东西：
// `_resetTerminalForNewSession` 复位序列本身，用一个"断线前正停在某个 TUI
// 里"的真实 SessionTab 起点来验证——这是原 scenario 7/8 的 Step 2，剥离掉
// 已经不存在的 Step 3/4 之后单独站得住。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/session_manager.dart';

Server _makeServer() => Server(
      id: const Uuid().v4(),
      name: 'Test',
      host: 'host',
      port: 22,
      username: 'user',
      authType: 'password',
    );

Future<SessionManager> _newManager() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return SessionManager(prefs: prefs);
}

/// Byte-for-byte copy of `ReconnectService._resetTerminalForNewSession`
/// (reconnect_service.dart ~1962-1973，写这份文件时的版本)。之所以复刻而不
/// 是直接调：真正的方法是私有的。局限：若那边改了复位序列，这里要跟着改。
void replicateResetTerminalForNewSession(SessionTab tab) {
  try {
    tab.terminal.write('\x1b[?1049l'); // exit alt-buffer
    tab.terminal.write('\x1b[r'); // reset scroll margins (DECSTBM)
    tab.terminal.write('\x1b[m'); // reset SGR attributes
    tab.terminal.write('\x1b[!p'); // DECSTR soft-reset (stub in xterm 4.x)
    tab.terminal.write('\x1b[?25h'); // show cursor
  } catch (_) {}
}

/// Byte-for-byte copy of `TerminalScreen._readTerminalText`.
String readTerminalText(Terminal terminal, {int maxLines = 200}) {
  final buffer = terminal.buffer;
  final totalLines = buffer.lines.length;
  if (totalLines == 0) return '';
  final startLine = (totalLines - maxLines).clamp(0, totalLines);
  final range = BufferRangeLine(
    CellOffset(0, startLine),
    CellOffset(
      terminal.viewWidth > 0 ? terminal.viewWidth - 1 : 79,
      totalLines - 1,
    ),
  );
  return buffer.getText(range).trimRight();
}

void main() {
  group('_resetTerminalForNewSession replica (HELLO 复位路径)', () {
    test(
        '从"断线前停在某个 TUI 里"的真实起点复位：退出 alt、光标恢复可见、'
        '不清屏', () async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      tab.isFirstConnection = false;

      // 构造一个逼真的"断线瞬间"起点：primary 有历史，随后进了某个 TUI
      // （htop/vim 之类）——进 alt 屏、收窄滚动区、隐藏光标、改了前景色。
      tab.terminal.write('user@host:~\$ htop\r\n');
      tab.terminal.write('\x1b[?1049h'); // 进 alt 屏
      tab.terminal.write('\x1b[5;20r'); // 收窄滚动区
      tab.terminal.write('\x1b[?25l'); // 隐藏光标
      tab.terminal.write('\x1b[31mred-tui-frame'); // 改前景色

      expect(tab.terminal.isUsingAltBuffer, isTrue);
      expect(tab.terminal.cursorVisibleMode, isFalse);

      replicateResetTerminalForNewSession(tab);

      expect(tab.terminal.isUsingAltBuffer, isFalse,
          reason: '唯一该复位终端的路径——HELLO 开了全新会话，旧会话残留的 '
              'alt buffer 属于上一个进程');
      expect(tab.terminal.cursorVisibleMode, isTrue);

      // 复位只退 alt / 复位光标·边距·SGR，不清屏：primary 的历史仍在，
      // 新 shell 的第一帧会接着往下写，就像真实终端重连时看到的那样。
      expect(readTerminalText(tab.terminal).contains('htop'), isTrue,
          reason: '复位不清屏——清屏是 clearAndRewrite 分支的事，这里只退 alt');

      mgr.dispose();
    });

    test('不在 alt 屏时复位也不报错，且把隐藏的光标恢复可见', () async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      tab.terminal.write('\x1b[?25l'); // 隐藏光标，但没进 alt 屏

      expect(() => replicateResetTerminalForNewSession(tab), returnsNormally);
      expect(tab.terminal.isUsingAltBuffer, isFalse);
      expect(tab.terminal.cursorVisibleMode, isTrue);

      mgr.dispose();
    });
  });
}
