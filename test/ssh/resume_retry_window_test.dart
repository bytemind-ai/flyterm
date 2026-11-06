import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart'
    show AqtResumeFailReason, AqtTransportFactory;
import 'package:flyterm/ssh/reconnect_service.dart'
    show ReconnectService, ResumeRetryDecision;
import 'package:flutter_test/flutter_test.dart';

/// 廉价 RESUME 重试窗口。
///
/// 背景：连通性事件先于路由表就绪到达（Mosh 路径同样如此，所以它按
/// 0/0.5/1.5/3s 连发四次心跳）。QUIC 之前只试一次 RESUME（路径在尝试中途
/// 死亡时才多试一次），失败即转入 SSH bootstrap 链（15-25s）。本组测试固定
/// 新的重试节奏与它的三条止损条件。
void main() {
  ResumeRetryDecision decide({
    bool pathDead = true,
    AqtResumeFailReason? reason = AqtResumeFailReason.networkTimeout,
    int attempt = 0,
    Duration elapsed = Duration.zero,
    // 缺省 0 = 快速失败（路由表未就绪，ENETUNREACH 同步返回）。这是重试节奏
    // 的目标场景，所以让它当缺省。
    Duration attemptElapsed = Duration.zero,
  }) =>
      ReconnectService.decideResumeRetry(
        pathDead: pathDead,
        reason: reason,
        attempt: attempt,
        elapsed: elapsed,
        attemptElapsed: attemptElapsed,
      );

  group('重试节奏与 Mosh 对齐', () {
    test('尝试落点为 t=0/0.5/1.5/3s', () {
      // gaps 是相邻两次尝试的间隔，累加即绝对落点。
      var t = Duration.zero;
      final landings = <int>[t.inMilliseconds];
      for (final gap in ReconnectService.kResumeRetryGaps) {
        t += gap;
        landings.add(t.inMilliseconds);
      }
      expect(landings, [0, 500, 1500, 3000],
          reason: '与 _onConnectivityChanged 里 Mosh 心跳的 0/500/1500/3000 一致');
    });

    test('窗口容得下最后一次尝试', () {
      final total = ReconnectService.kResumeRetryGaps
          .fold<Duration>(Duration.zero, (a, b) => a + b);
      expect(ReconnectService.kCheapResumeWindow, greaterThan(total),
          reason: '否则第 4 次尝试永远被 window 判死，节奏名存实亡');
    });

    test('快速失败时四次尝试全部放行', () {
      // 路由表未就绪 → ENETUNREACH 立刻返回，elapsed 几乎不增长。
      var elapsed = const Duration(milliseconds: 20);
      for (var attempt = 0;
          attempt < ReconnectService.kResumeRetryGaps.length;
          attempt++) {
        expect(decide(attempt: attempt, elapsed: elapsed),
            ResumeRetryDecision.retry,
            reason: 'attempt=$attempt 应继续重试');
        elapsed += ReconnectService.kResumeRetryGaps[attempt] +
            const Duration(milliseconds: 20);
      }
      // 第 4 次（attempt=3）失败后再无 gap 可用。
      expect(
        decide(
            attempt: ReconnectService.kResumeRetryGaps.length,
            elapsed: elapsed),
        ResumeRetryDecision.escalate,
      );
    });
  });

  group('三条止损条件', () {
    test('旧路径仍活 → keepOld，绝不因一次 RESUME 失败拆掉可用连接', () {
      expect(decide(pathDead: false), ResumeRetryDecision.keepOld);
      // 即便还有重试额度、时间也够，活着就不动它。
      expect(decide(pathDead: false, attempt: 0, elapsed: Duration.zero),
          ResumeRetryDecision.keepOld);
    });

    test('sessionNotFound → 立即升级，重试改变不了服务端没有这个 session', () {
      expect(decide(reason: AqtResumeFailReason.sessionNotFound),
          ResumeRetryDecision.escalate);
    });

    test('reason=null（根本无 session 信息可用）→ 立即升级', () {
      expect(decide(reason: null), ResumeRetryDecision.escalate);
    });

    test('慢失败自行耗尽窗口 → 升级（弱网 14s budget 不会叠成 4 次）', () {
      // 单次尝试就用掉了 14s：此时网络其实可达但不健康，属于 SSH 链的问题。
      expect(
        decide(attempt: 0, elapsed: const Duration(seconds: 14)),
        ResumeRetryDecision.escalate,
      );
    });

    test('临界：elapsed + 下一个 gap 恰好触到窗口边界即升级', () {
      final gap0 = ReconnectService.kResumeRetryGaps[0];
      final justInside =
          ReconnectService.kCheapResumeWindow - gap0 - const Duration(milliseconds: 1);
      expect(decide(attempt: 0, elapsed: justInside), ResumeRetryDecision.retry);
      expect(
        decide(attempt: 0, elapsed: ReconnectService.kCheapResumeWindow - gap0),
        ResumeRetryDecision.escalate,
      );
    });
  });

  group('回归护栏：修复前的行为不得复现', () {
    test('握手失败且路径已死时必须重试，而不是一次就转 SSH', () {
      // 修复前：deadAtStart=true → diedDuring=false → 只试一次直接升级。
      // 这正是网络恢复场景最常见的入口（调用方明知路径已死，probeFirst=false）。
      expect(
        decide(reason: AqtResumeFailReason.handshakeFailed, attempt: 0),
        ResumeRetryDecision.retry,
      );
    });

    test('networkTimeout 同样可重试', () {
      expect(decide(reason: AqtResumeFailReason.networkTimeout),
          ResumeRetryDecision.retry);
    });
  });

  group('「只重试快速失败」必须是显式判据，不能是数值巧合', () {
    // 这条契约原本写在 kCheapResumeWindow 的文档里（「只有 FAST failures，
    // 也就是路由表未就绪的签名，才会被重试」），但**实现**是靠
    // `elapsed + gap >= window` 间接达成的 —— 它只在
    // `budget(5s) > kCheapResumeWindow(4s)` 时才碰巧成立。
    //
    // proactive budget 收紧到 3s 之后这个巧合就没了：3.0 + 0.5 < 4.0 → 一次
    // 超时失败会被判成 retry，再等一个完整 budget，总耗时 3.0+0.5+3.0 = 6.5s
    // 才 escalate —— 比收紧之前的 5.0s 还慢，修复变倒退。
    //
    // 所以判据改看**这一次尝试自己花了多久**，与 budget 取值解耦。
    // 收紧 proactive budget 那次用的值。常量已删，这里保留字面量 ——
    // 这一组锁的是「判据与 budget 取值无关」，不该跟着常量增删而失效。
    const proactive = Duration(seconds: 3);

    test('打满 proactive budget 的一次失败 → 一次就 escalate', () {
      expect(
        decide(attempt: 0, elapsed: proactive, attemptElapsed: proactive),
        ResumeRetryDecision.escalate,
        reason: '等满 budget 说明对端根本没回，重试只会再等一个 budget',
      );
    });

    test('打满弱网 budget 的一次失败 → 同样一次就 escalate', () {
      const weak = AqtTransportFactory.kWeakNetworkResumeTimeout;
      expect(
        decide(attempt: 0, elapsed: weak, attemptElapsed: weak),
        ResumeRetryDecision.escalate,
      );
    });

    test('判据与 budget 取值解耦：budget 再怎么调都不改变结论', () {
      for (final b in const [
        Duration(seconds: 3),
        Duration(seconds: 5),
        Duration(seconds: 8),
        Duration(seconds: 14),
      ]) {
        expect(
          decide(attempt: 0, elapsed: b, attemptElapsed: b),
          ResumeRetryDecision.escalate,
          reason: 'budget=$b 时仍必须一次 escalate',
        );
      }
    });

    test('快速失败不受影响 —— 重试节奏的目标场景照常放行', () {
      expect(
        decide(
            attempt: 0,
            elapsed: const Duration(milliseconds: 20),
            attemptElapsed: const Duration(milliseconds: 20)),
        ResumeRetryDecision.retry,
      );
    });

    test('阈值必须落在「快速失败」与「打满 budget」之间', () {
      expect(ReconnectService.kFastFailureCeiling,
          lessThan(AqtTransportFactory.kDefaultResumeTimeout),
          reason: '不小于最短 budget 的话，打满 budget 也会被当成快速失败');
      expect(ReconnectService.kFastFailureCeiling,
          greaterThan(const Duration(milliseconds: 100)),
          reason: 'ENETUNREACH 是同步返回，但一次真实的失败握手往返也有几百 ms，'
              '阈值太小会把它误判成慢失败');
    });
  });

  // 真机现场（2026-09-05 02:49–02:51 UTC）：同一 tab 连续四次 RESUME 失败后
  // 退化成 HELLO，服务端 OPEN_TAB + prelude 26B —— 会话丢了。而同一秒另一个
  // tab 的 RESUME 拿回了 235162B，证明服务端 session 一直好好的。
  //
  // 根因不在网络也不在服务端，在元数据的存放位置：`_reconnect()` 里
  // `tab.transport = null` 是**永久副作用**，而承接它的 `prevAqtForFullreconn`
  // 是**每次调用重置的局部变量**。于是第一次尝试失败后：
  //
  //   attempt 1: tab.transport 非空 → 走 preSsh → 失败 → 存进局部变量 → 返回
  //   attempt 2: tab.transport 已是 null → 整个 preSsh 块跳过 → 局部变量又是 null
  //   fullreconn: null ?? null → 工厂没有元数据 → HELLO → 会话丢失
  //
  // 这一组锁住的不变量是：**元数据一旦拿到过，就不能因为 tab.transport 被清空
  // 而丢失**。
  group('RESUME 元数据的来源选择', () {
    // 用 Object 占位而不是造 AqtTransport —— 后者要 FFI handle，而这个判定
    // 只关心「取哪一个」，不碰 transport 的任何成员。
    final live = Object();
    final stashed = Object();

    test('tab 上还有 transport 时优先用它 —— 那是最新的元数据', () {
      expect(ReconnectService.resumeMetaFor(tabTransport: live, stashed: stashed),
          same(live));
    });

    test('tab.transport 被清空后回退到留存的元数据 —— 这条就是本次 bug', () {
      expect(ReconnectService.resumeMetaFor(tabTransport: null, stashed: stashed),
          same(stashed),
          reason: 'attempt 2 起 tab.transport 恒为 null，若不回退就再也发不出 RESUME');
    });

    test('两者皆空才是真的没有元数据可用', () {
      expect(ReconnectService.resumeMetaFor(tabTransport: null, stashed: null),
          isNull);
    });

    test('没有留存时按 tab 上的走 —— 首次尝试的常态', () {
      expect(ReconnectService.resumeMetaFor(tabTransport: live, stashed: null),
          same(live));
    });
  });
}
