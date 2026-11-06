import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';
import 'conn_test_dsl.dart';

void main() {
  group('L1 场景覆盖清单', () {
    machineCase('长后台回前台：elevated 命中，且不误判死亡',
      from: const MachineState(phase: ConnPhase.live, observeStartMs: 0),
      events: [
        (const LifecycleBackground(),
            const Facts(nowMs: 1000, rawRecvAgeMs: 500, isForeground: false)),
        (const LifecycleForeground(),
            const Facts(nowMs: 721000, rawRecvAgeMs: 720000)),
        (const WatchdogTick(),
            const Facts(nowMs: 721100, rawRecvAgeMs: 720100)),
      ],
      expectPhase: ConnPhase.live,
      forbidActions: [StartResume, SendProbe],
    );

    machineCase('刚 RESUME 完的新 handle：哨兵 age 不得判死',
      from: const MachineState(phase: ConnPhase.live, observeStartMs: 1000),
      events: [
        (const WatchdogTick(), const Facts(nowMs: 1050, rawRecvAgeMs: 1 << 40)),
      ],
      expectPhase: ConnPhase.live,
      forbidActions: [StartResume],
    );

    machineCase('弱网 5% 丢包：停在 suspect/probing，不进 recovering',
      from: const MachineState(phase: ConnPhase.live, observeStartMs: 0),
      events: [
        (const WatchdogTick(), const Facts(nowMs: 11000, rawRecvAgeMs: 11000)),
        (const WatchdogTick(), const Facts(nowMs: 12000, rawRecvAgeMs: 12000)),
        (const ProbeAnswered(), const Facts(nowMs: 12500, rawRecvAgeMs: 5)),
      ],
      expectPhase: ConnPhase.live,
      forbidActions: [StartResume],
    );

    machineCase('切网 WiFi→蜂窝：立即重试，不等退避',
      from: const MachineState(
          phase: ConnPhase.backoff, attempt: 3, backoffUntilMs: 999999),
      events: [
        (const ConnectivityChanged('cellular'),
            const Facts(nowMs: 50000, rawRecvAgeMs: 30000,
                networkType: 'cellular')),
      ],
      expectPhase: ConnPhase.recovering,
      expectActions: [StartResume],
    );

    machineCase('假活：transport 说连着但入向流量早停 → 必须判死',
      from: const MachineState(phase: ConnPhase.live, observeStartMs: 0),
      events: [
        (const WatchdogTick(), const Facts(nowMs: 25000, rawRecvAgeMs: 25000)),
      ],
      expectPhase: ConnPhase.recovering,
      expectActions: [StartResume],
    );

    machineCase('级联：连续成功但活不过 kMinAliveMs → givenUp',
      from: MachineState(
        phase: ConnPhase.recovering,
        inFlight: true,
        recoveringSinceMs: 26000,
        recent: [
          for (var i = 0; i < 5; i++)
            AttemptMark(startedAtMs: 1000 + i * 5000, aliveMs: 2000),
        ],
      ),
      events: [
        (const ConnectedOk(), const Facts(nowMs: 27000, rawRecvAgeMs: 10)),
      ],
      expectPhase: ConnPhase.givenUp,
      forbidActions: [ScheduleTick],
    );

    machineCase('handshakeFailed ×2 → 升级 bootstrap（防 ALPN 死循环）',
      from: const MachineState(
          phase: ConnPhase.recovering, inFlight: true, handshakeFailStreak: 1),
      events: [
        (const ConnectFailed(FailReason.handshakeFailed),
            const Facts(nowMs: 50000, rawRecvAgeMs: 100)),
      ],
      expectPhase: ConnPhase.recovering,
      expectActions: [StartBootstrap],
    );

    // 这条对应原来三个互斥集合（_reconnecting / _retrying / _proactiveResuming）
    // 在 6 个入口做的组合判断：已经有恢复在途时，不要再发起第二个。
    //
    // 那三个集合已随旧路径删除，不变量必须由状态机的 inFlight 承担。
    machineCase('inFlight 为真时，重复的恢复触发不产生第二个 StartResume',
      from: const MachineState(phase: ConnPhase.recovering, inFlight: true,
          recoveringSinceMs: 1000),
      events: [
        (const TransportClosed('again'),
            const Facts(nowMs: 1200, rawRecvAgeMs: 100)),
      ],
      expectPhase: ConnPhase.recovering,
      forbidActions: [StartResume],
    );
  });
}
