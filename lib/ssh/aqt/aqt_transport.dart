// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../../util/dlog.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show VoidCallback, visibleForTesting;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:dartssh2/dartssh2.dart' show SSHClient;

import '../transport/remote_transport.dart';
import 'aqt_bootstrap.dart';
import 'aqt_ffi.dart';
import 'aqt_route.dart';
import 'aqt_ssh_relay.dart';
import 'file_transfer/aqt_file_handle.dart';
import 'file_transfer/sha256_streaming.dart';

// Re-export PathStats so callers can `import 'aqt_transport.dart'`
// for the whole P4 surface (transport + model). The class itself
// lives in aqt_ffi.dart to avoid circular import.
export 'aqt_ffi.dart' show PathStats;

/// Per-phase wall-clock duration of the connect path. All values are
/// milliseconds; `0` means "not measured yet" (initial state). Captured
/// by `AqtTransportFactory.connectWithCredentials` and surfaced in the
/// debug overlay as the `conn` row.
class ConnectTimings {
  final int tcpMs;       // socket connect → server accept
  final int authMs;      // SSH userauth complete
  final int bootMs;      // exec flyterm-server → 4×AQT_* lines parsed
  final int handshakeMs; // QUIC ClientHello → 0-RTT data send-ready

  const ConnectTimings({
    this.tcpMs = 0,
    this.authMs = 0,
    this.bootMs = 0,
    this.handshakeMs = 0,
  });

  int get totalMs => tcpMs + authMs + bootMs + handshakeMs;

  ConnectTimings copyWith({int? tcpMs, int? authMs, int? bootMs, int? handshakeMs}) =>
      ConnectTimings(
        tcpMs: tcpMs ?? this.tcpMs,
        authMs: authMs ?? this.authMs,
        bootMs: bootMs ?? this.bootMs,
        handshakeMs: handshakeMs ?? this.handshakeMs,
      );
}

/// Wall-clock timestamps + size for the most recent RESUME cycle. Set in
/// 3 stages by AqtTransportFactory / SessionTab listener:
///   sentAt           — RESUME packet flushed to QUIC (factory entry)
///   ackAt            — RESUME_ACK parsed (transport state → connected)
///   replayCompleteAt — server prelude (lastResumeReplayBytes including
///                      trailing CAN) fully streamed into the client
/// Surfaced in debug overlay `res` row.
class ResumeTimings {
  final DateTime? sentAt;
  final DateTime? ackAt;
  final DateTime? replayCompleteAt;

  /// 本次恢复传了多少字节屏幕快照。
  ///
  /// 曾经是 `replayBytes`（ring 回放的字节数，含末尾 CAN）。恢复改成发幂等
  /// 快照之后没有「回放」这回事了，等价的诊断量是快照大小。
  final int screenBytes;

  const ResumeTimings({
    this.sentAt,
    this.ackAt,
    this.replayCompleteAt,
    this.screenBytes = 0,
  });

  int? get ackRttMs => (ackAt != null && sentAt != null)
      ? ackAt!.difference(sentAt!).inMilliseconds
      : null;

  int? get replayMs => (replayCompleteAt != null && ackAt != null)
      ? replayCompleteAt!.difference(ackAt!).inMilliseconds
      : null;

  int? get ageSec => replayCompleteAt != null
      ? DateTime.now().difference(replayCompleteAt!).inSeconds
      : null;
}

class AqtTransport implements RemoteTransport {
  /// Rust 侧 `SessionHandle` 的裸指针。**`close()` 之后置 null。**
  ///
  /// 声明成可空（而不是配一个 `bool _closed` 旁标志）是刻意的：让**编译器**
  /// 来守这条规则。这个类有 18 个 FFI 入口用到它，每一个都被强制显式处理
  /// null，将来新增入口同样过不了类型检查。靠「记得检查标志」守不住 ——
  /// 漏掉任何一个就是一次 use-after-free。
  ///
  /// 为什么 close 之后指针一定悬垂：`aqt_close`（ffi.rs:585）= `Arc::from_raw`
  /// 后立刻 drop，refcount 2→1；剩下那个 1 在 ffi.rs:496 的 1Hz 轮询 task 手
  /// 里，它下一个 tick 读到 `conn.close_reason()` 非空就 `break`，drop 掉自己
  /// 那份 Arc —— refcount 归零，SessionHandle 被释放。也就是说 close 之后约
  /// 一秒，这个指针就指向已释放内存了。
  ///
  /// 取值一律走 [_live]，不要直接读这个字段。
  Pointer<Void>? _handle;
  final StreamController<TransportState> _stateCtrl =
      StreamController.broadcast();
  // Single-subscription (NOT broadcast) so events emitted between
  // AqtTransport construction and the consumer's listen() are buffered
  // instead of dropped. Background:
  //   1. Constructor immediately calls _startPolling().
  //   2. tryResumeWithInfoDetailed awaits Connected + TabOpened — during
  //      this await the poll loop already produces PtyOutput events
  //      (the RESUME prelude lands right after RESUME_ACK).
  //   3. The caller assigns tab.transport = resumed, then calls
  //      tab.startStreaming() which finally attaches the listener.
  // With a broadcast controller, all PtyOutput between (1) and (3) were
  // dropped silently — symptom: cold RESUME completes but screen stays
  // blank (rendered:0B) until the user pops the keyboard, which triggers
  // SIGWINCH → fresh redraw bytes from the running TUI.
  // Output is consumed by exactly one place (SessionManager.startStreaming);
  // verified no other callers do .listen on transport.output.
  final StreamController<Uint8List> _outputCtrl =
      StreamController<Uint8List>();
  final Completer<void> _done = Completer();
  TransportState _state = TransportState.connecting;
  Timer? _pollTimer;
  // Tracks the pending 3s Disconnected recovery timer so close() can cancel it.
  Timer? _disconnectRecoveryTimer;
  final TransportMetrics _metrics = TransportMetrics.empty;

  /// Tab id assigned by the server after OPEN_TAB_ACK.
  int? _tabId;

  /// Rust error message from the last Failed event (for diagnostics).
  String? _failureReason;

  /// Public accessor for DebugOverlay to show Rust-side failure reason.
  String? get failureReason => _failureReason;

  /// `close()` 之后仍然有 FFI 入口来取 handle 的次数。稳态必须是 0。
  ///
  /// 非 0 就意味着有一条调用路径在 transport 关闭后还在往 Rust 侧打 ——
  /// 在真机上那就是 use-after-free。计数本身不修复什么，它是**证据**：
  /// 崩溃发生在 Rust 线程、延迟约一秒，tombstone 未必拿得到，而这个计数
  /// 加上 [lastFfiCallAfterClose] 能直接点名是哪个入口。
  @visibleForTesting
  int ffiCallsAfterClose = 0;

  /// 最后一个在 close 之后来取 handle 的入口名。见 [ffiCallsAfterClose]。
  @visibleForTesting
  String? lastFfiCallAfterClose;

  /// 心跳/看门狗定时器是否还活着。close 之后必须都是 false ——
  /// `setForeground` 会 `??=` 重建它们，那是最危险的一条残留路径。
  @visibleForTesting
  bool get hasHeartbeatTimer => _heartbeatTimer != null;

  @visibleForTesting
  bool get hasWatchdogTimer => _watchdogTimer != null;

  /// 取仍然有效的 handle —— **所有 FFI 调用的唯一入口**。
  ///
  /// close 之后返回 null 并记一笔账（计数 + 入口名 + 一行 log）。[site] 是
  /// 调用点的名字，真机上 logcat 里的「FFI call after close: setForeground」
  /// 就是残留入口的直接证据，不必等 tombstone。
  ///
  /// 只在**已经 close 过**时记账：`testStub` 的 handle 天生就是 null，把那种
  /// 正常使用也计进来的话，计数会被噪声刷满，真实的 UAF 反而淹掉。
  /// 是否已经走过 [close]。只用于 [_live] 的记账判据，见 `_closeOnce` 首行。
  bool _closed = false;

  Pointer<Void>? _live(String site) {
    final h = _handle;
    if (h == null && _closed) {
      ffiCallsAfterClose++;
      lastFfiCallAfterClose = site;
      dlog('AQT', 'FFI call after close: $site (#$ffiCallsAfterClose)');
    }
    return h;
  }

  /// Cancel all timers (recovery + poll + heartbeat) without closing the handle.
  /// Used by _refreshTab to prevent race conditions while keeping session info
  /// available for RESUME in the subsequent _connectServer call.
  ///
  /// 不再设 _quicPathDied=true：之前用"假死"骗 _connectServer 的 isAlive
  /// 检查返回 false 走重连路径，污染了 transport 状态机（其他依赖 isDead
  /// 的判断会误以为 transport 真的死了）。现在改为 _refreshTab 调
  /// _connectServer 时显式传 forceReconnect: true 表达"无论 transport
  /// 是否活着都走重连"的意图，cancelTimers 名副其实只取消 timer。
  void cancelTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;  // signals _pollAndReschedule to stop looping
    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastDisconnectAt = DateTime.now();
    _lastDisconnectReason = 'refresh';
  }

  /// Freeze the transport without stopping the poll timer externally.
  /// Safe to call from inside the poll loop (unlike cancelTimers which sets
  /// _pollTimer=null — that gets overwritten at the end of _pollAndReschedule).
  /// _frozen causes _pollAndReschedule to break mid-loop and skip rescheduling.
  void freeze() {
    _frozen = true;
    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  /// Completer fulfilled when the first TabOpened event arrives.
  final Completer<int> _tabOpenedCompleter = Completer();

  // --- 0-RTT reconnect info ---
  String? _lastHost;
  int? _lastPort;
  Uint8List? _lastSpki;
  // Session token retrieved after HELLO_ACK via aqt_get_session_token()
  Uint8List? _sessionToken;

  /// App-layer heartbeat interval. Quinn's keep_alive_interval is disabled;
  /// this datagram is the sole keepalive mechanism.
  static const Duration kHeartbeatInterval = Duration(seconds: 5);

  /// C1 — Foreground heartbeat tightened from 5s to 3s. Background still
  /// disables app-layer heartbeat (quinn keep_alive_interval=15s suffices).
  static const Duration kHeartbeatIntervalForeground = Duration(seconds: 3);

  /// C1 — Master switch for foreground silent-path watchdog.
  static const bool kForegroundWatchdog = true;

  /// When the app comes to foreground, we immediately probe the QUIC path
  /// instead of waiting up to kHeartbeatInterval for the timer to fire.
  static const bool kImmediateForegroundProbe = true;

  // --- Background heartbeat ---
  Timer? _heartbeatTimer;

  /// 给状态机报时的定时器。判断在 `lib/ssh/aqt/conn/conn_machine.dart` 里。
  Timer? _watchdogTimer;

  // 这里曾有 `_foregroundResumedAt` 与 `_connectedAt` 两个时间戳字段，供
  // `effectiveWatchdogAgeMs` 做两层归一化（分别夹取「前台以来」与「本实例连上
  // 以来」的沉默）。两者随该函数一起删除。
  //
  // 它们的信息现在活在状态机的 `MachineState.observeStartMs` 里 ——
  // 那一个字段就等于 `max(connectedAt, foregroundAt)`，因为
  // `min(now−A, now−B) = now − max(A,B)`。等价性由
  // `test/ssh/aqt/conn/conn_silence_test.dart` 的 20000 组穷举锁着。
  //
  // 顺带记一笔：`_connectedAt` 删除前是**只写不读**的死字段，但分析器没报
  // `unused_field` —— 因为它的写法是 `_connectedAt ??= ...`，`??=` 被算作一次
  // 读取。同批的 `_foregroundResumedAt` 用的是普通赋值，就被报了出来。
  // 这个不对称值得记住：`??=` 会把死字段藏起来。

  /// Set by ReconnectService to attempt RESUME on disconnect.
  /// When set, disconnected event skips reconnecting state and calls this instead.
  VoidCallback? onDisconnected;

  /// Set by ReconnectService (task 10) — fired for every decoded
  /// [AqtEventKind.notify] event on this transport, symmetric to
  /// [onDisconnected]. The callback is fire-and-forget from this class's
  /// point of view: [AqtTransport] itself does not decide whether to show
  /// the notification, does not persist dedup state, and does not ack —
  /// all of that lives in the widget-layer orchestrator (SplitManager and
  /// SessionManager are only reachable from there). This class's only job
  /// is decode-and-forward, plus exposing [ackNotify] so the orchestrator
  /// can ack strictly after it has actually displayed the notification.
  void Function(NotifyPayload payload)? onNotify;

  // True after freeze() — stops _pollAndReschedule from processing more events.
  bool _frozen = false;

  // True when Rust conn.closed() fired — QUIC path is definitively dead.
  // Used by ReconnectService to decide whether to reconnect after RESUME failure.
  bool _quicPathDied = false;

  /// True if the underlying QUIC connection is known to be dead.
  bool get isDead =>
      _quicPathDied ||
      _outputCtrl.isClosed ||
      _state == TransportState.failed ||
      _state == TransportState.closed;

  /// Human-readable explanation of why isDead is true (or "alive").
  /// Shown in debug overlay so we can tell which condition triggered.
  String get deadReason {
    if (_quicPathDied) return 'pathDied';
    if (_outputCtrl.isClosed) return 'outClosed';
    if (_state == TransportState.failed) return 'state=failed';
    if (_state == TransportState.closed) return 'state=closed';
    return 'alive';
  }

  /// Tracks the last Disconnected/close event for diagnostics.
  /// Set when conn.closed() fires (Rust) or close() is called locally.
  DateTime? _lastDisconnectAt;
  String? _lastDisconnectReason;
  DateTime? get lastDisconnectAt => _lastDisconnectAt;
  String? get lastDisconnectReason => _lastDisconnectReason;

  // --- Debug accessors for overlay ---
  bool get isFrozen => _frozen;
  bool get quicPathDied => _quicPathDied;
  bool get hasDisconnectedCallback => onDisconnected != null;

  AqtTransport._(this._handle) {
    _startPolling();
  }

  /// Named constructor for the 0-RTT resume path (handle already allocated).
  AqtTransport.withHandle(Pointer<Void> handle) : _handle = handle {
    _startPolling();
  }

  /// Test-only constructor — bypasses FFI handle creation and does NOT start
  /// the poll timer. Used by unit tests that need a previous transport carrying
  /// resume metadata to test factory dispatch logic.
  @visibleForTesting
  AqtTransport.testStub({
    int? port,
    Uint8List? spki,
    Uint8List? token,
    int? tabId,
    TransportState? state,
    bool Function(String ip, int port)? setPathImpl,
    int Function()? Function(String ip, int port, Uint8List spki, int timeoutMs)?
        probeImpl,
    int Function()? recvAgeImpl,
  }) : _handle = null {
    this.setPathImpl = setPathImpl;
    this.probeImpl = probeImpl;
    _recvAgeImpl = recvAgeImpl;
    _lastPort = port;
    _lastSpki = spki;
    _sessionToken = token;
    _tabId = tabId;
    // Intentionally do NOT call _startPolling() — there is no real handle.
    // Defaults to `connecting` (the field's own default) unless a test needs
    // to exercise state-gated logic (e.g. PrewarmPool adoption callers check
    // `currentState == TransportState.connected` before adopting — see
    // terminal_screen.dart::_connectServer and
    // ReconnectService._reconnect()'s cold-hydrate prewarm-adopt branch).
    if (state != null) _state = state;
  }

  /// Create by connecting via SSH bootstrap then QUIC.
  static Future<AqtTransport> connect({
    required String host,
    required AqtBootstrapInfo bootstrap,
    int cols = 80,
    int rows = 24,
  }) async {
    // Encode token as URL-safe base64 for SNI (alphanumeric + dash/underscore only)
    final sni = base64Url.encode(bootstrap.token).replaceAll('=', '');
    final handle = AqtFfi.connect(
      host: host,
      port: bootstrap.port,
      spki: bootstrap.spki,
      sessionToken: bootstrap.token,
      sni: sni,
    );
    final t = AqtTransport._(handle);

    // Wait for Connected event (up to 5 s). On timeout, close the FFI handle
    // (otherwise the Rust-side QUIC connection + polling leak) and throw a
    // descriptive error instead of the bare "Future not completed" — the usual
    // cause is a dead daemon / blocked UDP so the handshake reply never comes.
    await t.stateStream
        .where(
            (s) => s == TransportState.connected || s == TransportState.failed)
        .first
        .timeout(const Duration(seconds: 5), onTimeout: () async {
      await t.close();
      throw AqtBootstrapException(
          'QUIC handshake timed out after 5s '
          '($host:${bootstrap.port} unreachable — daemon dead or UDP blocked?)');
    });
    if (t._state == TransportState.failed) {
      final reason = t._failureReason;
      await t.close();
      throw AqtBootstrapException(
          'QUIC handshake failed${reason != null ? ": $reason" : ""}');
    }

    // Open default PTY tab
    AqtFfi.openTab(handle, cols, rows, 'xterm-256color');

    // Wait for TabOpened event to learn the tab_id (up to 5 s). Same handle-leak
    // guard + descriptive error as the handshake wait above.
    final tabId = await t._tabOpenedCompleter.future
        .timeout(const Duration(seconds: 5), onTimeout: () async {
      await t.close();
      throw AqtBootstrapException(
          'QUIC connected but OpenTab timed out after 5s ($host:${bootstrap.port})');
    });
    t._tabId = tabId;

    // Store session info for future 0-RTT reconnect
    t._lastHost = host;
    t._lastPort = bootstrap.port;
    t._lastSpki = bootstrap.spki;
    t._sessionToken = AqtFfi.getSessionToken(handle);

    return t;
  }

  // --- Public getters for 0-RTT reconnect ---
  String? get lastHost => _lastHost;
  int? get lastPort => _lastPort;

  /// 测试注入：替代 [AqtFfi.setPath]（handle 为 null 的 testStub 用）。
  @visibleForTesting
  bool Function(String ip, int port)? setPathImpl;

  /// 测试注入：替代 [AqtFfi.probeDirect] + [AqtFfi.probeResult]。启动探测，
  /// 返回轮询函数（-1 进行中 / 0 不可达 / 1 可达）；启动失败返回 null。
  @visibleForTesting
  int Function()? Function(
      String ip, int port, Uint8List spki, int timeoutMs)? probeImpl;

  int Function()? _recvAgeImpl;

  AqtRoute _route = AqtRoute.direct;
  AqtSshRelay? _relay;
  SSHClient? _ownedSshClient;

  /// How this transport reaches its daemon (see [AqtRoute]).
  AqtRoute get route => _route;

  /// 当前挂着的 relay（直连时为 null）。路线控制器靠它判断「断掉的是不是
  /// 正在用的那个」，以及探测失败后切回哪个端口。
  AqtSshRelay? get relay => _relay;

  /// Marks this transport as running through an SSH relay (or not) and hands
  /// it what must live exactly as long as the QUIC connection: the [relay]
  /// and, on a first connect, the SSH connection it rides on
  /// ([ownedSshClient]). Both are closed by [close].
  ///
  /// [daemonPort] replaces [lastPort]: the QUIC client dialed the relay's
  /// local port, but what is persisted for RESUME must be the daemon's.
  void attachRelay({
    required AqtRoute route,
    AqtSshRelay? relay,
    SSHClient? ownedSshClient,
    int? daemonPort,
  }) {
    _route = route;
    _relay = relay;
    _ownedSshClient = ownedSshClient;
    if (daemonPort != null) _lastPort = daemonPort;
  }

  /// 换入新的 relay / route，**返回旧 relay 且不关闭它**——由调用方决定
  /// 何时关（切换成功后再关，失败则可回滚）。
  AqtSshRelay? replaceRelay(AqtRoute route, AqtSshRelay? relay) {
    final old = _relay;
    _route = route;
    _relay = relay;
    return old;
  }

  /// 把 QUIC 连接的真实目的地切到 [ip]:[port]（连接/会话不变）。
  bool setPath(String ip, int port) {
    final inj = setPathImpl;
    if (inj != null) return inj(ip, port);
    final h = _live('setPath');
    if (h == null) return false;
    return AqtFfi.setPath(h, ip, port) == 0;
  }

  /// 探测 [ip]:[port] 的直连是否可达（独立 QUIC 握手，不影响当前会话）。
  /// 每 100 ms 轮询一次结果；超时或没有 SPKI 时为 false。
  Future<bool> probeDirect(String ip, int port,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final spki = _lastSpki;
    if (spki == null) return false;
    final timeoutMs = timeout.inMilliseconds;
    int Function()? poll;
    final inj = probeImpl;
    if (inj != null) {
      poll = inj(ip, port, spki, timeoutMs);
    } else {
      final h = _live('probeDirect');
      if (h != null && AqtFfi.probeDirect(h, ip, port, spki, timeoutMs) == 0) {
        poll = () => AqtFfi.probeResult(h);
      }
    }
    if (poll == null) return false;
    // Rust 侧自己按 timeoutMs 收尾；这里多留 1 s 余量防它迟迟不写结果。
    final deadline = DateTime.now().add(timeout + const Duration(seconds: 1));
    while (true) {
      final r = poll();
      if (r != -1) return r == 1;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Uint8List? get lastSpki => _lastSpki;
  Uint8List? get sessionToken => _sessionToken;
  int? get lastTabId => _tabId;

  /// 最近一次 RESUME 的处置，`takeResumeDisposition` 取回来后缓存在这里。
  AqtDisposition? _lastResumeDisposition;
  AqtDisposition? get lastResumeDisposition => _lastResumeDisposition;

  /// 从 FFI 取走本次 RESUME 的处置并缓存。
  ///
  /// **只能调一次**：`Restored.screen` 在 Rust 侧是 take 语义，取走即清空。
  /// 那是刻意的 —— 留着它会让「重连时机不巧、把上一次的快照又灌一遍」变成
  /// 可能，幂等模型下不损坏状态，却会把用户的屏幕拽回过去。
  ///
  /// 这里曾经是 `lastResumeServerOutOff` / `lastResumeReplayBytes` 两个
  /// getter，调用方用它们的差反推「服务端是续传还是重建」。服务端一改语义
  /// 那个判据就静默失效（d7dc3ef → e382759）。
  AqtDisposition? takeResumeDisposition() {
    final h = _live('takeResumeDisposition');
    if (h == null) return _lastResumeDisposition;
    _lastResumeDisposition = AqtFfi.resumeDisposition(h);
    return _lastResumeDisposition;
  }

  /// 服务端下发的 session TTL（秒）。0 = 拿不到，调用方用自己的兜底值。
  ///
  /// 会话过期判定的**权威来源**。客户端本地那个 7 天常量只是兜底 —— 常量
  /// 在两侧各写一份，一侧改了另一侧没跟上，就是「服务端 7 天 vs 客户端
  /// 110 分钟」那个 bug。
  int get resumeTtlSecs {
    final h = _live('resumeTtlSecs');
    return h == null ? 0 : AqtFfi.resumeTtlSecs(h);
  }

  /// 本次恢复的快照字节数，由服务端在 RESUME_ACK 里下发。
  ///
  /// **返回 0 有四种成因，无法区分**：
  ///   1. 客户端符号缺失 —— `libaqt_client_ffi.so` 是旧的（**构建问题**，
  ///      此时 `AqtFfi` 的 init 会打一条日志）；
  ///   2. 服务端是旧版本，不发 `prelude_lens` 字段；
  ///   3. 非 Restored 处置（TabGone / NewSession），本就没有快照；
  ///   4. transport 已 close，`_live()` 返回 null。
  ///
  /// **这个 getter 曾经恒返回 0**，而且是有意为之 —— 快照改成新 PTY 流的
  /// 头几个字节之后，客户端确实无从自己计数。后果是一条静默的断链：
  /// `preludeReplayRemaining` 恒 0 → `recordReplayComplete()` 永不被调用
  /// → `replayCompleteAt` 恒 null → ResumeTimings 名义上三段埋点、实际
  /// 只有握手那段是活的。现在由服务端把它下发过来，链路接回。
  ///
  /// **不要把它简化回常量。** 那正是上面那条断链的成因。
  ///
  /// **只喂诊断，不做分派** —— 见 `AqtFfi.resumePreludeLen` 的文档。
  int get lastResumeScreenBytes {
    final h = _live('lastResumeScreenBytes');
    return h == null ? 0 : AqtFfi.resumePreludeLen(h);
  }

  /// Whether this transport was established via RESUME (true) or HELLO (false).
  bool _wasResumed = false;
  bool get wasResumed => _wasResumed;
  set wasResumed(bool v) => _wasResumed = v;

  /// 4-phase connect timings captured by `AqtTransportFactory`. All zero
  /// until the factory assigns it. Surfaced in debug overlay `conn` row.
  ConnectTimings lastConnectTimings = const ConnectTimings();

  /// 3-stage timestamps for the most recent RESUME cycle. Mutated in
  /// place by recordResumeSent/Ack/ReplayComplete; surfaced in debug
  /// overlay `res` row.
  ResumeTimings lastResumeTimings = const ResumeTimings();

  void recordResumeSent() {
    lastResumeTimings = ResumeTimings(
      sentAt: DateTime.now(),
      // sent 阶段服务端还没回 ACK，快照大小无从知道 —— 直接写 0 而不是读
      // getter：那次 FFI 往返注定拿到 0，紧接着的 recordResumeAck() 才有真值。
      screenBytes: 0,
    );
  }

  void recordResumeAck() {
    lastResumeTimings = ResumeTimings(
      sentAt: lastResumeTimings.sentAt,
      ackAt: DateTime.now(),
      screenBytes: lastResumeScreenBytes,
    );
  }

  void recordReplayComplete() {
    lastResumeTimings = ResumeTimings(
      sentAt: lastResumeTimings.sentAt,
      ackAt: lastResumeTimings.ackAt,
      replayCompleteAt: DateTime.now(),
      screenBytes: lastResumeTimings.screenBytes,
    );
  }

  /// Most recent path stats fetched from Rust. Stays at [PathStats.empty]
  /// until the first [refreshPathStats] call succeeds. Surfaced in debug
  /// overlay `path` row.
  PathStats lastPathStats = PathStats.empty;

  /// Pull a fresh snapshot from the FFI. Cheap (try_lock on a RwLock);
  /// returns silently on null FFI symbol / contended lock / dead conn.
  void refreshPathStats() {
    final h = _live('refreshPathStats');
    if (h == null) return;
    final s = AqtFfi.getPathStats(h);
    if (s != null) lastPathStats = s;
  }

  /// watchdog tick 的出口，由状态机的 runner 设置；tick 只报时，判断全在
  /// 状态机里（lib/ssh/aqt/conn/conn_machine.dart）。
  ///
  /// 旧的 `_runWatchdogTick()` 回落路径已删除 —— runner 覆盖全部 6 个
  /// transport 附着点，`onWatchdogTick` 总是被设上，那条回落走不到。
  void Function()? onWatchdogTick;

  /// 距上次收到入向 UDP 字节多久。Rust 侧 1Hz 轮询 `conn.stats().udp_rx.bytes`；
  /// "从未收到"由 FFI 归一化成 [AqtFfi.kNeverReceivedAgeMs] 哨兵值。
  ///
  /// 与 [lastPathStats] 对称：都是给决策层读的只读事实。不暴露 `_handle`
  /// 本身 —— 裸指针漏出去就再也管不住谁在用它。
  int get lastRecvAgeMs {
    final inj = _recvAgeImpl;
    if (inj != null) return inj();
    final h = _live('lastRecvAgeMs');
    // close 之后按「从未收到」上报：这是决策层已经会处理的哨兵值，比返回
    // 一个看起来很新鲜的 0 安全 —— 后者会让状态机以为链路还活着。
    return h == null
        ? AqtFfi.kNeverReceivedAgeMs
        : AqtFfi.getLastRecvAgeMs(h);
  }

  // --- Setters used by tryResume() to carry session info onto a new transport ---
  set lastHost(String? v) => _lastHost = v;
  set lastPort(int? v) => _lastPort = v;
  set lastSpki(Uint8List? v) => _lastSpki = v;
  set sessionToken(Uint8List? v) => _sessionToken = v;

  /// Exposed so [AqtTransportFactory.tryResume] can await the first TabOpened.
  Future<int> get tabOpenedFuture => _tabOpenedCompleter.future;

  /// Allows the resume path to set the tab id after the resume handshake.
  set tabId(int v) => _tabId = v;

  // --- Adaptive poll —— display-rate-aware idle interval ---
  // Busy:  Duration.zero  → immediate re-poll (zero latency when data flowing)
  // Idle:  _idlePollInterval → matches device refresh rate (120Hz=8ms, 60Hz=16ms)
  //        Computed from PlatformDispatcher.displays; falls back to 16ms if unavailable.
  static Duration get _idlePollInterval {
    // PlatformDispatcher.instance.displays gives the actual Hz on Flutter 3.x.
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    final hz = displays.isNotEmpty ? displays.first.refreshRate : 60.0;
    // Stay strictly below one frame period so we never miss a vsync.
    final frameMs = (1000.0 / hz).floor().clamp(4, 16);
    return Duration(milliseconds: frameMs);
  }

  void _startPolling() {
    _schedulePoll();
  }

  void _schedulePoll() {
    _pollTimer = Timer(Duration.zero, _pollAndReschedule);
  }

  void _pollAndReschedule() {
    if (_pollTimer == null || _frozen) return;
    var foundAny = false;
    // handle 每轮重取，不能在循环外取一次就用到底：`_handleEvent` 会同步
    // 调用 `onDisconnected`（reconnect_service.dart:982），那条回调链能一路
    // 同步走到本 transport 的 `close()`。close 之后循环若继续拿着旧指针,
    // 下一次 pollEvent 就打在已交还 Rust 的 handle 上。
    while (true) {
      final h = _live('pollEvent');
      if (h == null) break;
      final event = AqtFfi.pollEvent(h);
      if (event == null) break;
      _handleEvent(event);
      foundAny = true;
      if (_frozen) break; // freeze() called mid-loop (e.g. from onDisconnected)
    }
    if (_pollTimer == null || _frozen) return;
    // Immediate re-poll when busy; otherwise match device frame period.
    _pollTimer = Timer(
      foundAny ? Duration.zero : _idlePollInterval,
      _pollAndReschedule,
    );
  }

  void _handleEvent(AqtEvent event) {
    switch (event.kind) {
      case AqtEventKind.connected:
        _setState(TransportState.connected);
        // On (re)connection, flush any input the user typed during the
        // outage so their keystrokes don't get silently dropped.
        _flushPendingInput();
      case AqtEventKind.disconnected:
        _lastDisconnectAt = DateTime.now();
        // Reason currently not carried in event payload — track source.
        _lastDisconnectReason = onDisconnected != null ? 'quic-evt' : 'quic-evt-no-cb';
        if (onDisconnected != null) {
          // QUIC confirmed path is dead — mark so ReconnectService knows this
          // is a real failure (not a speculative probe on a still-alive connection).
          _quicPathDied = true;
          // 同步状态：之前只置 _quicPathDied 不改 _state，导致 DebugOverlay
          // 显示 qstate:connected + dead:true 的矛盾状态，外部 stateStream
          // 监听者也无法感知死亡。这里改为 reconnecting，让 UI 可以显示
          // 正在恢复的指示。
          _setState(TransportState.reconnecting);
          onDisconnected!();
        } else {
          // Fallback path: no RESUME registered — use 3s self-recovery timer.
          _setState(TransportState.reconnecting);
          _disconnectRecoveryTimer?.cancel();
          _disconnectRecoveryTimer = Timer(const Duration(seconds: 3), () {
            _disconnectRecoveryTimer = null;
            if (_state == TransportState.reconnecting && !_outputCtrl.isClosed) {
              _setState(TransportState.failed);
              if (!_done.isCompleted) _done.complete();
              _outputCtrl.close();
            }
          });
        }
      case AqtEventKind.failed:
        // Capture Rust error message for diagnostics.
        if (event.data.isNotEmpty) {
          _failureReason = String.fromCharCodes(event.data);
        }
        _setState(TransportState.failed);
        if (!_done.isCompleted) _done.complete();
        // Close output stream so startStreaming()'s onDone fires
        // → tab.onSessionDead → ReconnectService retries connection
        if (!_outputCtrl.isClosed) _outputCtrl.close();
      case AqtEventKind.ptyOutput:
        if (!_outputCtrl.isClosed) {
          _chunkDebug(event.data.length);
          _outputCtrl.add(Uint8List.fromList(event.data));
        }
      case AqtEventKind.tabOpened:
        _tabId ??= event.tabId;
        if (!_tabOpenedCompleter.isCompleted) {
          _tabOpenedCompleter.complete(event.tabId);
        }
      case AqtEventKind.tabClosed:
        if (event.data.isNotEmpty) {
          final reason = String.fromCharCodes(event.data);
          if (reason.startsWith('lz4')) {
            dbgLz4Errors++;
            dlog('AQT', 'LZ4 error (tab ${event.tabId}): $reason');
          }
        }
        break;
      case AqtEventKind.historyPreloadDone:
        break; // TODO: 待 history preload UI 接入
      case AqtEventKind.ticketReceived:
        break; // 占位，task 6 实现持久化逻辑
      case AqtEventKind.notify:
        final eventId = event.notifyEventId;
        final tsUnixMs = event.notifyTsUnixMs;
        final text = event.notifyText;
        if (eventId != null && tsUnixMs != null && text != null) {
          onNotify?.call(NotifyPayload(
            eventId: eventId,
            tsUnixMs: tsUnixMs,
            tabId: event.notifyTabId,
            text: text,
          ));
        }
    }
  }

  // ── Chunk size diagnostic ─────────────────────────────────────────────────
  int _dbgChunkCount = 0;
  int _dbgChunkBytes = 0;
  int _dbgMinChunk = 1 << 30;
  int _dbgMaxChunk = 0;
  DateTime _dbgWindowStart = DateTime.now();

  /// Stats from the last completed 1-second window. Shown in DebugOverlay.
  String dbgChunkStats = 'n/a';

  /// All-time max chunk size — if > 4096B, LZ4 compression is active.
  int dbgMaxChunkEver = 0;

  /// Count of LZ4 decompression errors (each causes TabClosed + disconnect).
  int dbgLz4Errors = 0;

  /// Timestamp of the last PtyOutput event. Used by ReconnectService to detect
  /// "phantom connected" state: QUIC handshake succeeded but server stopped
  /// sending PTY data (e.g. after a concurrent RESUME race and DISCARD-swap).
  DateTime _lastPtyDataAt = DateTime.now();

  /// Age of the last PTY data event. Returns Duration.zero for a fresh transport.
  Duration get lastPtyDataAge => DateTime.now().difference(_lastPtyDataAt);

  /// 最后一次**真正交给 FFI** 的写入时刻。null 表示这条 transport 还没发过
  /// 任何输入。
  ///
  /// 只在 [write] 走到 `AqtFfi.writePty` 那一步才更新 —— 被 [_bufferInput]
  /// 缓冲下来的按键根本没离开设备，拿它当「发过输入」会让 [isPhantomStall]
  /// 去追一个从未上路的回音。
  DateTime? _lastWriteAt;

  /// 距最后一次成功写入的时长；从没写过时为 null。见 [isPhantomStall]。
  Duration? get sinceLastWrite {
    final at = _lastWriteAt;
    return at == null ? null : DateTime.now().difference(at);
  }

  /// 「发出去的字节多久没等到回音」才算坏死。
  ///
  /// 20s 而不是更短，是给「服务端合法地不回显」留的余量：sudo/ssh 的密码
  /// 提示（stty -echo）、以及前台命令正忙时用户敲下的回车，都是发得出去、
  /// 本来就不该有输出的。这类场景通常几秒内结束，20s 足够跨过去；再短就会
  /// 在用户输密码输到一半时把连接换掉。
  ///
  /// 它同时是 [softReconnect] 的短路守卫和 periodic sweep 的入队条件 ——
  /// 两处必须读同一个常量，否则会出现「sweep 判它是幻影、softReconnect 判
  /// 它还活着」的死锁：每 3 秒入队一次，每次都被短路成空转。
  static const Duration kUnansweredWriteStall = Duration(seconds: 20);

  /// 「QUIC 活着，但服务端已经不再往这条连接推数据」的判据。
  ///
  /// 成因是 RESUME 竞态：先后两条 RESUME 都拿到 ACK，客户端只装上其中一
  /// 条，服务端的 PTY 流却留在另一条上（见 a4.jpg 现场的 #19/#20）。留下
  /// 的 transport 各项体征全正常 —— state=connected、pathDied=false、
  /// rtt/loss 健康、write() 也发得出去 —— 只是永远收不到回音。[isDead]
  /// 这一族判据全都看不见它，所以需要单独一条。
  ///
  /// 判的是**回音**，不是静默。这两者的区别是这条判据的全部要点：
  ///
  /// * [sinceLastWrite] 为 null（从没写过）→ 永远不判。没发过输入就没有理
  ///   由期待输出，那样的静默只是空闲。上一版判据缺了这一条，把「读屏幕
  ///   / 思考 / 等 API 回包」全算成了坏死。
  /// * [sinceLastWrite] < [ptyDataAge] —— 最后一次写入比最后一次收数据更
  ///   近，也就是那次写入之后服务端一个字都没回过。反过来（收数据更近）
  ///   说明回音来过，链路是通的。
  /// * 超过 [threshold] 才算 —— 给服务端留出正常的处理与往返时间。
  ///
  /// 另两个前提：[wasResumed]（幻影只可能是 RESUME 的产物，新 HELLO 连接
  /// 的静默是「还没开始」）、[connected]（没连上的交给 [isDead]，两条判据
  /// 不重叠）。
  ///
  /// 抽成 static 纯函数是为了 device-free 可测（与 ReconnectService 里
  /// [shouldSkipPeriodicSweep] 同一模式）。
  static bool isPhantomStall({
    required bool wasResumed,
    required bool connected,
    required Duration? sinceLastWrite,
    required Duration ptyDataAge,
    Duration threshold = kUnansweredWriteStall,
  }) {
    if (!wasResumed || !connected) return false;
    final w = sinceLastWrite;
    if (w == null) return false;
    return w > threshold && w < ptyDataAge;
  }

  /// [isPhantomStall] 作用在本 transport 当前状态上的结果。
  bool get isPhantomStalled => isPhantomStall(
        wasResumed: _wasResumed,
        connected: _state == TransportState.connected,
        sinceLastWrite: sinceLastWrite,
        ptyDataAge: lastPtyDataAge,
      );

  /// [softReconnect] 的守卫：返回 false 表示协议层自救没有意义，必须把决定
  /// 权交回 ReconnectService 的完整 RESUME/FULLRECONN 链。
  ///
  /// 三个否决项各自对应一种「roam 一个空 datagram 治不好」的坏死方式：
  /// 路径已死、状态已终止、以及服务端不再认这条连接（[phantomStalled]）。
  /// 最后那条是后加的 —— 缺了它，幻影会被判成「协议层已恢复」，重连在
  /// 2s 后报成功却什么都没换。
  static bool canSoftReconnect({
    required bool pathDied,
    required bool failedOrClosed,
    required bool phantomStalled,
  }) =>
      !pathDied && !failedOrClosed && !phantomStalled;

  void _chunkDebug(int size) {
    _lastPtyDataAt = DateTime.now();
    _dbgChunkCount++;
    _dbgChunkBytes += size;
    if (size < _dbgMinChunk) _dbgMinChunk = size;
    if (size > _dbgMaxChunk) _dbgMaxChunk = size;
    if (size > dbgMaxChunkEver) dbgMaxChunkEver = size;
    final now = DateTime.now();
    if (now.difference(_dbgWindowStart).inMilliseconds >= 1000) {
      final avg = _dbgChunkCount > 0
          ? (_dbgChunkBytes ~/ _dbgChunkCount)
          : 0;
      dbgChunkStats =
          '${_dbgChunkCount}x avg=${avg}B '
          'max=${_dbgMaxChunk}B '
          'tot=${_fmtDbgBytes(_dbgChunkBytes)}/s';
      _dbgChunkCount = 0;
      _dbgChunkBytes = 0;
      _dbgMinChunk = 1 << 30;
      _dbgMaxChunk = 0;
      _dbgWindowStart = now;
    }
  }

  static String _fmtDbgBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}K';
    return '${(b / 1048576).toStringAsFixed(1)}M';
  }
  // ─────────────────────────────────────────────────────────────────────────

  void _setState(TransportState s) {
    if (_state == s) return;
    _state = s;
    _stateCtrl.add(s);
  }

  @override
  TransportKind get kind => TransportKind.aqt;

  @override
  Set<TransportCapability> get capabilities => const {
        TransportCapability.localEchoPrediction,
        TransportCapability.roaming,
        TransportCapability.scrollbackReplay,
        TransportCapability.fileTransfer,
        TransportCapability.suspendResume,
        TransportCapability.metricsRich,
      };

  @override
  TransportState get currentState => _state;

  @override
  Stream<TransportState> get stateStream => _stateCtrl.stream;

  @override
  TransportMetrics get metrics => _metrics;

  @override
  Stream<Uint8List> get output => _outputCtrl.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => _done.future;

  // ── Input buffering during reconnect ─────────────────────────────────────
  // When the transport is dead or reconnecting, writes are silently dropped
  // by AqtFfi.writePty (writing to a dead handle is a no-op). To make rebuilds
  // truly invisible to the user, buffer their keystrokes here and flush them
  // the moment a new healthy transport is available. The buffer is transferred
  // to the new transport during _swapTransport (so user input during a RESUME
  // window survives the swap).
  /// Cap to prevent unbounded growth if the connection truly cannot recover.
  static const int _kMaxPendingInputBytes = 8192;
  List<int>? _pendingInputBuffer;

  /// [write] 被调用的次数（含被缓冲和被丢弃的）。仅供 debug overlay ——
  /// 它是分辨「用户没打字」与「打了但没发出去」的唯一依据，而这两种在
  /// `sinceLastWrite == null` 上的表现完全相同。
  int _dbgWriteCalls = 0;
  int get debugWriteCalls => _dbgWriteCalls;

  /// 还压在缓冲里、没能发出去的输入字节数。
  int get pendingInputBytes => _pendingInputBuffer?.length ?? 0;

  /// 服务端分配的 tab id；null 表示 OPEN_TAB_ACK 还没回来。
  int? get debugTabId => _tabId;

  bool get _readyForWrite =>
      _tabId != null &&
      _state == TransportState.connected &&
      !isDead;

  void _bufferInput(Uint8List data) {
    _pendingInputBuffer ??= <int>[];
    final remaining = _kMaxPendingInputBytes - _pendingInputBuffer!.length;
    if (remaining <= 0) return; // already at cap — silently drop overflow
    final take = data.length > remaining ? remaining : data.length;
    _pendingInputBuffer!.addAll(data.sublist(0, take));
  }

  void _flushPendingInput() {
    final buf = _pendingInputBuffer;
    if (buf == null || buf.isEmpty) return;
    _pendingInputBuffer = null;
    final t = _tabId;
    if (t == null) return;
    final h = _live('flushPendingInput');
    if (h == null) return;
    _writePty(h, t, Uint8List.fromList(buf));
  }

  /// 唯一一处真正把字节交给 FFI 的地方，顺手记下 [_lastWriteAt]。
  ///
  /// 两个调用点（[write] 与 [_flushPendingInput]）都必须走这里：漏掉 flush
  /// 那一半，[isPhantomStall] 就看不见「断线期间攒下、重连后一次性发出」的
  /// 那批按键，而那恰恰是最需要盯回音的时刻。包成一个方法之后漏不掉。
  void _writePty(Pointer<Void> h, int tabId, Uint8List data) {
    _lastWriteAt = DateTime.now();
    AqtFfi.writePty(h, tabId, data);
  }

  /// Drain pending input; called by _swapTransport on the OLD transport.
  Uint8List? drainPendingInput() {
    final buf = _pendingInputBuffer;
    if (buf == null || buf.isEmpty) return null;
    _pendingInputBuffer = null;
    return Uint8List.fromList(buf);
  }

  /// Adopt pending input from previous transport; called on the NEW transport
  /// during _swapTransport BEFORE it transitions to connected state.
  void adoptPendingInput(Uint8List? data) {
    if (data == null || data.isEmpty) return;
    _pendingInputBuffer = List<int>.from(data);
  }

  @override
  void write(Uint8List data) {
    _dbgWriteCalls++;
    final t = _tabId;
    if (t == null) {
      // **缓冲而不是丢弃。** 这里此前是一句裸 `return` —— 而 `_tabId` 恰恰在
      // 「RESUME 握手已发出、OPEN_TAB_ACK 还没回来」这段窗口里为 null，也就是
      // 恢复过程中。用户在那几百毫秒（RESUME 超时的话是 5 秒）里敲的每一个键
      // 都被静默吞掉，屏幕上没有任何痕迹。
      //
      // 下面那条 `!_readyForWrite` 分支一直是缓冲的，两条路径没有理由不一致：
      // 都是「暂时发不出去」，都该等连接就绪后补发。
      _bufferInput(data);
      return;
    }
    if (!_readyForWrite) {
      // Transport is dead/reconnecting — buffer the keystrokes so they
      // survive the swap. Flushed on state→connected or in adoptPendingInput
      // → state→connected of the new transport.
      _bufferInput(data);
      return;
    }
    // Connected: drain any buffered input first to preserve order.
    if (_pendingInputBuffer != null && _pendingInputBuffer!.isNotEmpty) {
      _flushPendingInput();
    }
    final h = _live('write');
    if (h == null) return;
    _writePty(h, t, data);
  }

  @override
  void resize(int cols, int rows) {
    final t = _tabId;
    if (t == null) return;
    final h = _live('resize');
    if (h == null) return;
    AqtFfi.resizeTab(h, t, cols, rows);
  }

  /// Ack a notify event up to and including [eventId]. Server advances
  /// `last_acked` on receipt and prunes its queue accordingly.
  ///
  /// **Call this only after the notification has actually been displayed**
  /// (system notification posted, or in-app SnackBar shown). Acking early —
  /// e.g. right after [onNotify] fires, before display succeeds — lets the
  /// server prune an event the client hasn't actually shown yet; if the app
  /// then crashes before display completes, that event is gone forever with
  /// no way to recover it. This inverts the protocol's core guarantee
  /// ("宁可重复投递，不可静默丢失" — better to redeliver than silently lose).
  void ackNotify(int eventId) {
    final h = _live('ackNotify');
    if (h == null) return;
    AqtFfi.notifyAck(h, eventId);
  }

  /// `close()` 实际触达 FFI `aqt_close` 的次数。
  ///
  /// Rust 侧的 `aqt_close`（ffi.rs:591）就是 `Arc::from_raw(handle)` 之后立刻
  /// drop —— 调两次就是对同一个 Arc 减两次强引用计数，SessionHandle 提前归零
  /// 被释放，而 ffi.rs:483 那个 1Hz 轮询 task 仍持有它，下一个 tick 里的
  /// `h_poll.conn.read().await` 读到的就是已释放内存（SIGSEGV in aqt-rt）。
  ///
  /// 幂等测试必须断言这个计数：只断言「不抛异常」是不够的 —— `testStub` 的
  /// `_handle` 是 nullptr，而 `AqtFfi.close` 遇 nullptr 直接 return，于是 FFI
  /// 层的 double free 在那种断言下完全不可见。
  @visibleForTesting
  int ffiCloseCount = 0;

  /// 首次 `close()` 的 Future —— 幂等闸门。
  ///
  /// 用 Future 缓存而不是 `bool _closed` 闸门，是因为重复调用者要能 await 到
  /// **同一次**关闭真正跑完（`aqt_transport_factory` 里有多处
  /// `await t.close()`），而不是在首次关闭还没结束时就拿到一个立即完成的
  /// Future、误以为已经关干净了。
  Future<void>? _closing;

  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    // 第一行就置位。这个标志**不参与安全判断** —— 安全靠 `_handle` 可空 +
    // 编译器强制的 null 检查。它只决定 [_live] 记不记账，用来把「close 之后
    // 还有人来取」和「testStub 天生没有 handle」区分开。
    //
    // 不复用 `_closing != null` 作判据，是因为 `_closing ??= _closeOnce()`
    // 先求值右侧、后赋值：本方法的整个同步段（包括下面的 AqtFfi.close）跑完
    // 时 `_closing` 还是 null，那段窗口里的记账会漏掉。
    _closed = true;
    _pollTimer?.cancel();
    _pollTimer = null; // Signal _pollAndReschedule not to reschedule
    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    onDisconnected = null; // prevent stale callback after close
    onNotify = null; // ditto for notify callback
    _frozen = false;
    _quicPathDied = false;
    ffiCloseCount++;
    // 断开引用**必须**早于 AqtFfi.close，更要早于本方法后面那两个 await
    // （`_stateCtrl.close` / `_outputCtrl.close`）。await 会让出事件循环，
    // 期间任何入口取到这个指针，打的都是已经交还给 Rust 的 handle ——
    // 而 ffi.rs:496 的轮询 task 约一秒后就会让 refcount 归零、内存释放。
    final h = _handle;
    _handle = null;
    if (h != null) AqtFfi.close(h);
    // The relay (and the SSH connection it rides on) exist only for this
    // QUIC connection; closing them also ends the remote --relay process.
    final relay = _relay;
    _relay = null;
    unawaited(relay?.close());
    final ssh = _ownedSshClient;
    _ownedSshClient = null;
    ssh?.close();
    _setState(TransportState.closed);
    if (!_done.isCompleted) _done.complete();
    if (!_stateCtrl.isClosed) await _stateCtrl.close();
    // `_outputCtrl` 是单订阅（见它的定义处注释），而单订阅 controller 的
    // `close()` 只在 done **被送达订阅者之后**才完成 —— 没有订阅者时 done
    // 无处可送，`await` 永久挂住。broadcast 的 `_stateCtrl` 没这个问题，
    // 所以上面那行可以直接 await。
    //
    // 「没有订阅者」不是边缘情况，而是 RESUME 失败路径的常态：output 的
    // 唯一订阅点是 `SessionManager.startStreaming()`，它只在 RESUME 成功、
    // 调用方把 transport 赋给 `tab.transport` 之后才被调用。而
    // `tryResumeWithInfoDetailed` 有三处 `await t.close()`（state==failed /
    // TimeoutException / catch-all）全落在失败路径上。
    //
    // 挂在这里会让整条重连链停摆：resume 永不返回 → appendResumeResult 永不
    // 执行（日志里表现为「发起了却没有结果」）→ _retrying /
    // _proactiveResuming 标志永不清除 → 后续每次重连都被这些标志挡掉 →
    // QUIC 再也不恢复。SSH / mosh 不走 AQT resume，同一次网络恢复里照常
    // 重连 —— 「SSH 最快、mosh 其次、QUIC 一直不恢复」就是这么来的。
    //
    // 有订阅者时仍然 await：startStreaming 的重装配逻辑依赖 onDone 真的跑过。
    if (!_outputCtrl.isClosed) {
      if (_outputCtrl.hasListener) {
        await _outputCtrl.close();
      } else {
        _outputCtrl.close().ignore();
      }
    }
  }

  @override
  void setForeground(bool active) {
    final h = _live('setForeground');
    // close 之后直接返回 —— 不只是跳过这次 FFI 调用，更要紧的是**不能走到
    // 下面的 `??=` 分支**。那两个 `Timer.periodic` 一旦建起来，就会每 3 秒 /
    // 每 1 秒自己去取一次 handle，把一次性的误用变成持续的。close() 刚把它们
    // 取消掉，这里不能复活。
    if (h == null) return;
    AqtFfi.setForeground(h, active);
    if (active) {
      // 前台转换的时刻不再记在这里 —— 状态机收到 LifecycleForeground 时会把
      // observeStartMs 设成当时的 nowMs，那才是「观测重新开始」的单一记录点。
      // Foreground: 3 s app heartbeat for fast failure detection (C1: tightened from 5s).
      // Quinn keep_alive_interval (15 s, see Rust client.rs) handles NAT
      // keepalive at the protocol level; app heartbeat layers on top to
      // catch failures within seconds rather than ~15 s + Quinn PTO.
      // 回调里走 `heartbeat()` 而不是捕获上面那个 `h`：定时器的生命周期比
      // 这次调用长得多，闭包捕获一个裸指针等于把「close 后失效」这件事挡在
      // 闸门之外。`heartbeat()` 自己会重新取。
      _heartbeatTimer ??= Timer.periodic(kHeartbeatIntervalForeground, (_) {
        if (_state == TransportState.connected) heartbeat();
      });
      if (kImmediateForegroundProbe &&
          _state == TransportState.connected) {
        heartbeat();
      }
      if (kForegroundWatchdog) {
        // tick 只报时，判断全在状态机里（lib/ssh/aqt/conn/conn_machine.dart）。
        // 旧的 _runWatchdogTick 回落路径已删除 —— runner 覆盖全部 6 个 transport
        // 附着点，onWatchdogTick 总是被设上，那条回落走不到。
        _watchdogTimer ??= Timer.periodic(
          const Duration(seconds: 1),
          (_) => onWatchdogTick?.call(),
        );
      }
    } else {
      // Background: cancel app heartbeat. Quinn's keep_alive_interval (15 s)
      // is the sole keepalive in background — saves battery / cellular data
      // (3 s × ~30 B = 360 B/min × hours of background) and avoids the
      // 1.5 MB-prelude reconnect cycles previously seen on flaky networks
      // when background heartbeats prematurely declared connection death.
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
    }
  }

  @override
  void heartbeat() {
    final h = _live('heartbeat');
    if (h == null) return;
    AqtFfi.heartbeat(h);
  }

  @override
  void roam() {
    // Conservative: stimulate the EXISTING socket with a 1-byte datagram.
    // Called from periodic stale-probe loops in ReconnectService, so it
    // must NOT do anything disruptive (no rebind, no socket changes).
    // Real connection migration lives in `migrateEndpoint()` and is gated
    // on positively-identified network-interface change.
    final h = _live('roam');
    if (h == null) return;
    AqtFfi.roam(h);
  }

  /// True RFC 9000 §9 connection migration: rebind the Quinn endpoint to
  /// a fresh UDP socket on the current default route. Kernel's source-
  /// address selection picks whichever interface is now active (Wi-Fi
  /// or cellular), so packets leave from the new path immediately.
  /// Quinn initiates PATH_CHALLENGE on the new four-tuple; the server
  /// responds with PATH_RESPONSE and migrates the connection state —
  /// connection ID + PTY streams preserved, no RESUME needed.
  ///
  /// **Call ONLY from positively-identified network-type-change paths**
  /// (ConnectivityResult.wifi → ConnectivityResult.mobile, etc.). NOT
  /// from generic stale-probe loops — see a9.jpg / commit reverted in
  /// 1d20ce6 for why over-eager migration desyncs the xterm parser.
  ///
  /// Migration typically completes in ~1 RTT (100-400 ms). If it fails
  /// silently (server doesn't validate within Quinn's window), the
  /// normal heartbeat + idle-timeout chain detects the dead path and
  /// falls back to RESUME via onSessionDead.
  void migrateEndpoint() {
    final h = _live('migrateEndpoint');
    if (h == null) return;
    AqtFfi.rebind(h);
  }

  /// C3 — Force the path-dead bit and fire onDisconnected. Used by the
  /// post-migration audit in ReconnectService when QUIC's PATH_CHALLENGE
  /// validation silently fails. Idempotent: second call is a no-op so
  /// duplicate audits don't double-fire onDisconnected.
  ///
  /// Distinct from `close()`: leaves the transport object alive so resume
  /// metadata (lastPort/lastSpki/sessionToken/lastTabId) is still readable
  /// for downstream RESUME.
  void markPathDied(String reason) {
    if (_quicPathDied) return; // idempotent
    _quicPathDied = true;
    _lastDisconnectAt = DateTime.now();
    _lastDisconnectReason = reason;
    onDisconnected?.call();
  }

  @override
  Future<bool> softReconnect() async {
    // QUIC 路径已确认死亡（Disconnected 事件设置了 _quicPathDied=true 但未改变
    // _state，因为 onDisconnected 被注册了）。返回 false 强制 _reconnect() 走
    // RESUME/FULLRECONN 流程，而不是通过 SSH-alive 检查提前退出（否则终端冻结）。
    // 三个否决项合并在 [canSoftReconnect] 里，逐条的理由见那里。最要命的是
    // phantomStalled：路径没死、状态是 connected，下面那句 roam 会照常发出去
    // 并返回 true —— 而 true 的含义是「协议层自己搞定了，不必重建」，
    // _reconnect 收到它就在 2s 后直接 return 成功（reconnect_service.dart 的
    // softReconnect 分支）。transport 一个字节都没换，lastPtyDataAge 不归零，
    // 下一次 periodic sweep 立刻又判出幻影：每 3 秒一轮，永远不收敛，用户卡
    // 在「连接在、输入不了」里出不来（a4.jpg 的 07:49 那段日志）。
    //
    // 一个空 datagram 治不好「服务端不再认这条连接」，只有重发 RESUME 能。
    if (!canSoftReconnect(
      pathDied: _quicPathDied,
      failedOrClosed: _state == TransportState.failed ||
          _state == TransportState.closed,
      phantomStalled: isPhantomStalled,
    )) {
      return false;
    }
    final h = _live('softReconnect');
    if (h == null) return false;
    AqtFfi.roam(h);
    return true;
  }

  @override
  void suppressLocalEcho() {
    assertCapability(this, TransportCapability.localEchoPrediction);
    // Placeholder: local echo prediction not yet implemented in MVP.
  }

  @override
  void suppressNextLocalEcho() {
    assertCapability(this, TransportCapability.localEchoPrediction);
  }

  @override
  Future<FileTransferHandle> upload(File local, String remotePath) async {
    assertCapability(this, TransportCapability.fileTransfer);
    final size = await local.length();
    // Compute sha256 for integrity verification (passed to FFI in Stage 5)
    await computeFileSha256(local);

    // MVP stub: request_id = 1; real impl calls aqt_file_upload_start via FFI
    const requestId = 1;

    // 这里把 handle 交到类外，正是 `lastRecvAgeMs` 那条注释警告的事
    // （「裸指针漏出去就再也管不住谁在用它」）。至少不能漏一个已失效的：
    // transport 关了就没有会话可传，显式失败好过让 AqtFileHandle 拿着悬垂
    // 指针等到真正实现 FFI 调用的那天。
    final h = _live('upload');
    if (h == null) {
      throw StateError('transport 已关闭，无法发起上传');
    }

    final handle = AqtFileHandle(
      sessionHandle: h,
      requestId: requestId,
      totalBytes: size,
    );

    // Pump file bytes asynchronously; notifies progress stream
    unawaited(_pumpUpload(local, handle));
    return handle;
  }

  Future<void> _pumpUpload(File local, AqtFileHandle handle) async {
    try {
      var bytesSent = 0;
      await for (final chunk in local.openRead()) {
        bytesSent += chunk.length;
        handle.notifyProgress(bytesSent, null);
      }
      handle.notifyDone(state: FileTransferState.completed);
    } catch (e) {
      handle.notifyDone(
        state: FileTransferState.failed,
        error: e.toString(),
      );
    }
  }

  @override
  Future<FileTransferHandle> download(String remotePath, File local) async {
    assertCapability(this, TransportCapability.fileTransfer);
    // MVP stub: request_id = 1, totalBytes = 0 (unknown until server responds)
    // 同 [upload]：不把已失效的 handle 漏到类外。
    final h = _live('download');
    if (h == null) {
      throw StateError('transport 已关闭，无法发起下载');
    }
    final handle = AqtFileHandle(
      sessionHandle: h,
      requestId: 1,
      totalBytes: 0,
    );
    // Real implementation: call aqt_file_download_start and drive progress events
    return handle;
  }

  @override
  Future<void> requestScrollbackReplay(int fromOffset) async {
    assertCapability(this, TransportCapability.scrollbackReplay);
    // Placeholder: send RESUME frame with fromOffset via FFI.
  }
}
