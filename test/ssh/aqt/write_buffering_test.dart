/// `write()` 在 tabId 还没到时必须**缓冲**，不能丢。
///
/// a9.jpg 现场暴露的岔路：`sinceLastWrite == null` 有两种成因——用户没打字，
/// 或者打了但字节被吞了——而现场无法分辨。查的时候发现 `write()` 的第一行是
/// 一句裸 `return`：
///
/// ```dart
/// final t = _tabId;
/// if (t == null) return;        // 丢
/// if (!_readyForWrite) {
///   _bufferInput(data);         // 缓冲
/// ```
///
/// 两条路径没有理由不一致：都是「暂时发不出去」。而 `_tabId` 为 null 的窗口
/// 恰恰是 RESUME 握手期间（超时的话长达 5 秒），那正是用户最可能焦躁地敲键盘
/// 的时刻。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';

void main() {
  test('tabId 还没到时，输入进缓冲而不是被吞掉', () {
    // 未经 bootstrap/resume 的 transport：tabId 为 null，正是恢复握手中的状态
    final t = AqtTransport.testStub();
    expect(t.debugTabId, isNull, reason: '前提：还没拿到 OPEN_TAB_ACK');

    t.write(Uint8List.fromList('ls -la\n'.codeUnits));

    expect(t.pendingInputBytes, 7,
        reason: '这 7 个字节此前会被静默丢弃，屏幕上没有任何痕迹');
    expect(t.debugWriteCalls, 1, reason: 'write 确实被调用过 —— '
        '这正是分辨「没打字」与「打了没发出去」的依据');
  });

  test('缓冲有上限，不会无限涨', () {
    final t = AqtTransport.testStub();
    for (var i = 0; i < 200; i++) {
      t.write(Uint8List.fromList(List.filled(100, 0x41)));
    }
    expect(t.pendingInputBytes, lessThanOrEqualTo(8192),
        reason: '断线期间狂敲键盘不该把内存吃光');
    expect(t.debugWriteCalls, 200);
  });
}
