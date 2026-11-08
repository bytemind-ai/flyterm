// SPDX-License-Identifier: GPL-3.0-or-later
/// AQT 连接状态机的数据类型。
///
/// 这些类型一起变（加一个 phase 往往同时要加 event 与 action），所以放在同一
/// 个文件里。全部不可变、无 IO、无 Flutter 依赖 —— 状态机要能在纯 Dart 测试里跑。
library;

/// 连接所处的阶段。取代 `_reconnecting` / `_retrying` / `_proactiveResuming`
/// 三个集合的 8 种组合态。
enum ConnPhase {
  /// 还没连过，或已被用户关闭。
  ///
  /// 没有单独的 `connecting` 阶段：首次连接由 factory / bootstrap 负责，
  /// 状态机是在连上之后（`ConnectedOk`）才接管的。加一个没有转移会进入的
  /// 阶段只是死枚举值。
  idle,
  /// 最近收到过入向流量。
  live,
  /// 观测到的沉默越过 suspect 阈值，已发探测。
  suspect,
  /// 探测已发，等回音。
  probing,
  /// 判死，恢复（resume / bootstrap）在途。
  recovering,
  /// 恢复失败，退避等待中。
  backoff,
  /// 熔断：反复恢复成功但活不长，停止自动重连。
  givenUp,
  /// 服务端明确说 tab 没了。
  gone,
}

/// 一次恢复尝试的记录，供熔断判据用。
class AttemptMark {
  final int startedAtMs;
  /// 恢复成功后连接存活了多久；null 表示这次尝试失败了（从未 live）。
  final int? aliveMs;

  const AttemptMark({required this.startedAtMs, this.aliveMs});
}

class MachineState {
  final ConnPhase phase;

  /// 进入 suspect 的时刻。取代 `WatchdogState.suspectAt`。
  final int? suspectSinceMs;

  /// **我们从何时开始有能力观测**。取代现有的两层归一化
  /// （`msSinceForeground` / `msSinceConnected`）——
  /// 见 conn_silence.dart 里的等价性说明。
  final int? observeStartMs;

  /// 已连续失败几次，驱动退避曲线。取代 `_periodicRetryTimer` 的隐式游标。
  final int attempt;

  /// 退避到什么时候。取代 `InterruptibleSleeper._sleepers`。
  final int? backoffUntilMs;

  /// 有恢复动作在途。
  ///
  /// 原本的说法是「一个 bool 取代三个互斥集合 —— 那三个集合存在的唯一理由是
  /// 区分'是谁发起的'，收敛成单一状态机后只有一个发起者」。**那个前提没有成
  /// 立**：迁移停在半路，`_proactiveResumeAqtTabs`（periodic sweep）与 DISC
  /// 路径至今直接调 `_proactiveResumeAqtTab`，发起者始终是三个。于是同一个不
  /// 变量由这个 bool 和 `_proactiveResuming` 集合各管一半，谁也看不见对方 ——
  /// a6.jpg 就是这么来的。现在外部发起经 [ResumeStarted] 也登记到这里。
  final bool inFlight;

  /// [inFlight] 是何时置起的（墙钟）。null 表示不在途。
  ///
  /// 存在的理由是 [inFlight] 会被僵死的请求永久占住。a6.jpg 的 #8 在飞了
  /// 8 分 08 秒 —— 而 RESUME 的预算上限是 14s，差 35 倍，因为
  /// `Future.timeout` 注册的是 Dart Timer，进程被 doze 冻结后它不推进。
  ///
  /// 用墙钟而不是「回前台就作废」：`Facts.nowMs` 取自
  /// `DateTime.now().millisecondsSinceEpoch`，doze 期间照样推进，解冻后第一个
  /// tick 就能看出这次在飞已经多久；也就不依赖任何生命周期事件，tick /
  /// connectivity / 前台哪一路来都能突破。
  ///
  /// **每一处置 `inFlight: true` 的地方都必须同时给这个字段** —— [copyWith]
  /// 里有 assert 兜底，漏写会在 debug/测试下当场炸，而不是静默退化成"逃生阀
  /// 永远不触发"。
  final int? inFlightSinceMs;

  /// 连续 handshakeFailed 次数。达到 2 次升级为 bootstrap，防 ALPN 不匹配
  /// 时 prewarm 直连陷入永远失败的死循环。
  final int handshakeFailStreak;

  /// 进入 recovering 的时刻，用于横幅延迟。
  final int? recoveringSinceMs;

  /// 上一次看到的 rebindCount，用于检测路径迁移。
  final int lastRebindCount;

  /// 熔断窗口内的尝试记录。
  final List<AttemptMark> recent;

  /// 路线切换（直连 UDP ↔ SSH 中继）在途的起点（墙钟）；null 表示不在途。
  ///
  /// 与 [inFlight] 同一设计：在途只存在于状态机一处，runner 不做判断。
  /// 在途且未超 `kPathSwitchBudgetMs` 时，沉默类判死被暂缓。
  final int? pathSwitchSinceMs;

  /// 本个 live 周期是否已经尝试过路线切换（一周期只试一次）。
  /// 沉默回落到 pathSwitchMs 以下（新的 live 周期）时清零。
  final bool pathSwitchUsed;

  const MachineState({
    required this.phase,
    this.suspectSinceMs,
    this.observeStartMs,
    this.attempt = 0,
    this.backoffUntilMs,
    this.inFlight = false,
    this.inFlightSinceMs,
    this.handshakeFailStreak = 0,
    this.recoveringSinceMs,
    this.lastRebindCount = 0,
    this.recent = const [],
    this.pathSwitchSinceMs,
    this.pathSwitchUsed = false,
  });

  static const initial = MachineState(phase: ConnPhase.idle);

  /// `clearX` 参数用来把可空字段显式置 null —— 单靠 `X: null` 无法区分
  /// "不改"和"清空"。
  MachineState copyWith({
    ConnPhase? phase,
    int? suspectSinceMs,
    bool clearSuspectSince = false,
    int? observeStartMs,
    bool clearObserveStart = false,
    int? attempt,
    int? backoffUntilMs,
    bool clearBackoffUntil = false,
    bool? inFlight,
    int? inFlightSinceMs,
    int? handshakeFailStreak,
    int? recoveringSinceMs,
    bool clearRecoveringSince = false,
    int? lastRebindCount,
    List<AttemptMark>? recent,
    int? pathSwitchSinceMs,
    bool clearPathSwitchSince = false,
    bool? pathSwitchUsed,
  }) {
    // 置位必须带时刻。漏写的后果不是崩溃而是静默退化 —— inFlightSinceMs 停在
    // null，超龄逃生阀拿不到年龄，一个僵死请求就能永久占住互斥锁（a6.jpg 的
    // #8 挂了 8 分钟）。assert 让「不能漏」从注释变成结构保证。
    assert(
        inFlight != true ||
            inFlightSinceMs != null ||
            this.inFlightSinceMs != null,
        'inFlight 置位时必须给 inFlightSinceMs，见该字段文档');
    return MachineState(
      phase: phase ?? this.phase,
      suspectSinceMs:
          clearSuspectSince ? null : (suspectSinceMs ?? this.suspectSinceMs),
      observeStartMs:
          clearObserveStart ? null : (observeStartMs ?? this.observeStartMs),
      attempt: attempt ?? this.attempt,
      backoffUntilMs:
          clearBackoffUntil ? null : (backoffUntilMs ?? this.backoffUntilMs),
      inFlight: inFlight ?? this.inFlight,
      // 清位即清时刻 —— 没有「不在途但有在途起点」这种状态，把不变量绑在一起
      // 而不是靠调用点记得同时清。
      inFlightSinceMs: (inFlight ?? this.inFlight)
          ? (inFlightSinceMs ?? this.inFlightSinceMs)
          : null,
      handshakeFailStreak: handshakeFailStreak ?? this.handshakeFailStreak,
      recoveringSinceMs: clearRecoveringSince
          ? null
          : (recoveringSinceMs ?? this.recoveringSinceMs),
      lastRebindCount: lastRebindCount ?? this.lastRebindCount,
      recent: recent ?? this.recent,
      pathSwitchSinceMs: clearPathSwitchSince
          ? null
          : (pathSwitchSinceMs ?? this.pathSwitchSinceMs),
      pathSwitchUsed: pathSwitchUsed ?? this.pathSwitchUsed,
    );
  }
}

/// 为什么恢复失败。沿用 `AqtResumeFailReason` 的四态语义，但在这一层重新声明
/// 以保持 conn/ 目录对 factory 零依赖。映射在 conn_runner.dart 里做。
enum FailReason { networkTimeout, sessionNotFound, handshakeFailed, unknownError }

sealed class Event {
  const Event();
}

class ConnectedOk extends Event { const ConnectedOk(); }
class ConnectFailed extends Event {
  final FailReason reason;
  const ConnectFailed(this.reason);
}
class TransportClosed extends Event {
  final String reason;
  const TransportClosed(this.reason);
}
class WatchdogTick extends Event { const WatchdogTick(); }
class ProbeAnswered extends Event { const ProbeAnswered(); }
class LifecycleForeground extends Event { const LifecycleForeground(); }
class LifecycleBackground extends Event { const LifecycleBackground(); }
class ConnectivityChanged extends Event {
  final String networkType;
  const ConnectivityChanged(this.networkType);
}
class UserRefresh extends Event { const UserRefresh(); }
class TabClosed extends Event { const TabClosed(); }

/// 「有人**在状态机之外**发起了一次 RESUME」。
///
/// RESUME 有三个发起点，只有一个经状态机（`StartResume` → runner.onResume）。
/// 另两个 —— periodic sweep 的 `_proactiveResumeAqtTabs` 与 DISC 路径 ——
/// 直接调 `_proactiveResumeAqtTab`，各自查 `_proactiveResuming` 集合。于是
/// 「同一 tab 只能有一次恢复在飞」这个不变量由两份状态分别维护，谁也看不见
/// 对方：`_enterRecovering` 的 `if (s.inFlight)` 拦不住集合那一侧发起的，
/// 集合的守卫也拦不住状态机这一侧。
///
/// a6.jpg 现场就是这么来的：sweep 发起 #8 → doze 冻结 8 分钟 → 回前台后
/// 状态机 tick 判死发出 #9、#8 的超时随即 FAIL 又引出 #10 → 两条并发
/// RESUME 都拿到 ACK，客户端只装一条，服务端的 PTY 流留在被 DISCARD 的
/// 那条上。体征全绿而屏幕不动。
///
/// 这个事件让外部发起也登记进 `inFlight`，把两份状态收敛成一份。它**不派发**
/// [StartResume] —— 调用方已经在发了。
class ResumeStarted extends Event { const ResumeStarted(); }

/// 「那次外部发起的 RESUME 结束了」，无论成功、失败还是走了回退链。
///
/// 必须与 [ResumeStarted] 成对出现在同一个 try/finally 里。漏掉它比不加守卫
/// 更糟：`_proactiveResumeAqtTab` 有一条既不喂 `ConnectedOk` 也不喂
/// `ConnectFailed` 的退出路径（「cold RESUME 无可用结果，走回退链」），
/// `inFlight` 会永远停在 true，这个 tab 之后再也发不出恢复 —— 并发 bug 变
/// 永久死锁。
///
/// 只清 `inFlight`，不动 `phase`：phase 归 `ConnectedOk` / `ConnectFailed`
/// 管，走回退链时它该留在 `recovering` 让 tick 继续驱动。对已经因
/// `ConnectedOk` 进 live 的连接是幂等的。
class ResumeSettled extends Event { const ResumeSettled(); }

/// 路线切换（见 [StartPathSwitch]）完成：连接已迁到另一条路线。
class PathSwitched extends Event { const PathSwitched(); }

/// 路线切换失败或放弃。本 live 周期不再重试（`pathSwitchUsed` 保持）。
class PathSwitchFailed extends Event { const PathSwitchFailed(); }

/// 只读事实。**不含任何判断** —— 判断全在 step() 里。
class Facts {
  final int nowMs;
  /// `aqt_get_last_recv_age_ms`：距上次收到入向 UDP 字节多久（Rust 侧 1Hz 轮询
  /// `conn.stats().udp_rx.bytes`）。"从未收到"由 FFI 归一化成一个巨大哨兵值。
  final int rawRecvAgeMs;
  /// `aqt_get_path_stats().rebindingCount`：NAT 重绑定 / 路径迁移次数。
  final int rebindCount;
  final bool isForeground;
  final String networkType;

  /// 距上次收到 **PTY 数据** 多久（`AqtTransport.lastPtyDataAge`）。
  ///
  /// 与 [rawRecvAgeMs] 是两个层的事，不可互相替代：后者数的是入向 UDP 字节，
  /// ACK / PATH_RESPONSE / keepalive / 心跳 datagram 都会让它归零，而终端数据
  /// 走的是独立的 QUIC bi-stream。stream 死掉而连接层照常喘气时，只有这个
  /// 字段看得见 —— 见 conn_machine_pty_stall_test.dart 里那份真机现场。
  final int ptySilenceMs;

  /// 距上次真正把字节交给 FFI 多久；从未写过时为 null。
  ///
  /// PTY 停流判据要用它回答「我们**有没有理由**期待输出」：终端本来就可以
  /// 长时间静默（用户没在操作），只有"发过输入却迟迟等不到下文"这种沉默
  /// 才说明通道坏了。
  final int? sinceLastWriteMs;

  /// 当前是否具备切换路线的条件（前台、非 SSH 中继固定路线等，由调用方判定）。
  final bool canSwitchPath;

  const Facts({
    required this.nowMs,
    required this.rawRecvAgeMs,
    this.rebindCount = 0,
    this.isForeground = true,
    this.networkType = 'wifi',
    this.ptySilenceMs = 0,
    this.sinceLastWriteMs,
    this.canSwitchPath = false,
  });
}

sealed class Action {
  const Action();
}

class SendProbe extends Action { const SendProbe(); }
class StartResume extends Action { const StartResume(); }
/// 在判死之前先试另一条路线（直连 UDP ↔ SSH 中继）。
class StartPathSwitch extends Action { const StartPathSwitch(); }
class StartBootstrap extends Action { const StartBootstrap(); }
class Close extends Action { const Close(); }
// 没有 Rebind action：主动迁移端点仍走既有的 AqtTransport.migrateEndpoint()，
// 它以"正面识别到网卡变化"为闸门。状态机只**观察** rebindCount 来重置观测
// 窗口，不主动触发迁移 —— 加一个没有转移会产生的 action 只是死代码。
class ScheduleTick extends Action {
  final int delayMs;
  const ScheduleTick(this.delayMs);
}
class CancelTick extends Action { const CancelTick(); }
/// 只发码，不发文案 —— l10n 留在 UI 层，状态机保持无 Flutter 依赖。
class ShowBanner extends Action {
  final String code;
  const ShowBanner(this.code);
}
class ClearBanner extends Action { const ClearBanner(); }
