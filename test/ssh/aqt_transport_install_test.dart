// 这个文件测 `ReconnectService.applyDispositionToTerminal`：服务端"声明"了
// 什么处置，客户端就该"做"什么终端动作，不夹带任何推断。
//
// 它有两段历史，都值得留着当教训：
//
// 1. 最早测的是 `seedServerRingOff` / `resumeReplayMode` /
//    `serverRebuiltReplay` —— 客户端读 `server_out_off - replay_bytes` 做算术，
//    反推「服务端是续传还是重建」，再在 none/appendDelta/swallowAlt/
//    clearAndRewrite 四种模式间分派。那套结构整个被废弃：服务端改用
//    `Disposition` 枚举显式声明处置。
//
// 2. 之后这里手工**复刻**了被测的分派体。复刻里正确地写了 `Restored.screen`，
//    而真实代码里那次 write 根本不存在 —— 测试一路全绿，直到真机上表现为
//    「QUIC 连上了但屏幕全空」，被误判成连不上。复刻测试对「被测代码少了一行」
//    是免疫的。所以现在直接调真实实现，不留第二份。
//
// ## 恢复内容为什么不在这里测
//
// 它已经不经过客户端的手：服务端把「历史 + 当前屏」作为**新 PTY 流的头几个
// 字节**送出，与 live 输出同属一条有序流，由 `startStreaming` 的监听器照常
// 写进终端。`Disposition::Restored` 里不再有 `screen` 字段。
//
// 因此恢复内容的自足性与幂等性改由服务端侧端到端覆盖，见
// `rust/flyterm-server/tests/resume_idempotence_e2e.rs`（连续两次 RESUME、
// 六路并发、乱序应用 stale 三组，都从真实 PTY 流读字节验证）。本文件只负责
// 客户端这一半：三种处置各自触发什么终端动作。
import 'package:flyterm/ssh/aqt/aqt_ffi.dart';
import 'package:flyterm/ssh/reconnect_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('AqtRestored', () {
    test('不动终端 —— 恢复内容走 PTY 流，不经过这条路', () {
      final t = Terminal(maxLines: 200)..resize(80, 24);
      t.write('before');

      ReconnectService.applyDispositionToTerminal(
        t,
        const AqtRestored(serverInSeenOff: 0),
      );

      expect(t.buffer.lines[0].getText(0, 6), 'before',
          reason: '既不清屏也不写入');
    });

    test('反复应用同一个 Restored 不产生任何副作用', () {
      final t = Terminal(maxLines: 200)..resize(80, 24);
      t.write('\x1b[?1049h'); // 断线前停在 alt 屏
      t.write('tui frame');

      const d = AqtRestored(serverInSeenOff: 9);
      for (var i = 0; i < 3; i++) {
        ReconnectService.applyDispositionToTerminal(t, d);
      }

      expect(t.isUsingAltBuffer, isTrue, reason: 'alt 状态原样保留');
      expect(t.buffer.lines[0].getText(0, 9), 'tui frame');
    });
  });

  group('AqtNewSession', () {
    test('复位终端：退出 alt 屏', () {
      final t = Terminal(maxLines: 200)..resize(80, 24);
      t.write('\x1b[?1049h'); // 进 alt
      t.write('\x1b[?25l'); // TUI 藏了光标
      expect(t.isUsingAltBuffer, isTrue);

      ReconnectService.applyDispositionToTerminal(t, const AqtNewSession());

      expect(t.isUsingAltBuffer, isFalse, reason: '新会话必须退出 alt');
      // 光标可见性由 \x1b[?25h 恢复 —— 不恢复的话滚动会被路由去 SGR，
      // 直到新会话第一帧到达为止。
    });
  });

  group('AqtTabGone', () {
    test('不复位终端 —— 用户还在看那些输出', () {
      final t = Terminal(maxLines: 200)..resize(80, 24);
      t.write('\x1b[?1049h');
      t.write('last output');

      ReconnectService.applyDispositionToTerminal(t, const AqtTabGone(null));

      expect(t.isUsingAltBuffer, isTrue,
          reason: '进程退出不该清掉用户在看的内容');
      expect(t.buffer.lines[0].getText(0, 11), 'last output');
    });

    test('退出码原样透出，供上层展示', () {
      const d = AqtTabGone(137);
      expect(d.exitStatus, 137);
    });
  });

  group('null 处置', () {
    test('服务端没给处置（旧 .so / 拿不到 handle）时什么都不做', () {
      final t = Terminal(maxLines: 200)..resize(80, 24);
      t.write('\x1b[?1049h');
      t.write('content');

      ReconnectService.applyDispositionToTerminal(t, null);

      expect(t.isUsingAltBuffer, isTrue);
      expect(t.buffer.lines[0].getText(0, 7), 'content');
    });
  });

  group('分派按类型，不做算术推断', () {
    test('只有 NewSession 会退出 alt，其余三种都不碰', () {
      for (final MapEntry(key: label, value: expectAlt) in {
        'Restored': true, // 不写终端，起点状态原样保留
        'NewSession': false, // 唯一会强制退出 alt 的分支
        'TabGone': true, // 不写终端
        'null': true, // 不写终端
      }.entries) {
        final t = Terminal(maxLines: 200)..resize(80, 24);
        t.write('\x1b[?1049h'); // 起点：断线前停在 alt 屏

        final AqtDisposition? d = switch (label) {
          'Restored' =>
            const AqtRestored(serverInSeenOff: 0),
          'NewSession' => const AqtNewSession(),
          'TabGone' => const AqtTabGone(null),
          _ => null,
        };
        ReconnectService.applyDispositionToTerminal(t, d);

        expect(t.isUsingAltBuffer, expectAlt, reason: label);
      }
    });
  });
}
