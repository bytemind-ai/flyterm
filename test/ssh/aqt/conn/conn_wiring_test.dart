import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  test('mapFailReason 把 AqtResumeFailReason 映射到状态机的 FailReason', () {
    expect(ReconnectService.mapFailReason(AqtResumeFailReason.networkTimeout),
        FailReason.networkTimeout);
    expect(ReconnectService.mapFailReason(AqtResumeFailReason.sessionNotFound),
        FailReason.sessionNotFound);
    expect(ReconnectService.mapFailReason(AqtResumeFailReason.handshakeFailed),
        FailReason.handshakeFailed);
    expect(ReconnectService.mapFailReason(AqtResumeFailReason.unknownError),
        FailReason.unknownError);
  });

  test('readFacts 从参数直接组装 Facts，不做加工', () {
    final f = ReconnectService.readFacts(
        nowMs: 1234, rawRecvAgeMs: 5678, rebindCount: 9,
        isForeground: false, networkType: 'cellular');
    expect(f.nowMs, 1234);
    expect(f.rawRecvAgeMs, 5678);
    expect(f.rebindCount, 9);
    expect(f.isForeground, isFalse);
    expect(f.networkType, 'cellular');
  });

  test('readFacts 透传 PTY 停流两个字段', () {
    // 这两个是 2026-09-06「连着却收不到数据」那次卡死加的第二活性维度。
    // 接线断了的话状态机会退回只看 UDP 字节，而那正是当初判不出死的原因。
    final f = ReconnectService.readFacts(
        nowMs: 1, rawRecvAgeMs: 2, rebindCount: 0,
        isForeground: true, networkType: 'wifi',
        ptySilenceMs: 96000, sinceLastWriteMs: 98000);
    expect(f.ptySilenceMs, 96000);
    expect(f.sinceLastWriteMs, 98000);
  });

  test('readFacts 不填 PTY 字段时是中性值，不会凭空判死', () {
    final f = ReconnectService.readFacts(
        nowMs: 1, rawRecvAgeMs: 2, rebindCount: 0,
        isForeground: true, networkType: 'wifi');
    expect(f.ptySilenceMs, 0);
    expect(f.sinceLastWriteMs, isNull);
  });

  // 约束要能被检查，否则会慢慢腐蚀 —— 与 `conn_runner_test.dart` 末尾那条
  // 「不许读 state 做分支」同一个手法（仓库先例：notify_hooks_test 断言文档
  // 与脚本逐字节一致）。
  test('探测命中必须通知状态机 —— ProbeAnswered 不能再变回死事件', () {
    // 2026-09-13 之前，`ProbeAnswered` 在整个 lib/ 里**零个发出点**：事件定义
    // 好了、状态机也处理了，就是没有人发。后果是 `reconnect_service` 探测到
    // 「心跳还活着」时直接 return，而状态机停在 recovering 里等一个永远不会
    // 来的结果 —— 屏幕上「重新连接中…」一直挂着，连接其实一直是通的。
    //
    // 这条断言拦的是「把那行 feed 删掉」这类回归。它测不了调用时机（那需要
    // 装配整个 ReconnectService），但能保证发出点还在。
    final src = File('lib/ssh/reconnect_service.dart').readAsStringSync();
    final code = src
        .split('\n')
        .where((l) =>
            !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
        .join('\n');
    expect(code, contains('conn.ProbeAnswered()'),
        reason: '探测命中不通知状态机，tab 会卡在 recovering 出不来');
  });
}
