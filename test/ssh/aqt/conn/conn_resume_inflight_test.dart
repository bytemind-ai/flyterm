/// 「同一 tab 只能有一次恢复在飞」——**外部发起**那一半的不变量。
///
/// `_enterRecovering` 的 `if (s.inFlight)` 只挡住状态机自己派发的重复发起。
/// 但 RESUME 还有两个不经状态机的发起点（periodic sweep 的
/// `_proactiveResumeAqtTabs`、DISC 路径），它们各自维护 `_proactiveResuming`
/// 集合，状态机对此一无所知 —— `inFlight` 始终是 false。
///
/// 后果见 a6.jpg 现场：
///
/// ```
/// 28:37.832  #8→  proactive/live [c50b]     sweep 发起，状态机不知情
///            ...doze，timer 冻结 8 分钟...
/// 36:45.421  #9→  proactive/live [c50b]     状态机 tick 判死 → 又一条
/// 36:45.425  #8←  FAIL networkTimeout       → ConnectFailed → 进 backoff
/// 36:45.434  #10→ proactive/live [c50b]     backoff 到期 → 第三条
/// 36:45.766  #10← OK replay=0
/// 36:45.810  #9←  OK replay=0               两条并发 RESUME 都成功
/// ```
///
/// 客户端只装一条，服务端的 PTY 流留在被 DISCARD 的那条上，于是
/// `RESUMED✓ / connected / rtt 99ms / loss 0%` 全绿而屏幕不动。
///
/// [ResumeStarted] / [ResumeSettled] 让外部发起也经过 `inFlight`，把两份
/// in-flight 状态收敛成一份。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

void main() {
  group('shouldSkipExternalResume：入口守卫的判据', () {
    test('外部发起 + 状态机已在途 → 放弃（这正是 a6.jpg 要拦的那一条）', () {
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: false,
              machineInFlight: true,
              reconnectInFlight: false),
          isTrue);
    });

    test('外部发起 + 空闲 → 放行', () {
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: false,
              machineInFlight: false,
              reconnectInFlight: false),
          isFalse);
    });

    test('状态机自己派发的那一次 → inFlight 拦不住它', () {
      // _enterRecovering 刚把 inFlight 置起来就回调进来，拦下去等于状态机把
      // 自己掐死：这个 tab 再也发不出恢复。
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: true,
              machineInFlight: true,
              reconnectInFlight: false),
          isFalse,
          reason: 'fromMachine 必须能穿过 inFlight，否则并发 bug 变成永久阻塞');
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: true,
              machineInFlight: false,
              reconnectInFlight: false),
          isFalse);
    });
  });

  group('reconnectInFlight：全量链在跑时不再发廉价 RESUME', () {
    // 2026-09-05 18:49 现场：
    //   49:00.070 #29→ proactive/live
    //   49:05.070 #29← FAIL networkTimeout      打满 5s budget，escalate
    //             escalate 同一刻做了两件事：
    //               a) feed(ConnectFailed) → 状态机进 backoff（kBackoffMs[1]=1000ms）
    //               b) _reconnectWithRetry('aqtRoamFail') → SSH 全量链启动
    //   49:06.082 #30→ proactive/live           backoff 到期，状态机重发
    //   49:11.082 #30← FAIL networkTimeout      又白烧 5s
    //   49:11.807 #31→ fullreconn               SSH 链跑完，走工厂的 RESUME
    //   49:12.060 #31← OK replay=225639         253ms 成功
    //
    // #30 是纯亏：全量链已经在跑，它失败就白烧 5s；万一成功，还要和全量链的
    // `_installAqtTransport` 抢装配 —— 那正是 a6.jpg「体征全绿而屏幕不动」的形状。
    // 而全量链自带 preSsh + fullreconn 两次 RESUME 机会，廉价路径插进来不补任何缺口。
    test('状态机重发撞上在跑的全量链 → 放弃（#30 那一条）', () {
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: true,
              machineInFlight: true,
              reconnectInFlight: true),
          isTrue,
          reason: 'fromMachine 能穿过 machineInFlight，但**不能**穿过 '
              'reconnectInFlight —— 这是两个不同的互斥对象');
    });

    test('sweep 撞上在跑的全量链 → 放弃', () {
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: false,
              machineInFlight: false,
              reconnectInFlight: true),
          isTrue);
    });

    test('全量链结束后 → 重新放行，守卫不是永久阻塞', () {
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: true,
              machineInFlight: true,
              reconnectInFlight: false),
          isFalse);
      expect(
          ReconnectService.shouldSkipExternalResume(
              fromMachine: false,
              machineInFlight: false,
              reconnectInFlight: false),
          isFalse);
    });
  });

  group('shouldSettleOnSkip：被拦下时该不该替谁清位', () {
    // 守卫加了 reconnectInFlight 之后，`fromMachine` 那一条**也可能**被拦。
    // 而它的 inFlight 是 `_enterRecovering` 刚置上去的，本次调用是唯一的清位
    // 人 —— 拦下就 return 而不清，inFlight 永远停在 true，这个 tab 之后再也
    // 发不出恢复。并发 bug 换成永久死锁，比原病更重。
    test('fromMachine 被拦 → 必须清位', () {
      expect(ReconnectService.shouldSettleOnSkip(fromMachine: true), isTrue);
    });

    test('外部发起被拦 → 不得清位', () {
      // 这时 inFlight 是**别人**置的，别人的 finally 会清。替他放锁就等于
      // 把守卫拆了，回到 a6.jpg。
      expect(ReconnectService.shouldSettleOnSkip(fromMachine: false), isFalse);
    });
  });

  group('ResumeStarted：外部发起的登记', () {
    test('空闲时登记 → 只置 inFlight，phase 不动，且**不产生 StartResume**', () {
      const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
      const f = Facts(nowMs: 1000, rawRecvAgeMs: 100);
      final (s2, acts) = step(s, const ResumeStarted(), f);
      expect(s2.inFlight, isTrue);
      expect(s2.phase, ConnPhase.live,
          reason: 'phase 归真实连接事件管。推到 recovering 会让 _onTick 停止判活，'
              '而走回退链时没有任何事件把 phase 推走 —— tab 卡在 recovering 出不来');
      expect(acts, isEmpty,
          reason: '调用方已经在发 RESUME 了，再派发一条 StartResume 就是自己撞自己');
    });

    test('已在途时登记 → 原样吞掉，不叠加', () {
      const s = MachineState(
          phase: ConnPhase.recovering, inFlight: true, recoveringSinceMs: 500);
      const f = Facts(nowMs: 1000, rawRecvAgeMs: 100);
      final (s2, acts) = step(s, const ResumeStarted(), f);
      expect(s2.inFlight, isTrue);
      expect(s2.recoveringSinceMs, 500,
          reason: '不得把在途那一次的起点改写成现在，否则耗时统计会失真');
      expect(acts, isEmpty);
    });
  });

  group('ResumeSettled：无论成败都要清位', () {
    test('清 inFlight，且**不动 phase**', () {
      const s = MachineState(phase: ConnPhase.live, inFlight: true);
      const f = Facts(nowMs: 2000, rawRecvAgeMs: 100);
      final (s2, acts) = step(s, const ResumeSettled(), f);
      expect(s2.inFlight, isFalse);
      expect(s2.phase, ConnPhase.live,
          reason: 'phase 由 ConnectedOk / ConnectFailed / tick 判死决定，'
              '这个事件只表示「这次尝试结束了」');
      expect(acts, isEmpty);
    });

    test('幂等：成功路径 ConnectedOk 已清过位，finally 再清一次无害', () {
      var s = const MachineState(phase: ConnPhase.recovering, inFlight: true);
      const f = Facts(nowMs: 2000, rawRecvAgeMs: 100);
      (s, _) = step(s, const ConnectedOk(), f);
      expect(s.inFlight, isFalse, reason: '前提：ConnectedOk 自己会清位');
      final phaseAfterOk = s.phase;
      List<Action> acts;
      (s, acts) = step(s, const ResumeSettled(), f);
      expect(s.inFlight, isFalse);
      expect(s.phase, phaseAfterOk, reason: '不得把已经 live 的连接打回 recovering');
      expect(acts, isEmpty);
    });
  });

  group('在飞超龄逃生阀：僵死的请求不能永久占住互斥锁', () {
    // a6.jpg 的 #8：28:37.832 发起，36:45.425 才 FAIL —— 8 分 08 秒。
    // 而 RESUME 的预算上限是 kWeakNetworkResumeTimeout = 14s（默认 5s）。
    // 差 35 倍的原因是 Future.timeout 注册的是 Dart Timer，进程被 doze 冻结
    // 后 timer 不推进，那 8 分钟是 doze 时长本身。
    //
    // 这个数字在加守卫之前只是"放大竞态概率"；加了之后 inFlight 成了真互斥
    // 锁，它就变成"能把这个 tab 的恢复阻塞 8 分钟"。逃生阀是守卫的配套，不是
    // 可选项。
    const deadTick = Facts(nowMs: 100000, rawRecvAgeMs: 100000);

    test('在飞 8 分钟后 → tick 判死可以突破守卫', () {
      var s = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
      (s, _) =
          step(s, const ResumeStarted(), const Facts(nowMs: 0, rawRecvAgeMs: 0));
      expect(s.inFlight, isTrue);

      // 8 分 08 秒后（a6.jpg 的实际时长）
      const t = 488000;
      List<Action> acts;
      (s, acts) = step(s, const WatchdogTick(),
          const Facts(nowMs: t, rawRecvAgeMs: t));
      expect(acts.whereType<StartResume>(), hasLength(1),
          reason: '协议层早就把那条连接关了（QUIC max_idle_timeout），'
              '继续认它等于让用户干等 8 分钟');
    });

    test('在飞 5 秒（还在预算内）→ 守卫照常拦住', () {
      var s = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
      (s, _) =
          step(s, const ResumeStarted(), const Facts(nowMs: 0, rawRecvAgeMs: 0));
      List<Action> acts;
      (s, acts) = step(s, const WatchdogTick(),
          const Facts(nowMs: 5000, rawRecvAgeMs: 5000));
      expect(acts.whereType<StartResume>(), isEmpty,
          reason: '5s 内是正常的 RESUME 往返，抢跑它就回到了 a6.jpg');
    });

    test('逃生阀不吞掉阈值本身 —— 恰好到阈值前一刻仍拦住', () {
      var s = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
      (s, _) =
          step(s, const ResumeStarted(), const Facts(nowMs: 0, rawRecvAgeMs: 0));
      List<Action> acts;
      (s, acts) = step(
          s,
          const WatchdogTick(),
          const Facts(
              nowMs: kInFlightStaleMs - 1, rawRecvAgeMs: kInFlightStaleMs - 1));
      expect(acts.whereType<StartResume>(), isEmpty);
    });

    test('每个置位点都必须记下时刻，否则逃生阀永远不触发', () {
      // copyWith 里有 assert 兜底，这条测试是它的可读版本：漏记时刻的置位点
      // 会让 inFlightSinceMs 为 null，逃生阀拿不到年龄，僵死请求就永久占锁。
      const f = Facts(nowMs: 7777, rawRecvAgeMs: 100);
      for (final (name, ev) in <(String, Event)>[
        ('ResumeStarted', ResumeStarted()),
        ('UserRefresh', UserRefresh()),
      ]) {
        final (s2, _) = step(
            const MachineState(phase: ConnPhase.live, observeStartMs: 0), ev, f);
        if (s2.inFlight) {
          expect(s2.inFlightSinceMs, 7777, reason: '$name 置了 inFlight 却没记时刻');
        }
      }
      // backoff 到期那条路径
      final (s3, _) = step(
          const MachineState(
              phase: ConnPhase.backoff, backoffUntilMs: 5000, observeStartMs: 0),
          const WatchdogTick(),
          f);
      expect(s3.inFlight, isTrue, reason: '前提：backoff 到期会置位');
      expect(s3.inFlightSinceMs, 7777, reason: 'backoff 到期置了 inFlight 却没记时刻');
    });
  });

  group('a6.jpg 回归：外部发起在飞期间，状态机不得再发 RESUME', () {
    // 100 秒沉默：远超任何一档的 deathMs，_onTick 的「单次越过 death 天花板」
    // 分支会当场判死，不必先走 suspect→probe。用它把「判死」这一步变成确定的，
    // 测试就不依赖各档阈值的具体取值。
    const deadTick = Facts(nowMs: 100000, rawRecvAgeMs: 100000);
    const live = MachineState(phase: ConnPhase.live, observeStartMs: 0);

    /// 登记时刻定在 deadTick 前 1 秒，好让**沉默时长**和**在飞年龄**两条时间轴
    /// 分开：沉默要 100s（触发判死），在飞年龄只能 1s（不能越过
    /// [kInFlightStaleMs] 的逃生阀，否则测的就不是守卫而是逃生阀了）。
    const justStarted = Facts(nowMs: 99000, rawRecvAgeMs: 99000);

    test('对照组：没有外部发起时，这个 tick 确实会发 StartResume', () {
      final (_, acts) = step(live, const WatchdogTick(), deadTick);
      expect(acts.whereType<StartResume>(), hasLength(1),
          reason: '这条是下面两条的前提。它一旦不成立，'
              '下面的「不产生 StartResume」就是在断言一个永远为真的东西');
    });

    test('sweep 发起后同一个 tick → 不产生 StartResume', () {
      var s = live;
      (s, _) = step(s, const ResumeStarted(), justStarted);
      expect(s.inFlight, isTrue);

      List<Action> acts;
      (s, acts) = step(s, const WatchdogTick(), deadTick);
      expect(acts.whereType<StartResume>(), isEmpty,
          reason: '#8 还在飞，这一条就是 a6.jpg 里的 #9');
      expect(s.phase, ConnPhase.live, reason: '守卫生效时原样返回，phase 不动');
    });

    test('清位之后同一个 tick → 重新允许发起，守卫不是永久死锁', () {
      var s = live;
      (s, _) = step(s, const ResumeStarted(), justStarted);
      // 走回退链：既没有 ConnectedOk 也没有 ConnectFailed，只有 finally 的清位
      (s, _) = step(s, const ResumeSettled(),
          const Facts(nowMs: 99500, rawRecvAgeMs: 99500));
      expect(s.inFlight, isFalse);

      List<Action> acts;
      (s, acts) = step(s, const WatchdogTick(), deadTick);
      expect(acts.whereType<StartResume>(), hasLength(1),
          reason: '清位后必须能重新发起 —— 否则把并发 bug 换成了永久阻塞');
    });
  });
}
