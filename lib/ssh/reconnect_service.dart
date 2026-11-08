// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:path_provider/path_provider.dart';
import 'foreground_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartssh2/dartssh2.dart' show SSHKeyPair;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart';
import '../data/activity_tracker.dart';
import '../data/models/server.dart';
import '../data/secure_storage.dart';
import '../data/repositories/server_repository.dart';
import '../data/repositories/mosh_process_repository.dart';
import '../data/repositories/ssh_key_repository.dart';
import 'host_key_verifier.dart';
import 'mosh_connection.dart';
import 'ssh_connection.dart';
import 'ssh_connection_pool.dart';
import 'ssp_interface.dart' as v2iface;
import 'ssp_v2/mosh_shell_v2.dart';
import 'ssp_v2/moshv2_shell.dart' show createMoshV2Transport;
import 'ssp_v2/transport/connection.dart' show MoshV2Connection;
import 'session_manager.dart';
import 'aqt/aqt_transport.dart' show AqtTransport;
import 'aqt/aqt_transport_factory.dart'
    show
        AqtTransportFactory,
        AqtResumeResult,
        AqtResumeSuccess,
        AqtResumeFailed,
        AqtResumeFailReason;
import 'aqt/aqt_ffi.dart'
    show AqtDisposition, AqtNewSession, AqtRestored, AqtTabGone, PathStats;
import 'aqt/aqt_session_state.dart'
    show AqtSessionState, AqtSessionStateRepository, sessionStateFor;
import 'aqt/aqt_path_controller.dart';
import 'aqt/aqt_route.dart';
import 'aqt/aqt_ssh_relay.dart';
import 'aqt/notify_seen_store.dart' show NotifySeenStore;
import 'aqt/resume_issue_log.dart';
import 'aqt/resume_sample.dart';
import 'aqt/resume_sample_log.dart';
import 'transport/transport.dart';
import 'transport/remote_transport.dart'
    show RemoteTransport, TransportKind, TransportState;
import 'transport/transport_factory.dart';
import 'transport/composite_transport_factory.dart';
import 'multiplexer/multiplexer_backend.dart';
import 'multiplexer/none_backend.dart';
import 'multiplexer/tmux_backend.dart';
import 'jump_host_resolver.dart';
import '../data/terminal_settings.dart';
import 'package:xterm/xterm.dart' show Terminal;
import 'aqt/conn/conn_types.dart' as conn;
import 'aqt/conn/conn_runner.dart';
import 'aqt/conn/conn_silence.dart' show isPtyStalled;

/// What to do after a cheap RESUME attempt failed, decided by
/// [ReconnectService.decideResumeRetry].
enum ResumeRetryDecision {
  /// Sleep for the next gap and try RESUME again — still cheap, still worth it.
  retry,

  /// The old QUIC path is actually fine; the failure was benign. Keep the
  /// existing transport and do nothing.
  keepOld,

  /// Give up on the cheap path and fall into the SSH bootstrap chain.
  escalate,
}

// ResumeReplayMode 枚举（none / swallowAlt / clearAndRewrite / appendDelta）
// 已删除。
//
// 那四种模式是在**猜服务端做了什么**：客户端拿 server_out_off - replay_bytes
// 算出「是重建还是续传」，再据此决定清屏、吞吃还是追加。服务端一改语义
// （d7dc3ef）判据就静默失效（e382759），而 swallowAlt 找的 alt 标记恰好被
// 当时服务端的 strip_mode_changes 剥掉了 —— 找不到就吞满预算，TUI 输出全丢、
// 画面冻在切换前那一帧。（那个函数现已随字节流 ring 一并删除。）
//
// 现在服务端用 Disposition 直接声明处置，客户端按类型分派。见
// ReconnectService._applyResumeDisposition。

// Cascade warning: print a terminal notice once this many reconnects occur
// within the cascade window (to inform the user of instability).
const _kCascadeWindow = Duration(minutes: 5);
const _kCascadeWarnThreshold = 3;

// Circuit breaker: stop auto-reconnect when the session enters a tight
// self-perpetuating loop (many successful soft-reconnects in a short window).
const _kCascadeBreakerWindow = Duration(minutes: 2);
const _kCascadeBreakerThreshold = 5;

/// Sleep utility that supports cancellation. The retry loop inside
/// `_reconnectWithRetry` previously used `await Future.delayed(delay)`
/// between attempts, which kept `_retrying[tabId]` set for the full
/// natural duration (up to ~6 minutes worst case across 4 retries).
/// connectivity_plus would fire `hasNetwork=true` and the periodic
/// ticker would still skip the tab because the loop was sleeping.
///
/// `delay(tabId, d)` registers a per-tab completer; `wake(tabId)` or
/// `wakeAll()` resolves it early so the loop advances immediately.
class InterruptibleSleeper {
  final _sleepers = <String, Completer<void>>{};

  Future<void> delay(String tabId, Duration d) async {
    final c = Completer<void>();
    _sleepers[tabId] = c;
    final timer = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    try {
      await c.future;
    } finally {
      timer.cancel();
      if (identical(_sleepers[tabId], c)) {
        _sleepers.remove(tabId);
      }
    }
  }

  void wake(String tabId) {
    final c = _sleepers[tabId];
    if (c != null && !c.isCompleted) c.complete();
  }

  void wakeAll() {
    for (final c in _sleepers.values) {
      if (!c.isCompleted) c.complete();
    }
  }


  int get debugActiveCount => _sleepers.length;
}

/// One-shot foreground fast-path flag registry.
///
/// Mirrors the [InterruptibleSleeper] pattern: a standalone mini-class so the
/// flag logic can be tested in complete isolation without constructing a full
/// [ReconnectService] (which requires live [SessionManager] / [ServerRepository]
/// / etc.).
///
/// Lifecycle:
///   1. [onForegroundResumed] calls [mark] for every dead AQT tab.
///   2. [_reconnectWithRetry] calls [take] once on entry: true means use the
///      fast-path budget (0-delay banner, 0 retry delays); the flag is
///      atomically consumed so subsequent calls return false.
class FastPathRegistry {
  final _pending = <String>{};

  /// Mark [tabId] for a one-shot fast-path RWR on its next entry.
  void mark(String tabId) => _pending.add(tabId);

  /// Returns true if [tabId] is marked (without consuming the flag).
  bool contains(String tabId) => _pending.contains(tabId);

  /// Consumes and returns the fast-path flag for [tabId].
  /// Returns true on the first call after [mark]; false thereafter.
  bool take(String tabId) => _pending.remove(tabId);
}

class ReconnectService with WidgetsBindingObserver {
  final SessionManager _sessionManager;
  final SecureStorageService _storage;
  final ServerRepository _serverRepo;
  final MoshProcessRepository? _moshProcessRepo;
  final SSHKeyRepository _keyRepo;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _periodicRetryTimer;
  // Debounce lifecycle-triggered SSH reconnect checks: Android navigation
  // gestures (predictive back) fire inactive→resumed in ~300 ms. Without
  // the delay the check races the navigation animation and may find the TCP
  // socket transiently closed, causing a spurious "[重新连接中...]" banner.
  Timer? _resumeCheckTimer;
  // Debounce timer for SSH reconnect triggered by connectivity changes.
  Timer? _connectivityDebounceTimer;
  // Last time the app was paused — used to detect Android Doze kills.
  DateTime? _lastPauseTime;
  /// app 是否在前台。喂给状态机的 `Facts.isForeground`。
  ///
  /// 之前没有这个字段 —— 前台状态只以 `didChangeAppLifecycleState` 的瞬时分支
  /// 存在，没有任何地方能问「现在是不是前台」。状态机需要它作为事实输入。
  bool _isForegroundNow = true;
  // Last classified connectivity type ("wifi"/"cellular"/"vpn"/"ethernet"/"none").
  // Used by [_onConnectivityChanged] to suppress redundant heartbeat/roam
  // scheduling when only the signal level (not the network type) changed.
  String? _lastConnectivityType;

  /// 网络**类型**变化时调用（"wifi"/"cellular"/"vpn"/"ethernet"/"none"）。
  ///
  /// 参数是新旧类型，让调用方能自行决定「none → wifi」与「wifi → cellular」
  /// 是否要区别对待。SFTP 用它决定要不要重建那条独立 SSH：切网时 TCP 已失效。
  ///
  /// **只在类型变化时触发**，信号强度变化不触发 —— 与既有的
  /// `_lastConnectivityType` 判据一致，避免 wifi 忽强忽弱引发重连风暴。
  ///
  /// 纯增量字段：默认 null，不注入时行为与改动前一模一样。
  void Function(String newType, String? oldType)? onNetworkTypeChanged;

  /// App 回到前台时调用。
  ///
  /// SFTP 用它**主动探活**（后台冻结期间 keepalive 定时器停摆，连接可能已死）。
  /// **注意：这里不重建，只探活** —— 无差别重建会让「切出去看一眼通知再回来」
  /// 也触发一次重连。
  ///
  /// 纯增量字段：默认 null，不注入时行为与改动前一模一样。
  void Function()? onForegroundResumedForSftp;
  // Tracks tab IDs currently being reconnected to prevent concurrent attempts.
  final _reconnecting = <String>{};
  // Tracks QUIC tabs with a proactive RESUME in flight (network switch path).
  final _proactiveResuming = <String>{};
  // Completers fulfilled when a proactive resume finishes (success or fail).
  // _reconnectWithRetry awaits these to avoid issuing a concurrent RESUME
  // handshake for the same session token — two concurrent RESUMEs can both
  // get RESUME_ACK, then the DISCARD-swap path closes the "loser" connection,
  // which may kill the server session and leave the "winner" as a phantom.
  final _proactiveResumeCompleters = <String, Completer<void>>{};

  // Recent RESUME events for debug overlay.
  // Cap raised 12 → 32: a single failed proactive-resume cycle alone burns
  // 6-8 lines (DISC, START, FAIL1, RETRY ..., → reconnect, then
  // reconnectWithRetry's enter/attempt N/FAIL/exit). With the old 12 cap
  // those late lines would slide off the top before the user could
  // screenshot them.
  final _resumeLog = <String>[];
  List<String> get resumeLog => List.unmodifiable(_resumeLog);
  static const _kResumeLogCap = 32;
  void _logResume(String msg) {
    final ts = DateTime.now();
    final entry = '${ts.hour.toString().padLeft(2,"0")}:${ts.minute.toString().padLeft(2,"0")}:${ts.second.toString().padLeft(2,"0")} $msg';
    _resumeLog.add(entry);
    if (_resumeLog.length > _kResumeLogCap) _resumeLog.removeAt(0);
    debugPrint('[RESUME-LOG] $entry');
  }
  // Tracks tab IDs inside a _reconnectWithRetry loop (including between retry
  // delays) to prevent a second retry chain from starting on the same tab.
  final _retrying = <String>{};
  // Interruptible sleep utility for retry delays in _reconnectWithRetry.
  // When connectivity changes or the periodic timer fires, wakeAll() unblocks
  // all waiting retry loops so they advance immediately instead of sleeping
  // for the full delay (up to 6 minutes worst case).
  final InterruptibleSleeper _retrySleepers = InterruptibleSleeper();
  // Tabs marked for one-shot foreground fast-path RWR. Set by
  // onForegroundResumed; consumed (removed) on the next _reconnectWithRetry
  // entry for that tab. See FastPathRegistry for semantics.
  final FastPathRegistry _foregroundFastPathRegistry = FastPathRegistry();
  // v2 liveness subscriptions, keyed by tab id. Cancelled on tab close /
  // before installing a new shell so we don't leak old transports.
  final _v2LivenessSubs = <String, StreamSubscription<v2iface.SspLivenessEvent>>{};
  // Exponential backoff state for _reconnectSshForMosh.
  final _sshForMoshRetryCount = <String, int>{};
  final _sshForMoshRetryAfter = <String, DateTime>{};
  // Per-tab rate limiter for v2 staleness probes in _reconnectDisconnected.
  // Cleared on tab close so a re-added tab starts fresh.
  final _lastV2ProbeAt = <String, DateTime>{};
  // Polls SSH client.isClosed every 5s to detect dead connections that dartssh2
  // keepalive marked as closed before the next connectivity event fires.
  Timer? _isClosedPollTimer;

  /// Per-tab timers that fire kBannerDelay after _reconnectWithRetry starts.
  /// Cancelled if reconnect completes before the timer fires, so fast
  /// RESUME paths never trigger the "reconnecting" overlay.
  final _bannerTimers = <String, Timer>{};
  // Records the last time we detected a meaningful network comeback (type change
  // or app resume after ≥30 s pause). Used to bypass the cascade cooldown in
  // _reconnect so that connections recover immediately when the network returns
  // rather than waiting up to 30 s for the cooldown delay.
  DateTime? _lastNetworkComebackTime;
  // Per-tab reconnect round counter — incremented on every _reconnectWithRetry
  // invocation and reset on successful connect.  Written to the terminal log so
  // we can correlate round N with the attempt that finally succeeds (or doesn't).
  final _reconnectRound = <String, int>{};
  // Parsed SSH key pair cache, keyed by SSHKeyRepository key ID.
  // Avoids re-parsing PEM on every reconnect (RSA 4096 parsing: ~100–200 ms).
  // Cleared on stop() so stale key material does not outlive the session.
  final _keyPairCache = <String, List<SSHKeyPair>>{};
  // Inflight credentials-load dedup, keyed by server id.
  // 多个 tab 同时 reconnect 同一 server 时（c1.jpg 两 tab 同时 DISC 是典型），
  // 4 个串行 SecureStorage 调用 (findById + key/password + jump + agent) 会
  // 各跑一遍，Android Keystore mutex 把它们串成 0.5-2s 的额外延迟，挤压
  // RESUME 时间预算。inflight dedup 让并发请求共享一次加载。
  final _credsInflight = <String, Future<_ServerCreds>>{};

  // 4-step smooth curve. Step 1 (50 ms) catches transient TCP/UDP blips
  // that 100 ms would already miss; step 3 (800 ms) handles 4G handshake
  // latency that previously fell off the cliff into the 3 s tail.
  static const _kRetryDelays = [
    Duration(milliseconds: 50),
    Duration(milliseconds: 200),
    Duration(milliseconds: 800),
    Duration(seconds: 3),
  ];

  // Fast path (network-comeback / proactive failure triggers): aim for
  // sub-second total wait.
  static const _kFastRetryDelays = [
    Duration(milliseconds: 50),
    Duration(milliseconds: 150),
    Duration(milliseconds: 500),
  ];


  static List<Duration> get debugRetryDelays => _kRetryDelays;

  static List<Duration> get debugFastRetryDelays => _kFastRetryDelays;

  /// Choose a RESUME budget based on observed PathStats. Weak-network
  /// path (rtt > 200 ms) gets the longer budget; proactive elsewhere.
  ///
  /// **只服务 proactive 这一条路径** —— 唯一调用点是 [_doResumeAttemptDetailed]。
  ///
  /// 这条路径确实没有竞速伙伴（工厂层的 `_reconnectRace` 会在
  /// [AqtTransportFactory.kBootstrapBackupDelay] 处并行拉起 bootstrap，这里
  /// 直接调 `tryResumeWithInfoDetailed`，什么都没有），所以等满 budget 是纯
  /// 呆滞。但**解法不是给它一个更小的 budget** —— 那只会让它更早地误判失败，
  /// 转进 15–25s 的 SSH 全量链。收紧过一次，翻车了，完整推导见
  /// `AqtTransportFactory` 里 kProactiveResumeTimeout 那段墓志铭。
  Duration _selectResumeBudget(SessionTab tab) {
    final aqt = tab.transport;
    if (aqt is! AqtTransport) {
      return AqtTransportFactory.kDefaultResumeTimeout;
    }
    return _selectResumeBudgetForRtt(aqt.lastPathStats);
  }

  /// **rtt 不是服务端有多忙的代理指标。** 见
  /// [AqtTransportFactory.kWeakNetworkResumeTimeout] 的盲区说明：真机现场
  /// rtt 97ms 而握手段 1273ms。想按「慢」分档就得换判据（例如观测到的
  /// `hs` 段分位数），照着 rtt 调只会调错方向。
  static Duration _selectResumeBudgetForRtt(PathStats p) {
    return p.rttMs > 200
        ? AqtTransportFactory.kWeakNetworkResumeTimeout
        : AqtTransportFactory.kDefaultResumeTimeout;
  }


  static Duration debugSelectResumeBudgetForRtt(PathStats p) =>
      _selectResumeBudgetForRtt(p);

  /// Per-attempt timeout for `_reconnect()`. First attempt is aggressive
  /// (15 s) so a single dead-network case doesn't burn an outer budget;
  /// subsequent attempts get 30 s for slow handshakes (4G TLS + bootstrap).
  static const Duration _kReconnectTimeoutFast = Duration(seconds: 15);
  static const Duration _kReconnectTimeoutDefault = Duration(seconds: 30);

  static Duration _selectReconnectTimeout({required bool firstAttempt}) =>
      firstAttempt ? _kReconnectTimeoutFast : _kReconnectTimeoutDefault;


  static Duration debugSelectReconnectTimeout({required bool firstAttempt}) =>
      _selectReconnectTimeout(firstAttempt: firstAttempt);

  /// Master switch for v2 mosh soft reconnect.
  ///
  /// When `true`, [_trySoftMoshReconnect] first attempts to reuse the existing
  /// mosh-server (new UDP socket, same OCB key) and only falls back to a full
  /// re-handshake (kill server + new SSH + new mosh-server) if the soft path
  /// fails its alive-check. Saves ~3–10 s recovery time + scrollback.
  ///
  /// Re-enabled 2026-05-12 after the f16/f19 "succeeded but frozen" failure
  /// mode was eliminated. The prior gate (`authenticatedPackets.first`, OCB
  /// pass only) accepted packets that subsequently chain-dropped at the
  /// receiver, leaving the UI live but the terminal frozen. The current gate
  /// ([MoshV2Connection.firstAppliedPacket]) only completes when the receiver
  /// actually applies a diff — proves state machines are aligned. Receiver-
  /// stuck triggers (reason contains 'stuck') still skip soft and go directly
  /// hard via [_v2FallbackToFullReconnect] since soft against the same server
  /// reproduces the divergence.
  ///
  /// Lock-leak guards landed in the same change:
  ///   * Bug 1: `_killServer.stdout.drain` now has a 3 s timeout.
  ///   * Bug 2: `_v2FallbackToFullReconnect` wraps close in try/finally.
  ///   * Bug 4: success path split into Phase 1 (verify) / Phase 2 (install);
  ///     Phase 2 holds `_reconnecting` inside try/finally.
  ///
  /// Flip to `false` if a "soft success but frozen" regression appears; check
  /// `firstInstDump` + `receiverLastBranch` in the debug overlay to confirm
  /// the symptom first.
  ///
  /// Public so the debug overlay can surface the active value — flipping it
  /// requires a rebuild, but the displayed flag still helps when triaging
  /// reconnect behaviour across multiple test devices.
  static const bool kSoftReconnectEnabledV2 = true;

  /// Heartbeat probe wait before deciding the QUIC path is dead.
  /// 150 ms covers typical mobile RTTs (< 80 ms) with headroom while
  /// being short enough that hard interface-down events (synchronous
  /// ENETUNREACH) don't waste 350 ms unnecessarily.
  static const Duration kProbeWaitDuration = Duration(milliseconds: 150);

  /// QUIC 的 `max_idle_timeout`。**必须与 `rust/aqt_client_ffi/src/client.rs`
  /// 和 `rust/flyterm-server/src/endpoint.rs` 保持同步** —— 生效值是两端
  /// 通告值的最小值，任一侧漂移都会让这里的判据失真。
  static const Duration kQuicIdleTimeout = Duration(seconds: 90);

  /// 恢复前要不要先探测旧连接。
  ///
  /// 判据来自协议参数而不是经验值：后台不足 [kQuicIdleTimeout] 的连接有
  /// 活着的可能，150ms 探测远比一次 RESUME 便宜；超过它服务端必已关闭，
  /// 探测是纯浪费。
  ///
  /// 旧实现是硬编码的 30s，两端都不对：30~90s 的健康连接被白白丢弃重连，
  /// 而 >90s 的必死连接仍要走一遍试探流程。
  ///
  /// **两个入口（onForegroundResumed 与 didChangeAppLifecycleState）必须
  /// 共用这个函数。** 判据分叉本身就是 bug —— 同一次回前台若一个入口判
  /// 「探测」另一个判「不探测」，先到的那个赢，行为随调度顺序摇摆。
  ///
  /// [backgroundFor] 为 null 表示这次不是从后台回来（网络切换等），
  /// 此时无从判断旧连接死活，探测是最省的做法。
  static bool shouldProbeBeforeResume(Duration? backgroundFor) {
    if (backgroundFor == null) return true;
    return backgroundFor < kQuicIdleTimeout;
  }

  /// periodic sweep 要不要跳过这个 tab。
  ///
  /// 三个集合缺一不可。漏掉 `proactiveResuming` 的后果是：廉价 RESUME 在飞
  /// 时，一次 periodic sweep 就能把同一个 tab 推进全量重连链 —— 用 15~25s
  /// 的 SSH bootstrap 抢跑一条几百毫秒就能完成的路径。
  ///
  /// 抽成纯函数是为了能 device-free 测（与 [decideResumeRetry] /
  /// [shouldProbeBeforeResume] 同一模式）：守卫条件是那种"少写一个就静默
  /// 退化"的逻辑，靠集成测试很难覆盖到。
  static bool shouldSkipPeriodicSweep({
    required bool reconnecting,
    required bool retrying,
    required bool proactiveResuming,
  }) =>
      reconnecting || retrying || proactiveResuming;

  /// 状态机之外发起的 RESUME 该不该放弃 —— [_proactiveResumeAqtTab] 的入口守卫。
  ///
  /// 与 [shouldSkipPeriodicSweep] 同一模式（static 纯函数、device-free 可测），
  /// 理由也一样：这是"少写一个条件就静默退化"的逻辑，而它退化的后果是 a6.jpg
  /// —— 同一 tab 两条并发 RESUME 都拿到 ACK，服务端的 PTY 流留在客户端丢掉的
  /// 那条上，体征全绿而屏幕不动。
  ///
  /// [fromMachine] 为真时 [machineInFlight] **必须放行**：那一次是状态机派发
  /// `StartResume` 后回调进来的，`_enterRecovering` 已经把 `inFlight` 置起来了，
  /// 拦下去等于状态机把自己掐死 —— 这个 tab 再也恢复不了。
  ///
  /// [reconnectInFlight] 是另一个互斥对象，[fromMachine] **穿不过**它：SSH 全量
  /// 重连链已经在跑。2026-09-05 18:49 现场就是这一条漏掉的后果 ——
  ///
  /// ```
  /// 49:05.070 #29← FAIL networkTimeout   escalate 同时做了两件事：
  ///                                        a) ConnectFailed → backoff 1000ms
  ///                                        b) _reconnectWithRetry → SSH 全量链
  /// 49:06.082 #30→ proactive/live        backoff 到期，状态机重发
  /// 49:11.082 #30← FAIL networkTimeout   又白烧 5s
  /// 49:11.807 #31→ fullreconn            全量链跑完
  /// ```
  ///
  /// #30 没有任何上行空间：全量链自带 preSsh + fullreconn 两次 RESUME，它补不了
  /// 任何缺口；失败就白烧一个 budget，成功反而要和全量链的 `_installAqtTransport`
  /// 抢装配 —— 那正是 a6.jpg 的形状。
  ///
  /// 三个参数缺一不可，判据必须同时看全部，不能只看其中之一。
  static bool shouldSkipExternalResume({
    required bool fromMachine,
    required bool machineInFlight,
    required bool reconnectInFlight,
  }) =>
      reconnectInFlight || (!fromMachine && machineInFlight);

  /// 被 [shouldSkipExternalResume] 拦下时，该不该替谁把 `inFlight` 清掉。
  ///
  /// 加了 [reconnectInFlight] 之后 `fromMachine` 那一条**也会**被拦，而它的
  /// `inFlight` 是 `_enterRecovering` 刚置上去的、本次调用是唯一的清位人。拦下
  /// 就 return 而不清，`inFlight` 永远停在 true，这个 tab 之后再也发不出恢复
  /// —— 并发 bug 换成永久死锁，比原病更重。
  ///
  /// 反过来，外部发起被拦时 `inFlight` 是**别人**置的，别人的 finally 会清。
  /// 替他放锁就等于把守卫拆了，回到 a6.jpg。
  static bool shouldSettleOnSkip({required bool fromMachine}) => fromMachine;

  /// Gaps between successive cheap-RESUME attempts, i.e. attempts land at
  /// t = 0 / 0.5 s / 1.5 s / 3 s — deliberately the same cadence as the Mosh
  /// heartbeat volley in [_onConnectivityChanged].
  ///
  /// Why more than one attempt: Android fires the connectivity event BEFORE
  /// the routing table is updated (same reason the Mosh path re-probes four
  /// times), so the first RESUME after a network comeback routinely fails in
  /// milliseconds with ENETUNREACH — the path simply isn't ready yet. QUIC
  /// used to give up after that single failure (two only if the path died
  /// mid-attempt) and fall into the SSH bootstrap chain, which costs 15-25 s.
  /// A RESUME is 0-RTT and needs no SSH, so several of them are far cheaper
  /// than one premature escalation.
  static const List<Duration> kResumeRetryGaps = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1000),
    Duration(milliseconds: 1500),
  ];

  /// Total wall-clock budget for the cheap-RESUME retry window above.
  ///
  /// This is what keeps the retries honest. Attempts are serialized and each
  /// carries the full [_selectResumeBudget] (up to 14 s on weak links), so a
  /// SLOW failure blows past this window on its own and escalates immediately
  /// — only FAST failures, which are exactly the routing-table-not-ready
  /// signature, ever get retried. Set just above the last attempt at 3 s.
  static const Duration kCheapResumeWindow = Duration(seconds: 4);

  /// C3 — Master switch for aggressive migration. When true, hard
  /// connectivity type-change skips the 150ms probe and runs an 800ms
  /// post-migration audit. When false, falls back to pre-C3 probe behavior.
  static const bool kAggressiveMigration = true;

  /// C3 — Window after migrate to confirm migration_count incremented.
  static const Duration kPostMigrationAuditDelay = Duration(milliseconds: 800);

  /// Delay before showing the reconnecting banner in _reconnectWithRetry.
  /// RESUME typically completes in 300–800 ms; hiding the banner until
  /// 1500 ms makes fast recovery paths completely invisible to the user.
  static const Duration kBannerDelay = Duration(milliseconds: 1500);

  /// QUIC freeze auto-recovery silent window. Used for `aqtRoamFail` /
  /// `aqtRoamException` triggers — proactive RESUME already failed, but
  /// the C2 race (RESUME ↔ bootstrap) typically wins in 3-5s. Show banner
  /// only if recovery hasn't completed within this window. Longer than kBannerDelay
  /// because the C2 fallback path is intrinsically slower than the
  /// normal first-attempt RESUME.
  static const Duration kQuicFreezeBannerDelay = Duration(milliseconds: 3000);

  /// Master switch for the QUIC freeze silent-recovery window. False
  /// reverts to the pre-fix behaviour: immediate banner on aqtRoamFail.
  static const bool kSilentQuicFreezeRecovery = true;

  final HostKeyVerifier? _hostKeyVerifier;
  final SshConnectionPool? _connectionPool;
  final TerminalSettings? _terminalSettings;
  final TransportFactory _transportFactory;
  // Nullable —— ReconnectService 本身没有
  // Database 引用，没法像旧 `AqtSessionStore()` 那样给个无参默认值；生产
  // 环境下 main.dart 总会注入，测试/非 QUIC 场景允许留空（对应调用点都已
  // 判空跳过）。
  final AqtSessionStateRepository? _aqtSessionStateRepo;
  final NotifySeenStore _notifySeenStore;

  ReconnectService(
    this._sessionManager,
    this._storage,
    this._serverRepo,
    this._keyRepo, {
    HostKeyVerifier? hostKeyVerifier,
    SshConnectionPool? connectionPool,
    TerminalSettings? terminalSettings,
    MoshProcessRepository? moshProcessRepo,
    TransportFactory? transportFactory,
    AqtSessionStateRepository? aqtSessionStateRepo,
    NotifySeenStore? notifySeenStore,
  }) : _hostKeyVerifier = hostKeyVerifier,
       _connectionPool = connectionPool,
       _terminalSettings = terminalSettings,
       _moshProcessRepo = moshProcessRepo,
       _transportFactory = transportFactory ?? CompositeTransportFactory(),
       _aqtSessionStateRepo = aqtSessionStateRepo,
       _notifySeenStore = notifySeenStore ?? NotifySeenStore();

  /// 测试专用构造：只装配回调字段与最小依赖，不启动任何监听/定时器。
  ///
  /// `ReconnectService` 的生产构造依赖 SessionManager / Repository / Storage，
  /// 正常路径都在 `start()` 之后才生效；本构造只让两条回调触发路径可以被
  /// 独立测试（[debugFeedNetworkType] / [onForegroundResumed]），不触碰
  /// AQT/Mosh 的任何既有逻辑。
  @visibleForTesting
  ReconnectService.forTest(
    SessionManager sessionManager,
    ServerRepository serverRepo,
    SSHKeyRepository keyRepo,
    SecureStorageService storage, {
    this.onNetworkTypeChanged,
    this.onForegroundResumedForSftp,
  })  : _sessionManager = sessionManager,
        _storage = storage,
        _serverRepo = serverRepo,
        _keyRepo = keyRepo,
        _moshProcessRepo = null,
        _hostKeyVerifier = null,
        _connectionPool = null,
        _terminalSettings = null,
        _transportFactory = CompositeTransportFactory(),
        _aqtSessionStateRepo = null,
        _notifySeenStore = NotifySeenStore();

  /// 是否应因网络**类型**变化而通知外部（SFTP 等）。
  ///
  /// 抽出为纯静态函数，让「只在类型变化时触发」这条判据可被独立测试；
  /// [_onConnectivityChanged] 与 [debugFeedNetworkType] 共用同一份判据。
  @visibleForTesting
  static bool shouldNotifyNetworkTypeChange(String? oldType, String newType) =>
      newType != oldType;

  /// 测试缝：仅喂入一个新的网络类型，复现 [_onConnectivityChanged] 里
  /// 「类型变化 → 触发回调」这一段，不触碰任何既有重连逻辑。
  @visibleForTesting
  void debugFeedNetworkType(String newType) {
    final oldType = _lastConnectivityType;
    _lastConnectivityType = newType;
    if (shouldNotifyNetworkTypeChange(oldType, newType)) {
      onNetworkTypeChanged?.call(newType, oldType);
    }
  }

  /// 持久化 QUIC session 元数据。在成功 connect/RESUME 后调用，
  /// 让冷启动也能 RESUME（前提：服务端 session 未过期且 PTY 仍活着）。
  ///
  /// 同时把服务端刚下发的 TTL / scrollback 游标写回去（RESUME 路径才有；
  /// 全新 HELLO 连接没有这两个值，下面用 `?? existing.xxx` 保留上一次已知
  /// 值而不是拿 0/null 冲掉它）。**关键约束**：一旦刷新 serverTtlSecs，
  /// savedAt 必须同一次写操作里刷新成 DateTime.now() ——服务端的过期计时
  /// 是从最后一次 touch()（即这次成功 RESUME/连接）算起的
  /// （`rust/flyterm-server/src/session.rs` 的 `AqtSession::touch`），不是从
  /// 会话创建算起。只刷 TTL 不刷 savedAt，`AqtSessionState.isExpired` 会
  /// 拿一个早已过时的起点去算，把刚被服务端续期的会话误判为过期。
  Future<void> _persistAqtSession(SessionTab tab) async {
    final repo = _aqtSessionStateRepo;
    if (repo == null) return;
    final aqt = tab.transport;
    if (aqt is! AqtTransport) return;
    if (aqt.lastPort == null) return;
    try {
      final existing = await repo.load(tab.id);
      final state = sessionStateFor(
        aqt,
        tabId: tab.id,
        existing: existing,
        ttlSecs: aqt.resumeTtlSecs,
      );
      if (state != null) await repo.save(state);
    } catch (_) {}
  }

  /// tabId → 该 tab 的连接状态机 runner。
  /// 取代 `_reconnecting` / `_retrying` / `_proactiveResuming` 三个集合。
  final _runners = <String, AqtConnRunner>{};

  /// 状态机唯一的定时器。取代 `_periodicRetryTimer` / `_resumeCheckTimer` /
  /// `_connectivityDebounceTimer` / `_isClosedPollTimer` 四个。
  final _machineTicks = <String, Timer?>{};

  /// `SessionTab.transport` 变更时建/拆 runner。
  ///
  /// 这是 runner 的**唯一**创建点 —— 全仓库 6 个 transport 赋值点都经这里，
  /// 包括首连（terminal_screen.dart:921）与 prewarm 接管。
  void _onTabTransportChanged(SessionTab tab, RemoteTransport? next) {
    // 控制器绑死一个 transport：换了（包括 RESUME 换出来的新 transport）就
    // 销毁旧的、给新的另建一个。
    _disposePathController(tab.id);
    if (next is! AqtTransport) {
      _teardownRunner(tab.id);
      return;
    }
    _runners[tab.id] = AqtConnRunner(
      onProbe: next.heartbeat,
      // 看门狗触发：不是"回到前台"也不是"网络变了"，环境判据在这里会
      // 猜错（多半猜成 connectivity），必须由调用方显式指定。
      //
      // 已知限制：状态机的 StartResume 有四个来源，其中「backoff 期间收到
      // ConnectivityChanged」其实是网络驱动而非看门狗驱动，这里会把它一并
      // 标成 watchdog。不修是因为要区分就得给 onResume 回调加事件来源参数、
      // 改动到 conn_runner/conn_machine 接口，而这个误标不影响任何分档统计
      // （watchdog 与 connectivity 都是 backgroundMs == null、不进桶），
      // 只影响导出文件里 trigger 这一列的精度。
      // fromMachine: 这一次是状态机派发 StartResume 的结果，_enterRecovering
      // 已经把 inFlight 置起来了。入口的守卫必须放它过去，否则状态机会把自己
      // 掐死（详见 _proactiveResumeAqtTab 入口注释）。
      onResume: () => unawaited(_proactiveResumeAqtTab(tab,
          source: ResumeTrigger.watchdog, fromMachine: true)),
      onBootstrap: () => unawaited(_reconnectWithRetry(tab)),
      // 放进 microtask：控制器在 disposed / 后台时会**同步**喂回
      // PathSwitchFailed，而这里正处在 runner.feed 的动作循环里 —— 重入会把
      // 两次 step 的动作交错执行。
      onPathSwitch: () => scheduleMicrotask(() {
        // transport 已被换掉：旧 runner 随之作废，不需要回音。
        if (!identical(tab.transport, next)) return;
        final c = _pathControllers[tab.id];
        if (c != null) {
          unawaited(c.onStartPathSwitch());
        } else {
          // canSwitchPath 要求控制器存在，正常走不到这里；万一走到，也得给状态机
          // 一个回音，否则它一直以为切换在途。
          final t = tab.transport;
          if (t is AqtTransport) {
            _runners[tab.id]
                ?.feed(const conn.PathSwitchFailed(), _factsFor(tab, t));
          }
        }
      }),
      onClose: next.close,
      onBanner: (code) => _setReconnectMessage(
        tab,
        ReconnectUiMessageCode.values.firstWhere((c) => c.name == code),
      ),
      onClearBanner: () {
        tab.reconnectUiMessage = null;
        _sessionManager.notifyTabChanged();
      },
      scheduleTick: (ms) {
        _machineTicks[tab.id]?.cancel();
        _machineTicks[tab.id] =
            Timer(Duration(milliseconds: ms), () => _feedTick(tab));
      },
      cancelTick: () {
        _machineTicks[tab.id]?.cancel();
        _machineTicks[tab.id] = null;
      },
    );
    next.onWatchdogTick = () => _feedTick(tab);
    final ctl = AqtPathController(
      transport: next,
      openRelay: (p) => openAqtRelay(tab, p),
      resolveDirect: () => _resolveDirect(tab, next),
      // 只认自己那个 transport：已被换掉的话，迟到的事件不属于新 runner。
      feed: (e) {
        if (!identical(tab.transport, next)) return;
        _runners[tab.id]?.feed(e, _factsFor(tab, next));
      },
      // 路线变了 → aqt_session_state.via_ssh 跟着变，冷启动 RESUME 才会走对路。
      onRouteChanged: () {
        if (identical(tab.transport, next)) unawaited(_persistAqtSession(tab));
      },
      isForeground: () => _isForegroundNow,
      // 「总是走 SSH 通道」的服务器只走中继，绝不探测切回直连。
      directAllowed: () => !tab.server.aqtViaSsh,
    );
    _pathControllers[tab.id] = ctl;
    ctl.start();
    // 刻意不在这里喂 ConnectedOk —— 「连上了」的语义应当是「已接好线、能收
    // 数据」，由 _installAqtTransport 在 startStreaming 之后喂。
  }

  /// tabId → 该 tab 当前 AQT transport 的路线控制器（直连 ↔ SSH 中继，同一条
  /// QUIC 连接内换路）。与 transport 同生共死，见 [_onTabTransportChanged]。
  final _pathControllers = <String, AqtPathController>{};

  void _disposePathController(String tabId) {
    _pathControllers.remove(tabId)?.dispose();
  }

  /// 直连目的地址：服务器域名解析出的第一个 IPv4，端口是 daemon 端口。
  /// 每次调用都重新解析（控制器自己缓存，换网时清掉）。
  Future<({String ip, int port})?> _resolveDirect(
      SessionTab tab, AqtTransport t) async {
    final port = t.lastPort;
    if (port == null) return null;
    try {
      final addrs = await InternetAddress.lookup(tab.server.host,
          type: InternetAddressType.IPv4);
      if (addrs.isEmpty) return null;
      return (ip: addrs.first.address, port: port);
    } catch (e) {
      // 离线 / DNS 未就绪：按控制器的约定返回 null（「解析不了」），下次再试。
      debugPrint('[AqtPath] resolve ${tab.server.host} failed: $e');
      return null;
    }
  }

  void _teardownRunner(String tabId) {
    _disposePathController(tabId);
    _machineTicks[tabId]?.cancel();
    _machineTicks.remove(tabId);
    _runners.remove(tabId);
  }

  conn.Facts _factsFor(SessionTab tab, AqtTransport t) => readFacts(
        nowMs: DateTime.now().millisecondsSinceEpoch,
        rawRecvAgeMs: t.lastRecvAgeMs,
        rebindCount: t.lastPathStats.rebindingCount,
        isForeground: _isForegroundNow,
        networkType: _lastConnectivityType ?? 'wifi',
        // 只在前台、非强制中继、且这条 transport 有控制器时才允许换路。
        canSwitchPath: _isForegroundNow &&
            !tab.server.aqtViaSsh &&
            _pathControllers[tab.id] != null,
        // 与 rawRecvAgeMs 并列的第二个活性维度：前者数入向 UDP 字节（ACK /
        // keepalive / 心跳 datagram 都算），后者只在真正收到 PTY 数据时归零。
        // stream 停摆而连接层照常喘气时，只有后者看得见。
        ptySilenceMs: t.lastPtyDataAge.inMilliseconds,
        sinceLastWriteMs: t.sinceLastWrite?.inMilliseconds,
      );

  void _feedTick(SessionTab tab) {
    final t = tab.transport;
    if (t is! AqtTransport) return;
    _runners[tab.id]?.feed(const conn.WatchdogTick(), _factsFor(tab, t));
    // 熔断那一刻的序列最值钱 —— 立刻落盘，别等切后台。
    if (_runners[tab.id]?.state.phase == conn.ConnPhase.givenUp) {
      unawaited(exportConnTrace(tab.id));
      // 样本环只有 64 条（conn-trace 是 512），一段抖动期的反复重连很容易
      // 把熔断前那些记录着失败恢复的样本挤出去 —— 而那恰恰是最该留下的。
      // 所以熔断这一刻也落一次盘，与 conn-trace 的双触发点对称。
      unawaited(exportResumeSamples());
    }
  }

  /// 最近一次轨迹落盘的路径与行数，供 debug overlay 只读显示。
  String? lastTraceExportPath;
  int lastTraceExportLines = 0;

  /// 恢复耗时样本。**只喂诊断**，不参与任何决策。
  final resumeSamples = ResumeSampleLog();

  /// 在途的恢复 span，按 tab 记。恢复闭合或放弃时移除。
  final _resumeSpans = <String, ResumeSpan>{};

  /// 上次进后台的时刻，用于给样本标注 backgroundMs。与 [_lastPauseTime]
  /// 分开：那个字段在 resumed 分支里被多处判读，这里需要的是「闭合样本时
  /// 仍然可读」的快照值。
  final _bgEnteredAt = <String, DateTime>{};

  /// `_bgEnteredAt` 的延时清理 timer。**重排前必须先取消上一个。**
  ///
  /// 不取消的话，「后台→前台→后台→前台」这种 10 秒内的快速切换会让第一次
  /// 排下的 clear 把第二次刚写入的新鲜条目一并清空 —— 那次恢复就会被误标成
  /// connectivity 触发、backgroundMs 记为 null，样本不进任何分档。而前台恢复
  /// 的分档基线正是这套设施要产出的东西。
  Timer? _bgClearTimer;

  /// 某个 tab 的状态机当前阶段名，供 debug overlay 只读显示。
  /// 返回 null 表示该 tab 没有 runner（非 AQT，或还没附着）。
  String? runnerPhaseOf(String tabId) => _runners[tabId]?.state.phase.name;

  /// 把某个 tab 的状态机轨迹写到 app 私有目录。
  ///
  /// **事件驱动，不做周期落盘** —— 触发点只有两个：切后台（用户刚做完操作要
  /// 离开，且 app 随时可能被系统杀掉，这是最后的机会）与进 givenUp（最需要
  /// 现场的时刻）。周期写会带来 IO 抖动，而排查需要的是"出事那一刻的序列"，
  /// 不是流水账。
  ///
  /// 为什么不做成按钮：debug overlay 外层是 IgnorePointer，收不到点击，而那
  /// 是刻意设计（面板不可交互、不可滚），不该为加按钮去动它。
  ///
  /// 轨迹只含事件名、时间与 facts 的数值，不含任何终端内容（见 conn_trace.dart）。
  Future<String?> exportConnTrace(String tabId) async {
    final r = _runners[tabId];
    if (r == null || r.trace.lines.isEmpty) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/conn-trace-$tabId.txt');
      await f.writeAsString(r.trace.export());
      lastTraceExportPath = f.path;
      lastTraceExportLines = r.trace.lines.length;
      _sessionManager.notifyTabChanged();
      return f.path;
    } catch (e) {
      // 落盘失败不能连累重连本身 —— 它只是诊断设施。
      _logResume('[${_shortTabId(tabId)}] trace export failed: $e');
      return null;
    }
  }

  /// 最近一次样本落盘的路径与条数，供 debug overlay 只读显示。
  String? lastSampleExportPath;
  int lastSampleExportCount = 0;

  /// 把恢复耗时样本写到 app 私有目录。
  ///
  /// **独立文件，不混进 conn-trace** —— 后者的行格式与
  /// `conn_test_dsl.dart` 的 `machineCase` 输入是一一对应的契约（见
  /// `conn_trace.dart` 头部），塞进异构行会断掉「真机轨迹直接粘成回归
  /// 用例」这条链路。
  ///
  /// 只含数值与枚举名，不含任何终端内容。
  Future<String?> exportResumeSamples() async {
    // 守卫要认 probeHits：命中不进样本环（它没有五段耗时），但「整轮都是
    // 探测命中」恰恰是 90s 阈值赌注成立时的典型形态 —— 那时 samples 为空，
    // 只看 samples 就会一个文件都不写，赌注越成立数据丢得越干净。判据挪进
    // ResumeSampleLog.hasAnythingToExport，好处是它能被直接测试。
    if (!resumeSamples.hasAnythingToExport) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      String? path;
      // samples 可能为空（整轮都是探测命中）——这种情况下不写空的
      // resume-samples.txt，只写下面的命中兄弟文件。
      if (resumeSamples.samples.isNotEmpty) {
        final f = File('${dir.path}/resume-samples.txt');
        await f.writeAsString(resumeSamples.export());
        lastSampleExportPath = f.path;
        lastSampleExportCount = resumeSamples.samples.length;
        path = f.path;
      }
      // 命中数单独成文件，不混进 resume-samples.txt —— 后者是「一行一样本」
      // 的定列格式，而命中是「每档一个标量」，塞进去会破坏解析契约。这与
      // 当初把 resume-samples 从 conn-trace 里分出来是同一个理由。
      if (resumeSamples.probeHits.isNotEmpty) {
        final hf = File('${dir.path}/resume-probe-hits.txt');
        await hf.writeAsString(resumeSamples.probeHits.entries
            .map((e) => '${e.key.name} ${e.value}')
            .join('\n'));
        // 整轮都是探测命中时主文件没写，overlay 那行就该指向命中文件 ——
        // 否则「赌注成立」这个最该被看见的场景，反而看不出落盘去了哪，
        // 而真机检查点正是靠这个路径去 adb pull 的。
        if (resumeSamples.samples.isEmpty) {
          lastSampleExportPath = hf.path;
          lastSampleExportCount = 0;
        }
        path ??= hf.path;
      }
      return path;
    } catch (e) {
      // 落盘失败不能连累重连本身 —— 它只是诊断设施。
      _logResume('resume sample export failed: $e');
      return null;
    }
  }

  // 防并发预热：同一 tab 不要同时开多个 SSH 客户端
  final _warmingUpSsh = <String>{};

  /// 上次**自动**重新预热的时刻，按 tab 记。用于限流。
  final _lastAuxRewarm = <String, DateTime>{};

  /// 自动重建辅助连接的冷却窗口。防「建成→秒死→重建」打转：服务端若在拒绝
  /// 新连接（MaxStartups、防火墙、重启中），无限重试只会拖垮服务器和电池。
  /// 冷却期内断开就不再自动重建，等下一次 RESUME / 重连顺带把它带起来。
  static const _kAuxRewarmCooldown = Duration(seconds: 30);

  /// 辅助 SSH 断开后安排一次重新预热。
  ///
  /// 没有这条路径的话，SSH 一断就得等到下次 RESUME / 重连（`registerAqtTab`）
  /// 才会重新预热 —— 而 QUIC 主通道**不会**因为 SSH 断开而重连，两者完全独立。
  /// 那段真空期里 SFTP 和 agent 只能各自新开连接（慢）或直接失败。
  void _scheduleAuxRewarm(SessionTab tab) {
    if (!_sessionManager.tabs.contains(tab)) {
      _lastAuxRewarm.remove(tab.id);
      return;
    }
    if (tab.transport is! AqtTransport) return;
    final tid = _shortTabId(tab.id);
    final now = DateTime.now();
    final last = _lastAuxRewarm[tab.id];
    if (last != null && now.difference(last) < _kAuxRewarmCooldown) {
      debugPrint('[AuxSSH][$tid] 断开，但距上次自动重建不足 '
          '${_kAuxRewarmCooldown.inSeconds}s → 跳过，等下次 RESUME');
      return;
    }
    _lastAuxRewarm[tab.id] = now;
    debugPrint('[AuxSSH][$tid] 连接断开 → 2s 后重新预热');
    // 2s 缓冲：断开常常与网络切换同时发生，立刻重连多半撞在切换中途。
    Future.delayed(const Duration(seconds: 2), () {
      if (!_sessionManager.tabs.contains(tab)) return;
      _warmupAuxSshClient(tab).ignore();
    });
  }

  /// 为 [tab] 的 SSH 通道会话（[AqtRoute.viaSsh]）开一条 relay，走一条**专属**
  /// SSH 连接，relay 关闭时一并断开。
  ///
  /// 不复用 `tab.connection`（辅助连接）：冷启动时 terminal_screen 会在同一个
  /// `SSHConnection` 上再调一次 `connect()`，而 `connect()` 第一步就是关掉现有
  /// client —— relay 骑在上面的话，刚恢复的会话随之断掉。等辅助连接预热也没有
  /// 可靠的终点（预热失败只留日志），曾经的轮询会一直转下去。专属连接两头都
  /// 避开，代价是会话期间多一条 SSH 连接。超时由调用方的 relay 预算兜住，
  /// 超时后才建好的 relay 会被关掉（见 tryResumeWithInfoDetailed）。
  Future<AqtSshRelay> openAqtRelay(SessionTab tab, int daemonPort) async {
    final creds = await _loadServerCreds(tab.server.id, tab.server);
    if (!_sessionManager.tabs.contains(tab)) {
      throw StateError('tab closed before its SSH relay opened');
    }
    final server = creds.server;
    final jump = creds.jump;
    final conn = SSHConnection();
    await conn.connect(
      host: server.host,
      port: server.port,
      username: server.username,
      password: creds.password,
      keyPairs: creds.keyPairs,
      jumpHost: jump?.host,
      jumpPort: jump?.port,
      jumpUsername: jump?.username,
      jumpPassword: jump?.password,
      jumpPrivateKeyPem: jump?.privateKeyPem,
      agentKeyPairs: creds.agentKeyPairs,
      openShell: false,
      firstAttempt: false,
      hostKeyVerifier: _hostKeyVerifier,
      // 不进连接池：池化的 client 是多个 tab 共享的，relay 关闭时要能整条断开。
      addressFamily: server.addressFamily,
      sshCompression: _sshCompression,
    );
    final client = conn.client;
    if (client == null) {
      await conn.close();
      throw StateError('SSH connection for the relay did not come up');
    }
    try {
      return await AqtSshRelay.start(client,
          daemonPort: daemonPort, onClose: () => unawaited(conn.close()));
    } catch (_) {
      await conn.close();
      rethrow;
    }
  }

  /// QUIC tab 后台预热 SSH 辅助连接，供 SFTP / tmux / tunnel 等需要 SSH 的
  /// 功能复用。fire-and-forget，失败不影响 QUIC 主路径。
  ///
  /// 用户从「QUIC 连上 → 点 SFTP」通常耗时 > 3s，足够让预热在后台完成。
  /// 这样 SFTP 入口能直接 `SFTPService.fromClient(已认证的client)`，跳过
  /// 2-4s 的完整 SSH 握手。
  Future<void> _warmupAuxSshClient(SessionTab tab) async {
    final tid = _shortTabId(tab.id);
    if (_warmingUpSsh.contains(tab.id)) {
      debugPrint('[AuxSSH][$tid] skip: 已在预热中');
      return;
    }
    final existing = tab.connection.client;
    if (existing != null && !existing.isClosed) {
      debugPrint('[AuxSSH][$tid] skip: 已有 client (isClosed=false)');
      return; // 已经有可用 client
    }
    debugPrint('[AuxSSH][$tid] start: existing=${existing == null ? "null" : "closed"}');
    final sw = Stopwatch()..start();
    _warmingUpSsh.add(tab.id);
    try {
      final creds = await _loadServerCreds(tab.server.id, tab.server);
      final server = creds.server;
      final password = creds.password;
      final keyPairs = creds.keyPairs;
      final jump = creds.jump;
      final agentKeyPairs = creds.agentKeyPairs;
      // 检查是否已被关闭/移除
      if (!_sessionManager.tabs.contains(tab)) {
        debugPrint('[AuxSSH][$tid] abort: tab 已移除');
        return;
      }
      // 二次检查 client（建连前可能已被其他路径建立）
      final recheck = tab.connection.client;
      if (recheck != null && !recheck.isClosed) {
        debugPrint('[AuxSSH][$tid] abort: 其他路径已建好 client');
        return;
      }
      debugPrint('[AuxSSH][$tid] dialing ${server.host}:${server.port} '
          'user=${server.username} keys=${keyPairs.length} '
          'agentKeys=${agentKeyPairs.length} pw=${password != null} '
          'jump=${jump != null} pooled=${server.keyId != null}');
      await tab.connection.connect(
        host: server.host,
        port: server.port,
        username: server.username,
        password: password,
        keyPairs: keyPairs,
        jumpHost: jump?.host,
        jumpPort: jump?.port,
        jumpUsername: jump?.username,
        jumpPassword: jump?.password,
        jumpPrivateKeyPem: jump?.privateKeyPem,
        agentKeyPairs: agentKeyPairs,
        openShell: false, // exec-only：不要 PTY，节省服务端资源
        firstAttempt: false,
        hostKeyVerifier: _hostKeyVerifier,
        pool: _connectionPool,
        keyId: server.keyId,
        jumpHostId: server.jumpHostId,
        addressFamily: server.addressFamily,
        sshCompression: _sshCompression,
      );
      // openShell:false 绕开了 connect() 内唯一的半死连接探测，这里显式验一次。
      // 不验的话，一条 isClosed==false 却开不出 channel 的连接会被挂到 tab 上，
      // SFTP 与 agent 随后都复用它 —— 两个功能一起废，且各自要等到自己的超时。
      if (!await tab.connection.verifyExecChannel()) {
        debugPrint('[AuxSSH][$tid] 验证失败 (${sw.elapsedMilliseconds}ms)：'
            '开不出 exec channel，已从池中剔除并丢弃');
        return;
      }
      debugPrint('[AuxSSH][$tid] OK (${sw.elapsedMilliseconds}ms) '
          'client=${tab.connection.client != null}');
      // 挂断开监听，让这条辅助连接能自愈。done 有两种完成方式（正常 close /
      // closeWithError），两条都要接住 —— 只写成功回调的话，异常断开（切网、
      // socket 出错）反而不会触发重建，而那恰恰是最常见的断开原因。
      final fresh = tab.connection.client;
      if (fresh != null) {
        unawaited(fresh.done
            .then((_) {}, onError: (_) {})
            .whenComplete(() => _scheduleAuxRewarm(tab)));
      }
    } catch (e) {
      // 预热失败不影响主路径，SFTP 会回退到 openDedicated()。
      // 但**必须留痕**：这里曾经是 `catch (_) {}`，预热失败零痕迹，
      // 导致「SFTP/agent 忽然不可用」在日志里完全无法回溯。
      debugPrint('[AuxSSH][$tid] FAIL (${sw.elapsedMilliseconds}ms): '
          '${e.runtimeType}: $e');
    } finally {
      _warmingUpSsh.remove(tab.id);
    }
  }

  bool get _sshCompression => _terminalSettings?.sshCompression ?? true;

  /// Returns true when ≥5 reconnects occurred in the last 5 minutes — cascade.
  ///
  /// [since]: when provided, only events AFTER this timestamp are counted.
  /// Pass [_lastNetworkComebackTime] so that failures on the previous network
  /// (before a WiFi→cellular or cellular→WiFi switch) are excluded — the old
  /// network's instability should not cause a cooldown on the new network.

  static bool shouldCooldown(List<ReconnectEvent> history, {DateTime? since}) {
    // 90 s window: at the 30 s cooldown interval max 3 events accumulate,
    // which is below the threshold=5, so the cycle breaks after one cooldown.
    // A 5-minute window was too wide — every 30 s cooldown added an event,
    // keeping the count ≥5 permanently and preventing SSH tabs from reconnecting.
    final cutoff = DateTime.now().subtract(const Duration(seconds: 90));
    final recent =
        history.where((e) {
          if (!e.at.isAfter(cutoff)) return false;
          if (since != null && !e.at.isAfter(since)) return false;
          // Only count failures — successful reconnects should not contribute to
          // the cooldown threshold.  A success means the network works; penalising
          // the next reconnect for a previous success wastes recovery time.
          if (e.succeeded) return false;
          return true;
        }).length;
    return recent >= 5;
  }


  static List<Duration> retryDelaysForTrigger(String trigger) {
    if (trigger.startsWith('connectivity/') ||
        trigger == 'appResume' ||
        trigger == 'dozeResume' ||
        trigger == 'isClosedPoll') {
      return _kFastRetryDelays;
    }
    return _kRetryDelays;
  }

  /// 按触发来源决定 banner 显示延迟。
  ///
  /// 设计原则：1.5s 静默窗口的前提是"系统自动触发 + 用户没主动发起 +
  /// 瞬时可自愈"。对不满足这些前提的 trigger 应立即显示，避免用户
  /// 等待无反馈或看到 banner 闪烁。
  ///
  /// • Duration.zero（立即显示）—— 已失败转级类：
  ///     - moshV2SoftFailed/full：soft 已经失败 1.5s+，不是"瞬时"，
  ///       full 阶段必然要花时间，无需再静默
  /// • kQuicFreezeBannerDelay（3s 静默）—— QUIC 卡死自动恢复：
  ///     - aqtRoamFail / aqtRoamException：proactive RESUME 失败，
  ///       但 C2 race（RESUME ↔ bootstrap）通常 3-5s 完成；3s 静默窗
  ///       让一半以上的卡死恢复"无感"
  /// • kBannerDelay（1.5s 静默）—— 默认：
  ///     - connectivity/typeChange、connectivity/settle：wifi↔cellular
  ///       漫游，多半 <1.5s 自愈
  ///     - appResume / dozeResume / isClosedPoll：后台唤醒，多半
  ///       RESUME 很快
  ///     - doneCb/init、doneCb/reconnect、aqtDead：真断开首次重试，
  ///       可能是瞬时 TCP reset，给一次静默机会

  static Duration bannerDelayForTrigger(String trigger) {
    if (trigger == 'moshV2SoftFailed/full') {
      return Duration.zero;
    }
    if (kSilentQuicFreezeRecovery &&
        (trigger == 'aqtRoamFail' || trigger == 'aqtRoamException')) {
      return kQuicFreezeBannerDelay;
    }
    return kBannerDelay;
  }

  /// 一次重连尝试的两项预算：多久后显示"重连中"横幅、失败后按什么曲线重试。
  ///
  /// **fastPath 只压缩重试，绝不让横幅提前。** 这两件事以前写在同一个三元
  /// 表达式里（`fastPath ? Duration.zero : bannerDelayForTrigger(trigger)`），
  /// 于是 fastPath 顺带拿到了"立即显示横幅"——而那句的注释"已失败转级类
  /// trigger：立即显示 banner"本来是给 moshV2SoftFailed/full 写的：软重连
  /// 已经失败、用户已经卡了一会儿，立刻给横幅是对的。
  ///
  /// fastPath 的语义正相反：App 刚回前台，先快速试一次，通常几百毫秒就成
  /// 了，是所有场景里最该安静的那个。横幅一提前点亮，`isReconnecting` 就为
  /// 真，成功后 `silentReconnect` 判定失效，于是弹出「已重新连接」——恰好
  /// 在"用户根本没察觉断过"的场景里冒出一个提示。
  ///
  /// 分开之后：fastPath 走正常的 [kBannerDelay]，几百毫秒成功时横幅计时器
  /// 还没到就被取消，全程静默；真慢过阈值才显示横幅，那时成功提示也合理。

  static ({Duration bannerDelay, List<Duration> retryDelays}) resumeUiBudget({
    required String trigger,
    required bool fastPath,
  }) =>
      (
        bannerDelay: bannerDelayForTrigger(trigger),
        retryDelays:
            fastPath ? const <Duration>[] : retryDelaysForTrigger(trigger),
      );

  void _setReconnectMessage(
    SessionTab tab,
    ReconnectUiMessageCode code, {
    Map<String, Object> args = const {},
    ReconnectUiMessageKind kind = ReconnectUiMessageKind.info,
    Duration? ttl,
  }) {
    tab.reconnectUiMessage = ReconnectUiMessage.localized(
      code: code,
      args: args,
      kind: kind,
      updatedAt: DateTime.now(),
      ttl: ttl,
    );
    _sessionManager.notifyTabChanged();
  }

  /// Write a cascade warning to the terminal once the threshold is crossed.
  /// Called immediately after every appendReconnect from the reconnect paths.
  void _maybeWarnCascade(SessionTab tab) {
    // QUIC tabs handle stability via proactive RESUME + lazy banner (1.5s).
    // Background heartbeat (5s) causes frequent reconnect events that easily
    // exceed the SSH/Mosh-calibrated threshold of 3 in 5 min, producing
    // spurious "网络不稳定" warnings. QUIC's own mechanisms provide adequate
    // user feedback without cascade noise.
    if (tab.server.transport == Transport.quic) return;
    final cutoff = DateTime.now().subtract(_kCascadeWindow);
    final recent =
        tab.reconnectHistory.where((e) => e.at.isAfter(cutoff)).length;
    if (recent < _kCascadeWarnThreshold) return;
    final proto = tab.isMosh ? 'mosh' : 'SSH';
    _setReconnectMessage(
      tab,
      ReconnectUiMessageCode.reconnectCascadeWarning,
      args: {
        'protocol': proto,
        'count': recent,
        'minutes': _kCascadeWindow.inMinutes,
      },
      kind: ReconnectUiMessageKind.warning,
      ttl: const Duration(seconds: 5),
    );
  }

  /// Detect a self-perpetuating reconnect loop and refuse to schedule
  /// another attempt automatically. Returns true if the breaker tripped.
  bool _circuitBreakerTripped(SessionTab tab) {
    final cutoff = DateTime.now().subtract(_kCascadeBreakerWindow);
    final recent =
        tab.reconnectHistory.where((e) => e.at.isAfter(cutoff)).toList();
    if (recent.length < _kCascadeBreakerThreshold) return false;
    final allSoftAndSucceeded = recent.every(
      (e) => e.kind == ReconnectKind.soft && e.succeeded,
    );
    if (!allSoftAndSucceeded) return false;
    final proto = tab.isMosh ? 'mosh' : 'SSH';
    _setReconnectMessage(
      tab,
      ReconnectUiMessageCode.reconnectLoopDetected,
      args: {'protocol': proto},
      kind: ReconnectUiMessageKind.error,
    );
    tab.connectionError = '$proto: cascade detected';
    return true;
  }

  /// 把 connectivity_plus 的结果集合归类为一个字符串：
  /// "vpn" / "wifi" / "cellular" / "ethernet" / "none"。
  /// 信号强度变化 / 同类型 SSID 切换不会改变返回值。

  static String classifyNetwork(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.vpn)) return 'vpn';
    if (results.contains(ConnectivityResult.wifi)) return 'wifi';
    if (results.contains(ConnectivityResult.mobile)) return 'cellular';
    if (results.contains(ConnectivityResult.ethernet)) return 'ethernet';
    return 'none';
  }

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _sessionManager.addTabClosedListener(_onTabClosed);
    // 诊断埋点（不是修复）——把 SessionTab.startStreaming() 的调用点接进既有
    // 的 _logResume（debug overlay 的 verbose 日志），用于验证"二次装配"假设。
    // 见任务 #53 / #55、session_manager.dart 里 debugAqtStartStreamingHook
    // 的文档。只接一次；start() 本身也只应调用一次。
    SessionTab.debugAqtStartStreamingHook =
        (tabId, source, sentLastOutOff, lastResumeReplayBytes) {
      final tid = _shortTabId(tabId);
      _logResume('[$tid] STREAM src=$source sentOff=${sentLastOutOff ?? "-"} '
          'replay=$lastResumeReplayBytes');
    };
    SessionTab.onTransportChanged = _onTabTransportChanged;
    // Seed _lastConnectivityType so the first stream event does not spuriously
    // trigger typeChanged=true (which would fire heartbeat bursts on startup).
    Connectivity().checkConnectivity().then((results) {
      _lastConnectivityType ??= classifyNetwork(results);
    });
    _sub = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    // Periodic fallback for networks with packet loss but no connectivity
    // change events (e.g. WiFi with intermittent drops). After all retry
    // attempts are exhausted, this timer ensures dead tabs are retried every
    // 30 s instead of staying permanently stuck until the user backgrounds the
    // app or the connectivity state changes.
    _periodicRetryTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _reconnectDisconnected(),
    );
    // Poll SSH client.isClosed every 2s: dartssh2 marks the client closed when
    // keepalive pings fail. Without this poll the death goes undetected until
    // the next connectivity event or lifecycle event.
    _isClosedPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      for (final tab in _sessionManager.tabs) {
        if (tab.isMosh) continue;
        if (tab.localShell != null) continue;
        if (tab.server.serverType == 'local') continue;
        // QUIC tabs use UDP for PTY I/O; the SSH client is only used for
        // bootstrap. SSH dying after a network switch is normal and does NOT
        // mean the QUIC session is dead. QUIC death is detected by its own
        // onDisconnected callback (Rust conn.closed() monitor).
        if (tab.transport?.kind == TransportKind.aqt) continue;
        if (tab.connection.client?.isClosed == true &&
            !tab.isReconnecting &&
            !_reconnecting.contains(tab.id) &&
            !_retrying.contains(tab.id)) {
          _reconnectWithRetry(tab, trigger: 'isClosedPoll');
        }
      }
    });
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionManager.removeTabClosedListener(_onTabClosed);
    SessionTab.onTransportChanged = null;
    for (final id in _machineTicks.keys.toList()) {
      _teardownRunner(id);
    }
    for (final id in _pathControllers.keys.toList()) {
      _disposePathController(id);
    }
    _sub?.cancel();
    _sub = null;
    _periodicRetryTimer?.cancel();
    _periodicRetryTimer = null;
    _resumeCheckTimer?.cancel();
    _resumeCheckTimer = null;
    _connectivityDebounceTimer?.cancel();
    _connectivityDebounceTimer = null;
    _isClosedPollTimer?.cancel();
    _isClosedPollTimer = null;
    _bgClearTimer?.cancel();
    _bgClearTimer = null;
    for (final t in _bannerTimers.values) {
      t.cancel();
    }
    _bannerTimers.clear();
    _lastNetworkComebackTime = null;
    _keyPairCache.clear();
    _lastV2ProbeAt.clear();
    for (final s in _v2LivenessSubs.values) {
      s.cancel();
    }
    _v2LivenessSubs.clear();
    _reconnecting.clear();
    _retrying.clear();
    _reconnectRound.clear();
    _sshForMoshRetryCount.clear();
    _sshForMoshRetryAfter.clear();
  }

  void _onTabClosed(String tabId) {
    // tab 正在关闭，transport 可能已经没了，所以不能用 _factsFor。
    _runners[tabId]?.feed(
      const conn.TabClosed(),
      readFacts(
        nowMs: DateTime.now().millisecondsSinceEpoch,
        rawRecvAgeMs: 0,
        rebindCount: 0,
        isForeground: _isForegroundNow,
        networkType: _lastConnectivityType ?? 'wifi',
      ),
    );
    _teardownRunner(tabId);
    _v2LivenessSubs.remove(tabId)?.cancel();
    _reconnecting.remove(tabId);
    _retrying.remove(tabId);
    _reconnectRound.remove(tabId);
    _sshForMoshRetryCount.remove(tabId);
    _sshForMoshRetryAfter.remove(tabId);
    _lastV2ProbeAt.remove(tabId);
    _proactiveResumeCompleters.remove(tabId)?.complete();
    _bannerTimers.remove(tabId)?.cancel();
    _bgEnteredAt.remove(tabId);
    // 防御性：正常路径下 span 由成功交接或 finally 兜底移除，这里不该有残留。
    // 但与上面那些 per-tab map 保持一致地清一次，成本为零。
    _resumeSpans.remove(tabId);
    // 清理持久化的 QUIC session（避免下次启动尝试恢复一个已关闭的 tab）
    _aqtSessionStateRepo?.remove(tabId).catchError((_) {});
  }

  /// Returns true if [tabId] is currently inside a reconnect/retry loop.
  /// Used by [TerminalScreen._connectServer] to avoid double-connecting when
  /// the service is already handling a tab.
  bool isHandling(String tabId) =>
      _reconnecting.contains(tabId) || _retrying.contains(tabId);

  /// Release a tab from in-flight reconnect bookkeeping so a user-initiated
  /// refresh can proceed. Background tasks already in flight will still finish,
  /// but they will no longer block a fresh _connectServer for this tab.
  void abandonReconnect(String tabId) {
    _reconnecting.remove(tabId);
    _retrying.remove(tabId);
    // 同步取消 pending banner timer：否则 refresh 入口设的
    // isReconnecting=true 在 finally 清回 false 后，旧的 1.5s timer 仍可能
    // fire 把状态再次拉成 true → banner 卡在残留状态。
    _bannerTimers[tabId]?.cancel();
    _bannerTimers.remove(tabId);
  }

  /// Register the onSessionDead watchdog callback for a freshly connected
  /// Mosh tab. Called both on first connection (terminal_screen) and on every
  /// reconnect (_reconnect) so the callback is always wired regardless of path.
  void registerMoshTab(SessionTab tab) {
    if (!tab.isMosh) return;
    _registerMoshDeadCallback(tab);
  }

  /// Register the stream.done watchdog for a freshly connected SSH-only tab.
  /// Called from terminal_screen after the initial connection so TCP drops are
  /// detected immediately — _reconnect() also registers this, but it is only
  /// reached on the second+ connection, leaving the first connection unguarded.
  void registerSshTab(SessionTab tab) {
    if (tab.isMosh) return;
    // QUIC tabs: SSH client is just for bootstrap. Don't tie session
    // liveness to it — registerAqtTab handles QUIC-level death.
    if (tab.transport?.kind == TransportKind.aqt) return;
    tab.connection.done.then((_) {
      if (_retrying.contains(tab.id) || _reconnecting.contains(tab.id)) return;
      if (!_sessionManager.tabs.contains(tab)) return;
      _reconnectWithRetry(tab, trigger: 'doneCb/init');
    });
  }

  /// Register reconnect callback for QUIC (AQT) transport tabs.
  /// Without this, tab.onSessionDead is null and QUIC failures never trigger
  /// the reconnect flow — the transport dies silently.
  void registerAqtTab(SessionTab tab) {
    final aqt = tab.transport;
    if (aqt is AqtTransport) {
      // Trigger RESUME directly on QUIC disconnect — earlier than waiting for
      // the 3s recovery timer. Idempotent with network-switch-triggered RESUME
      // via the _proactiveResuming guard.
      aqt.onDisconnected = () {
        final trNow = tab.transport;
        if (trNow is AqtTransport) {
          _runners[tab.id]?.feed(
              const conn.TransportClosed('onDisconnected'), _factsFor(tab, trNow));
        }
        final tid = _shortTabId(tab.id);
        _logResume('[$tid] DISC resuming=${_proactiveResuming.contains(tab.id)}');
        if (_proactiveResuming.contains(tab.id) ||
            _reconnecting.contains(tab.id) ||
            _retrying.contains(tab.id) ||
            !_sessionManager.tabs.contains(tab)) return;
        // 传输层自己报告断连，同样不是环境事件——理由同上（见
        // AqtConnRunner.onResume 那处的注释）。
        _proactiveResumeAqtTab(tab, source: ResumeTrigger.watchdog).ignore();
      };
      // 转发服务端推送的 Notify 事件。registerAqtTab 是唯一一处
      // 每条 AqtTransport 装配路径（初次 connect / RESUME 成功 / FULLRECONN）
      // 都会经过的地方（见 _installAqtTransport 顶部注释："以前四个装配点
      // 各写各的，分歧本身就是 bug"），所以是挂 onNotify 回调的正确位置——
      // 不会漏掉任何一条路径。真正的展示/判定/ack 逻辑不在这里，转发给
      // SessionManager 之后由 widget 层的 NotifyOrchestrator 处理（它才拿
      // 得到 SplitManager 判断分屏/悬浮窗可见性，见该类文档）。
      aqt.onNotify = (payload) => _sessionManager.publishNotify(tab, payload);
      // 新 HELLO（这个 tab 对应的服务端 session 从零重新计数）→ 清空**这个
      // tab** 持久化的去重窗口。按 tab 而不是按 server：event_id 的编号
      // 空间绑定在 QUIC session 上，每个 tab 各自一条独立连接 = 各自一个
      // session，同一服务器的多个 tab 之间 event_id 完全没有可比性（详见
      // notify_seen_store.dart 顶部注释）。早前按 serverId 清空/合并去重
      // 窗口是错的：一是新 tab 真实全新的通知会被同服务器上另一个 tab 早
      // 就记过的号码误判为"已展示过"而永久静默丢弃；二是新开一个 tab 走
      // HELLO 时会连带清掉同 server 上另一个存活 tab 的记录。
      // fire-and-forget：这是收尾清理，不应阻塞主连接路径。
      if (!aqt.wasResumed) {
        _notifySeenStore.clear(tab.id).ignore();
      }
      // 持久化 session 元数据：所有 QUIC 成功路径都会调 registerAqtTab，
      // 在此统一持久化避免遗漏（覆盖 initial connect / RESUME / FULLRECONN）。
      _persistAqtSession(tab);
      // 后台预热 SSH 辅助连接（exec-only，不要 PTY）。QUIC RESUME 路径
      // 跳过 SSH 建连节省了主路径 2-4s，但 SFTP/tmux/tunnel 等仍依赖 SSH。
      // 预热在后台跑，用户从看到终端 → 点 SFTP 通常 > 3s，能抢在前面完成。
      // fire-and-forget：失败不影响主路径，SFTP 会回退到 openDedicated()。
      _warmupAuxSshClient(tab).ignore();
    }
    tab.onSessionDead = () {
      final tid = _shortTabId(tab.id);
      if (_proactiveResuming.contains(tab.id)) {
        _logResume('[$tid] sessionDead skip: resuming');
        return;
      }
      if (_retrying.contains(tab.id) || _reconnecting.contains(tab.id)) {
        _logResume('[$tid] sessionDead skip: reconnecting');
        return;
      }
      if (!_sessionManager.tabs.contains(tab)) return;
      _logResume('[$tid] sessionDead → reconnect');
      _reconnectWithRetry(tab, trigger: 'aqtDead');
    };
  }

  /// Map a raw exception to a stable l10n key consumed by the UI layer.
  /// Returns one of the `reconnectErr*` keys defined in app_*.arb, or a
  /// truncated plain-text fallback for unknown errors.
  /// The caller stores this in ReconnectUiMessage.args['error'] and
  /// terminal_screen.dart translates it via _localizeReconnectError().
  static String _friendlyError(Object e) {
    final s = e.toString();
    if (e is TimeoutException) return 'timeout';
    if (s.contains('Connection refused')) return 'refused';
    if (s.contains('Connection reset')) return 'reset';
    if (s.contains('Network is unreachable') ||
        s.contains('No route to host')) return 'unreachable';
    if (s.contains('Host lookup') || s.contains('Failed host lookup')) {
      return 'dns';
    }
    if (s.contains('Authentication') || s.contains('auth')) return 'auth';
    if (s.contains('Permission denied')) return 'permission';
    if (s.contains('SocketException')) return 'socket';
    // Fallback: first line only, strip class prefix, cap at 60 chars
    final first = s.split('\n').first.replaceAll(RegExp(r'^\w+Exception: '), '');
    return first.length > 60 ? '${first.substring(0, 60)}…' : first;
  }

  static String _shortTabId(String tabId) =>
      tabId.length > 4 ? tabId.substring(0, 4) : tabId;

  void _registerMoshDeadCallback(SessionTab tab) {
    tab.onSessionDead = () {
      _trySoftMoshReconnect(tab);
    };
    // v2: also listen for hardReconnectNeeded liveness events. v2 owns its own
    // watchdog (LivenessSupervisor), so we bypass the v1 onSessionDead path
    // and trigger a full reconnect immediately when v2 says the session is gone.
    final shell = tab.moshShell;
    if (shell is MoshShellV2) {
      _v2LivenessSubs.remove(tab.id)?.cancel();
      _v2LivenessSubs[tab.id] = shell.liveness.listen((ev) {
        if (ev.kind == v2iface.SspLivenessKind.gracePeriod) {
          // Grace period fires at 30 s of silence — don't wait for
          // hardReconnectNeeded (75 s). Phase 0 probe costs only 1 s and
          // has no side effects; on miss it promotes to Phase 1 (new
          // transport). This cuts the passive worst-case from ~84 s to ~39 s.
          // _trySoftMoshReconnect is guarded by _reconnecting, so duplicate
          // events (roaming re-emits every 15 s) are no-ops.
          _trySoftMoshReconnect(tab);
        }
        if (ev.kind == v2iface.SspLivenessKind.hardReconnectNeeded) {
          tab.moshStats.noteHardTrigger(ev.reason ?? 'no auth packet for ?s');
          final reason = ev.reason ?? '';
          // "stuck" reasons (receiver state divergence) come from
          // MoshV2Connection._checkReceiverStuck. They mean the server's
          // state machine has diverged from ours, NOT that the network is
          // dead. A soft reconnect (new UDP socket talking to the same
          // mosh-server) reproduces the same divergence — the server is
          // the source. Skip soft and go directly to a full re-handshake
          // (kill server + new SSH + new mosh-server). Other
          // hardReconnectNeeded reasons (supervisor 75s gap, sender backlog)
          // may still benefit from soft-first because the server is alive.
          final skipSoft = reason.contains('stuck');
          _trySoftMoshReconnect(tab, skipSoft: skipSoft);
        }
      });
    }
  }

  /// Standard Mosh reconnect: attempt to resume the existing mosh-server
  /// session using the saved UDP key before falling back to a full SSH
  /// re-handshake that starts a new server process.
  ///
  /// Protocol:
  ///   1. Create a fresh [SspTransport] with the same host:port:key.
  ///   2. Call connect() with a 15 s timeout — the server authenticates
  ///      packets by OCB key, not source address, so a new socket reconnects.
  ///   3. On success: install the new shell, keep SSH alive, re-arm watchdog.
  ///   4. On timeout (server truly dead): kill old PID, close SSH, full reconnect.
  Future<void> _trySoftMoshReconnect(SessionTab tab,
      {bool skipSoft = false}) async {
    if (_reconnecting.contains(tab.id)) return;
    if (_circuitBreakerTripped(tab)) return;
    _reconnecting.add(tab.id);
    // P0-2: delay the banner by kBannerDelay so a quick soft-reconnect
    // (typically < 2 s for Mosh v2 Phase-0 probe + Phase-1 new transport)
    // is invisible to the user — matching QUIC's 1.5 s silent window.
    _bannerTimers[tab.id]?.cancel();
    _bannerTimers[tab.id] = Timer(kBannerDelay, () {
      if (_reconnecting.contains(tab.id)) {
        tab.isReconnecting = true;
        _sessionManager.notifyTabChanged();
      }
    });

    // v2 soft-reconnect path: reuse the same mosh-server (same host:port:key)
    // with a fresh UDP transport. On success the server is NOT killed —
    // closeTransport() tears down only the local socket. On failure we fall
    // through to the hard-reconnect path which kills the server via SSH to
    // prevent zombie processes accumulating on the remote host.
    final v2Shell =
        tab.moshShell is MoshShellV2 ? tab.moshShell as MoshShellV2 : null;
    if (v2Shell != null) {
      _setReconnectMessage(
        tab,
        ReconnectUiMessageCode.reconnectMoshDisconnectedRestoring,
      );
      tab.onSessionDead = null;
      await _v2LivenessSubs.remove(tab.id)?.cancel();

      // Two reasons to skip the soft attempt and go straight to a full
      // re-handshake:
      //   (1) skipSoft=true — receiver-stuck path. The mosh-server's state
      //       machine has diverged from ours and a new UDP socket won't
      //       fix that (the server is the source). f19.jpg showed this
      //       loop: 11 stuck triggers, 8 "successful" soft reconnects, 0
      //       actual recovery.
      //   (2) [kSoftReconnectEnabledV2] = false — global disable while we
      //       evaluate whether v2 soft adds enough value to justify the
      //       state-divergence failure modes. Hard reconnect costs ~3-10 s
      //       (kill server + new SSH + new mosh-server) but guarantees
      //       fresh state on every recovery.
      if (skipSoft || !kSoftReconnectEnabledV2) {
        await _v2FallbackToFullReconnect(
          tab,
          v2Shell,
          reason: skipSoft
              ? 'v2 stuck: skipped soft attempt'
              : 'v2 soft reconnect disabled (kSoftReconnectEnabledV2=false)',
        );
        return;
      }

      // Phase 0: probe existing transport — fast path, no new connection.
      // Sends a heartbeat on the current socket and waits 1 s for the next
      // applied diff. If the server responds, skip Phase 1 entirely and
      // proceed straight to the Phase 2 install block.
      // Connection-safety: no new transport is created here; if the probe
      // succeeds the existing transport stays alive and we just re-register
      // the liveness callback. _reconnecting is always released in finally.
      bool probeSucceeded = false;
      try {
        probeSucceeded = await v2Shell.probeAlive(
          timeout: const Duration(seconds: 1),
        );
      } catch (_) {}

      if (probeSucceeded) {
        try {
          try { tab.terminal.write('\x1b[?25h'); } catch (_) {}
          _setReconnectMessage(
            tab,
            ReconnectUiMessageCode.reconnectMoshSessionRestored,
            kind: ReconnectUiMessageKind.success,
            ttl: const Duration(seconds: 2),
          );
          tab.appendReconnect(ReconnectEvent(
            DateTime.now(),
            ReconnectCause.watchdogTimeout,
            ReconnectKind.soft,
            true,
          ));
          _maybeWarnCascade(tab);
          tab.networkStability.recordReconnectSuccess();
          tab.moshStats.noteAttemptOk();
          _registerMoshDeadCallback(tab);
          tab.startStreaming(source: 'moshSoftReconnectProbe');
          final w = tab.terminal.viewWidth;
          final h = tab.terminal.viewHeight;
          if (w > 0 && h > 0) tab.moshShell?.resizeTerminal(w, h);
        } finally {
          _reconnecting.remove(tab.id);
          tab.isReconnecting = false;
          _sessionManager.notifyTabChanged();
        }
        return;
      }

      // Phase 1: bind new transport and verify server is alive.
      // Failure here → fall back to hard reconnect (server may be dead).
      // resolvedAddr skips DNS — Roamer already resolved it on first connect.
      v2iface.SspTransport? newTransport;
      try {
        newTransport = await createMoshV2Transport(
          host: v2Shell.udpHost,
          port: v2Shell.udpPort,
          sessionKey: v2Shell.moshKey,
          initialCols:
              tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 80,
          initialRows:
              tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 24,
          resolvedAddr: v2Shell.resolvedPeerAddress,
        );
        // Zombie prevention: wait for the first applied diff before declaring
        // success. authenticatedPackets.first fires on OCB decrypt alone — the
        // diff may still be dropped by baseMiss/chainGate, leaving the session
        // frozen (f16/f19 pattern). firstAppliedPacket only completes when
        // appliedCount increments, proving state machines are aligned.
        // 8 s gives margin for 4G→WiFi handoff + server processing.
        await (newTransport as MoshV2Connection)
            .firstAppliedPacket
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('[ReconnectService] v2 soft reconnect phase-1 failed: $e');
        try {
          newTransport?.close();
        } catch (_) {}
        await _v2FallbackToFullReconnect(
          tab,
          v2Shell,
          reason: 'v2 soft reconnect failed: $e',
        );
        return;
      }

      // Phase 2: server confirmed alive — install new transport.
      // Exceptions here do NOT fall back (shell already replaced); lock is
      // released in finally regardless.
      try {
        await v2Shell.closeTransport();
        tab.moshShell = v2Shell.recreate(newTransport);
        // Reset cursor visibility on soft reconnect — same reason as hard
        // reconnect (line 1431): xterm 4.x doesn't reset cursorVisibleMode via
        // DECSTR, so a previous TUI (tmux/Claude/vim) that hid the cursor
        // leaves cursorVisibleMode=false. Without this, the scroll handler
        // sees cursorHidden=true, uses the SGR-to-stdin path, and the SGR
        // bytes leak to bash as garbled text until the server resends its state.
        try { tab.terminal.write('\x1b[?25h'); } catch (_) {}
        _setReconnectMessage(
          tab,
          ReconnectUiMessageCode.reconnectMoshSessionRestored,
          kind: ReconnectUiMessageKind.success,
          ttl: const Duration(seconds: 2),
        );
        tab.appendReconnect(ReconnectEvent(
          DateTime.now(),
          ReconnectCause.watchdogTimeout,
          ReconnectKind.soft,
          true,
        ));
        _maybeWarnCascade(tab);
        tab.networkStability.recordReconnectSuccess();
        tab.moshStats.noteAttemptOk();
        _registerMoshDeadCallback(tab);
        tab.startStreaming(source: 'moshSoftReconnectPhase2');
        final w = tab.terminal.viewWidth;
        final h = tab.terminal.viewHeight;
        if (w > 0 && h > 0) tab.moshShell?.resizeTerminal(w, h);
      } finally {
        _reconnecting.remove(tab.id);
        tab.isReconnecting = false;
        _sessionManager.notifyTabChanged();
      }
      return;
    }
  }

  /// Shared cleanup + full re-handshake path for v2 mosh.
  ///
  /// Invoked from two places in [_trySoftMoshReconnect]:
  ///   1. soft attempt threw (catch block) — old server's reachability is in
  ///      doubt, kill it to prevent zombies and start fresh.
  ///   2. skipSoft=true (stuck-state path) — server is alive but its state
  ///      machine has diverged; reusing it via soft reconnect won't help, so
  ///      jump straight to a clean re-handshake.
  ///
  /// Caller must have already:
  ///   - acquired the _reconnecting lock for [tab.id]
  ///   - cleared tab.onSessionDead
  ///   - cancelled the v2 liveness subscription
  ///
  /// On return, _reconnecting is released and _reconnectWithRetry is scheduled.
  Future<void> _v2FallbackToFullReconnect(
    SessionTab tab,
    MoshShellV2 v2Shell, {
    required String reason,
  }) async {
    _setReconnectMessage(
      tab,
      ReconnectUiMessageCode.reconnectMoshRestoreFailedRehandshake,
      kind: ReconnectUiMessageKind.warning,
    );
    tab.appendReconnect(ReconnectEvent(
      DateTime.now(),
      ReconnectCause.watchdogTimeout,
      ReconnectKind.soft,
      false,
    ));
    _maybeWarnCascade(tab);
    tab.networkStability.recordMissedDeadline(reason);
    tab.moshStats.noteAttemptFail(reason);
    // Zombie prevention: kill the server even when soft was skipped — the
    // stuck-state path knows the server is unrecoverable from this client's
    // perspective; leaving it running would accumulate zombies if the user
    // refreshes repeatedly.
    final oldPid = v2Shell.serverPid;
    if (oldPid != null) tab.pendingKillPid = oldPid;
    await _moshProcessRepo?.markPendingKillByTabId(tab.id);
    tab.pendingServerKill = v2Shell.kill;
    try {
      // closeTransport() tears down only the local UDP socket — no new SSH.
      // Kill the server via the existing SSH client if it is still alive.
      // This avoids the ~1–2 s overhead of sshConnectForExec() inside
      // v2Shell.close(). If the SSH client is gone, pendingKillPid ensures
      // _reconnect retries the kill on the freshly authenticated connection.
      await v2Shell.closeTransport();
      tab.moshShell = null;
      final sshClient = tab.connection.client;
      if (sshClient != null && !sshClient.isClosed && oldPid != null) {
        try {
          final s = await sshClient
              .execute('kill $oldPid 2>/dev/null; true')
              .timeout(const Duration(seconds: 3));
          await s.stdout.drain<void>().timeout(const Duration(seconds: 3));
          await _moshProcessRepo?.markKilledByTabId(tab.id);
          // Kill succeeded — clear so _reconnect skips the redundant kill exec.
          tab.pendingKillPid = null;
        } catch (_) {} // best-effort; pendingKillPid retries in _reconnect if set
      }
      // Leave tab.connection open — _reconnect will reuse the authenticated
      // SSH client for the new mosh-server handshake, saving the full
      // re-auth round-trip (~1–2 s on a typical mobile connection).
    } finally {
      _bannerTimers.remove(tab.id)?.cancel();
      _reconnecting.remove(tab.id);
      tab.isReconnecting = false;
      _sessionManager.notifyTabChanged();
    }
    _reconnectWithRetry(tab, trigger: 'moshV2SoftFailed/full');
  }

  /// Called by [TerminalScreen] on [AppLifecycleState.resumed].
  ///
  /// Marks every dead AQT tab for a one-shot fast-path RWR: zero banner delay,
  /// single attempt (no retries). A failed fast-path attempt simply clears the
  /// flag and falls through to the normal retry loop on the next trigger.
  ///
  /// Also wakes all sleeping retry loops immediately (via [_retrySleepers]) so
  /// any ongoing inter-attempt delays are skipped, and kicks off a proactive
  /// RESUME probe for live AQT tabs.
  void onForegroundResumed() {
    for (final tab in _sessionManager.tabs) {
      final t = tab.transport;
      if (t is AqtTransport && t.isDead) {
        _foregroundFastPathRegistry.mark(tab.id);
      }
    }
    _retrySleepers.wakeAll();
    final lastPause = _lastPauseTime;
    final bg = lastPause == null
        ? null
        : DateTime.now().difference(lastPause);
    _proactiveResumeAqtTabs(probeFirst: shouldProbeBeforeResume(bg));
    // SFTP 生命周期协同：后台冻结期间 keepalive 停摆，回前台先探活（不重建）。
    // 放在末尾，不影响上面任何既有分支。
    onForegroundResumedForSftp?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _isForegroundNow = false;
      for (final t in _sessionManager.tabs) {
        final tr = t.transport;
        if (tr is! AqtTransport) continue;
        _runners[t.id]?.feed(const conn.LifecycleBackground(), _factsFor(t, tr));
      }
      // 切后台是落盘的最后机会：app 随时可能被系统杀掉，而轨迹只在内存里。
      for (final t in _sessionManager.tabs) {
        if (t.transport is AqtTransport) unawaited(exportConnTrace(t.id));
      }
      unawaited(exportResumeSamples());
      _lastPauseTime = DateTime.now();
      // 给恢复样本标注 backgroundMs 用。按 tab 记，因为 tab 可能在后台
      // 期间被关闭，全局单值会张冠李戴。
      for (final t in _sessionManager.tabs) {
        if (t.transport is AqtTransport) {
          _bgEnteredAt[t.id] = DateTime.now();
        }
      }
      // Suppress watchdogs while backgrounded so they don't trigger reconnects
      // behind the user's back.  For v1 (SspTransport): setForeground(false)
      // clears _isInForeground, which gates the 12–40 s watchdog timer.
      // For v2 (MoshShellV2): setForeground(false) calls notePaused() which
      // resets the LivenessSupervisor baseline and sets _backgrounded=true so
      // hardReconnectNeeded events are suppressed until the app resumes.
      // On resume, setForeground(true) re-enables both watchdog paths.
      for (final tab in _sessionManager.tabs) {
        if (tab.isMosh) {
          (tab.moshShell as dynamic)?.setForeground(false);
          // Also notify typed transport when present (e.g. future AQT/QUIC).
          tab.transport?.setForeground(false);
        }
      }
    }

    if (state == AppLifecycleState.resumed) {
      _isForegroundNow = true;
      for (final t in _sessionManager.tabs) {
        final tr = t.transport;
        if (tr is! AqtTransport) continue;
        _runners[t.id]?.feed(const conn.LifecycleForeground(), _factsFor(t, tr));
      }
      // Mosh: setForeground immediately — safe, idempotent, and needed to
      // re-enable the watchdog before the next heartbeat window.
      for (final tab in _sessionManager.tabs) {
        if (tab.isMosh) {
          // setForeground(true) re-enables the watchdog and checks liveness.
          // Dynamic dispatch: tab.moshShell may be MoshShell (v1) or MoshShellV2
          // (v2); a hard cast to MoshShell? silently returns null for v2 and
          // skips the call entirely.
          (tab.moshShell as dynamic)?.setForeground(true);
          // Also notify typed transport when present.
          tab.transport?.setForeground(true);
        } else if (tab.transport is AqtTransport) {
          // QUIC tabs also need setForeground(true) to start the heartbeat
          // timer and send an immediate probe.
          tab.transport!.setForeground(true);
        }
      }

      // Android Doze: if screen was off > 3 min, TCP connections are likely
      // silently dead. Force an immediate reconnect before the 1 s timer fires.
      final lastPause = _lastPauseTime;
      if (lastPause != null &&
          DateTime.now().difference(lastPause) > const Duration(minutes: 3)) {
        _reconnectDisconnected(trigger: 'dozeResume');
      }
      // After a long background period the device has effectively been through a
      // network outage from the app's perspective.  Mark a network comeback so the
      // cascade cooldown is bypassed on the next reconnect attempt — avoids the
      // 30 s delay that would otherwise apply after multiple pre-Doze failures.
      if (lastPause != null &&
          DateTime.now().difference(lastPause) > const Duration(seconds: 30)) {
        _lastNetworkComebackTime = DateTime.now();
      }
      // 回前台一律走廉价 RESUME，探不探测由协议参数决定（见
      // shouldProbeBeforeResume）。这里不再有 30s 硬编码阈值。
      //
      // 与 onForegroundResumed 可能几乎同时到达 —— _proactiveResuming
      // 会去重，且两者共用同一个判据，所以不会出现一个探测一个不探测。
      if (lastPause != null) {
        _proactiveResumeAqtTabs(
          probeFirst:
              shouldProbeBeforeResume(DateTime.now().difference(lastPause)),
        );
      }

      // SSH: delay the disconnection check by 1 s. Android 14's predictive-back
      // gesture fires inactive→resumed in ~300 ms; without the delay the check
      // may race the animation and find _client.isClosed transiently true,
      // producing a spurious "[重新连接中...]" banner for a healthy connection.
      // A truly dead SSH socket will still be dead after 1 s and be reconnected.
      _resumeCheckTimer?.cancel();
      _resumeCheckTimer = Timer(
        const Duration(seconds: 1),
        () => _reconnectDisconnected(trigger: 'appResume'),
      );

      // 前台恢复走完后清掉，避免下一次网络切换恢复被误标成 foreground。
      // 延后到 resume 决策之后：_proactiveResumeAqtTab 要读它。
      //
      // 先 cancel 再重排：见 _bgClearTimer 的文档，不取消会让旧 timer 清掉
      // 新一轮刚写入的条目。
      _bgClearTimer?.cancel();
      _bgClearTimer = Timer(
        const Duration(seconds: 10),
        _bgEnteredAt.clear,
      );
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    final newType = classifyNetwork(results);
    final typeChanged = newType != _lastConnectivityType;
    final oldType = _lastConnectivityType;
    _lastConnectivityType = newType;
    if (typeChanged) {
      // SFTP 生命周期协同：切网时那条独立 SSH 的 TCP 已失效，等用户发现太晚。
      // 挂在既有 typeChanged 判据上（信号强度变化不触发），不新造判据。
      onNetworkTypeChanged?.call(newType, oldType);
    }
    for (final t in _sessionManager.tabs) {
      final tr = t.transport;
      if (tr is! AqtTransport) continue;
      _runners[t.id]?.feed(conn.ConnectivityChanged(newType), _factsFor(t, tr));
    }
    if (!hasNetwork) {
      _connectivityDebounceTimer?.cancel();
      _connectivityDebounceTimer = null;
      // Fix 2: When the OS reports network is gone, proactively start the
      // mosh transport's grace period. Otherwise mosh has to wait through
      // 9 s of heartbeat misses (~3 missed beats) before grace begins. By
      // entering grace immediately, close() can fire as early as 10 s after
      // the network drop instead of 19 s. If the network returns within the
      // grace window, the next authenticated packet cancels grace and the
      // session continues; otherwise close() drives onSessionDead → reconnect.
      for (final tab in _sessionManager.tabs) {
        if (tab.isMosh && tab.moshShell != null) {
          try {
            (tab.moshShell as dynamic).enterGracePeriodNow();
          } catch (_) {}
        }
      }
      return;
    }

    // Mosh heartbeats: send immediately and repeatedly — no debounce needed.
    //
    // Real mosh does NOT rebind on network changes — it sends from the existing
    // socket and lets the OS routing table switch the outgoing interface. The
    // server sees the packet from a new NAT address (same client port), matches
    // the session by OCB key, and updates its peer address.
    //
    // Calling roam() (rebind) here is wrong: Android fires the connectivity
    // event BEFORE the routing table updates, so the new socket still routes
    // through the dying interface. Worse, a new port forces a fresh roam-announce
    // cycle — if those packets also exit through the dying interface the 15s
    // roam deadline fires → full SSH reconnect.
    //
    // Instead: send heartbeats from the existing socket at t=0/500ms/1.5s/3s.
    // By t=1.5s the Android routing table is usually stable and the heartbeat
    // exits through the new interface. The server responds, roaming succeeds.
    //
    // Safety-net roam() at t=5s: if the socket was silently killed (no onDone
    // event — common during Android deep-sleep) the heartbeat send throws,
    // _sendFragment automatically calls _bindSocket, but as an explicit
    // fallback we also call roam() once the routing table is stable (t=5s).
    //
    // Type-change guard: Android fires connectivity events for signal-level
    // shifts on the same WiFi (or VPN tunnel flutter on the same underlying
    // network). Those events do not change the classified type, so we skip
    // the heartbeat/roam burst — a healthy connection does not need its UDP
    // socket disturbed, and the unconditional rebind at t=5s would otherwise
    // arm the 15 s roam deadline on a perfectly fine session.
    // AQT: trigger optimistic RESUME on ANY connectivity change (not just type-change).
    // For soft events (same network type — signal blip, OS event flutter, etc.)
    // probe the existing connection first: most are false positives where the
    // socket is still good, and RESUME would waste 200-500 ms.
    //
    // On HARD type-change (wifi↔cellular), kick off true RFC 9000 §9
    // connection migration FIRST. Migration rebinds the Quinn endpoint
    // to a fresh UDP socket — the OS routing table selects the new
    // interface automatically, packets leave with the existing QUIC
    // connection ID, and server validates via PATH_CHALLENGE/RESPONSE.
    // Result: ~100-400 ms migration (one RTT) preserves tab state,
    // versus 200-500 ms RESUME that replaces the transport entirely.
    //
    // C3: on hard type-change (kAggressiveMigration=true) we skip the 150ms
    // probe and run RESUME immediately (probeFirst: false). An 800ms audit
    // then checks PathStats.migrationCount; if quinn didn't actually migrate,
    // markPathDied is called to force RESUME. On soft change (same type) or
    // when kAggressiveMigration=false, probeFirst=true is retained.
    _logResume('conn→$newType${typeChanged ? "(changed)" : "(same)"} hasNet=$hasNetwork');
    if (typeChanged && hasNetwork) {
      // Capture baseline migration_count BEFORE migrate so the audit can
      // detect whether quinn actually moved.
      // Key the baseline by AqtTransport object identity, NOT tab.id. If
      // RESUME swaps tab.transport during the 800ms audit window, the new
      // transport won't be in the map — audit then skips that tab,
      // avoiding a double-RESUME race.
      final baselineMigrationCounts = <AqtTransport, int>{};
      for (final tab in _sessionManager.tabs) {
        final t = tab.transport;
        if (t is AqtTransport) {
          baselineMigrationCounts[t] = t.lastPathStats.migrationCount;
          t.migrateEndpoint();
          // 走直连时控制器什么都不做（迁移就是上面这行）；走中继时立即探测
          // 直连并重建中继。
          _pathControllers[tab.id]?.onNetworkChanged();
        }
      }
      if (kAggressiveMigration) {
        // Skip the 150ms probe — we KNOW the network changed. Run RESUME
        // immediately. 800ms later audit whether migration actually
        // happened; if not, force RESUME via markPathDied.
        Timer(kPostMigrationAuditDelay,
            () => _postMigrationAudit(baselineMigrationCounts));
        _proactiveResumeAqtTabs(probeFirst: false);
      } else {
        _proactiveResumeAqtTabs(probeFirst: true);
      }
    } else {
      _proactiveResumeAqtTabs(probeFirst: true);
    }

    if (typeChanged) {
      // Record network comeback time so _reconnect can bypass the 30 s cascade
      // cooldown on the very next attempt.  Without this, a tab that exhausted
      // retries while the network was down would wait 30 s before trying again
      // even though the network just recovered.
      if (hasNetwork) _lastNetworkComebackTime = DateTime.now();
      _heartbeatMoshTabs();
      Timer(const Duration(milliseconds: 500), _heartbeatMoshTabs);
      Timer(const Duration(milliseconds: 1500), _heartbeatMoshTabs);
      Timer(const Duration(milliseconds: 3000), _heartbeatMoshTabs);
      Timer(const Duration(milliseconds: 5000), _roamMoshTabs);
      // QUIC proactive RESUME: immediately reconnect from new network path.
      // Unlike Mosh (which sends from existing socket and waits for routing),
      // QUIC needs a fresh connection from the new interface. We skip SSH
      // bootstrap and connect directly to the daemon using stored session info.
      // If RESUME succeeds (~200-500 ms) the transport is atomically swapped —
      // user is unaware of the switch. If it fails, normal reconnect handles it.
      _proactiveResumeAqtTabs();
      // Post-type-change audits: be conservative but faster than the previous
      // roam-timeout path. At 5s we only probe; at 8s we enter grace (not close)
      // so a late authenticated packet can still cancel recovery; at 12s we
      // close only if the session is still silent.
      Timer(
        const Duration(milliseconds: 5000),
        () => _auditMoshAfterTypeChange(stage: '5s'),
      );
      Timer(
        const Duration(milliseconds: 8000),
        () => _auditMoshAfterTypeChange(stage: '8s'),
      );
      Timer(
        const Duration(milliseconds: 12000),
        () => _auditMoshAfterTypeChange(stage: '12s'),
      );
      Timer(
        const Duration(milliseconds: 40000),
        () => _auditMoshAfterTypeChange(stage: '40s'),
      );
      Timer(
        const Duration(milliseconds: 90000),
        () => _auditMoshAfterTypeChange(stage: '90s'),
      );
      Timer(
        const Duration(milliseconds: 120000),
        () => _auditMoshAfterTypeChange(stage: '120s'),
      );
      // SSH-only tabs: proactively close the old TCP socket on network type
      // change so that done.then() fires immediately. Without this, the TCP
      // socket stays "alive" (isClosed == false) for 8–16 s while dartssh2's
      // keepalive eventually times out — isConnected returns true the whole
      // time, causing _reconnectDisconnected() and the stability self-heal
      // grace to both skip reconnect thinking the connection is fine.
      for (final tab in _sessionManager.tabs) {
        if (tab.isMosh && tab.moshShell != null) continue; // mosh roams via UDP
        if (tab.server.serverType == 'local') continue;
        if (tab.transport?.kind == TransportKind.aqt) continue; // QUIC uses UDP
        if (_reconnecting.contains(tab.id) || _retrying.contains(tab.id))
          continue;
        if (tab.connection.isConnected) tab.connection.close();
      }
    }

    // D3: Wake all retry sleepers on network recovery.
    // Whenever connectivity returns (regardless of type-change), any in-flight
    // retry sleeps should complete immediately so the next attempt starts ASAP.
    if (hasNetwork) {
      _retrySleepers.wakeAll();
      _logResume('connectivity hasNetwork=true → wakeAll retry sleepers');
    }

    // SSH reconnect: debounce to 200 ms so rapid connectivity events
    // (e.g. WiFi scan → connected) don't launch concurrent reconnect chains.
    // On type change: SSH sockets were already closed above, so attempt an
    // immediate reconnect PLUS a second pass after 2 s to catch any tabs
    // that were mid-reconnect during the first pass.
    // On non-type-change: wait 2 s for the interface to stabilise first.
    _connectivityDebounceTimer?.cancel();
    _connectivityDebounceTimer = Timer(
      const Duration(milliseconds: 200),
      () async {
        if (typeChanged) {
          await _reconnectDisconnected(trigger: 'connectivity/typeChange');
        }
        await Future.delayed(const Duration(seconds: 2));
        await _reconnectDisconnected(trigger: 'connectivity/settle');
      },
    );
  }

  void _heartbeatMoshTabs() {
    for (final tab in _sessionManager.tabs) {
      if (tab.isMosh && tab.moshShell != null) {
        // v2 was previously skipped here on the assumption its internal
        // supervisor would handle recovery — but that only fires after a
        // 30/45/75 s silence cascade. On a 4G→WiFi handoff the user perceives
        // mosh as frozen for the full 45 s before roam kicks in. v2's
        // heartbeat() now forwards to MoshV2Connection.triggerHeartbeat so
        // the connectivity burst at 0/500/1500/3000 ms also probes v2.
        try {
          (tab.moshShell as dynamic)?.heartbeat();
        } catch (_) {}
      }
      // Also dispatch to typed transport when present (e.g. AQT/QUIC).
      if (tab.transport != null) {
        try {
          tab.transport!.heartbeat();
        } catch (_) {}
      }
    }
  }

  void _auditMoshAfterTypeChange({required String stage}) {
    for (final tab in _sessionManager.tabs) {
      if (!tab.isMosh) continue;
      if (_reconnecting.contains(tab.id)) continue;
      if (_retrying.contains(tab.id)) continue;
      if (tab.moshShell is MoshShellV2) {
        // v2 audit: probe-only stages (5/8/12 s). Skip 40 s+ force-close
        // because v2's LivenessSupervisor hardReconnect at 75 s is the
        // canonical safety net and we don't want to kill mosh-server
        // earlier than needed — false force-close on a slow handoff would
        // burn an SSH re-handshake and lose mosh-server state.
        final v2 = tab.moshShell as MoshShellV2;
        final stale = v2.supervisorLastInboundAgeMs ~/ 1000;
        if (stage == '5s' && stale > 5) {
          debugPrint('[ReconnectService] v2 audit 5s: stale=${stale}s → heartbeat');
          try { v2.heartbeat(); } catch (_) {}
        } else if (stage == '8s' && stale > 8) {
          debugPrint('[ReconnectService] v2 audit 8s: stale=${stale}s → heartbeat+roam');
          try { v2.heartbeat(); v2.roam(); } catch (_) {}
        } else if (stage == '12s' && stale > 12) {
          debugPrint('[ReconnectService] v2 audit 12s: stale=${stale}s → roam');
          try { v2.roam(); } catch (_) {}
        }
        // 40 s/90 s/120 s: deliberately no-op — supervisor will hard-reconnect.
        continue;
      }
    }
  }

  void _roamMoshTabs() {
    for (final tab in _sessionManager.tabs) {
      if (tab.isMosh && tab.moshShell != null) {
        // v2's roam() now forwards to MoshV2Connection.triggerRoam — rebinds
        // the UDP socket and resets the supervisor baseline. Without this,
        // v2 sessions only roam after a 45 s silence on the LivenessSupervisor.
        try {
          (tab.moshShell as dynamic)?.roam();
        } catch (_) {}
      }
      // Also dispatch to typed transport when present (e.g. AQT/QUIC).
      if (tab.transport != null) {
        try {
          tab.transport!.roam();
        } catch (_) {}
      }
    }
  }

  /// Proactively RESUME all QUIC tabs when network changes.
  /// C3 — Runs [kPostMigrationAuditDelay] after a hard connectivity
  /// type-change. For each AqtTransport tab, checks whether quinn actually
  /// observed a migration (PathStats.migrationCount > baseline). If not,
  /// force-mark path dead so the regular RESUME path takes over.
  void _postMigrationAudit(Map<AqtTransport, int> baseline) {
    for (final tab in _sessionManager.tabs) {
      final t = tab.transport;
      if (t is! AqtTransport) continue;
      final before = baseline[t];
      if (before == null) {
        // The transport instance differs from the one we armed audit on —
        // typically because RESUME completed during the 800ms window and
        // swapped tab.transport. The new transport is the recovery; auditing
        // it would double-fire onDisconnected. Skip.
        _logResume('[${_shortTabId(tab.id)}] migration audit skip — transport swapped');
        continue;
      }
      final current = t.lastPathStats.migrationCount;
      if (current > before) {
        _logResume(
            '[${_shortTabId(tab.id)}] migration audit OK (count $before → $current)');
      } else {
        _logResume(
            '[${_shortTabId(tab.id)}] migration audit FAIL (count stuck at $current) → markPathDied');
        t.markPathDied('migration-audit-failed');
      }
    }
  }

  /// Runs immediately (no debounce) so the new connection is established
  /// before the old one dies — enabling seamless handover (~200-500 ms).
  void _proactiveResumeAqtTabs({bool probeFirst = false}) {
    for (final tab in _sessionManager.tabs) {
      final tid = _shortTabId(tab.id);
      if (tab.transport?.kind != TransportKind.aqt) {
        _logResume('[$tid] skip:non-aqt');
        continue;
      }
      if (_reconnecting.contains(tab.id) || _retrying.contains(tab.id)) {
        _logResume('[$tid] skip:reconnecting');
        continue;
      }
      if (_proactiveResuming.contains(tab.id)) {
        _logResume('[$tid] skip:in-flight');
        continue;
      }
      _proactiveResumeAqtTab(tab, probeFirst: probeFirst).ignore();
    }
  }

  /// Pure policy for the cheap-RESUME retry window. Extracted so the schedule
  /// can be tested device-free.
  ///
  /// [attempt] is the 0-based index of the attempt that just failed;
  /// [reason] is null when RESUME could not even be attempted (no session
  /// info anywhere), which is not something a retry can fix.

  /// 这次尝试拿什么做 RESUME 的元数据来源。
  ///
  /// [tabTransport] 是 tab 上当前的 transport（最新，优先），[stashed] 是上
  /// 一次尝试失败时留存下来的。**两者都要看**，因为它们的生命周期完全不同：
  ///
  /// `_reconnect()` 在发起 pre-SSH RESUME 之前会执行 `tab.transport = null`
  /// （避免 FULLRECONN 块重复 close），那是**永久副作用**；而承接它的
  /// `prevAqtForFullreconn` 是函数内的局部变量，`_reconnectWithRetry` 的重试
  /// 循环每转一圈就重新调用 `_reconnect`，局部变量随之重置。
  ///
  /// 只看 `tab.transport` 的后果（真机 2026-09-05 02:49–02:51 UTC 现场）：
  ///
  ///   attempt 1: transport 非空 → 发 RESUME → 失败 → 存进局部变量 → 返回
  ///   attempt 2: transport 已 null → 整个 pre-SSH 块跳过 → 局部变量又是 null
  ///   FULLRECONN: 拿不到元数据 → 工厂只能发 HELLO → 服务端 OPEN_TAB → 会话没了
  ///
  /// 而那一刻服务端的 session 完好无损 —— 同一秒另一个 tab 的 RESUME 拿回了
  /// 235162B 历史。**会话不是丢在断网，是丢在元数据的存放位置上。**
  ///
  /// 泛型化到 `Object?` 是为了能 device-free 测：这个判定只回答「取哪一个」，
  /// 不碰 transport 的任何成员，没有理由为它去造一个带 FFI handle 的实例。
  static T? resumeMetaFor<T extends Object>({
    required T? tabTransport,
    required T? stashed,
  }) =>
      tabTransport ?? stashed;

  /// pre-SSH RESUME 失败后留存的旧 transport，**按 tab 索引、跨重试保留**。
  ///
  /// 放在这里而不是 `_reconnect()` 的栈上，理由见 [resumeMetaFor]。与
  /// `_retrying` / `_proactiveResuming` 同级，生命周期由
  /// [_takeResumeMeta] 消费、[_discardResumeMeta] 兜底清理。
  final Map<String, AqtTransport> _pendingResumeMeta = {};

  /// 取走留存的元数据（取走即消费，不会被第二个调用点重复使用）。
  AqtTransport? _takeResumeMeta(String tabId) => _pendingResumeMeta.remove(tabId);

  /// 丢弃并关闭留存的元数据。
  ///
  /// **必须 close**：留存的 transport 仍持有 FFI handle 与一条 QUIC 连接，
  /// 只从 map 里删掉引用就是泄漏。重连成功或彻底放弃时调用。
  void _discardResumeMeta(String tabId) {
    final t = _pendingResumeMeta.remove(tabId);
    if (t != null) {
      _logResume('[${_shortTabId(tabId)}] discard stashed resume meta');
      t.close();
    }
  }

  /// 「这一次失败算不算 FAST failure」的分界。
  ///
  /// [kResumeRetryGaps] 的存在理由只有一个：Android 的连通性事件先于路由表就绪
  /// 到达，此时 RESUME 会以 ENETUNREACH **同步**失败（毫秒级）。那种失败重试
  /// 极其划算。而一次等满 budget 的失败说明对端根本没回，重试只是再等一个
  /// budget。
  ///
  /// 这条契约原本只写在 [kCheapResumeWindow] 的文档里，实现却是靠
  /// `elapsed + gap >= window` 间接达成的 —— 它只在 `budget > window` 时才碰巧
  /// 成立。budget 一收紧（proactive 档那次，见 aqt_transport_factory.dart 的墓志铭）
  /// 巧合就没了：3.0 + 0.5 < 4.0 会把超时失败判成 retry，总耗时反而从 5.0s
  /// 涨到 6.5s。所以判据必须显式，且与 budget 取值解耦。
  ///
  /// 500 ms：ENETUNREACH 是同步返回（~ms），而一次真实的失败握手往返在 4G 上
  /// 也就几百毫秒。取在两者之间，且严格小于最短的 budget。
  static const Duration kFastFailureCeiling = Duration(milliseconds: 500);

  static ResumeRetryDecision decideResumeRetry({
    required bool pathDead,
    required AqtResumeFailReason? reason,
    required int attempt,
    required Duration elapsed,
    required Duration attemptElapsed,
  }) {
    // The old connection still works — a failed RESUME here is benign
    // (server busy, transient handshake glitch). Never tear down a live path.
    if (!pathDead) return ResumeRetryDecision.keepOld;
    // Retrying provably cannot help: the server says the session is gone, or
    // we have nothing to resume with. Escalate now rather than burn the window.
    if (reason == null || reason == AqtResumeFailReason.sessionNotFound) {
      return ResumeRetryDecision.escalate;
    }
    if (attempt >= kResumeRetryGaps.length) return ResumeRetryDecision.escalate;
    // 这一次不是 FAST failure —— 对端没回，重试只会再等一个 budget。
    // 路径可达但不健康是 SSH 链的问题，不是廉价路径的。
    if (attemptElapsed >= kFastFailureCeiling) {
      return ResumeRetryDecision.escalate;
    }
    // 总时长兜底：即便每一次都是快速失败，整个廉价窗口也有上限。
    if (elapsed + kResumeRetryGaps[attempt] >= kCheapResumeWindow) {
      return ResumeRetryDecision.escalate;
    }
    return ResumeRetryDecision.retry;
  }

  /// [source] 由调用方指定触发源（例如看门狗），跳过下面的环境判据。
  /// 留空（默认）时按环境状态推断 foreground/connectivity —— 这两种恰好
  /// 是环境状态能正确回答的唯一情况，见下面 trigger 赋值处的注释。
  Future<void> _proactiveResumeAqtTab(SessionTab tab,
      {bool probeFirst = false,
      ResumeTrigger? source,
      bool fromMachine = false}) async {
    final aqt = tab.transport;
    if (aqt is! AqtTransport) return;

    // Guard: snapshot transport reference to detect concurrent swaps.
    final originalTransport = aqt;

    // 「同一 tab 只能有一次恢复在飞」的唯一守卫点。
    //
    // 此前这个不变量由两份状态分别维护：本方法的三个调用点里，sweep 与 DISC
    // 查 `_proactiveResuming` 集合，状态机那条（onResume）查自己的 inFlight，
    // 谁也看不见对方。a6.jpg 现场就是这么来的 —— sweep 发起 #8，doze 冻结
    // 8 分钟，回前台后状态机 tick 判死发出 #9、#8 的超时随即 FAIL 又引出
    // #10，两条并发 RESUME 都拿到 ACK，客户端只装一条，服务端的 PTY 流留在
    // 被 DISCARD 的那条上：体征全绿而屏幕不动。
    //
    // 现在外部发起也登记进状态机的 inFlight（ResumeStarted），于是两侧读的
    // 是同一份事实。
    //
    // `_proactiveResuming` 与 sweep / DISC 那两处对它的检查**故意留着**，不是
    // 忘了删：本方法的守卫依赖 `_runners[tab.id]` 非空，而它一旦为空（理论上
    // 不该发生 —— `_onTabTransportChanged` 是唯一创建点且覆盖全部 6 个附着点
    // —— 但这条守卫的失效代价是回到 a6.jpg）就完全放行。集合是那种情况下唯一
    // 剩下的保护。两层的判据一致，多一层只会更严，不会误拦。
    // 526 行说的「取代三个集合」是终点，删除要等到状态机覆盖所有发起路径。
    //
    // [fromMachine] 是状态机自己派发 StartResume 后回调进来的那一次：
    // `_enterRecovering` 已经把 inFlight 置起来了，这里再查就会把它自己掐死。
    //
    // 而 SSH 全量链（`_reconnecting` / `_retrying`）是**另一个**互斥对象，
    // fromMachine 穿不过它 —— 见 [shouldSkipExternalResume] 里 18:49 那段现场。
    final runner = _runners[tab.id];
    final reconnectInFlight =
        _reconnecting.contains(tab.id) || _retrying.contains(tab.id);
    if (shouldSkipExternalResume(
      fromMachine: fromMachine,
      machineInFlight: runner?.state.inFlight ?? false,
      reconnectInFlight: reconnectInFlight,
    )) {
      _logResume('[${_shortTabId(tab.id)}] '
          'skip:${reconnectInFlight ? "reconnecting" : "inFlight(machine)"}');
      // 被拦的若是状态机自己那一次，它置的 inFlight 只有这里能清 —— 漏掉就
      // 是永久死锁。外部发起的位是别人的，替他放锁等于把守卫拆了。
      if (shouldSettleOnSkip(fromMachine: fromMachine)) {
        runner?.feed(
            const conn.ResumeSettled(), _factsFor(tab, originalTransport));
      }
      return;
    }
    if (!fromMachine) {
      runner?.feed(const conn.ResumeStarted(), _factsFor(tab, originalTransport));
    }
    _proactiveResuming.add(tab.id);
    _proactiveResumeCompleters[tab.id] ??= Completer<void>();
    final sw = Stopwatch()..start();
    final tid = _shortTabId(tab.id);
    final deadAtStart = originalTransport.quicPathDied;
    _logResume('[$tid] START port=${aqt.lastPort} dead=$deadAtStart probe=$probeFirst');

    try {
      // 开一个恢复 span。t0 = 本次恢复决策的起点。放在 try 的第一行：
      // 让"任何退出路径都不泄漏"从"实践上成立"变成"结构上成立"——
      // 之前 putIfAbsent 在 try 外面，中间隔着 Completer()/Stopwatch()
      // 之类的调用，理论上不会抛，但 finally 的兜底就只是"实践上"覆盖。
      //
      // 用 putIfAbsent 而不是直接赋值：同一次恢复可能被多个入口触碰
      // （前台事件 + 网络事件几乎同时到达是常态），第一个到的那个才是
      // 真正的决策起点。
      final nowMs0 = DateTime.now().millisecondsSinceEpoch;
      final bgAt = _bgEnteredAt[tab.id];
      // trigger 与 backgroundMs 必须同源：只有「确实是从后台回到前台」这一种
      // 情况才带 backgroundMs。
      //
      // 反例（真实可达）：app 停在后台时 wifi 掉、蜂窝接管，connectivity_plus
      // 不看生命周期照样触发恢复 —— 那次 trigger 是 connectivity，但 _bgEnteredAt
      // 里的条目还在（要等 resumed 后 10s 才清），若不门控就会带上 backgroundMs，
      // 被 statsByBucket 当成一次前台恢复统计进去。而它的 ⑤ 段还特别大（后台不
      // 出帧，postFrame 要等回前台第一帧），正好污染 under30s/under90s 这两个
      // 用来验证阈值修正的档位。
      //
      // bucketFor() 的文档也写明了这条契约：「网络切换、看门狗等不参与分档统计」。
      //
      // source 非空 = 调用方已经知道自己是谁（看门狗等非环境触发），直接
      // 采用，不再猜；环境判据只在两种真正靠环境状态就能分清的情况下才
      // 准——前台恢复 vs 网络切换恢复，其余一律交给调用方显式指定。
      final trigger = source ??
          (_isForegroundNow && bgAt != null
              ? ResumeTrigger.foreground
              : ResumeTrigger.connectivity);
      _resumeSpans.putIfAbsent(
        tab.id,
        () => ResumeSpan(
          trigger: trigger,
          backgroundMs: trigger == ResumeTrigger.foreground
              ? DateTime.now().difference(bgAt!).inMilliseconds
              : null,
          t0: nowMs0,
        ),
      );

      // ── Liveness probe ────────────────────────────────────────────────
      // For "soft" connectivity events (same network, signal blips,
      // foreground/background) the old QUIC connection is usually still
      // usable. Send a 1-byte heartbeat datagram and wait briefly: if the
      // kernel can't route through the bound interface (ENETUNREACH after
      // network switch) the send_datagram call fails synchronously and
      // quinn closes the connection, flipping quicPathDied. If quicPathDied
      // is still false after the probe window, treat as alive and skip
      // the (~200-500 ms) RESUME entirely.
      //
      // Skip probe when:
      //   • probeFirst=false (caller already knows path is dead, e.g.
      //     onDisconnected callback, or hard network-type change)
      //   • deadAtStart (connection already declared dead)
      //
      // 心跳走的是 QUIC datagram，而终端数据走独立的 bi-stream —— 前者通不
      // 代表后者通。stream 停摆时这个探测会稳定地报「活着」并跳过恢复，把
      // 一次可自愈的停顿变成永久卡死（真机现场：心跳 150ms 返回，终端已经
      // 96 秒收不到字节）。所以判活多一道 PTY 维度的否决。
      if (probeFirst && !deadAtStart) {
        originalTransport.heartbeat();
        await Future.delayed(kProbeWaitDuration);
        final ptyStalled = isPtyStalled(
          isForeground: _isForegroundNow,
          ptySilenceMs: originalTransport.lastPtyDataAge.inMilliseconds,
          sinceLastWriteMs: originalTransport.sinceLastWrite?.inMilliseconds,
        );
        if (!originalTransport.isDead &&
            !originalTransport.quicPathDied &&
            !ptyStalled) {
          _logResume('[$tid] SKIP — heartbeat alive ${sw.elapsedMilliseconds}ms ✓');
          // **必须通知状态机**：它可能正停在 `recovering`（这次恢复就是它派
          // 的 StartResume 起的），而那一档是完全被动的 —— `_onTick` 只显示
          // 横幅、不判活（「判活的对象是旧连接，已经没了」）。这里直接 return
          // 而不喂任何事件的话，它永远等不到结果，横幅就一直挂着「重新连接
          // 中…」，而连接其实一直是通的。
          //
          // 2026-09-13 真机现场：`qstate:connected dead:false pathDied:false`
          // 配 `mphase:recovering`，心跳 150ms 就回来了，横幅却不走。
          //
          // `ProbeAnswered` 在这次改动之前**全项目零个发出点** —— 事件定义好
          // 了、状态机也处理了，只是从没有人发过它。删掉这一行会让
          // `conn_wiring_test.dart` 那条「不能再变回死事件」变红。
          runner?.feed(
              const conn.ProbeAnswered(), _factsFor(tab, originalTransport));
          // 探测命中：连接还活着，这次**没有发生恢复**。把 span 撤掉并记一次
          // 命中，而不是让 finally 兜成 abandoned —— 后者会让「探测省掉了一次
          // RESUME」和「恢复失败了」混成同一种记录，而前者正是 90s 阈值那个
          // 赌注要的证据（见 ResumeSampleLog.probeHits）。
          final span = _resumeSpans.remove(tab.id);
          if (span != null) resumeSamples.recordProbeHit(bucketFor(span.backgroundMs));
          return;
        }
        _logResume(ptyStalled
            ? '[$tid] heartbeat alive 但 PTY 停流 '
                '${originalTransport.lastPtyDataAge.inSeconds}s → RESUME'
            : '[$tid] heartbeat→pathDied → RESUME');
      }

      // ── Cheap-RESUME retry window ─────────────────────────────────────
      // Attempts at t = 0 / 0.5 / 1.5 / 3 s (kResumeRetryGaps), bounded by
      // kCheapResumeWindow. See those constants for why one attempt is not
      // enough at network-comeback time.
      AqtTransport? newTransport;
      var attempt = 0;
      while (true) {
        final attemptStartMs = DateTime.now().millisecondsSinceEpoch;
        _resumeSpans[tab.id]?.markFirstAttempt(attemptStartMs);
        final result = await _doResumeAttemptDetailed(originalTransport, tab);
        if (result is AqtResumeSuccess) {
          newTransport = result.transport;
          final span = _resumeSpans[tab.id];
          if (span != null) {
            // ② 终点 = ③ 起点：用 transport 自己记的 sentAt，而不是此刻 ——
            // 两者之间隔着 await 调度，用此刻会把调度延迟算进握手段。
            final ts = newTransport.lastResumeTimings;
            final sentMs = ts.sentAt?.millisecondsSinceEpoch;
            final ackMs = ts.ackAt?.millisecondsSinceEpoch;
            if (sentMs != null) span.markSent(sentMs);
            if (ackMs != null) span.markAck(ackMs);
            span.screenBytes = newTransport.lastResumeScreenBytes;
          }
          break;
        }
        final reason = result is AqtResumeFailed ? result.reason : null;
        // 这一次尝试自己花了多久 —— 与 sw.elapsed（本轮恢复的累计耗时）不同，
        // 后者还含探测、前几次尝试与它们之间的 gap。分辨「快速失败」靠的是
        // 前者，见 kFastFailureCeiling。
        final attemptElapsedMs =
            DateTime.now().millisecondsSinceEpoch - attemptStartMs;
        final decision = decideResumeRetry(
          pathDead: originalTransport.isDead,
          reason: reason,
          attempt: attempt,
          elapsed: sw.elapsed,
          attemptElapsed: Duration(milliseconds: attemptElapsedMs),
        );
        _logResume('[$tid] FAIL${attempt + 1} reason=${reason?.name ?? "noInfo"} '
            '${attemptElapsedMs}ms/${sw.elapsedMilliseconds}ms → ${decision.name}');
        _resumeSpans[tab.id]?.recordAttempt(
          reason: reason?.name ?? 'noInfo',
          elapsedMs: attemptElapsedMs,
        );
        if (decision == ResumeRetryDecision.keepOld) return;
        if (decision == ResumeRetryDecision.escalate) {
          // 只在 escalate 喂：keepOld 说明旧路还活着（喂了会把健康连接推进
          // backoff）；retry 是这个循环自己的重试、自带 kResumeRetryGaps，
          // 喂了会和状态机的 kBackoffMs 双重计数。escalate 才是终态失败。
          final trFail = tab.transport;
          if (trFail is AqtTransport) {
            _runners[tab.id]?.feed(
                conn.ConnectFailed(mapFailReason(reason ?? AqtResumeFailReason.unknownError)),
                _factsFor(tab, trFail));
          }
          break;
        }

        await Future.delayed(kResumeRetryGaps[attempt]);
        // The world may have moved while we slept: the tab could be gone, a
        // reconnect could have started, or another path could have swapped in
        // a new transport. Any of those makes this retry meaningless.
        if (!_sessionManager.tabs.contains(tab) ||
            _reconnecting.contains(tab.id) ||
            _retrying.contains(tab.id) ||
            tab.transport != originalTransport) {
          _logResume('[$tid] ABORT — state changed during backoff');
          return;
        }
        attempt++;
      }

      if (newTransport == null) {
        // Reaching here means the last decision was `escalate`, which implies
        // the path is dead — a live path returns via `keepOld` above.
        if (_sessionManager.tabs.contains(tab) &&
            !_reconnecting.contains(tab.id) &&
            !_retrying.contains(tab.id)) {
          _logResume('[$tid] → reconnect after ${attempt + 1} resume attempt(s) '
              '${sw.elapsedMilliseconds}ms');
          // skipFirstResume stays true: the cheap path just got a full window
          // of attempts, so repeating it as the reconnect's first step would
          // only add latency.
          _reconnectWithRetry(tab, trigger: 'aqtRoamFail', skipFirstResume: true);
        }
        return;
      }

      if (!_sessionManager.tabs.contains(tab) || tab.transport != originalTransport) {
        newTransport.close();
        _logResume('[$tid] DISCARD swapped');
        return;
      }

      _logResume('[$tid] OK ${sw.elapsedMilliseconds}ms ✓');
      // 把 span 从表里交接给渲染回调：它要活到帧渲染完，而 finally 马上
      // 就会跑。取走之后 finally 的 remove 会拿到 null，正确地判定「没有
      // 孤儿」；失败路径没走到这里，span 还在表里，finally 会兜住。
      final handedOff = _resumeSpans.remove(tab.id);
      // 局部 final 捕获：非空性由上面的 `newTransport == null` 早退保证，
      // 但让闭包捕获一个已知非空的局部变量，比让读者去推理控制流更自明。
      final swapped = newTransport;
      // ⑤ 段：快照渲染完成时闭合样本。
      // `onResumeRenderComplete` 由 SessionTab 保证**至多触发一次**
      // （它在派发的同一个同步块里就把字段置空），所以这里不必自己防重复。
      //
      // **必须在 _swapTransport 之前赋值**：它会走到 _installAqtTransport →
      // startStreaming()，那之后字节才开始被监听器消费、preludeReplayRemaining
      // 才可能归零并就地捕获这个回调。挪到任何 await 之后，捕获时读到的就是
      // null，⑤ 段会静默丢失且没有任何信号。
      tab.onResumeRenderComplete = (renderedAtMs) {
        if (handedOff == null) return;
        // ④ 终点 = ⑤ 起点：快照末字节抵达的时刻，由 transport 记。
        final done = swapped.lastResumeTimings.replayCompleteAt;
        if (done != null) {
          handedOff.markTransferDone(done.millisecondsSinceEpoch);
        }
        resumeSamples.add(handedOff.close(
          t5: renderedAtMs,
          outcome: ResumeOutcomeKind.ok,
        ));
      };
      _swapTransport(tab, originalTransport, newTransport);
    } catch (e) {
      final dead = originalTransport.isDead;
      _logResume('[$tid] EXC ${e.toString().substring(0, e.toString().length.clamp(0, 30))} dead=$dead');
      if (dead &&
          _sessionManager.tabs.contains(tab) &&
          !_reconnecting.contains(tab.id) &&
          !_retrying.contains(tab.id)) {
        _reconnectWithRetry(tab, trigger: 'aqtRoamException', skipFirstResume: true);
      }
    } finally {
      // span 还在表里 = 这次恢复没走到渲染完成（失败、被抢占、异常）。
      // 闭合成 abandoned 而不是留着悬挂 —— 悬挂的 span 会让下一次恢复的
      // putIfAbsent 复用一个陈旧的 t0，把两次恢复的耗时叠成一个假样本。
      //
      // 成功路径已经在上面把 span 取走交给渲染回调了，这里拿到 null。
      final orphan = _resumeSpans.remove(tab.id);
      if (orphan != null) {
        resumeSamples.add(orphan.close(
          t5: DateTime.now().millisecondsSinceEpoch,
          outcome: ResumeOutcomeKind.abandoned,
        ));
      }
      _proactiveResuming.remove(tab.id);
      // 与入口的 ResumeStarted 成对。**必须在 finally**：本方法有一条既不喂
      // ConnectedOk 也不喂 ConnectFailed 的退出路径（「cold RESUME 无可用结果，
      // 走回退链」），漏掉这里 inFlight 就永远停在 true，这个 tab 之后再也发
      // 不出恢复 —— 并发 bug 变永久死锁。
      //
      // fromMachine 那条也要清：状态机在 _enterRecovering 里置的位，同样得有
      // 人负责放下。成功/失败路径已经各自清过，这里是幂等兜底。
      _runners[tab.id]
          ?.feed(const conn.ResumeSettled(), _factsFor(tab, originalTransport));
      _proactiveResumeCompleters.remove(tab.id)?.complete();
    }
  }

  /// One cheap RESUME attempt, keeping the failure reason so the retry policy
  /// can tell "path not ready yet" (retryable) from "session is gone" (not).
  ///
  /// Returns null when RESUME cannot be attempted at all — no session info in
  /// the live transport and none on disk either.
  Future<AqtResumeResult?> _doResumeAttemptDetailed(
      AqtTransport aqt, SessionTab tab) async {
    final budget = _selectResumeBudget(tab);

    // Preferred source: the still-referenced (if dead) transport.
    final port = aqt.lastPort;
    final spki = aqt.lastSpki;
    final token = aqt.sessionToken;
    final tabId = aqt.lastTabId;
    if (port != null && spki != null && token != null && tabId != null) {
      final seq = appendResumeIssue(
        site: 'proactive/live',
        tabId: tab.id,
      );
      final r = await AqtTransportFactory.tryResumeWithInfoDetailed(
        host: tab.server.host,
        port: port,
        spki: spki,
        sessionToken: token,
        tabId: tabId,
        budget: budget,
        route: aqt.route,
        openRelay: (p) => openAqtRelay(tab, p),
      );
      _noteResumeOutcome(seq, r);
      return r;
    }

    // Fallback: the persisted session info the cold-start path uses. Without
    // this, a transport that died before it ever recorded its metadata would
    // skip the cheap path entirely and go straight to SSH bootstrap, even
    // though a perfectly usable token is sitting in SecureStorage.
    AqtSessionState? info;
    try {
      info = await _aqtSessionStateRepo?.load(tab.id);
    } catch (_) {}
    if (info == null) {
      _logResume('[${_shortTabId(tab.id)}] resume skip: no session info');
      return null;
    }
    final seq = appendResumeIssue(
      site: 'proactive/disk',
      tabId: tab.id,
    );
    final r = await AqtTransportFactory.tryResumeWithInfoDetailed(
      host: tab.server.host,
      port: info.port,
      spki: Uint8List.fromList(info.spki),
      sessionToken: Uint8List.fromList(info.sessionToken),
      tabId: info.aqtTabId,
      budget: budget,
      route: info.route,
      openRelay: (p) => openAqtRelay(tab, p),
    );
    _noteResumeOutcome(seq, r);
    return r;
  }

  /// 把 [AqtResumeResult] 归一成一行结果日志，配 [appendResumeIssue] 的序号。
  /// 失败分支带上 reason —— 区分"路径还没通"(可重试) 和"会话没了"(不可重试)
  /// 正是 [decideResumeRetry] 的判据，日志里看不到就没法验证它判对没有。
  static void _noteResumeOutcome(int seq, AqtResumeResult r) {
    appendResumeResult(
      seq: seq,
      outcome: resumeOutcomeLabel(r),
      replayBytes:
          r is AqtResumeSuccess ? r.transport.lastResumeScreenBytes : null,
    );
  }

  /// resume issue log 里那一行结果的文本。
  ///
  /// `networkTimeout` 额外带 `hs:ok` / `hs:--`（握手通没通，见
  /// [AqtResumeFailed.reachedConnected]）—— 只有它对两种完全不同的故障一视同
  /// 仁，而那正是 2026-09-05 18:49 现场分不开的岔路：连着两发 `proactive/live`
  /// 都恰好打满 budget 报 networkTimeout，0.7 秒后 `fullreconn` 用同一个 addr、
  /// 同一个 token、同一个 FFI 函数 253ms 就成功了。
  ///
  /// 其余归类不带后缀：`sessionNotFound` 说明服务端明确答复过（握手当然通），
  /// `handshakeFailed` 名字本身已经回答了这个问题。debug overlay 一行宽度有限，
  /// 只在有歧义的地方花字符。
  static String resumeOutcomeLabel(AqtResumeResult r) => switch (r) {
        AqtResumeSuccess() => 'OK',
        AqtResumeFailed(
          reason: AqtResumeFailReason.networkTimeout,
          :final reachedConnected
        ) =>
          'FAIL networkTimeout hs:${reachedConnected ? "ok" : "--"}',
        AqtResumeFailed(:final reason) => 'FAIL ${reason.name}',
      };

  /// 唯一的 AQT transport 装配入口。
  ///
  /// 从前四个装配点各写各的，且已经飘散：只有 _swapTransport 转移了按键缓冲、
  /// 只有它做了回放分流，FULLRECONN 分支甚至完全没重置 serverRingOff。
  /// **分歧本身就是 bug**，所以这段逻辑现在只有这一份。
  ///
  /// [sentLastOutOff] 是产生 [next] 的那次 RESUME 实际发上线的 last_out_off：
  ///   == 0 → cold RESUME，服务端回放最多 256 KB 权威历史
  ///   >  0 → hot  RESUME，服务端只回放自上次 ack 以来的 delta
  /// 当 [next] 来自 HELLO（`wasResumed == false`）时该值无意义、被忽略。
  ///
  /// [old] 会被 freeze → 抽走待发按键 → close。若调用方已经提前关掉了旧
  /// transport（FULLRECONN 就是这样），改为把预先抽出的按键从 [carryInput]
  /// 传进来。
  Future<void> _installAqtTransport(
    SessionTab tab,
    AqtTransport next, {
    required String source,
    AqtTransport? old,
    Uint8List? carryInput,
  }) async {
    // 诊断埋点（不是修复）——验证"二次装配"假设，见任务 #53 / #55。
    // 记录本次装配的来源、发上线的 lastOutOff、这次 RESUME 实际回放的字节数、
    // 装配前 tab.serverRingOff 的旧值（下面几行会覆写它）。
    _logResume('[${_shortTabId(tab.id)}] INSTALL src=$source '
        'wasResumed=${next.wasResumed}');
    if (old != null) {
      old.freeze();
    }
    // Transfer any input the user typed during the outage to the new
    // transport. Once `next` transitions to connected it auto-flushes the
    // buffer — without this the user silently loses everything they typed
    // while the old transport was dead.
    //
    // Two buffers, and the order between them is chronological, not arbitrary:
    // the transport-level one collected keystrokes while `old` still existed
    // but couldn't reach the server; the tab-level one collected them after
    // ReconnectService nulled tab.transport for the SSH chain. Concatenating
    // them the other way round would reorder the user's typing.
    next.adoptPendingInput(_concatInput(
      carryInput ?? old?.drainPendingInput(),
      tab.drainPendingInput(),
    ));
    tab.transport = next;
    tab.clearRemoteTuiHintForNewTransport(); // prevent stale ?25l from old session

    // HELLO：服务端开了一个全新会话，本地残留的 alt buffer / 滚动边距 / SGR
    // 都属于上一个会话，必须清掉。RESUME 走不到这里——续传绝不能复位，理由
    // 见 _resetTerminalForNewSession。
    if (!next.wasResumed) {
      _resetTerminalForNewSession(tab);
    }

    if (next.wasResumed) {
      await _applyResumeDisposition(tab, next);
    }

    // 快照字节预算：让 SessionManager 的输出监听能数出「快照流完了」这个
    // 时刻，进而打上 replayCompleteAt。
    //
    // **无条件赋值**，不要写成 `if (wasResumed) { ... }` —— SessionTab 跨
    // 重连复用，而 HELLO 路径没有任何别处会重置这个字段。一次 RESUME 若在
    // 快照放完前又断了，残值会留在 tab 上；随后若服务端因会话过期返回
    // HELLO，那些残值会去啃新会话的开头字节，归零时给一个根本没有快照的
    // 会话打上虚假的 replayCompleteAt，进而伪造出一个恢复样本。
    //
    // HELLO 是全新会话，没有快照可言，所以取 0。
    //
    // 放在 startStreaming 之前是为了顺序清晰，而不是因为「晚设会丢字节」：
    // _outputCtrl 是单订阅 controller，没有监听者时事件会缓冲，真正的
    // 订阅发生在 startStreaming 里。即便中间隔着 await，也不会有字节抢跑。
    //
    // 判别用 `next.wasResumed`，不是「HELLO 反正 lastResumeScreenBytes 会
    // 是 0」——`lastResumeScreenBytes` 自己的文档写明「返回 0 有四种成因，
    // 无法区分」，其中就包括客户端符号缺失（构建问题）和 transport 已
    // close 这两种跟「是不是 HELLO」毫无关系的情况。`wasResumed` 是工厂
    // 装配时就地写死的 Dart 侧布尔量，语义确定、不受这些噪声干扰，才是
    // 正确的判别式；`lastResumeScreenBytes` 只用来喂具体字节数，不该兼
    // 职做 HELLO/RESUME 的分派依据。
    tab.preludeReplayRemaining =
        next.wasResumed ? next.lastResumeScreenBytes : 0;

    // prelude 头部十六进制捕获的预算。**这一行是补回来的，不是新加的。**
    //
    // 采集逻辑一直在 stdout listener 里（`preludeCaptureRemaining > 0` 那段），
    // 但把预算设成非零的那一行，在某次重构里随 `_swapTransport` 的旧实现一起
    // 消失了 —— 全仓库从此没有任何地方给它赋非零值，于是 `lastPreludeHexHead`
    // 恒为空串，而 overlay 里 `prelude:` 那行带 `isNotEmpty` 守卫，就此永不
    // 渲染。一条专门为「恢复负载到底断在哪个字节」设计的诊断，静默死了，
    // 且没有任何信号 —— `session_manager.dart` 里那句「set to 16 by
    // _swapTransport」的注释还留着，描述的是已经不存在的代码。
    //
    // 与 `preludeReplayRemaining` 同源放置：两者都是「这次装配要观测多少
    // 字节」，也都必须在 `startStreaming` 之前设好。
    //
    // HELLO 也捕获（不像上面那行按 wasResumed 分流）：这 16 字节回答的是
    // 「新流的头几个字节长什么样」，对全新会话同样有诊断价值，而代价是
    // 一次 16 字节的十六进制拼接。
    //
    // 每次装配都要清空累积串，否则第二次恢复会把新旧两段接在一起，读的人
    // 会把上一代的 prelude 当成这一代的。
    tab.lastPreludeHexHead = '';
    tab.preludeCaptureRemaining = 16;

    // 本方法的 4 个调用点都是 fire-and-forget（没有 await、没有 catch），
    // 所以这里抛出的异常会变成 unhandled Future error：只进 logcat，UI 上
    // 毫无痕迹。而它吃掉的是下面两行 —— registerAqtTab 决定「会话死了能不能
    // 被发现」，old.close() 决定旧 transport 会不会泄漏。两者都比这次装配本身
    // 更不能少，所以 startStreaming 单独兜住，失败进 resume log（debug overlay
    // 可见），流程继续往下走。
    try {
      tab.startStreaming(
        source: 'installAqtTransport:$source',
      );
    } catch (e) {
      _logResume('[${_shortTabId(tab.id)}] startStreaming EXC: $e');
    }
    // 「连上了」= 已接好线、能收数据。若在 tab.transport = next 处就喂，
    // observeStartMs 会早于 listener 装好，轨迹里会出现一段「已连接却收不到
    // 任何东西」的假象，给日后排查添噪。
    _runners[tab.id]?.feed(const conn.ConnectedOk(), _factsFor(tab, next));
    registerAqtTab(tab);
    old?.close();

    // 装配成功 = 这条 tab 有了一条经服务端确认的 transport。**必须在这里清掉
    // connectionError**，否则 tab 上那个红点会一直留着。
    //
    // `connectionError` 原有的清除点全在「开始重连时」——`_reconnect` 入口
    // 与重试倒计时中，目的都是让 UI 显示 spinner 而不是错误屏。**没有一处
    // 是「恢复成功时」。** 而 QUIC 的 proactive resume 完全绕过 `_reconnect`，
    // 于是这个时序会留下一个永久的红点：
    //
    //   一次连接超时 → connectionError = 'TimeoutException: …'（红点）
    //   → proactive resume 291ms 恢复成功 → 没有任何人清它
    //   → qstate:connected / RESUMED✓ / 字节在流动，圆点却还是红的，
    //     一直红到下一次完整重连
    //
    // Mosh v2 早就有这条清理（`onAuthenticatedPacket` 里那段），它的注释写
    // 的是同一个症状：「Without this the tab dot can stay red-blinking for
    // tens of seconds while real bytes are landing」。QUIC 缺的就是那个对
    // 等物。
    //
    // 放在这里而不是各个调用点：本方法是 QUIC 的**统一装配点**
    // （proactiveResume / coldHydrate / earlyResumed 都经过它），而它们走到
    // 这里的共同含义恰好就是「一条能用的 transport 装上了」。去逐个调用点
    // 清等于把同一条不变量抄四遍，抄漏一个就是这个 bug 本身。
    //
    // 时机比 Mosh 那处更靠后、更硬：Mosh 等的是第一个 auth packet，而能走到
    // 这里说明 RESUME 握手已经带着服务端的 replay 确认回来了。
    //
    // `isReconnecting` 一并清掉，与 Mosh 那处一致。即便外层
    // `_reconnectWithRetry` 还在跑它的 tmux / post-setup 步骤也照清 —— 那正
    // 是 Mosh 注释里说的：transport 上有真实流量就意味着会话无疑活着，UI 没
    // 有理由继续显示重连中。
    if (clearStaleErrorState(tab)) {
      _sessionManager.notifyTabChanged();
    }
  }

  /// 清掉一条 tab 上残留的错误态。返回 true 表示确实清了东西，调用方据此决定
  /// 要不要 `notifyTabChanged()` —— 没变就不刷 UI。
  ///
  /// **抽成 static 只为一件事：可测。** 在这之前 `ReconnectService` 的实例
  /// 行为一行测试都没有（整个 test/ 目录里没有任何地方构造过它，也没有任何
  /// 地方碰过 `connectionError`），而这条不变量 ——「装上了一条能用的
  /// transport，就不该再显示连接错误」—— 恰恰是那个「连上了但圆点一直红」
  /// 的 bug 的全部内容。它值得有测试守着，而守它不该要求先搭起半个 app。
  static bool clearStaleErrorState(SessionTab tab) {
    if (tab.connectionError == null && !tab.isReconnecting) return false;
    tab.connectionError = null;
    tab.isReconnecting = false;
    return true;
  }

  /// 顺序拼接两段待发按键，任一为空时避免多余拷贝。

  static Uint8List? concatPendingInput(Uint8List? first, Uint8List? second) =>
      _concatInput(first, second);

  static Uint8List? _concatInput(Uint8List? first, Uint8List? second) {
    if (first == null || first.isEmpty) return second;
    if (second == null || second.isEmpty) return first;
    final out = Uint8List(first.length + second.length);
    out.setAll(0, first);
    out.setAll(first.length, second);
    return out;
  }

  /// 把终端复位到干净状态，供**新会话**开始前使用。
  ///
  /// 只有"确实开了一个新 shell"才该调用：SSH / Mosh 的每次重连，以及 QUIC
  /// 回落到 HELLO 的时候。QUIC RESUME 成功时**绝不能**调用——那是续传，远端
  /// PTY 还在原来的状态里跑着，`?1049l` 会把 TUI 那一屏丢掉，而续传路径只发
  /// delta、没有任何东西再去重画，屏幕就黑在那里且无法自愈。
  ///
  /// try-catch 包住：xterm 的 IndexAwareCircularBuffer.moveChild 在某些
  /// buffer 状态下 useMainBuffer() 会触发 null-check bug（xterm 自身问题）。
  /// 这里崩掉不能连累重连本身。
  void _resetTerminalForNewSession(SessionTab tab) =>
      resetTerminalForNewSession(tab.terminal);

  @visibleForTesting
  static void resetTerminalForNewSession(Terminal terminal) {
    try {
      terminal.write('\x1b[?1049l'); // exit alt-buffer
      terminal.write('\x1b[r'); // reset scroll margins (DECSTBM)
      terminal.write('\x1b[m'); // reset SGR attributes
      terminal.write('\x1b[!p'); // DECSTR soft-reset (stub in xterm 4.x)
      terminal.write('\x1b[?25h'); // show cursor — DECSTR doesn't reset
      // cursorVisibleMode in xterm 4.x, so an old session that hid the cursor
      // (TUI app) leaves cursorVisibleMode=false, routing scroll to SGR until
      // the new session's first frame arrives.
    } catch (_) {}
  }

  /// `AqtResumeFailReason` → 状态机的 `FailReason`。
  ///
  /// 两个枚举故意分开：状态机所在的 `conn/` 目录对 factory 层零依赖，
  /// 否则「纯函数、可在纯 Dart 测试里跑」这个前提就破了。映射放在接线层
  /// 是它该在的位置。
  @visibleForTesting
  static conn.FailReason mapFailReason(AqtResumeFailReason r) => switch (r) {
        AqtResumeFailReason.networkTimeout => conn.FailReason.networkTimeout,
        AqtResumeFailReason.sessionNotFound => conn.FailReason.sessionNotFound,
        AqtResumeFailReason.handshakeFailed => conn.FailReason.handshakeFailed,
        AqtResumeFailReason.unknownError => conn.FailReason.unknownError,
      };

  /// 组装 Facts。**字段直取，不做任何加工** —— 加工就是判断，而判断只许在
  /// `step()` 里。一旦这里出现 if 或算术，「单一真相」就又漏了。
  @visibleForTesting
  static conn.Facts readFacts({
    required int nowMs,
    required int rawRecvAgeMs,
    required int rebindCount,
    required bool isForeground,
    required String networkType,
    int ptySilenceMs = 0,
    int? sinceLastWriteMs,
    bool canSwitchPath = false,
  }) =>
      conn.Facts(
        nowMs: nowMs,
        rawRecvAgeMs: rawRecvAgeMs,
        rebindCount: rebindCount,
        isForeground: isForeground,
        networkType: networkType,
        ptySilenceMs: ptySilenceMs,
        sinceLastWriteMs: sinceLastWriteMs,
        canSwitchPath: canSwitchPath,
      );

  /// 服务端处置 → 终端动作。**唯一**一份实现。
  ///
  /// 抽成静态是为了让测试能调真实代码。此前
  /// `test/ssh/aqt_transport_install_test.dart` 手工复刻了这段分派逻辑并
  /// 在复刻里正确地写了 screen —— 而真实代码里那次 write 根本不存在，测试
  /// 却一直是绿的，直到真机上表现为「连上了但屏幕全空」。复刻测试对
  /// 「被测代码少了一行」是免疫的，所以这里不再留第二份实现。
  @visibleForTesting
  static void applyDispositionToTerminal(
      Terminal terminal, AqtDisposition? d) {
    switch (d) {
      case AqtRestored():
        // 什么都不做。
        //
        // 恢复内容不再经这里 —— 服务端把它作为新 PTY 流的头几个字节送出，
        // 与 live 输出同属一条有序流，由 startStreaming 的监听器照常写进
        // 终端。客户端不需要区分「哪些字节是恢复内容」，也就不需要旧
        // prelude 时代那三个计数器。
        break;
      case AqtNewSession():
        // 唯一该复位终端的路径。
        resetTerminalForNewSession(terminal);
      case AqtTabGone():
        // **不**复位：用户还在看那些输出，进程退出不该把它清掉。
        break;
      case null:
        // 服务端没给处置（旧 .so / 拿不到 handle）——什么都不做比猜安全。
        break;
    }
  }

  void _swapTransport(SessionTab tab, AqtTransport old, AqtTransport next) {
    // 必须在 _installAqtTransport 覆写 tab.serverRingOff 之前读取：此刻它仍是
    _installAqtTransport(tab, next, source: 'proactiveResume', old: old);
    _sessionManager.notifyTabChanged();
  }




  /// 应用服务端声明的处置。
  ///
  /// 这里**没有任何分支在猜服务端做了什么** —— 它只是把 Disposition 摊开。
  /// 旧实现（seedServerRingOff + serverRebuiltReplay + resumeReplayMode 三件套）
  /// 用 `server_out_off - replay_bytes` 的算术推断「续传还是重建」，再在四种
  /// 模式间分派；服务端一改语义那个判据就静默失效。
  Future<void> _applyResumeDisposition(
      SessionTab tab, AqtTransport next) async {
    final d = next.takeResumeDisposition();

    // 这里只做 tab 记账；终端动作统一交给 applyDispositionToTerminal，
    // 全项目**唯一**一份实现（见那个方法的文档：复刻出过事故）。
    switch (d) {
      case AqtRestored(:final serverInSeenOff):
        tab.serverInSeenOff = serverInSeenOff;
        // 恢复内容会从新 PTY 流重新灌满终端，渲染计数归零。
        tab.renderedOutputBytes = 0;
        // 历史不需要在这里做任何事：恢复负载**自带**服务端 parser 里的整段
        // primary scrollback，一次写完。
        //
        // 这里曾经起一个后台 `_backfillScrollback`，用 `FetchScrollback` 把更早
        // 的历史取回来、再前插到 buffer 顶部。整条链路删掉了 —— 它前插的是
        // `LineRing` 的原始字节行（重复内容的来源之一），而且预取是网络往返，
        // 回来时终端可能已经被新一轮 resume 换代，插进去就是把上一代历史叠在
        // 新历史前面。守卫补过两轮（`shouldPrependBackfill`、
        // `_awaitResumeContentRendered`）仍然只是缩小窗口。

      case AqtTabGone(:final exitStatus):
        _logResume('[${_shortTabId(tab.id)}] tab gone on server'
            '${exitStatus != null ? " (exit $exitStatus)" : ""}');

      case AqtNewSession():
      case null:
        break;
    }

    applyDispositionToTerminal(tab.terminal, d);
  }


  /// Reconnect all disconnected tabs. Called at startup for restored tabs and
  /// by connectivity / lifecycle events for dropped connections.
  Future<void> reconnectAll() =>
      _reconnectDisconnected(trigger: 'reconnectAll');

  /// Reconnect a specific tab on demand (e.g. lazy reconnect on tab switch).
  /// Active mosh tabs are skipped — their UDP session manages reconnection natively.
  /// Dead mosh tabs (moshShell == null, session died) are reconnected.
  Future<void> reconnectTab(SessionTab tab) {
    if (tab.isMosh && tab.moshShell != null) return Future.value();
    return _reconnect(tab);
  }

  /// Retry-aware wrapper around [_reconnect].
  /// On failure, waits [_kRetryDelays[i]] then tries again, up to 3 extra
  /// attempts. Stops early if the tab is no longer in the session list
  /// (closed by user) or if [_reconnect] succeeds (connectionError == null).
  Future<void> _reconnectWithRetry(
    SessionTab tab, {
    String trigger = 'unknown',
    bool skipFirstResume = false,
  }) async {
    if (_retrying.contains(tab.id)) return;
    _retrying.add(tab.id);
    // Consume the one-shot foreground fast-path flag (set by onForegroundResumed).
    // true  → use fast-path budget: no banner delay, single attempt (no retries).
    // false → normal retry curve for this trigger.
    final fastPath = _foregroundFastPathRegistry.take(tab.id);
    final round = (_reconnectRound[tab.id] ?? 0) + 1;
    _reconnectRound[tab.id] = round;
    _bannerTimers[tab.id]?.cancel();
    final budget = resumeUiBudget(trigger: trigger, fastPath: fastPath);
    final bannerDelay = budget.bannerDelay;
    if (bannerDelay == Duration.zero) {
      // 已失败转级类 trigger（目前只有 moshV2SoftFailed/full）：立即显示 banner。
      // 注意同步执行：mosh soft 失败 finally 刚把 isReconnecting=false +
      // notifyTabChanged，这里立刻 set true + notify。两次 notify 之间没
      // 有 await，Flutter 会合并到同一帧，最终渲染 true 不出现 flicker。
      tab.isReconnecting = true;
      _sessionManager.notifyTabChanged();
      _logResume('[${_shortTabId(tab.id)}] banner shown immediately (trig=$trigger)');
    } else {
      _bannerTimers[tab.id] = Timer(bannerDelay, () {
        if (_retrying.contains(tab.id)) {
          tab.isReconnecting = true;
          _sessionManager.notifyTabChanged();
          _logResume('[${_shortTabId(tab.id)}] banner shown (>${bannerDelay.inMilliseconds}ms trig=$trigger)');
        }
      });
    }
    final tid = _shortTabId(tab.id);
    // Fast-path: single attempt with no inter-attempt delays. If this attempt
    // fails the flag is already consumed, so the next caller uses normal delays.
    // 与 bannerDelay 取自同一个 resumeUiBudget，避免两处各算一遍再漂移。
    final retryDelays = budget.retryDelays;
    _logResume('[$tid] RWR enter trig=$trigger round=$round fastPath=$fastPath attempts=${retryDelays.length + 1} skipResume=$skipFirstResume');

    // Serialise RESUME attempts: if a proactive resume is already in-flight
    // for this tab, wait for it to finish before issuing our own.
    // Without this guard, both paths send RESUME to the server concurrently
    // with the same session token — both can get RESUME_ACK (server race
    // window), and the DISCARD-swap close() may kill the server session,
    // leaving the survivor as a phantom-connected transport.
    final proactiveCompleter = _proactiveResumeCompleters[tab.id];
    if (proactiveCompleter != null && !proactiveCompleter.isCompleted) {
      _logResume('[$tid] RWR wait: proactive in-flight');
      await proactiveCompleter.future.timeout(
        const Duration(seconds: 13), // tryResume budget + small buffer
        onTimeout: () {},
      );
      if (!_sessionManager.tabs.contains(tab)) return;
      // If proactive succeeded, the transport is already alive — skip reconnect.
      final aqt = tab.transport;
      if (aqt is AqtTransport && !aqt.isDead) {
        _logResume('[$tid] RWR skip: proactive won');
        _retrying.remove(tab.id);
        // 这条 return 在 try 之前，走不到下面的 finally。proactive 已经把
        // 连接接回来了，上一轮留存的元数据再无用武之地，就地释放。
        _discardResumeMeta(tab.id);
        tab.isReconnecting = false;
        _sessionManager.notifyTabChanged();
        return;
      }
      _logResume('[$tid] RWR continue: proactive failed/timed out');
    }
    var lastErr = '';
    var attemptsRun = 0;
    try {
      for (var i = 0; i <= retryDelays.length; i++) {
        if (!_sessionManager.tabs.contains(tab)) return;
        attemptsRun = i + 1;
        // 90s global timeout guards against any unbounded await inside
        // _reconnect (e.g. slow SSH exec, blocked bootstrap stream).
        // Without this, _reconnecting holds the tab.id forever and the
        // periodic timer skips the tab — permanent "reconnecting" with no
        // recovery (a5.jpg symptom: QUIC-? + ssh:open + recon:Y stuck).
        await _reconnect(
          tab,
          firstAttempt: i == 0,
          skipEarlyResume: i == 0 && skipFirstResume,
        ).timeout(
          _selectReconnectTimeout(firstAttempt: i == 0),
          onTimeout: () {
            _logResume('[$tid] RWR attempt=${i + 1} layered timeout');
            tab.connectionError = 'timeout';
            // G2 (k9.jpg): _reconnect adds tab.id to _reconnecting at the
            // top of its body (line ~1971) and removes it only in finally
            // (line ~2655). Dart's `Future.timeout()` does NOT cancel the
            // inner future — when our layered timeout fires here, the
            // inner _reconnect is still hung on some await (e.g.
            // bootstrapDaemonStrict step 2 / step 3), its finally hasn't
            // run, and _reconnecting permanently contains tab.id. The
            // 3 s periodic ticker then skips this tab forever and the
            // session shows recon:N + ssh:closed + transport=null with
            // no auto-recovery. Force-release the lock here so the next
            // tick can pick the tab up.
            _reconnecting.remove(tab.id);
          },
        );
        if (tab.connectionError == null) {
          _logResume('[$tid] RWR success @attempt=${i + 1}');
          _reconnectRound.remove(tab.id); // reset on success
          return;
        }
        lastErr = tab.connectionError ?? 'unknown';
        final lastErrShort = lastErr.length > 30 ? lastErr.substring(0, 30) : lastErr;
        _logResume('[$tid] RWR attempt=${i + 1} fail: $lastErrShort');
        if (i < retryDelays.length) {
          final delay = retryDelays[i];
          _setReconnectMessage(
            tab,
            ReconnectUiMessageCode.reconnectRetryCountdown,
            args: {
              'seconds': delay.inSeconds,
              'round': round,
              'attempt': i + 1,
              'total': retryDelays.length,
            },
            kind: ReconnectUiMessageKind.warning,
          );
          // Clear error during countdown so the UI shows spinner, not error screen.
          // The error screen has a "Back" button that looks like a permanent failure.
          tab.connectionError = null;
          _sessionManager.notifyTabChanged();
          await _retrySleepers.delay(tab.id, delay);
        }
      }
      // Exhausted all retries — log and let the periodic timer pick it up
      // next tick (now sees AqtTransport.isDead=true even when state is
      // sticky-reconnecting, so QUIC tabs really do re-enter the queue).
      _logResume('[$tid] RWR exhausted after $attemptsRun — periodic will retry');
    } finally {
      _bannerTimers.remove(tab.id)?.cancel();
      _retrying.remove(tab.id);
      // 重试链走完了（成功、放弃、或抛异常），留存的元数据到此为止：正常路径
      // 上它早已被 FULLRECONN 消费掉，这里兜的是「一次都没走到 FULLRECONN 就
      // 结束」的情形。**必须 close 而不是只删引用** —— 它还攥着 FFI handle
      // 和一条 QUIC 连接。
      _discardResumeMeta(tab.id);
      tab.isReconnecting = false;
      _sessionManager.notifyTabChanged();
    }
  }

  /// periodic sweep 的三集合忙碌判定。
  ///
  /// 存在的理由是**消除调用点重复**：这个判据在 `_reconnectDisconnected`
  /// 里有两处（主循环收集 pending 时、worker 取任务前的二次校验），两处
  /// 必须完全一致。原先各自手写三行取值，一致性只靠注释提醒维持 ——
  /// 而实际已经开始漂移（一处带花括号一处不带）。包成一个方法之后，
  /// 分叉在结构上不再可能。
  ///
  /// 纯判据本身留在 [shouldSkipPeriodicSweep]（static、可 device-free 单测）；
  /// 这里只负责从三个集合取值，没有独立测试的必要 —— 编译器已经保证两处
  /// 拿到的是同一份实现。
  bool _isTabBusy(String tabId) => shouldSkipPeriodicSweep(
        reconnecting: _reconnecting.contains(tabId),
        retrying: _retrying.contains(tabId),
        proactiveResuming: _proactiveResuming.contains(tabId),
      );

  Future<void> _reconnectDisconnected({
    String trigger = 'periodicTimer',
  }) async {
    // Collect tabs that need a real reconnect attempt — handle the
    // mosh-keepalive / mosh-stale book-keeping inline (those branches
    // do non-blocking work or just continue) and leave the heavy
    // [_reconnectWithRetry] for the parallel pass at the bottom.
    final pending = <SessionTab>[];
    for (final tab in _sessionManager.tabs) {
      if (tab.server.serverType == 'local') continue;
      if (tab.isMosh && tab.moshShell != null) {
        // v2 mosh tabs manage their own liveness via LivenessSupervisor and
        // _v2LivenessSubs — no v1 stale/semantic checks needed here.
        // Casting to MoshShell throws for MoshShellV2; skip entirely.
        if (tab.moshShell is MoshShellV2) {
          // v2 probe path: 3 s periodic check. If supervisor.lastInbound has
          // not advanced for a while, kick the existing socket (heartbeat) or
          // rebind it (roam). This is the safety net when connectivity_plus
          // does not fire on 4G→WiFi (some Android versions delay the event)
          // — without it, recovery waits the full supervisor 45 s/75 s cascade.
          //
          // Actions are non-destructive: heartbeat sends one empty ack packet,
          // roam swaps to a fresh ephemeral source port. Neither tears down
          // the session, kills mosh-server, or shows a reconnect banner.
          //
          // Rate-limit via _lastV2ProbeAt so we don't churn UDP sockets every
          // 3 s under sustained outage — the supervisor will hard-reconnect at
          // 75 s regardless.
          if (!_reconnecting.contains(tab.id) &&
              !_retrying.contains(tab.id)) {
            final v2 = tab.moshShell as MoshShellV2;
            final ageSec = v2.supervisorLastInboundAgeMs ~/ 1000;
            final last = _lastV2ProbeAt[tab.id];
            final sinceLast = last == null
                ? const Duration(days: 1)
                : DateTime.now().difference(last);
            if (ageSec > 8 && sinceLast.inSeconds >= 10) {
              debugPrint(
                '[ReconnectService] v2 stale ${ageSec}s → heartbeat+roam',
              );
              try {
                v2.heartbeat();
                v2.roam();
              } catch (_) {}
              _lastV2ProbeAt[tab.id] = DateTime.now();
            } else if (ageSec > 5 && sinceLast.inSeconds >= 3) {
              debugPrint(
                '[ReconnectService] v2 stale ${ageSec}s → heartbeat probe',
              );
              try {
                v2.heartbeat();
              } catch (_) {}
              _lastV2ProbeAt[tab.id] = DateTime.now();
            }
          }
          if (tab.backend.needsControlPipeReinit &&
              !_reconnecting.contains(tab.id) &&
              !_retrying.contains(tab.id)) {
            _reconnectSshForMosh(tab).ignore();
          }
          continue;
        }
        continue;
      }
      if (_isTabBusy(tab.id)) continue;
      // For QUIC tabs: SSH client death is normal after network switch
      // (TCP socket dies but QUIC UDP path is independent). Only consider
      // the QUIC transport state — never SSH connection state.
      if (tab.transport?.kind == TransportKind.aqt) {
        // Use AqtTransport.isDead (covers _quicPathDied/_outputCtrl.isClosed
        // in addition to failed/closed). Why this matters: when the Rust
        // side fires Disconnected, our onDisconnected handler sets state
        // to `reconnecting` and `_quicPathDied=true` (sticky), then kicks
        // off proactive resume. If proactive + _reconnectWithRetry all
        // exhaust their attempts, transport.state is still `reconnecting`
        // forever — the old `state in {failed, closed}` check would skip
        // this tab on every periodic sweep, stranding the user in a
        // permanent "reconnecting" UI with no auto-recovery. Reading
        // isDead lets us re-arm reconnect on every 3 s periodic tick.
        final aqtT = tab.transport;
        final aqtDead = aqtT is AqtTransport
            ? aqtT.isDead
            : (aqtT?.currentState == TransportState.failed ||
                aqtT?.currentState == TransportState.closed);
        // Detect "phantom connected" state: QUIC handshake succeeded but the
        // server's PTY session stopped sending data. This happens when two
        // concurrent RESUME attempts both get RESUME_ACK (race window), and the
        // DISCARD-swap path closes the one the server was actually streaming to.
        // The surviving transport appears connected (no Disconnected event) but
        // never receives PTY data — isDead stays false, so without this check
        // the tab stays frozen indefinitely.
        //
        // 判据住在 AqtTransport.isPhantomStall，不在这里内联：AqtTransport
        // .softReconnect 必须读到同一份，否则 sweep 判出的幻影会被那边的
        // 「路径没死就算恢复」短路掉，重连变成每 3 秒一轮的空转（见
        // isPhantomStalled 处的注释）。
        final aqtPhantom =
            !aqtDead && aqtT is AqtTransport && aqtT.isPhantomStalled;
        if (aqtDead || aqtPhantom) {
          // Diagnostic: log WHY this tab is being added to pending so we can
          // distinguish "dead path" (QUIC errored) from "phantom" (no PTY data)
          // in the resume log when investigating rapid reconnect cycles.
          final tid = _shortTabId(tab.id);
          // 幻影这一支要记的是「发出去多久没回音」（判据本身），ptyAge 只是
          // 旁证 —— 只记 ptyAge 会让人误以为判据还是「静默多久」，那正是上
          // 一版把空闲当坏死的由来。
          final why = aqtDead
              ? 'dead/${aqtT is AqtTransport ? aqtT.deadReason : "?"}'
              : 'phantom/noEcho=${aqtT is AqtTransport ? (aqtT.sinceLastWrite?.inSeconds ?? -1) : -1}s'
                  ' ptyAge=${aqtT is AqtTransport ? aqtT.lastPtyDataAge.inSeconds : 0}s';
          _logResume('[$tid] periodic add pending: $why');
          pending.add(tab);
        }
        continue;
      }
      if (!tab.connection.isConnected ||
          (tab.isMosh && tab.moshShell == null)) {
        pending.add(tab);
      }
    }
    if (pending.isEmpty) return;
    // Run reconnects in parallel with a small concurrency cap. Serial
    // restore takes ~N × (TCP+KEX+auth) ≈ 300-700 ms each — for 5 tabs
    // that's up to 3.5 s before the user sees their last tab. Parallel
    // collapses to roughly the slowest single connection. Cap at 4 to
    // avoid burst-overwhelming the home network or one-host servers
    // (multiple tabs to the same host already share via the connection
    // pool, so concurrent acquires for the same key dedupe inside it).
    const maxConcurrent = 4;
    final queue = List<SessionTab>.from(pending);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final tab = queue.removeAt(0);
        // 二次校验：从收集 pending 到真正取到这个 tab，中间隔着前一个 tab
        // 的完整重连（await，15~30s 量级），状态很可能已经变了。
        if (_isTabBusy(tab.id)) continue;
        await _reconnectWithRetry(tab, trigger: trigger);
      }
    }

    await Future.wait([
      for (var i = 0; i < pending.length.clamp(1, maxConcurrent); i++) worker(),
    ]);
  }

  /// Reconnect SSH for an active mosh tab whose SSH connection has died.
  /// Mosh UDP session is untouched — only the SSH client is refreshed so that
  /// [TmuxControlPipe] can continue delivering tmux scroll/copy-mode commands.
  /// Silent — no "[重新连接中...]" banner shown to the user.
  /// Uses exponential backoff: 3s → 8s → 20s → 60s between attempts.
  Future<void> _reconnectSshForMosh(SessionTab tab) async {
    // Exponential backoff: skip until the retry window has elapsed.
    final retryAfter = _sshForMoshRetryAfter[tab.id];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;

    if (_reconnecting.contains(tab.id)) return;
    _reconnecting.add(tab.id);
    try {
      final creds = await _loadServerCreds(tab.server.id, tab.server).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('keystore creds load > 5s');
        },
      );
      final server = creds.server;
      final password = creds.password;
      final keyPairs = creds.keyPairs;
      final jump = creds.jump;
      final agentKeyPairs = creds.agentKeyPairs;
      await tab.connection.connect(
        host: server.host,
        port: server.port,
        username: server.username,
        password: password,
        keyPairs: keyPairs,
        jumpHost: jump?.host,
        jumpPort: jump?.port,
        jumpUsername: jump?.username,
        jumpPassword: jump?.password,
        jumpPrivateKeyPem: jump?.privateKeyPem,
        agentKeyPairs: agentKeyPairs,
        openShell:
            false, // mosh runs over UDP; SSH is only needed for exec channels
        firstAttempt: false,
        hostKeyVerifier: _hostKeyVerifier,
        pool: _connectionPool,
        keyId: server.keyId,
        jumpHostId: server.jumpHostId,
        addressFamily: server.addressFamily,
        sshCompression: _sshCompression,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('SSH connect > 10s'),
      );
      // Reinit control pipe via backend (no-op for NoneBackend).
      await tab.backend.reinitControlPipe(tab.connection, tab.sessionKey);
      // Success: reset backoff state.
      _sshForMoshRetryCount.remove(tab.id);
      _sshForMoshRetryAfter.remove(tab.id);
      debugPrint(
        '[ReconnectService] SSH for mosh tab ${tab.id} reconnected — pipe reinited',
      );
    } catch (e) {
      // Exponential backoff: 3s → 8s → 20s → cap at 60s.
      const delays = [3, 8, 20, 60];
      final count = (_sshForMoshRetryCount[tab.id] ?? 0) + 1;
      _sshForMoshRetryCount[tab.id] = count;
      final delaySecs = delays[(count - 1).clamp(0, delays.length - 1)];
      _sshForMoshRetryAfter[tab.id] = DateTime.now().add(
        Duration(seconds: delaySecs),
      );
      debugPrint(
        '[ReconnectService] SSH-for-mosh reconnect failed for ${tab.id}: $e — retry in ${delaySecs}s',
      );
    } finally {
      _reconnecting.remove(tab.id);
    }
  }

  Future<void> _reconnect(
    SessionTab tab, {
    bool firstAttempt = true,
    bool skipEarlyResume = false,
  }) async {
    if (_reconnecting.contains(tab.id)) return;
    if (_circuitBreakerTripped(tab)) return;
    _reconnecting.add(tab.id);
    // Clear any previous error so the spinner is shown while connecting.
    tab.connectionError = null;
    bool reconnectSucceeded = false;
    tab.moshStats.noteAttemptStart(firstAttempt ? 'first' : 'retry');
    try {
      // Cascade guard: ≥5 failures in 90 s → 30s cooldown.
      // Bypass if the network just recovered (connectivity type change or app
      // foreground after long pause) — the outage itself caused the cascade, and
      // delaying the first post-recovery attempt makes the session feel stuck.
      final lastComeback = _lastNetworkComebackTime;
      final comebackSecs =
          lastComeback != null
              ? DateTime.now().difference(lastComeback).inSeconds
              : null;
      final networkJustCameBack = comebackSecs != null && comebackSecs < 30;
      final cooldownNeeded =
          !networkJustCameBack &&
          shouldCooldown(tab.reconnectHistory, since: lastComeback);
      if (cooldownNeeded) {
        // For QUIC: keep the 30 s cooldown to prevent thrashing, but
        // SUPPRESS the "网络不稳定" banner. QUIC has its own seamless
        // recovery (proactive RESUME, lazy banner, input buffering) —
        // an explicit instability message during silent recovery defeats
        // the "no-banner" UX goal.
        final isQuicTab = tab.transport is AqtTransport ||
            tab.server.transport == Transport.quic;
        if (!isQuicTab) {
          _setReconnectMessage(
            tab,
            ReconnectUiMessageCode.reconnectNetworkUnstableRetry,
            kind: ReconnectUiMessageKind.warning,
          );
        }
        await Future.delayed(const Duration(seconds: 30));
      }
      // Stable-network self-heal grace: first disconnect on a healthy connection
      // — wait 1s to see if it's a transient blip before a full reconnect.
      final recentCount =
          tab.reconnectHistory
              .where(
                (e) => e.at.isAfter(
                  DateTime.now().subtract(const Duration(minutes: 5)),
                ),
              )
              .length;
      // QUIC/UDP: onDisconnected 触发即路径已死，无内核级重传，
      // 等 1s 无法自愈，只延迟重连。TCP-based (SSH/Mosh) 保留此 grace。
      final isQuicTab = tab.transport is AqtTransport ||
          tab.server.transport == Transport.quic;
      if (tab.networkStability.isStable && recentCount == 0 && !isQuicTab) {
        await Future.delayed(const Duration(seconds: 1));
        // QUIC tab 的 tab.connection 是 SSH bootstrap channel，QUIC 死了
        // SSH TCP 通常还活 (c1.jpg 现场: ssh:open + pathDied:true)。仅看
        // isConnected 会把"QUIC 死、SSH 还在"误判成已恢复，让 _reconnect
        // 提前 return，tab.transport 卡在 dead 状态 UI 永远不刷新。
        final t = tab.transport;
        final transportDead = t is AqtTransport && t.isDead;
        if (tab.connection.isConnected && !transportDead) {
          reconnectSucceeded = true;
          return;
        }
      }
      // Soft reconnect: try protocol-internal recovery first (QUIC path migration, Mosh roam).
      // If it returns true, the transport handled it without needing a full SSH re-auth cycle.
      if (!tab.isFirstConnection && tab.transport != null) {
        final handled = await tab.transport!.softReconnect();
        if (handled) {
          // Give the transport 2s to recover, then check if SSH shell is still OK.
          await Future.delayed(const Duration(seconds: 2));
          if (tab.connection.isConnected) {
            reconnectSucceeded = true;
            tab.networkStability.recordReconnectSuccess();
            _sessionManager.notifyReconnected();
            return;
          }
        }
      }
      // First-time connections (restored tabs) get no reconnect banner.
      // Only show reconnect messages for tabs that were previously connected.
      // QUIC 排除在外：这段复位是 SSH 时代的语义——SSH 重连意味着开一个新
      // shell，把终端复位到干净状态是对的。QUIC RESUME 是**续传**，远端 PTY
      // 还在 alt 模式跑着、会话根本没断，此时写 ?1049l 会把 TUI 那一屏丢掉，
      // 而服务端按续传只发 delta，没有任何东西再去重画 → 黑屏，且 offset 已
      // 推过那段 delta，服务端不会重发，自愈不了。
      //
      // QUIC 的复位改到 _installAqtTransport 里、确认服务端给的是 HELLO
      // （wasResumed == false，真的开了新会话）时才做。见 _resetTerminalForNewSession。
      if (!tab.isFirstConnection && tab.server.transport != Transport.quic) {
        _resetTerminalForNewSession(tab);
        // All protocols: skip the immediate banner — the kBannerDelay timer
        // in _reconnectWithRetry shows it after 1.5 s if still reconnecting.
        // Fast recoveries (< 1.5 s) are invisible to the user on all protocols,
        // matching the QUIC "silent RESUME" UX.
        // (Previously SSH/Mosh showed the banner immediately while QUIC waited
        //  1.5 s — this caused visible flicker on short network blips for SSH.)
      }
      // 从 DB 取最新配置，避免使用建 tab 时的快照（启动命令可能已更新）。
      // 走 _loadServerCreds 让并发 reconnect 共享一次 Keystore 加载。
      final creds = await _loadServerCreds(tab.server.id, tab.server).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('keystore creds load > 5s');
        },
      );
      final server = creds.server;
      final password = creds.password;
      const String? privateKeyPem = null; // 历史：始终 null，保留以兼容下游 API
      final keyPairs = creds.keyPairs;
      final jump = creds.jump;
      final agentKeyPairs = creds.agentKeyPairs;
      // For mosh (non-jump) tabs: skip PTY channel on SSH auth — mosh runs over
      // UDP and we never use the SSH PTY.  Saves ~3 RTTs (channel-open+pty+shell).
      final isMoshPath = server.transport == Transport.mosh && server.jumpHostId == null;

      // ── 冷启动会话恢复：从 SecureStorage 读 QUIC session 元数据 ──────────
      // App 被杀重开后 tab.transport=null，但 SecureStorage 里还存着上次的
      // token/port/spki/tabId。如果服务端 session 未过期（2h TTL）且 PTY 仍活，
      // 直接走 RESUME 即可恢复 Claude 会话，完全跳过 SSH 建连。
      final strategyForHydrate = server.transport;
      final isQuicHydrate = strategyForHydrate == Transport.quic;
      if (isQuicHydrate && tab.transport == null) {
        // 冷启动恢复：走 coordinator，不自己发 RESUME。
        //
        // 这里曾经有两条几乎一样的路径：claim 到了就自己发，claim 不到就等
        // prewarm 完再 adopt 它的结果 —— 两段的成功处理逐行相同，只有
        // `source` 字符串不一样。那个二分是 PrewarmPool.claimColdResume 两方
        // 去重留下的形状（没有它之前，生产日志里有 23 次同秒双连接）。
        //
        // coordinator 让「谁发的」这个区分消失：所有发起点共享同一个
        // in-flight，拿到的是同一个结果，于是两段合并成一段。
        //
        // transport 仍经 pool 移交 —— coordinator 只合并发起，不管所有权，
        // take() 的移交语义保证不会出现双重持有。
        final coordinator = _sessionManager.resumeCoordinator;
        if (coordinator != null) {
          await coordinator.ensureResumed(tab.id);
          final adopted = _sessionManager.prewarmPool.take(tab.id);
          if (adopted != null &&
              adopted.currentState == TransportState.connected) {
            _logResume('[${_shortTabId(tab.id)}] cold RESUME ok');
            _installAqtTransport(tab, adopted, source: 'coldHydrate');
            final wasFirstConn = tab.isFirstConnection;
            tab.isFirstConnection = false;
            reconnectSucceeded = true;
            tab.networkStability.recordReconnectSuccess();
            tab.moshStats.noteAttemptOk();
            // QUIC 快速 RESUME（<1.5s）时用户根本没看见 spinner，再弹一条
            // 成功提示等于凭空冒出一个横幅，反而破坏「无感重连」。
            final isQuicTab = tab.transport is AqtTransport ||
                tab.server.transport == Transport.quic;
            final silentReconnect = isQuicTab && !tab.isReconnecting;
            if (!wasFirstConn && !silentReconnect) {
              _setReconnectMessage(
                tab,
                ReconnectUiMessageCode.reconnectSuccess,
                kind: ReconnectUiMessageKind.success,
                ttl: const Duration(seconds: 2),
              );
            } else {
              tab.reconnectUiMessage = null;
            }
            _sessionManager.notifyReconnected();
            return;
          }
          // 没拿到可用 transport —— 落到下面的 pre-SSH RESUME / SSH bootstrap，
          // 与「本来就没有会话凭据」同一条路。失效凭据的清理由 coordinator
          // 的 doResume 统一负责（见 main.dart）。
          //
          // 为什么要记原因：a4.jpg 现场里 #19(coordinator) 记的是 OK —— 也就
          // 是说 doResume 一定走到了 `pool.store`（那条路径上 OK 与 store 是
          // 同一个分支）—— 可这里仍然判成「无可用结果」，紧接着又发了一条
          // #20(fullreconn)。一次成功的 RESUME 结果被丢掉，还多换了一条连接。
          // 两种成因要区分开才能往下查：
          //   pool 空   → 在 store 与 take 之间被另一个调用方取走了
          //   state=xx  → 取到了，但从 store 到 take 之间连接状态变了
          // 后者还意味着这条 transport 既没被用、也没被 close（泄漏）。
          final why = adopted == null
              ? 'pool empty'
              : 'state=${adopted.currentState.name}';
          _logResume(
              '[${_shortTabId(tab.id)}] cold RESUME 无可用结果（$why），走回退链');
        }
      }

      // ── QUIC: 在 SSH 建连之前先尝试 RESUME（第一次机会）────────────────────
      // RESUME 通过 UDP/QUIC 独立于 TCP 的 SSH 工作。在网络抖动场景下：
      //   - UDP 路径往往比 TCP 更早恢复（无握手开销）
      //   - RESUME 成功则完全跳过 SSH，节省 5-15s 并保留 Claude CLI 进程
      //   - RESUME 失败则保留旧 transport 元数据，供 SSH 完成后第二次 RESUME 使用
      //
      // 重要：pre-SSH RESUME 失败时 **不关闭** 旧 transport，而是将其保存到
      // prevAqtForFullreconn，由 QUIC FULLRECONN 块复用元数据做第二次尝试。
      // 两次机会设计：
      //   第1次（pre-SSH）：网络可能刚恢复，赶在 SSH 建连之前抢占
      //   第2次（FULLRECONN）：SSH 完成后（5-15s 后）网络已充分恢复时再试
      // 起手先把上一次尝试留存的元数据接回来。**不能只看 tab.transport** ——
      // 下面几行的 `tab.transport = null` 是永久副作用，而这个变量随每次
      // `_reconnect` 调用重置，只看前者会让 attempt 2 起彻底失去 RESUME 能力
      // （真机现场与完整推导见 `resumeMetaFor` 的文档）。
      AqtTransport? prevAqtForFullreconn = _takeResumeMeta(tab.id);
      final aqtStrategyForEarlyResume = server.transport;
      if (aqtStrategyForEarlyResume == Transport.quic && !skipEarlyResume) {
        final prevAqt = resumeMetaFor(
          tabTransport: tab.transport as AqtTransport?,
          stashed: prevAqtForFullreconn,
        );
        // 已经接手，避免下面 FULLRECONN 处重复消费同一个对象。
        prevAqtForFullreconn = null;
        if (prevAqt != null) {
          tab.transport = null; // 提前清空避免 FULLRECONN 块重复 close
          _logResume('[${_shortTabId(tab.id)}] pre-SSH RESUME start');
          // 记下真正发上线的 last_out_off —— 装配时要靠它判断 cold/hot。
          final earlySeq = appendResumeIssue(
            site: 'preSsh',
            tabId: tab.id,
          );
          final earlyResumed = await AqtTransportFactory.tryResume(
            prevAqt,
            server.host,
            openRelay: (p) => openAqtRelay(tab, p),
          );
          // tryResume 只返回 transport?，拿不到 AqtResumeFailReason —— 这里
          // 的 FAIL 天然比其它站点粗，不是漏写。
          appendResumeResult(
            seq: earlySeq,
            outcome: earlyResumed != null ? 'OK' : 'FAIL',
            replayBytes: earlyResumed?.lastResumeScreenBytes,
          );
          if (earlyResumed != null) {
            // RESUME 成功：跳过 SSH，直接使用恢复的 transport
            _logResume('[${_shortTabId(tab.id)}] pre-SSH RESUME ok');
            _installAqtTransport(tab, earlyResumed,
                source: 'preSshResume',
                old: prevAqt);
            final wasFirstConn = tab.isFirstConnection;
            tab.isFirstConnection = false;
            reconnectSucceeded = true;
            tab.networkStability.recordReconnectSuccess();
            tab.moshStats.noteAttemptOk();
            // For QUIC: skip the success toast unless the spinner banner was
            // actually shown (i.e. reconnect took >kBannerDelay). For fast
            // RESUME (<1.5s), user never saw a banner — a success toast would
            // be a banner appearing out of nowhere, defeating "no-banner" UX.
            final isQuicTab = tab.transport is AqtTransport ||
                tab.server.transport == Transport.quic;
            final silentReconnect = isQuicTab && !tab.isReconnecting;
            if (!wasFirstConn && !silentReconnect) {
              _setReconnectMessage(
                tab,
                ReconnectUiMessageCode.reconnectSuccess,
                kind: ReconnectUiMessageKind.success,
                ttl: const Duration(seconds: 2),
              );
            } else {
              tab.reconnectUiMessage = null;
            }
            _sessionManager.notifyReconnected();
            return;
          }
          // RESUME 失败：不关闭 prevAqt，让 FULLRECONN 块用其元数据做第二次 RESUME
          prevAqtForFullreconn = prevAqt;
          // 同时留存到跨重试的暂存区：本次 `_reconnect` 若在到达 FULLRECONN
          // 之前就失败返回（SSH 建连超时等），下一轮重试还能靠它发 RESUME。
          // 少了这一步，元数据就随本函数的栈帧一起消失。
          _pendingResumeMeta[tab.id] = prevAqt;
          _logResume('[${_shortTabId(tab.id)}] pre-SSH RESUME fail → keep for retry');
        }
      }
      // ── Mosh 优化：复用已认证的 SSH 客户端 ─────────────────────────────────
      // for mosh, if the SSH client from the previous session is
      // still alive (the hard-reconnect path deliberately preserved it), skip
      // the full re-auth cycle. The existing authenticated client is passed
      // directly to MoshHandshake.run(reuseClient:) below. If the reused
      // client turns out to be stale, MoshHandshake.run() throws and the
      // catch block reconnects SSH normally.
      // QUIC tabs: open SSH for bootstrap only (no shell — QUIC owns the PTY).
      // SSH/Mosh tabs: open SSH with a full shell.
      final isQuicPath = server.transport == Transport.quic;
      if (!isMoshPath || !tab.connection.isConnected) {
        await tab.connection.connect(
          host: server.host,
          port: server.port,
          username: server.username,
          password: password,
          keyPairs: keyPairs,
          jumpHost: jump?.host,
          jumpPort: jump?.port,
          jumpUsername: jump?.username,
          jumpPassword: jump?.password,
          jumpPrivateKeyPem: jump?.privateKeyPem,
          agentKeyPairs: agentKeyPairs,
          // QUIC only needs SSH for bootstrap (flyterm-server --once/--status).
          // Opening a shell here would create a stale SSH shell that
          // startStreaming() might accidentally pick up if QUIC fails.
          openShell: !isMoshPath && !isQuicPath,
          firstAttempt: firstAttempt,
          hostKeyVerifier: _hostKeyVerifier,
          pool: _connectionPool,
          keyId: server.keyId,
          jumpHostId: server.jumpHostId,
          addressFamily: server.addressFamily,
          sshCompression: _sshCompression,
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException('SSH connect > 10s'),
        );
      }

      // QUIC reconnect via factory — keeps credential logic in factory, not here.
      final aqtStrategy = server.transport;
      if (aqtStrategy == Transport.quic) {
        // 优先使用 pre-SSH RESUME 保存的 transport 元数据（第二次 RESUME 机会）；
        // 若没有，则退化到 tab.transport（冷启动时为 null）。
        final oldTransport = prevAqtForFullreconn ?? tab.transport;
        prevAqtForFullreconn = null;
        // 暂存区里可能正是同一个对象（pre-SSH 失败时两处都留了引用）。这里
        // 必须一并摘掉：下面几行就要 close 它，留在暂存区意味着下一轮重试会
        // 取到一个已经关闭的 transport，元数据看着有、实际发不出 RESUME。
        _pendingResumeMeta.remove(tab.id);
        tab.transport = null;
        // 这里的 close 早于 factory 调用（oldTransport 之后只当元数据用），
        // 所以必须先把用户在断网期间敲下的按键抽出来，否则它们随 close 蒸发。
        final carriedInput =
            oldTransport is AqtTransport ? oldTransport.drainPendingInput() : null;
        oldTransport?.close();
        _logResume('[${_shortTabId(tab.id)}] FULLRECONN prev=${oldTransport != null}');
        // 只有拿到 previous 元数据时工厂才会尝试 RESUME；否则它直接走 HELLO，
        // 记一条 ISSUE 就是假的。
        final fullSeq = oldTransport != null
            ? appendResumeIssue(
                site: 'fullreconn',
                tabId: tab.id,
              )
            : null;
        try {
          final creds = ReconnectCredentials(
            password: password,
            privateKeyPem: privateKeyPem,
            keyPairs: keyPairs,
            reuseClient: tab.connection.client,
          );
          final newTransport = await _transportFactory.reconnect(
            server: server,
            creds: creds,
            previous: oldTransport, // 有元数据时工厂先尝试 RESUME，失败再 FULLRECONN
            onPurgeSession: () async {
              // RESUME 报 sessionNotFound（server 重启 / upgrade 把内存里的
              // session 表清掉）—— 立刻把 SecureStorage 里的 stale token 一并
              // 清掉，否则下一次冷启动还会用这份过期 token 先试一次 RESUME，
              // 浪费 ~1 RTT 才回落到 SSH bootstrap。
              //
              // Purge is janitorial — never let SecureStorage errors fail the
              // reconnect itself. Pattern matches L647 elsewhere in this file.
              _logResume('[${_shortTabId(tab.id)}] hot RESUME sessionNotFound → purge store');
              await _aqtSessionStateRepo?.remove(tab.id).catchError((e) {
                _logResume('[${_shortTabId(tab.id)}] purge store failed (ignored): $e');
              });
            },
          );
          _logResume('[${_shortTabId(tab.id)}] FULLRECONN ok kind=${newTransport.kind.name}');
          if (fullSeq != null) {
            // 工厂内部 RESUME 成功 → wasResumed；回落到 HELLO → 会话已丢，
            // 这两件事在诊断上意义完全不同，不能都记成 OK。
            switch (newTransport) {
              case AqtTransport(wasResumed: true, :final lastResumeScreenBytes):
                appendResumeResult(
                    seq: fullSeq, outcome: 'OK',
                    replayBytes: lastResumeScreenBytes);
              default:
                appendResumeResult(seq: fullSeq, outcome: 'HELLO(fellback)');
            }
          }
          if (newTransport is AqtTransport) {
            // 必须与上面传给 factory 的 resumeLastOutOff 是同一个值：装配时
            // 靠它判 cold/hot。传 0 而实际发了 hot offset，就会把几 KB 的
            // delta 当成权威历史去清屏重写，用户的 scrollback 当场消失。
            _installAqtTransport(tab, newTransport,
                source: 'fullreconn',
                carryInput: carriedInput);
          } else {
            tab.transport = newTransport;
            // 防御性归零：目前 CompositeTransportFactory 把 Transport.quic
            // 严格路由给 AQT 工厂，它只会返回 AqtTransport 或抛异常，这个
            // 分支理论上走不到。但一旦以后 factory 契约放宽、真的在这里
            // 装上了非 AqtTransport，就不会经过 _installAqtTransport 的
            // 无条件赋值——tab 上可能还留着上一次 RESUME 的残值，得在这里
            // 顺手清掉，避免重演 preludeReplayRemaining 跨会话串号的那个
            // bug。
            tab.preludeReplayRemaining = 0;
            tab.clearRemoteTuiHintForNewTransport();
            tab.startStreaming(source: 'fullreconnNonAqt');
            // Re-register dead callback so future QUIC failures trigger reconnect.
            registerAqtTab(tab);
          }
          final wasFirstConn = tab.isFirstConnection;
          tab.isFirstConnection = false;
          reconnectSucceeded = true;
          tab.networkStability.recordReconnectSuccess();
          tab.moshStats.noteAttemptOk();
          // Clear reconnect banner — same pattern as SSH/Mosh success path.
          // For QUIC: skip success toast on silent fast RESUME (no preceding banner).
          final isQuicTab = tab.transport is AqtTransport ||
              tab.server.transport == Transport.quic;
          final silentReconnect = isQuicTab && !tab.isReconnecting;
          if (!wasFirstConn && !silentReconnect) {
            _setReconnectMessage(
              tab,
              ReconnectUiMessageCode.reconnectSuccess,
              kind: ReconnectUiMessageKind.success,
              ttl: const Duration(seconds: 2),
            );
          } else {
            tab.reconnectUiMessage = null;
          }
          _sessionManager.notifyReconnected();
          return;
        } catch (e) {
          if (fullSeq != null) {
            appendResumeResult(seq: fullSeq, outcome: 'EXC');
          }
          _logResume('[${_shortTabId(tab.id)}] FULLRECONN fail: ${e.toString().substring(0, e.toString().length.clamp(0, 40))}');
          // QUIC strict: do NOT fall through to SSH. Rethrow so _reconnectWithRetry
          // applies its backoff/retry policy and surfaces the error to the user.
          // Silent SSH fallback would violate QUIC strict mode (no fallback).
          rethrow;
        }
      }

      // Mosh handshake — runs on initial restore AND on reconnect for mosh tabs.
      // In restore mode tab.isMosh is false (not persisted); we detect via
      // server.transport == Transport.mosh. On network-drop reconnects
      // tab.isMosh was already true, but we still come here because
      // _reconnectDisconnected skips only active mosh tabs (isMosh=true);
      // restored ones have isMosh=false until this runs.
      if (isMoshPath) {
        _setReconnectMessage(
          tab,
          ReconnectUiMessageCode.reconnectMoshHandshake,
        );
        // Kill the old mosh-server PID BEFORE spawning a new one, using the
        // freshly authenticated SSH client. This is far more reliable than
        // _killServer()'s independent SSH connection which fails when the network
        // was just restored and the old connection was severed. Without this,
        // every reconnect leaves a zombie mosh-server holding its UDP port.
        final killPid = tab.pendingKillPid;
        tab.pendingKillPid = null;
        tab.pendingServerKill = null;
        final pendingProcesses =
            await _moshProcessRepo?.findByTabId(tab.id) ?? const [];
        // Batch all stale PIDs into MoshHandshake.run's prependKillPids so
        // kill + mosh-server new share a single SSH exec channel (saves ~2 RTTs
        // vs the old pattern of a separate kill exec before the handshake).
        // De-duplicate in case pendingKillPid overlaps with a DB entry.
        final prependKills = {
          for (final p in pendingProcesses) p.pid,
          if (killPid != null) killPid,
        }.toList();
        // Track whether the SSH exec that contains the prepend kill commands
        // was sent. If MoshHandshake.run() throws after the exec but before
        // returning, pendingProcesses still need to be marked killed in finally.
        var prependKillSent = false;
        try {
          // Reuse the already-authenticated SSHClient — skips a full SSH
          // re-authentication (~5-8 RTTs) for the mosh-server exec channel.
          final moshShell = await MoshHandshake.run(
            host: server.host,
            port: server.port,
            username: server.username,
            password: password,
            privateKeyPem: privateKeyPem,
            portRange: server.moshPortRange,
            reuseClient: tab.connection.client,
            terminalWidth:
                tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 80,
            terminalHeight:
                tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 24,
            addressFamily: server.addressFamily,
            sshCompression: _sshCompression,
            flytermSessionId: tab.id,
            flytermServerId: server.id,
            prependKillPids: prependKills,
            onServerStarted: (pid, udpPort) {
              prependKillSent = true; // exec channel opened → kills ran
              return _moshProcessRepo?.upsertActive(
                    id: '${tab.id}-$pid',
                    serverId: server.id,
                    tabId: tab.id,
                    tmuxKey: tab.sessionKey,
                    pid: pid,
                    udpPort: udpPort,
                    host: server.host,
                    sshPort: server.port,
                    username: server.username,
                    portRange: server.moshPortRange,
                  ) ??
                  Future.value();
            },
            onServerKilled: (pid) {
              return _moshProcessRepo?.markKilled('${tab.id}-$pid') ??
                  Future.value();
            },
          );
          // Kill commands ran as part of the handshake exec — mark DB entries.
          for (final p in pendingProcesses) {
            await _moshProcessRepo?.markKilled(p.id);
          }
          // Close old mosh shell if any (e.g. re-handshake after session death).
          final prev = tab.moshShell;
          if (prev is MoshShellV2) {
            await prev.close();
          }
          await _v2LivenessSubs.remove(tab.id)?.cancel();
          tab.moshShell = moshShell;
          tab.isMosh = true;
          // Fix 4: re-wire NetworkStability hook on the fresh transport so
          // post-reconnect packets continue feeding the score.
          // Also clear stale connectionError / isReconnecting on the FIRST
          // auth packet — if v2 traffic is flowing on a new transport the
          // session is unambiguously alive, regardless of whether the outer
          // _reconnectWithRetry loop has finished its tmux/post-setup steps.
          // Without this the tab dot can stay red-blinking for tens of
          // seconds while real bytes are landing.
          // First auth packet on a fresh transport hard-resets the score to
          // 50 (stable) so we don't show orange while +1 ticks crawl back
          // from a previous missedDeadline penalty.
          var firstAuth = true;
          moshShell.onAuthenticatedPacket = (rtt) {
            if (firstAuth) {
              firstAuth = false;
              tab.networkStability.recordReconnectSuccess();
            } else {
              tab.networkStability.recordOkPacket(rtt);
            }
            if (tab.connectionError != null || tab.isReconnecting) {
              tab.connectionError = null;
              tab.isReconnecting = false;
              _sessionManager.notifyTabChanged();
            }
          };
          tab.onClosing = () => _moshProcessRepo?.markPendingKillByTabId(tab.id);
          tab.onClose = () => _moshProcessRepo?.markKilledByTabId(tab.id);
        } catch (e) {
          // If the prepend-kill exec ran before the handshake failed, mark those
          // PIDs as killed so they don't stay pending_kill forever.
          if (prependKillSent) {
            for (final p in pendingProcesses) {
              await _moshProcessRepo?.markKilled(p.id);
            }
          }
          // Graceful degradation: mosh failed, open SSH PTY and continue.
          final oldMosh = tab.moshShell;
          tab.stopStreaming(discardPending: true);
          if (oldMosh is MoshShellV2) {
            await oldMosh.closeTransport();
          }
          tab.resetProtocolStateForSshFallback();
          _setReconnectMessage(
            tab,
            ReconnectUiMessageCode.reconnectMoshFallback,
            kind: ReconnectUiMessageKind.warning,
            ttl: const Duration(seconds: 4),
          );
          tab.moshShell = null;
          tab.isMosh = false;
          // The reuseClient SSH connection (opened with openShell=false) may
          // have its channel map corrupted if the mosh exec hit the dartssh2
          // null-check bug.  Always create a fresh connection instead of
          // calling openShell() on a potentially-bad client.
          await tab.connection.connect(
            host: server.host,
            port: server.port,
            username: server.username,
            password: password,
            keyPairs: keyPairs,
            jumpHost: jump?.host,
            jumpPort: jump?.port,
            jumpUsername: jump?.username,
            jumpPassword: jump?.password,
            jumpPrivateKeyPem: jump?.privateKeyPem,
            agentKeyPairs: agentKeyPairs,
            openShell: true,
            firstAttempt: false,
            hostKeyVerifier: _hostKeyVerifier,
            pool: _connectionPool,
            keyId: server.keyId,
            jumpHostId: server.jumpHostId,
            addressFamily: server.addressFamily,
            sshCompression: _sshCompression,
          ).timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('SSH connect > 10s'),
          );
        }
      }

      tab.startStreaming(source: 'reconnectLegacyMoshSsh');
      // Register dead-session callback so the 30 s watchdog in SspTransport
      // can trigger a full re-handshake when the mosh-server process dies.
      // Only set for mosh tabs; plain SSH reconnects are handled by
      // _reconnectDisconnected() via the isConnected check.
      if (tab.isMosh) {
        _registerMoshDeadCallback(tab);
      } else {
        // SSH-only tab (or mosh degraded to SSH): listen for TCP connection drop
        // and trigger reconnect. _reconnectDisconnected() is event-driven, so
        // silent SSH drops would otherwise go undetected between events.
        tab.connection.done.then((_) {
          if (_retrying.contains(tab.id) || _reconnecting.contains(tab.id))
            return;
          if (!_sessionManager.tabs.contains(tab)) return;
          _reconnectWithRetry(tab, trigger: 'doneCb/reconnect');
        });
      }
      // Capture before tmux setup so we know whether to show the reconnect banner.
      // The banner is written AFTER all post-connect operations succeed to avoid
      // showing "[已重新连接]" followed by "[重连失败]" when tmux setup throws.
      final wasFirstConnection = tab.isFirstConnection;
      SshForegroundService.startOrUpdate(server.name);

      // Route shell input/resize to mosh when active, otherwise to SSH PTY.
      final activeShell = (tab.moshShell ?? tab.connection.shell) as dynamic;
      // Session multiplexer attach (tmux / none).
      final mtype = server.multiplexerType;
      if (mtype != MultiplexerType.none) {
        // Dispose old backend before creating a new one (avoids pipe leak on
        // re-connect when the backend type hasn't changed).
        tab.backend.dispose();
        tab.backend = switch (mtype) {
          MultiplexerType.tmux => TmuxBackend(),
          MultiplexerType.none => NoneBackend(),
        };
        _sessionManager.notifyTabChanged();
        final found = await tab.backend.detect(tab.connection);
        if (found) {
          // Fix: SSH PTY is created at 80×24 by default.  terminal.onResize
          // only fires when the pixel layout changes, so it won't retrigger
          // after reconnect if the keyboard state is unchanged — leaving tmux
          // rendering at 80×24 regardless of the actual terminal height.
          // Send the current terminal dimensions before attach so tmux redraws
          // at the correct size from the first frame.
          final w = tab.terminal.viewWidth;
          final h = tab.terminal.viewHeight;
          if (w > 0 && h > 0) {
            activeShell?.resizeTerminal(w, h);
          }
          final attachCmd = tab.backend.attachOrCreateCommand(
            tab.sessionKey,
            isMosh: tab.isMosh,
          );
          if (attachCmd.isNotEmpty) {
            activeShell?.stdin.add(utf8.encode('$attachCmd\n'));
          }
          await Future.delayed(const Duration(milliseconds: 100));
          // Enable mouse mode via exec channel — reliable on all remote shells.
          await tab.backend.enableMouse(tab.connection);
          // Open/reopen persistent control pipe for low-latency scroll commands.
          await tab.backend.initControlPipe(tab.connection, tab.sessionKey);
          // tmux intercepts ESC[?1049h so local echo cannot detect alt-buffer.
          // Must suppress for every new mosh shell (each reconnect creates one).
          if (mtype == MultiplexerType.tmux) {
            final ms = tab.moshShell;
            if (ms is MoshShellV2) {
              ms.suppressLocalEcho();
            }
          }
          _sessionManager.notifyTabChanged();
          // On first connection (restored tab), send startup command inside tmux.
          if (tab.isFirstConnection) {
            final cmd = server.startupCommand;
            if (cmd != null && cmd.isNotEmpty) {
              activeShell?.stdin.add(utf8.encode('$cmd\n'));
            }
          }
        } else {
          _setReconnectMessage(
            tab,
            ReconnectUiMessageCode.tmuxNotFoundDisabled,
            kind: ReconnectUiMessageKind.warning,
            ttl: const Duration(seconds: 4),
          );
          tab.backend.dispose();
          tab.backend = NoneBackend();
          _sessionManager.notifyTabChanged();
          if (tab.isFirstConnection) {
            final cmd = server.startupCommand;
            if (cmd != null && cmd.isNotEmpty) {
              activeShell?.stdin.add(utf8.encode('$cmd\n'));
            }
          }
        }
      } else if (tab.isFirstConnection) {
        // Non-multiplexer first connection: send startup command once.
        final cmd = server.startupCommand;
        if (cmd != null && cmd.isNotEmpty) {
          activeShell?.stdin.add(utf8.encode('$cmd\n'));
        }
      }
      // Mark connected so subsequent reconnects suppress startup command.
      tab.isFirstConnection = false;
      reconnectSucceeded = true;
      tab.networkStability.recordReconnectSuccess();
      tab.moshStats.noteAttemptOk();
      // Only show the banner after ALL post-connect operations (tmux etc.) succeed.
      if (!wasFirstConnection) {
        _setReconnectMessage(
          tab,
          ReconnectUiMessageCode.reconnectSuccess,
          kind: ReconnectUiMessageKind.success,
          ttl: const Duration(seconds: 2),
        );
      }
      _sessionManager.notifyReconnected();
    } catch (e) {
      final errType =
          e is TimeoutException
              ? 'timeout'
              : e is StateError
              ? 'state'
              : e.runtimeType.toString();
      // P1: map raw exceptions to user-friendly messages instead of exposing
      // technical stack traces (e.g. "SocketException: Connection refused").
      final friendlyError = _friendlyError(e);
      _setReconnectMessage(
        tab,
        ReconnectUiMessageCode.reconnectFailedWithError,
        args: {'error': friendlyError},
        kind: ReconnectUiMessageKind.error,
      );
      tab.connectionError = e.toString();
      final raw = '${e.runtimeType}: ${e.toString().split('\n').first}';
      final truncated = raw.length > 60 ? raw.substring(0, 60) : raw;
      tab.networkStability.recordMissedDeadline(truncated);
      tab.moshStats.noteAttemptFail(truncated);
      // P3: bump errCnt bucket for the debug overlay.
      tab.recordError(classifyConnectError(e));
      _sessionManager.notifyReconnected();
    } finally {
      tab.appendReconnect(
        ReconnectEvent(
          DateTime.now(),
          ReconnectCause.fullReconnect,
          ReconnectKind.hard,
          reconnectSucceeded,
        ),
      );
      _maybeWarnCascade(tab);
      _reconnecting.remove(tab.id);
    }
  }

  /// 并发安全地加载一个 server 的完整 credentials。
  /// 同 server.id 的并发调用复用同一个 Future（inflight dedup），避免
  /// Android Keystore mutex 把多 tab 的重连请求串行化。完成后立即从 inflight
  /// 表移除 —— 不长期缓存，防止 stale credentials。
  Future<_ServerCreds> _loadServerCreds(String serverId, Server fallback) {
    return _credsInflight.putIfAbsent(serverId, () async {
      try {
        final server = await _serverRepo.findById(serverId) ?? fallback;
        String? password;
        List<SSHKeyPair> keyPairs = const [];
        if (server.authType == 'key' && server.keyId != null) {
          keyPairs = await _loadKeyPairs(server.keyId!);
        } else if (server.authType == 'password') {
          password = await _storage.loadPassword(server.id);
        }
        final jump = await resolveJumpParams(server, _serverRepo, _storage);
        final agentKeyPairs = await _buildAgentKeyPairs(server);
        return _ServerCreds(
          server: server,
          password: password,
          keyPairs: keyPairs,
          jump: jump,
          agentKeyPairs: agentKeyPairs,
        );
      } finally {
        _credsInflight.remove(serverId);
      }
    });
  }

  /// Load and cache parsed SSH key pairs for [keyId].
  /// First call parses the PEM from secure storage; subsequent calls return
  /// the cached result, avoiding expensive RSA key parsing on every reconnect.
  Future<List<SSHKeyPair>> _loadKeyPairs(String keyId) async {
    final cached = _keyPairCache[keyId];
    if (cached != null) return cached;
    final pem = await _storage.loadPrivateKey(keyId);
    if (pem == null) return const [];
    try {
      final pairs = SSHKeyPair.fromPem(pem);
      _keyPairCache[keyId] = pairs;
      return pairs;
    } catch (e) {
      debugPrint('[SSH] Failed to parse key $keyId: $e');
      return const [];
    }
  }

  Future<List<SSHKeyPair>> _buildAgentKeyPairs(Server server) async {
    if (!server.agentForwarding) return const [];
    try {
      final keys = await _keyRepo.findAll();
      final pems = await _storage.loadPrivateKeys(
        keys.map((k) => k.id).toList(),
      );
      final pairs = <SSHKeyPair>[];
      for (final pem in pems) {
        try {
          pairs.addAll(SSHKeyPair.fromPem(pem));
        } catch (e) {
          debugPrint('[Agent] Failed to parse key PEM: $e');
        }
      }
      return pairs;
    } catch (e) {
      debugPrint('[Agent] Failed to load agent keys: $e');
      return const [];
    }
  }
}

/// Snapshot of one server's complete reconnect credentials.
/// Returned by [ReconnectService._loadServerCreds] so multiple concurrent
/// reconnects can share a single Keystore round-trip.
class _ServerCreds {
  final Server server;
  final String? password;
  final List<SSHKeyPair> keyPairs;
  final JumpHostParams? jump;
  final List<SSHKeyPair> agentKeyPairs;
  const _ServerCreds({
    required this.server,
    required this.password,
    required this.keyPairs,
    required this.jump,
    required this.agentKeyPairs,
  });
}
