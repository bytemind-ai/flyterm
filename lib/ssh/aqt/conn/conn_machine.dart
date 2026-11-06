// SPDX-License-Identifier: GPL-3.0-or-later
/// AQT 连接状态机。**唯一的决策处。**
///
/// 纯函数：不做 IO、不调 `DateTime.now()`（时间由 Facts 传入）、不依赖 Flutter。
/// 于是一条真机失败序列可以原样变成测试向量 —— 这是整套设计的支点。
///
/// 执行壳 `conn_runner.dart` 只负责把事件喂进来、把 actions 执行掉，自己不做
/// 任何判断。
library;

import 'conn_silence.dart';
import 'conn_types.dart';

/// watchdog 的观察节奏。与现有 `Timer.periodic(1s)` 一致。
const int kTickIntervalMs = 1000;

/// 退避曲线。沿用 `ReconnectService._kRetryDelays` 的量级，不引入新经验值。
/// 超出表尾则固定用最后一档。
const List<int> kBackoffMs = [0, 1000, 3000, 8000, 15000];

int backoffFor(int attempt) =>
    kBackoffMs[attempt.clamp(0, kBackoffMs.length - 1)];

/// 连续多少次 handshakeFailed 之后升级为 bootstrap。
/// 2 次足以区分「偶发握手抖动」与「协议/版本真的不匹配」。
const int kHandshakeFailEscalateAt = 2;

/// 熔断窗口与阈值。沿用 `ReconnectService._kCascadeBreakerWindow`(2min) 与
/// `_kCascadeBreakerThreshold`(5)，不引入新值 —— 改的只是判据。
const int kBreakerWindowMs = 2 * 60 * 1000;
const int kBreakerThreshold = 5;

/// "活不过这么久就不算成功"。等于 normal 档的 suspect 阈值：一次重连若活不到
/// 一个 suspect 周期，它从未证明过自己是活的。
const int kMinAliveMs = 10000;

/// 在飞多久之后就不再认它，允许新的恢复发起。
///
/// RESUME 的预算上限是 `AqtTransportFactory.kWeakNetworkResumeTimeout` = 14s
/// （默认档 5s，前台快档 3s），所以正常情况下 in-flight 最多十几秒。取 30s 是
/// 那个上限的两倍余量，容得下弱网重试与事件调度延迟。
///
/// 为什么需要它：`Future.timeout` 注册的是 Dart Timer，进程被 Android doze
/// 冻结后 timer 不推进 —— a6.jpg 的 #8 因此在飞了 **8 分 08 秒**才报
/// networkTimeout，是设计上限的 35 倍。在 inFlight 只是「放大竞态概率」的年代
/// 这只是个噪声；一旦它成为真互斥锁，一个僵死请求就能把该 tab 的恢复阻塞整个
/// doze 时长。协议层那边其实早已了结（QUIC max_idle_timeout 会关掉连接），继续
/// 认它纯粹是让用户干等。
const int kInFlightStaleMs = 30000;

/// recovering 持续超过这么久才提示用户。
///
/// **这是本设计唯一需要实测标定的值**，初值 800ms。定义是"恢复耗时的 p50"——
/// 低于它的恢复对用户不可见，高于它才值得打扰。标定数据从 conn_trace 的轨迹
/// 导出里读（recovering→live 的时间差），实施收尾时用真机跑一轮取值。
const int kBannerDelayMs = 800;

/// 级联的定义：窗口内尝试够多，且**成功的那些都活不长**。
///
/// 现有实现的判据是"最近 5 次全是 soft 且成功"，很难说清它在防什么；而单纯
/// 次数多在弱网下是正常的，不该熔断。
///
/// 全是失败（aliveMs 均为 null）也不算级联 —— 那是"连不上"，该继续退避重试，
/// 不是"连上又掉"。
bool isCascading(List<AttemptMark> recent, int nowMs) {
  final inWindow =
      recent.where((m) => nowMs - m.startedAtMs <= kBreakerWindowMs).toList();
  if (inWindow.length < kBreakerThreshold) return false;
  final succeeded = inWindow.where((m) => m.aliveMs != null);
  if (succeeded.isEmpty) return false;
  return succeeded.every((m) => m.aliveMs! < kMinAliveMs);
}

(MachineState, List<Action>) step(MachineState s, Event e, Facts f) {
  return switch (e) {
    WatchdogTick() => _onTick(s, f),
    // 探测得到了回应 —— 连接是活的，把恢复相关的位**全部**归零。
    //
    // 三件事缺一不可，少做一件就是把一个明显的 bug 换成两个隐蔽的
    // （2026-09-13 真机排查，见 `conn_probe_hit_test.dart` 里的现场）：
    //
    //   phase → live            否则 `_onTick` 那支只显示横幅、不判活，永远
    //                           出不来（`conn_resume_inflight_test.dart` 头部
    //                           记过同一类失效：「tab 卡在 recovering 出不来」）
    //   clearRecoveringSince    否则下次再进 recovering 时 `nowMs - since` 一
    //                           上来就超过 kBannerDelayMs，横幅立刻弹而不是
    //                           延迟几秒 —— 卡死变闪烁
    //   inFlight → false        否则 `_enterRecovering` 的 `if (s.inFlight)`
    //                           会把后续所有发起都吞掉，连自愈机会都没了
    ProbeAnswered() => (
        s.copyWith(
            phase: ConnPhase.live,
            inFlight: false,
            clearSuspectSince: true,
            clearRecoveringSince: true),
        [const ScheduleTick(kTickIntervalMs)],
      ),
    // 进后台：不探测、不判死。observeStartMs 清空表示"进入盲区"——
    // 进程可能被冻结也可能没有，状态机不关心，它只记录"这段时间看不见"。
    LifecycleBackground() => (
        s.copyWith(clearObserveStart: true, clearSuspectSince: true),
        [const CancelTick()],
      ),
    // 回前台：观测重新开始。立刻看一眼而不是等 1s ——
    // 盲区越长越该早看，而这里正是盲区刚结束的时刻。
    LifecycleForeground() => (
        s.copyWith(observeStartMs: f.nowMs, clearSuspectSince: true),
        [const ScheduleTick(0)],
      ),
    ConnectedOk() => _onConnected(s, f),
    ConnectFailed(:final reason) => _onFailed(s, f, reason),
    TransportClosed() => _enterRecovering(s, f),
    UserRefresh() => (
        s.copyWith(
          phase: ConnPhase.recovering,
          inFlight: true,
          inFlightSinceMs: f.nowMs,
          attempt: 0,
          clearBackoffUntil: true,
          recoveringSinceMs: f.nowMs,
          recent: const [], // 手动刷新重置熔断窗口
        ),
        [const CancelTick(), const StartResume()],
      ),
    ConnectivityChanged() => s.phase == ConnPhase.backoff
        // 网络变了：不必等退避走完。"叫醒"变成状态转移的自然结果，
        // 于是 InterruptibleSleeper 那套旁路机制不再需要。
        ? (
            s.copyWith(
                phase: ConnPhase.recovering,
                inFlight: true,
                inFlightSinceMs: f.nowMs,
                clearBackoffUntil: true,
                recoveringSinceMs: f.nowMs),
            [const StartResume()],
          )
        : (s.copyWith(observeStartMs: f.nowMs), [const ScheduleTick(0)]),
    TabClosed() => (
        s.copyWith(phase: ConnPhase.gone, inFlight: false),
        [const CancelTick(), const Close()],
      ),
    // 状态机之外发起的恢复，登记 / 注销。为什么需要它们见 conn_types.dart 里
    // 两个类的文档。这里强调两点：
    //
    // 1. 都**不派发任何 action**。发起方自己在跑那次 RESUME，状态机在这里的
    //    职责仅仅是持有「在飞」这一个事实，好让 _enterRecovering 的守卫看得见。
    // 2. 都只动 inFlight（与它绑定的 inFlightSinceMs），**phase 一概不碰**。
    //    试过让 ResumeStarted 顺手把 phase 推到 recovering（「登记了就是在恢
    //    复」听起来很自然），结果是把并发 bug 换成另一种死锁：_onTick 只在
    //    「认为连着」的阶段判活，phase 一旦停在 recovering 就没人再驱动它，而
    //    外部发起的那次恢复若走了回退链，既不会有 ConnectedOk 也不会有
    //    ConnectFailed 把 phase 推走 —— tab 卡在 recovering 出不来。
    //    交给 _enterRecovering 的既有守卫就够了。
    ResumeStarted() => (
        s.copyWith(inFlight: true, inFlightSinceMs: f.nowMs),
        const []
      ),
    ResumeSettled() => (s.copyWith(inFlight: false), const []),
    // 这里**刻意没有** `_ =>` 兜底分支。
    //
    // 迁移期曾有一个（好让只实现了一部分事件的中间提交能编译），全部事件接完
    // 之后 Dart 把它判成 unreachable_switch_case —— 那是准确的，删掉而不是用
    // `// ignore:` 压住。
    //
    // 删掉还换来一件事：`Event` 是 sealed class，没有兜底分支时穷尽检查恢复
    // 生效。将来往里加一个新事件子类，这个 switch 会**编译不过**，强制你在
    // 唯一的决策处处理它 —— 而不是让它悄悄落进「什么都不做」。
  };
}

(MachineState, List<Action>) _onTick(MachineState s, Facts f) {
  // 熔断后不再自动做任何事，等 UserRefresh。
  if (s.phase == ConnPhase.givenUp || s.phase == ConnPhase.gone) {
    return (s, const []);
  }

  // 恢复在途：只管要不要提示用户，不做判活（判活的对象是旧连接，已经没了）。
  if (s.phase == ConnPhase.recovering) {
    final since = s.recoveringSinceMs;
    if (since != null && f.nowMs - since > kBannerDelayMs) {
      return (
        s,
        [const ShowBanner('reconnectInProgress'), const ScheduleTick(kTickIntervalMs)]
      );
    }
    return (s, [const ScheduleTick(kTickIntervalMs)]);
  }

  // 退避到期：再试一次。取代 _periodicRetryTimer。
  if (s.phase == ConnPhase.backoff) {
    final until = s.backoffUntilMs;
    if (until != null && f.nowMs >= until) {
      return (
        s.copyWith(
            phase: ConnPhase.recovering,
            inFlight: true,
            inFlightSinceMs: f.nowMs,
            clearBackoffUntil: true,
            recoveringSinceMs: f.nowMs),
        [const StartResume()],
      );
    }
    return (s, [const ScheduleTick(kTickIntervalMs)]);
  }

  // 只有"认为连着"的阶段才需要判活。
  if (s.phase != ConnPhase.live &&
      s.phase != ConnPhase.suspect &&
      s.phase != ConnPhase.probing) {
    return (s, const []);
  }

  // 路径迁移 / NAT 重绑定：迁移之前的沉默对新路径没有说明力，与"刚回前台"
  // 是同一类事情（观测起点变了）。不重置的话，一次重绑定会因为 rawAge 跨越
  // 迁移点而立刻被判死。
  //
  // rebindCount 来自 aqt_get_path_stats()，一直存在但此前只被 debug_overlay
  // 显示给人看，没进过任何自动决策。
  if (f.rebindCount != s.lastRebindCount) {
    return (
      s.copyWith(
        phase: ConnPhase.live,
        observeStartMs: f.nowMs,
        lastRebindCount: f.rebindCount,
        clearSuspectSince: true,
      ),
      [const ScheduleTick(kTickIntervalMs)],
    );
  }

  // PTY 停流：传输层再新鲜，终端收不到数据也是死的。
  //
  // 必须排在下面那条 silence 链**之前** —— 那条链的第一个分支就是
  // `silence < suspectMs → live`，排在它后面等于永远不会被执行到，而
  // 这个 bug 的现场恰恰就是 silence 很小（心跳刚把它刷新过）。
  //
  // 判据本身见 ptyStalled：它只在前台、且"发过输入却等不到下文"时才成立，
  // 空闲静默不会被误判。
  if (ptyStalled(s, f)) {
    return _enterRecovering(s, f);
  }

  final t = thresholdsFor(urgency: urgencyFor(s, f));
  final silence = observedSilence(s, f);

  // 沉默还没到 suspect：新鲜。
  if (silence < t.suspectMs) {
    return (
      s.copyWith(phase: ConnPhase.live, clearSuspectSince: true),
      [const ScheduleTick(kTickIntervalMs)],
    );
  }

  // 丢 tick 的安全网：单次 tick 直接越过 death，当场判死不经 probe。
  // 没有这一条，丢 tick 时只会 arm probe，要再等一个（可能十几秒后的）tick
  // 才判死。
  //
  // 证据在本目录 conn_machine_liveness_test.dart 的「丢 tick：单次越过 death
  // 天花板」那条。原先另有一个 death_ceiling_test.dart 用旧的 WatchdogState
  // 锁同一结论，已随旧实现一起删除。
  if (silence >= t.deathMs) {
    return _enterRecovering(s, f);
  }

  // 首次越过 suspect：发探测。
  final since = s.suspectSinceMs;
  if (since == null) {
    return (
      s.copyWith(phase: ConnPhase.suspect, suspectSinceMs: f.nowMs),
      [const SendProbe(), const ScheduleTick(kTickIntervalMs)],
    );
  }

  // 探测在途：超时则判死，否则继续等。
  if (f.nowMs - since > t.probeTimeoutMs) {
    return _enterRecovering(s, f);
  }
  return (
    s.copyWith(phase: ConnPhase.probing),
    [const ScheduleTick(kTickIntervalMs)],
  );
}

/// 在飞的那次是否已经僵死到不值得再等。见 [kInFlightStaleMs]。
///
/// 起点为 null 时返回 false（保守：拿不到年龄就当它还新鲜）—— 不过
/// `MachineState.copyWith` 的 assert 已经保证置位必带起点，这里只是防御。
bool isInFlightStale(MachineState s, Facts f) {
  final since = s.inFlightSinceMs;
  if (since == null) return false;
  return f.nowMs - since > kInFlightStaleMs;
}

(MachineState, List<Action>) _enterRecovering(MachineState s, Facts f) {
  // 已在途：不重复发起。
  //
  // 这个不变量原来由 _reconnecting / _retrying / _proactiveResuming 三个集合
  // 在 6 个入口的组合判断承担；那三个集合随旧路径删除后，它必须由 inFlight
  // 一处承担。漏掉它的后果是同一个 tab 同时有两次恢复在飞 —— 生产日志里出现过
  // 2 秒内三条连接对同一个 tab 各做一次 RESUME。
  //
  // 例外是僵死的在飞请求（doze 冻结 timer，a6.jpg 的 #8 挂了 8 分钟）：那种
  // 情况下守卫本身成了故障 —— 它会把这个 tab 的恢复一直挡住。逃生阀让年龄超过
  // kInFlightStaleMs 的在飞不再被认。
  if (s.inFlight && !isInFlightStale(s, f)) return (s, const []);

  return (
    s.copyWith(
      phase: ConnPhase.recovering,
      inFlight: true,
      inFlightSinceMs: f.nowMs,
      clearSuspectSince: true,
      recoveringSinceMs: f.nowMs,
    ),
    [const CancelTick(), const StartResume()],
  );
}

(MachineState, List<Action>) _onFailed(
    MachineState s, Facts f, FailReason reason) {
  switch (reason) {
    // 服务端明确说会话没了 → 没有可续的东西，直接建新会话。
    case FailReason.sessionNotFound:
      return (
        s.copyWith(
            phase: ConnPhase.recovering,
            inFlight: true,
            inFlightSinceMs: f.nowMs,
            attempt: 0,
            handshakeFailStreak: 0,
            recoveringSinceMs: f.nowMs),
        [const StartBootstrap()],
      );

    // 握手失败可能是 SPKI 或**协议版本**不匹配。连续两次就必须走 SSH 重新
    // 引导 —— prewarm 拿磁盘 token 直连 QUIC、不走 SSH，没有任何一处比对
    // 版本，不升级就是永远失败的死循环（ALPN aqt/1→aqt/2 那次已验证）。
    case FailReason.handshakeFailed:
      final streak = s.handshakeFailStreak + 1;
      if (streak >= kHandshakeFailEscalateAt) {
        return (
          s.copyWith(
              phase: ConnPhase.recovering,
              inFlight: true,
              inFlightSinceMs: f.nowMs,
              handshakeFailStreak: 0,
              recoveringSinceMs: f.nowMs),
          [const StartBootstrap()],
        );
      }
      return _enterBackoff(s, f, handshakeFailStreak: streak);

    case FailReason.networkTimeout:
    case FailReason.unknownError:
      return _enterBackoff(s, f);
  }
}

(MachineState, List<Action>) _enterBackoff(MachineState s, Facts f,
    {int? handshakeFailStreak}) {
  final attempt = s.attempt + 1;
  final delay = backoffFor(attempt);
  return (
    s.copyWith(
      phase: ConnPhase.backoff,
      inFlight: false,
      attempt: attempt,
      backoffUntilMs: f.nowMs + delay,
      handshakeFailStreak: handshakeFailStreak ?? s.handshakeFailStreak,
      clearRecoveringSince: true,
    ),
    [ScheduleTick(delay)],
  );
}

(MachineState, List<Action>) _onConnected(MachineState s, Facts f) {
  final recent = [
    ...s.recent,
    AttemptMark(startedAtMs: s.recoveringSinceMs ?? f.nowMs),
  ].where((m) => f.nowMs - m.startedAtMs <= kBreakerWindowMs).toList();

  if (isCascading(recent, f.nowMs)) {
    return (
      s.copyWith(
          phase: ConnPhase.givenUp,
          inFlight: false,
          recent: recent,
          clearRecoveringSince: true),
      [const CancelTick(), const ShowBanner('reconnectLoopDetected')],
    );
  }
  return (
    s.copyWith(
      phase: ConnPhase.live,
      attempt: 0,
      handshakeFailStreak: 0,
      clearBackoffUntil: true,
      clearSuspectSince: true,
      clearRecoveringSince: true,
      inFlight: false,
      observeStartMs: f.nowMs,
      recent: recent,
    ),
    [const ClearBanner(), const ScheduleTick(kTickIntervalMs)],
  );
}
