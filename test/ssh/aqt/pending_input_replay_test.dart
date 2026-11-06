import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';

/// 断线期间的按键缓冲与重连重放 —— **表征测试**。
///
/// 这些断言固化的是**当前行为**，不是「应该如此」的规格。写它们是为了在排查
/// 「QUIC 下跑着跑着 CC 自己退出、shell 还在」时，把一条可疑机制从「读代码
/// 觉得是这样」变成可执行的证据。
///
/// ## 被固化的机制
///
/// `write()` 在 `!_readyForWrite`（state != connected 或 isDead）时不发送，
/// 而是把字节存进 `_pendingInputBuffer`；等 `connected` 事件到达时
/// `_flushPendingInput()` 一次性写进 PTY。缓冲还能跨 transport 交接
/// （`drainPendingInput` / `adoptPendingInput`），所以完整走一轮 RESUME 也不丢。
///
/// 关键点是**缓冲对内容不做任何区分**：`0x04`（Ctrl-D）和普通字符一样原样
/// 保留。而断线期间屏幕没有回显，用户按下去看不到任何反应。
///
/// ## 于是有这样一条链
///
///   链路抖动 → 用户以为卡住，按 Ctrl-D 想退出 → 字节进缓冲、无回显
///     → QUIC 重连成功 → 缓冲灌进 PTY → CC 读到 EOF 退出
///     → shell 收到 EOF 不退出，提示符还在
///
/// SSH / mosh 路径没有这套缓冲重放，断了就是断了 —— 这是这条机制**只在 QUIC
/// 上咬人**的原因。
///
/// ## 这些测试证明了什么、没证明什么
///
/// 证明：机制确实存在，控制字符确实会被原样重放。
/// **没有**证明：用户遇到的就是这条路径。那需要真机上的 `echo $?`
/// （EOF 应为 0）或飞行模式复现来确认。
void main() {
  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  group('断线期间的输入缓冲', () {
    test('未连接时 write 不发送，而是进缓冲', () {
      // testStub 默认 state 是 connecting（见其构造函数注释：刻意不调
      // _startPolling，也不置 connected）—— 正是断线 / 重连中的那个状态。
      final t = AqtTransport.testStub(tabId: 1);

      t.write(bytes([0x61, 0x62])); // "ab"

      expect(t.drainPendingInput(), equals(bytes([0x61, 0x62])));
    });

    /// 这条是整个假设的核心：致命的控制字符不会被区别对待。
    test('Ctrl-D（0x04）被原样缓冲，不做任何过滤', () {
      final t = AqtTransport.testStub(tabId: 1);

      t.write(bytes([0x04]));

      expect(t.drainPendingInput(), equals(bytes([0x04])),
          reason: '0x04 进 PTY 就是 stdin EOF，前台的 CC 会直接退出，'
              '而 shell 收到 EOF 不退出 —— 正是观察到的症状');
    });

    test('Ctrl-C（0x03）同样原样保留', () {
      final t = AqtTransport.testStub(tabId: 1);
      t.write(bytes([0x03]));
      expect(t.drainPendingInput(), equals(bytes([0x03])));
    });

    test('多次按键按顺序累积', () {
      final t = AqtTransport.testStub(tabId: 1);
      t.write(bytes([0x61]));
      t.write(bytes([0x04]));
      t.write(bytes([0x62]));
      expect(t.drainPendingInput(), equals(bytes([0x61, 0x04, 0x62])),
          reason: '顺序保留 —— 重放时 Ctrl-D 之后的字节会落到 CC 退出后的 shell 上');
    });

    test('缓冲上限 8 KiB，超出部分静默丢弃', () {
      final t = AqtTransport.testStub(tabId: 1);
      t.write(Uint8List(9000)); // 全 0
      expect(t.drainPendingInput()!.length, 8192);
    });

    test('drain 之后缓冲清空', () {
      final t = AqtTransport.testStub(tabId: 1);
      t.write(bytes([0x04]));
      expect(t.drainPendingInput(), isNotNull);
      expect(t.drainPendingInput(), isNull, reason: '取走即清空，不会重复投递');
    });
  });

  group('缓冲跨 transport 交接', () {
    /// `_swapTransport` 走的就是这条路：旧 transport drain、新 transport adopt。
    /// 这解释了为什么完整走一轮 RESUME、换掉整个 transport 之后，那个 Ctrl-D
    /// 依然活着。
    test('旧 transport 的缓冲能被新 transport 接管', () {
      final oldT = AqtTransport.testStub(tabId: 1);
      oldT.write(bytes([0x04]));

      final carried = oldT.drainPendingInput();
      expect(carried, equals(bytes([0x04])));

      final newT = AqtTransport.testStub(tabId: 1);
      newT.adoptPendingInput(carried);

      expect(newT.drainPendingInput(), equals(bytes([0x04])),
          reason: '换了 transport 也不丢 —— 一整轮 RESUME 之后仍会被重放');
    });

    test('adopt 空数据是 no-op', () {
      final t = AqtTransport.testStub(tabId: 1);
      t.adoptPendingInput(null);
      t.adoptPendingInput(Uint8List(0));
      expect(t.drainPendingInput(), isNull);
    });
  });
}
