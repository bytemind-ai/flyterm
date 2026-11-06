/// 失败的 RESUME 要能回答「握手到底通没通」。
///
/// 2026-09-05 18:49 现场留下一个分不开的岔路：`proactive/live` 连着两发都
/// **恰好**打满 budget 报 networkTimeout（49:00→49:05、49:06→49:11），而
/// 0.7 秒后 `fullreconn` 用同一个 addr、同一个 token、同一个 FFI 函数
/// 253ms 就成功了。服务端会话完好（两次 `replay=225639` 字节完全相同），
/// 同期 SSH 也一直通，所以既不是 daemon 挂了也不是整条路径黑洞。
///
/// 剩下两个候选，而它们都会被 `oldTransport.close()` 解开 —— fullreconn
/// 恰好在 RESUME 之前关旧 transport，proactive 路径全程不关：
///
///   A 客户端：`aqt_client_ffi/src/runtime.rs` 是 `new_current_thread()`，
///     全 App 所有 QUIC 连接共用一个线程。旧连接的任务占住它，新握手一步
///     都走不动。
///   B 服务端：PTY reader 线程持 `output_forwarder` 锁卡在 `blocking_send`
///     （`pty_task.rs:277/295`），RESUME handler 卡在同一把锁上
///     （`connection.rs:201`）。
///
/// `networkTimeout` 这个分类对两者一视同仁，所以光看日志分不开。但**握手
/// 是否完成**能一刀切开：A 会卡在握手本身（`connect_0rtt` 里的
/// `accepted.await` 不返回），B 的握手是通的、卡在其后的 ResumeAck。
///
/// 客户端在 `*h.conn_state = ConnState::Connected` 时才发 connected 事件，
/// 而那一行紧跟在 `connect_0rtt` 之后 —— 所以「有没有走到 connected」正是
/// 「握手通没通」。本组测试锁住它被记进日志。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('resumeOutcomeLabel：超时失败必须带上握手可达性', () {
    test('超时但握手通过 → hs:ok（矛头指向服务端/ResumeAck）', () {
      expect(
        ReconnectService.resumeOutcomeLabel(const AqtResumeFailed(
          AqtResumeFailReason.networkTimeout,
          detail: 'TimeoutException',
          reachedConnected: true,
        )),
        'FAIL networkTimeout hs:ok',
      );
    });

    test('超时且握手未通过 → hs:-- （矛头指向客户端 runtime / 出向路径）', () {
      expect(
        ReconnectService.resumeOutcomeLabel(const AqtResumeFailed(
          AqtResumeFailReason.networkTimeout,
          detail: 'TimeoutException',
          reachedConnected: false,
        )),
        'FAIL networkTimeout hs:--',
      );
    });

    test('两种超时的标签必须不同 —— 否则这个埋点白加', () {
      const a = AqtResumeFailed(AqtResumeFailReason.networkTimeout,
          reachedConnected: true);
      const b = AqtResumeFailed(AqtResumeFailReason.networkTimeout,
          reachedConnected: false);
      expect(ReconnectService.resumeOutcomeLabel(a),
          isNot(ReconnectService.resumeOutcomeLabel(b)));
    });
  });

  group('其余归类不带后缀：debug overlay 一行宽度有限，只在有歧义处花字符', () {
    test('sessionNotFound —— 服务端明确答复过，握手当然是通的', () {
      expect(
        ReconnectService.resumeOutcomeLabel(const AqtResumeFailed(
          AqtResumeFailReason.sessionNotFound,
          reachedConnected: true,
        )),
        'FAIL sessionNotFound',
      );
    });

    test('handshakeFailed —— 名字本身已经回答了这个问题', () {
      expect(
        ReconnectService.resumeOutcomeLabel(const AqtResumeFailed(
          AqtResumeFailReason.handshakeFailed,
          reachedConnected: false,
        )),
        'FAIL handshakeFailed',
      );
    });

    test('成功 → OK', () {
      final t = AqtTransport.testStub();
      expect(ReconnectService.resumeOutcomeLabel(AqtResumeSuccess(t)), 'OK');
    });
  });

  group('reachedConnected 的默认值', () {
    test('不传即 false —— 缺省必须是"没证据说握手通了"', () {
      // 反过来默认 true 会让所有未改造的构造点凭空报告握手成功，
      // 把这个埋点变成噪声源。
      expect(
        const AqtResumeFailed(AqtResumeFailReason.networkTimeout)
            .reachedConnected,
        isFalse,
      );
    });
  });
}
