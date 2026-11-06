// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../util/dlog.dart';
import 'dart:convert';
import 'dart:typed_data' show Uint8List;
import 'package:flutter/foundation.dart'
    show visibleForTesting, ChangeNotifier;
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';
import '../ai/ai_engine.dart';
import '../data/models/server.dart';
import '../data/repositories/tab_session_repository.dart';
import '../sftp/sftp_service.dart';
import 'mosh_reconnect_stats.dart';
import 'network_stability.dart';
import 'aqt/aqt_transport.dart' show AqtTransport;
import 'aqt/aqt_ffi.dart' show NotifyPayload;
import 'aqt/prewarm_pool.dart';
import 'aqt/session_resume_coordinator.dart';
import 'ssh_connection.dart';
import 'tmux_helper.dart' show TmuxHelper;
import 'multiplexer/multiplexer_backend.dart';
import 'multiplexer/none_backend.dart';
import 'multiplexer/tmux_backend.dart';
import 'local_shell.dart';
import 'transport/composite_transport_factory.dart';
import 'transport/remote_transport.dart';
import 'transport/transport.dart';
import 'transport/tmux_passthrough_unwrapper.dart';
import 'foreground_input_owner.dart' as fg;
import 'transport/transport_factory.dart';

/// Why a reconnect attempt was triggered.
enum ReconnectCause { watchdogTimeout, sendError, explicitClose, fullReconnect }

/// Whether a reconnect tried the soft path or the hard path.
enum ReconnectKind { soft, hard }

enum ReconnectUiMessageKind { info, success, warning, error }

enum ReconnectUiMessageCode {
  text,
  reconnectInProgress,
  /// 用户主动从 tab 菜单点"刷新"触发的重连。与 reconnectInProgress 分开：
  /// 后者表达"连接异常 → 系统在抢救"的语义，会让用户误以为出问题；
  /// 这个表达"你点的刷新按钮在工作中"，符合用户主动操作的心智。
  refreshing,
  reconnectSuccess,
  reconnectFailedWithError,
  reconnectRetryCountdown,
  reconnectNetworkUnstableRetry,
  reconnectCascadeWarning,
  reconnectLoopDetected,
  reconnectMoshHandshake,
  reconnectMoshConnected,
  reconnectMoshFallback,
  reconnectMoshFallbackWithReason,
  reconnectMoshDisconnectedRestoring,
  reconnectMoshSessionRestored,
  reconnectMoshRestoreFailedRehandshake,
  tmuxNotFoundDisabled,
}

class ReconnectUiMessage {
  final String text;
  final ReconnectUiMessageCode code;
  final Map<String, Object> args;
  final ReconnectUiMessageKind kind;
  final DateTime updatedAt;
  final Duration? ttl;

  const ReconnectUiMessage({
    required this.text,
    required this.kind,
    required this.updatedAt,
    this.code = ReconnectUiMessageCode.text,
    this.args = const {},
    this.ttl,
  });

  const ReconnectUiMessage.localized({
    required this.code,
    required this.kind,
    required this.updatedAt,
    this.args = const {},
    this.ttl,
  }) : text = '';

  bool get isExpired =>
      ttl != null && DateTime.now().isAfter(updatedAt.add(ttl!));
}

class ReconnectEvent {
  final DateTime at;
  final ReconnectCause cause;
  final ReconnectKind kind;
  final bool succeeded;
  const ReconnectEvent(this.at, this.cause, this.kind, this.succeeded);
}

/// Describes a single restored tab passed to [SessionManager.restoreFromSaved].
class TabRestoreEntry {
  final String tabId;
  final Server server;
  final String tmuxKey;
  final String? sftpLastPath;
  const TabRestoreEntry({
    required this.tabId,
    required this.server,
    required this.tmuxKey,
    this.sftpLastPath,
  });
}

/// Which view the user is currently looking at for a given tab.
/// terminal — xterm shell view (default for all new/resumed tabs).
/// sftp — embedded SFTP browser bound to the same SSH/QUIC client.
enum TabViewMode { terminal, sftp }

/// Per-tab error category for `SessionTab.errorCounts`. Each connect/RESUME
/// failure is classified into exactly one bucket (with `other` as the
/// catch-all) and surfaced as the `errCnt` row in debug overlay.
enum ErrCategory {
  /// `SSHChannelOpenError` — server refused new channel
  /// (sshd MaxSessions / half-dead pooled client / network half-open).
  sshChannel,
  /// `AqtBootstrapException` containing "timeout" / "exec timed out" —
  /// remote `flyterm-server` exec hung before printing AQT_* lines.
  bootTimeout,
  /// QUIC handshake timed out (8 s budget) — UDP path blocked / wrong
  /// SPKI / server crashed mid-bootstrap.
  quicTimeout,
  /// `AqtServerNotInstalledException` — server binary missing from
  /// remote PATH and ~/.flyterm-server/bin/.
  notInstalled,
  /// `AqtDaemonStartFailedException` — daemon-mode start gave up after
  /// 5 s polling for daemon.info.
  daemonFail,
  /// Anything else (catch-all for unclassified exceptions).
  other,
}

/// Classify an exception into its [ErrCategory]. Order matters — most
/// specific match first; `other` is the fall-through.
ErrCategory classifyConnectError(Object e) {
  final s = e.toString();
  if (s.contains('SSHChannelOpenError')) {
    return ErrCategory.sshChannel;
  }
  if (s.contains('AqtServerNotInstalledException') ||
      s.contains('AqtServerNotInstalled')) {
    return ErrCategory.notInstalled;
  }
  if (s.contains('AqtDaemonStartFailedException') ||
      s.contains('AqtDaemonStartFailed')) {
    return ErrCategory.daemonFail;
  }
  if (s.contains('QUIC connect timed out') ||
      s.contains('QUIC handshake')) {
    return ErrCategory.quicTimeout;
  }
  if (s.contains('AqtBootstrapException') &&
      (s.contains('timeout') || s.contains('timed out'))) {
    return ErrCategory.bootTimeout;
  }
  return ErrCategory.other;
}

class SessionTab {
  final String id;
  final Server server;
  final SSHConnection connection;
  final Terminal terminal;

  /// Key used to derive the multiplexer session name.
  /// For restored tabs this is loaded from [tab_sessions]; for new tabs the
  /// first tab for a server uses server.id (survives app restarts), additional
  /// tabs use a UUID.
  final String sessionKey;

  /// Active multiplexer backend for this tab.
  /// Defaults to [NoneBackend]; replaced with [TmuxBackend] (or another) once
  /// the multiplexer is detected and initialized.
  MultiplexerBackend backend = NoneBackend();

  /// Deprecated — use [sessionKey] instead.
  @Deprecated('Use sessionKey')
  String get tmuxSessionKey => sessionKey;

  /// Deprecated — access the control pipe via `(backend as TmuxBackend).controlPipe`.
  @Deprecated('Use backend; cast to TmuxBackend to access controlPipe')
  dynamic get controlPipe =>
      backend is TmuxBackend ? (backend as TmuxBackend).controlPipe : null;

  /// True until the first successful SSH connection completes.
  /// Prevents startupCommand from running again on reconnect.
  bool isFirstConnection = true;

  /// True once tmux detection succeeded and attachOrCreate was sent.
  /// Drives the [T] indicator in the tab title and reconnect behaviour.
  /// True when the multiplexer backend has successfully attached to a session.
  bool get inTmux => backend.isActive;

  /// True when this tab is connected via mosh SSP (not plain SSH).
  bool isMosh = false;

  /// Which UI surface the user is viewing. Modified only via
  /// [SessionManager.toggleViewMode] so listeners always fire.
  TabViewMode viewMode = TabViewMode.terminal;

  /// Last SFTP path browsed on this tab; restored when toggling back.
  String? sftpCwd;

  /// Cached SFTP service for this tab. Set when the user first opens SFTP
  /// on this tab and reused on subsequent view toggles to avoid reconnect.
  SFTPService? sftpSvc;

  /// True when sftpSvc is alive and safe to use without reconnecting.
  bool get sftpSvcIsUsable => sftpSvc != null && !sftpSvc!.isDisposed;

  /// 上次**自动**重连 SFTP 的时刻，用于限流。
  ///
  /// 必须挂在 tab 上而不是视图里：自动重连会换掉 [sftpSvc] 并重建
  /// `SftpInlineView`，视图内的「已重连过」标志随之清零 —— 如果新连接也失败，
  /// 就会无限重连下去。tab 比这两者都长寿，是唯一能刹住车的地方。
  /// 用户手动点「重新连接」不受此限流约束。
  DateTime? lastSftpAutoReconnect;

  /// Dispose and null [sftpSvc] so the next SFTP open creates a fresh
  /// connection. [sftpCwd] is preserved — the new session starts in the
  /// same directory the user was browsing before the disconnect.
  void invalidateSftpSvc() {
    sftpSvc?.dispose();
    sftpSvc = null;
  }

  /// Typed transport — set when a session is opened via TransportFactory.
  /// When set, takes precedence over moshShell + connection.shell for I/O.
  RemoteTransport? _transport;

  /// 当前传输。**受控 setter** —— 赋值会触发 [onTransportChanged]。
  ///
  /// 为什么必须受控：全仓库有 6 个地方给它赋值（reconnect_service 2 处、
  /// terminal_screen 4 处，其中一个是首连路径）。连接状态机的 runner 必须跟着
  /// transport 的生命周期走；若只在 reconnect_service 里建，首连与 prewarm 接管
  /// 的 tab 就永远拿不到 runner —— 新旧两套判活逻辑长期并存。
  ///
  /// 收敛成 setter 而不是去改那 6 个调用点：调用点还会再长出来，而 setter 是
  /// 唯一必经之路。
  RemoteTransport? get transport => _transport;
  set transport(RemoteTransport? t) {
    if (identical(_transport, t)) return;
    _transport = t;
    onTransportChanged?.call(this, t);
  }

  /// `transport` 变更的回调，由 `ReconnectService.start()` 注册。
  ///
  /// 用静态 hook 而不是构造注入：`SessionTab` 不能依赖 `ReconnectService`
  /// （循环依赖）。同一手法见 [debugAqtStartStreamingHook]。
  static void Function(SessionTab tab, RemoteTransport? next)?
      onTransportChanged;

  /// Helper getters derived from transport.kind (for callers that need type info)
  bool get isLocalTransport => transport?.kind == TransportKind.local;
  bool get isAqtTransport => transport?.kind == TransportKind.aqt;

  /// True while ReconnectService is actively retrying this tab.
  bool isReconnecting = false;

  /// UI-only reconnect status.  This must never be written into the terminal
  /// buffer, because tmux/TUI apps own that surface and may repaint over it.
  ReconnectUiMessage? reconnectUiMessage;

  /// Per-tab network health score; both transports feed events here.
  final networkStability = NetworkStability();

  /// Sliding-window timestamps of recent SGR mouse-wheel sends from the
  /// terminal widget. Used by DebugOverlay to compute the live SGR send
  /// rate, which directly proves whether the throttle/gate is active:
  ///   • ungated (Plan A) — rate ≈ pointer-event rate (~60 Hz during drag)
  ///   • RTT-paced gate    — rate ≈ 1000 / SRTT (e.g. 30 Hz at 33 ms RTT)
  /// Auto-trimmed to the last 1 s so the count == events-per-second.
  final scrollSgrSendTimes = <DateTime>[];
  DateTime? lastSgrSendAt;

  void recordSgrSend() {
    final now = DateTime.now();
    lastSgrSendAt = now;
    scrollSgrSendTimes.add(now);
    final cutoff = now.subtract(const Duration(seconds: 1));
    scrollSgrSendTimes.removeWhere((t) => t.isBefore(cutoff));
  }

  int get secondsSinceLastSgrSend {
    final value = lastSgrSendAt;
    if (value == null) return 1 << 30;
    return DateTime.now().difference(value).inSeconds;
  }

  /// Per-tab log of reconnect attempts (auto-trimmed to last 5 minutes).
  final reconnectHistory = <ReconnectEvent>[];

  /// Per-tab mosh reconnect stats — counters, reason buckets, recent-event
  /// ring buffer. Both v1 and v2 paths feed into this so the debug overlay
  /// shows a single unified picture instead of scattered fields.
  final moshStats = MoshReconnectStats();

  /// Append and auto-trim entries older than 5 minutes.
  void appendReconnect(ReconnectEvent e) {
    reconnectHistory.add(e);
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    reconnectHistory.removeWhere((x) => x.at.isBefore(cutoff));
  }

  /// Non-null when the mosh SSP shell is active.
  /// [startStreaming] prefers this over [connection.shell] when set.
  dynamic moshShell; // MoshShell — typed as dynamic to avoid circular import

  /// Non-null when this tab is running a local PTY shell (serverType == 'local').
  LocalShell? localShell;

  /// Set by [ReconnectService] when a connection attempt fails. Non-null is
  /// what turns the tab dot red (`isDisconnected` in terminal_screen).
  ///
  /// Cleared at the start of each reconnect attempt **and** as soon as a
  /// usable transport is installed (`ReconnectService.clearStaleErrorState`).
  /// That second clear is not redundant: QUIC's proactive resume never goes
  /// through `_reconnect()`, so with only the first one a tab that recovered
  /// in 291 ms kept a red dot until the next full reconnect — while
  /// `qstate:connected` and bytes were flowing.
  String? connectionError;

  /// Called when the active shell stream ends unexpectedly (e.g. mosh-server
  /// process died and the 30 s watchdog fired). Set by [ReconnectService]
  /// after each successful connection so it can trigger a re-handshake.
  void Function()? onSessionDead;

  /// PID of the old mosh-server that needs to be killed on the next reconnect.
  /// Set by [ReconnectService.onSessionDead] and cleared after kill attempt.
  /// Killing via the NEW SSH connection (after re-auth) is far more reliable
  /// than _killServer()'s fire-and-forget approach during network failure.
  int? pendingKillPid;

  /// Fire-and-forget callback that kills the remote mosh-server process.
  /// Set by [ReconnectService] when a session dies so that if the tab is
  /// closed before reconnect completes the orphaned PID is still cleaned up.
  /// Cleared after [ReconnectService._reconnect] performs the reliable kill.
  Future<bool> Function()? pendingServerKill;

  /// Called by [SessionManager.closeTab] immediately when a tab is closed,
  /// before the kill attempt. Mosh tabs use this to mark pending_kill so the
  /// PID is tracked even when SSH is unavailable (startup cleanup picks it up).
  void Function()? onClosing;

  /// Called by [SessionManager.closeTab] after a successful remote cleanup.
  /// Mosh tabs use this to mark their mosh_processes row killed.
  void Function()? onClose;

  /// Last known working directory, parsed from OSC 7 sequences emitted by the
  /// remote shell (format: `\e]7;file://hostname/path\a`).
  /// null if the shell has not emitted OSC 7 yet (e.g. older bash without
  /// VTE integration), in which case callers should fall back to $HOME.
  String? cwd;

  /// Shell type detected heuristically from first typed character. null if undetected.
  String? shell;

  /// Heuristic foreground TUI signal from terminal output. Used for tmux
  /// transparent scrolling when tmux pane-state is not queried yet.
  bool remoteTuiHint = false;

  /// 前台程序是否接管了输入行的渲染 —— 给**命令补全**用。
  ///
  /// 与 [remoteTuiHint] 刻意分开：那个回答「滚轮该不该转 SGR 鼠标事件」，
  /// 只认 `?25l` / `?1049h`；这个还要认出在主 buffer 里全屏重绘的 TUI
  /// （Claude Code 不切 alt buffer、也不藏光标，两个信号一个都不发）。
  /// 判据与理由见 `foreground_input_owner.dart`。
  ///
  /// 读 xterm 的权威状态而不是自己跟踪字符串：`_trackRemoteTui` 那套会在
  /// ESC 序列跨 chunk 边界被切断时漏掉事件，而 TUI 往往只在启动时宣告一次。
  bool get foregroundOwnsInputLine => fg.foregroundOwnsInputLine(
        cursorVisible: terminal.cursorVisibleMode,
        altBuffer: terminal.isUsingAltBuffer,
        focusTracking: terminal.reportFocusMode,
        inTmux: inTmux,
      );

  /// Last command entered by the user (tracked by TerminalScreen via onUserInput).
  String? lastCommand;

  /// Per-tab AI engine, keyed by [server.id] so multiple tabs for the same
  /// server share the same conversation history.
  final AIEngine aiEngine;

  var _contextLines = <String>[];
  static const _maxContextLines = 200;

  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;

  /// [_stdoutSub] / [_stderrSub] 当前订阅的那个**输出源对象**（transport 或
  /// legacy shell）。用于让 [startStreaming] 对同一来源的重复调用变成 no-op。
  ///
  /// 为什么需要它：`AqtTransport.output` 是**单订阅** stream（刻意的，为了
  /// 缓冲 listen 之前就到达的 PtyOutput），而单订阅 stream 二次 `listen()`
  /// 会同步抛 `Bad state: Stream has already been listened to.` —— 即便第一个
  /// 订阅已经 cancel 过。抛出点在 [startStreaming] 里 `_stdoutSub?.cancel()`
  /// **之后**，于是 tab 会停在"旧订阅已取消、新订阅没装上"的状态：从此收不到
  /// 任何输出，`onDone` 也永远不来（重连链因此不会被唤醒），屏幕永久停住。
  /// 恢复内容改走 PTY 流之后（`eaf65d1`）这一条尤其致命：服务端只在 RESUME
  /// 那一刻发一次快照、永不重发，listener 没装上就是永久黑屏。
  Object? _streamingSource;

  /// [startStreaming] 装订阅失败的次数，以及最后一次的错误。
  ///
  /// 这不是"以防万一"的计数器：装不上订阅意味着这个 tab 彻底失聪，而失聪
  /// 在 UI 上与"服务端没输出"无法区分（`_buildTabBody` 对非首连 tab 一律渲染
  /// 终端，错误页根本不会显示）。留个可读的痕迹，下次真机复现时能一眼确认。
  int streamAttachFailures = 0;
  String? lastStreamAttachError;

  /// Cumulative bytes written to terminal since last transport connect.
  /// Used as last_out_off for QUIC RESUME so only NEW content is replayed.
  int renderedOutputBytes = 0;

  /// 服务端已收到的输入字节数（`Restored.server_in_seen_off`）。
  /// 重连后据此补发断线瞬间没送达的按键。
  ///
  /// 输出方向的 offset 全删了，这个留着 —— 它是**服务端的**状态，单一
  /// 来源、不会分裂世代，而且承担正确性：用户敲的键不能丢。
  int serverInSeenOff = 0;

  /// Wall-clock timestamp of the last `_swapTransport` call that performed
  /// ring replay (primary buffer path). `null` until the first swap.
  ///
  /// Watched by `TerminalScreen` to schedule a post-frame
  /// `scrollController.jumpTo(0)`.
  DateTime? lastTransportSwapAt;

  /// Hex dump of the first up-to-16 bytes of the most recent RESUME prelude
  /// received from the server. Captured incrementally by the QUIC listener
  /// after `_swapTransport` sets [preludeCaptureRemaining]. Empty until the
  /// first swap. Surface in the debug overlay to verify server-side G1
  /// (drop_leading_csi_tail) actually trimmed the CSI residue — if the head
  /// starts with `1b` (ESC), G1 worked; if it starts with `3b` / `31` /
  /// other CSI parameter bytes, residue is leaking through.
  String lastPreludeHexHead = '';
  int preludeCaptureRemaining = 0;

  /// Cumulative count of U+FFFD (UNICODE REPLACEMENT CHARACTER) glyphs
  /// observed in the decoded UTF-8 stream by `_flushOutput`. Each one is a
  /// byte the decoder couldn't map to a valid codepoint — typically a
  /// chunk-boundary truncation or corrupt byte from the wire. Rises
  /// monotonically; a sudden spike after a RESUME storm indicates type-3
  /// (UTF-8 boundary) or type-4 (CSI tail) leakage. Surface in the debug
  /// overlay for live diagnosis.
  int fffdRenderCount = 0;

  /// Per-category cumulative count of connect / RESUME failures. Mutated via
  /// [recordError]; reset only on tab disposal. Surfaced as `errCnt` row.
  final Map<ErrCategory, int> errorCounts = {
    for (final c in ErrCategory.values) c: 0,
  };

  void recordError(ErrCategory cat) {
    errorCounts[cat] = (errorCounts[cat] ?? 0) + 1;
  }

  // ringTailHash 已删除：它是 RESUME 帧里用来校验「客户端报的 offset 是否
  // 与服务端 ring 同步」的哈希。恢复不再携带任何位置信息，也就没有什么
  // 需要校验了。

  // ── 断连期间的按键缓冲（tab 级）─────────────────────────────────────
  // AqtTransport 自己也有一个缓冲，但只覆盖"transport 还在、只是连不通"的
  // 情况。走 SSH 回退链时 ReconnectService 会先把 tab.transport 置 null，
  // 之后 5-25 秒里 _writeToShell 找不到 transport、QUIC tab 的 shell 又是
  // null，用户敲的每个字符都被静默丢弃。这个缓冲补的就是那段空窗。
  static const int kMaxPendingInputBytes = 8192;

  /// 缓冲的按键超过这个年龄就丢弃。重连彻底失败、用户几分钟后才手动重连时，
  /// 把当时半截的命令（可能带回车）突然送出去是危险的意外行为。
  static const Duration kPendingInputMaxAge = Duration(seconds: 60);

  List<int>? _pendingInput;
  DateTime? _pendingInputAt;

  /// 无处可送的按键先存这里，等新 transport 装上时回灌。
  void bufferPendingInput(List<int> data) {
    if (data.isEmpty) return;
    final buf = _pendingInput ??= <int>[];
    if (buf.isEmpty) _pendingInputAt = DateTime.now();
    final remaining = kMaxPendingInputBytes - buf.length;
    if (remaining <= 0) return; // 到顶后静默丢弃溢出部分
    buf.addAll(data.length > remaining ? data.sublist(0, remaining) : data);
  }

  /// 取走缓冲。超龄的直接丢掉并返回 null。
  Uint8List? drainPendingInput() {
    final buf = _pendingInput;
    final at = _pendingInputAt;
    _pendingInput = null;
    _pendingInputAt = null;
    if (buf == null || buf.isEmpty) return null;
    if (at != null && DateTime.now().difference(at) > kPendingInputMaxAge) {
      return null;
    }
    return Uint8List.fromList(buf);
  }

  /// QUIC 自动 RESUME 在 alt buffer 模式下的 prelude 字节吞吃计数。
  /// 服务端不区分 alt/primary 都回放 256KB ring 历史；alt buffer 模式下
  /// 把这些历史字节写进 xterm 会画在 TUI 屏幕上、污染输入框（b3.jpg）。
  /// _swapTransport 检测到 alt buffer 时设此计数 = replay_bytes，listener
  /// 收到字节时前 N 字节不写 xterm，N 之后正常处理。serverRingOff 仍累加
  /// 保证下次 RESUME 的 lastOutOff 与服务端 tail 对得上。
  int preludeSwallowRemaining = 0;

  /// 已匹配到的 [kAltScreenEnter] 前缀长度，跨 chunk 保留。
  ///
  /// `\x1b[?1049h` 有 8 个字节，QUIC 分片完全可能把它劈成两半（例如 chunk
  /// 尾部是 `\x1b[?10`、下一个 chunk 开头是 `49h`）。只在单个 chunk 内找标记
  /// 会漏掉这种情况，而漏掉的后果正是这次要修的 bug —— 恢复负载被继续吞掉。
  int preludeAltEnterMatched = 0;

  /// 服务端恢复负载的边界标记：`ESC [ ? 1 0 4 9 h`（进 alt 屏）。
  ///
  /// `alt_eviction.rs::assemble_cold_resume_prelude_alt` 组装的 prelude 形如
  ///   pre_alt 历史 + eviction log + **?1049h** + 2J + H + SGR + 完整快照 + CAN
  /// 标记之前是"写进 TUI 会污染画面"的历史，之后是自包含、可直接写 xterm 的
  /// 恢复负载。以它为界正好把两段分开。
  ///
  /// 服务端曾经在 `strip_mode_changes` 里把 ring 历史中原有的 `?1049h/l` 全部
  /// 剥掉，所以流里出现这个序列只可能是服务端重新注入的那一个。
  ///
  /// ⚠ 那个函数已经不存在了（连同它作用的字节流 ring 一起删除）：现在历史是
  /// 从 vt100 的 cell 网格渲染出来的，只可能含 SGR 与列移动，模式序列在结构上
  /// 进不来 —— 剥离这件事没有了对象。这里连同下面的吞吃逻辑一起是**死代码**：
  /// 全仓库没有任何生产调用点会把 `preludeSwallowRemaining` 设成非零，见
  /// `test/ssh/cold_start_prelude_render_test.dart` 里的核实记录。留着未清理。
  static const List<int> kAltScreenEnter = [
    0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68, // ESC [ ? 1 0 4 9 h
  ];

  /// alt 屏下吞吃 prelude，**直到遇见 [kAltScreenEnter] 为止**。
  ///
  /// 修复的问题：客户端 93413cf (2026-05-28) 写这段吞吃时，服务端冷 RESUME
  /// 回放的是裸 ring 字节，在 alt 屏下写进 xterm 会污染 TUI，全吞掉再等
  /// SIGWINCH 自重绘是合理的。四天后服务端 f5ef7bd (2026-06-01) 改成组装
  /// 自包含的恢复负载，而吞吃逻辑没跟着改 —— 于是服务端专门为 alt 场景造的
  /// 完整快照，被客户端在同样的 alt 场景下整段丢掉，屏幕恢复不出来；且被吞
  /// 的字节仍计入 serverRingOff，服务端不会重发，只能手动刷新。
  ///
  /// 找到标记后连标记本身一起放行：xterm 需要它来进 alt 屏，紧随其后的 `2J`
  /// 会把屏幕清干净，快照再画上去。
  ///
  /// 没有标记的负载（`alt_eviction` 被关掉、或热 RESUME 发的裸 delta）行为
  /// 与修复前完全一致 —— 吞满预算为止。退化是安全的。
  ///
  /// 返回 `kept`（要写进 xterm 的字节）、剩余吞吃预算、以及跨 chunk 的匹配
  /// 进度。纯函数，不读写任何实例状态，便于直接测。
  @visibleForTesting
  static ({List<int> kept, int swallowRemaining, int altEnterMatched})
      swallowUntilAltEnter(
    List<int> bytes,
    int swallowRemaining,
    int altEnterMatched,
  ) {
    var i = 0;
    var matched = altEnterMatched;
    var remaining = swallowRemaining;
    while (i < bytes.length && remaining > 0) {
      final b = bytes[i];
      i++;
      remaining--;
      if (b == kAltScreenEnter[matched]) {
        matched++;
        if (matched == kAltScreenEnter.length) {
          // 标记补齐。它的前缀可能是在上一个 chunk 里被吞掉的，所以这里
          // 用常量重新拼出完整标记，而不是从 bytes 里回切 —— 回切在跨
          // chunk 的情况下会越界到本 chunk 开头之前。
          return (
            kept: [...kAltScreenEnter, ...bytes.sublist(i)],
            swallowRemaining: 0,
            altEnterMatched: 0,
          );
        }
      } else {
        // 失配即重置；但当前字节自身可能就是新一轮的 ESC 起点
        // （如 `\x1b\x1b[?1049h`），漏掉就会错过紧随其后的真标记。
        matched = (b == kAltScreenEnter[0]) ? 1 : 0;
      }
    }
    if (remaining > 0) {
      // 整个 chunk 都在预算内被吞掉，匹配进度留给下一个 chunk。
      return (
        kept: const <int>[],
        swallowRemaining: remaining,
        altEnterMatched: matched,
      );
    }
    // 预算用尽仍未见标记 —— 走原来的行为：对齐 UTF-8 边界后放行剩余字节。
    return (
      kept: bytes.sublist(alignToUtf8CharStart(bytes, i)),
      swallowRemaining: 0,
      altEnterMatched: 0,
    );
  }

  /// Bytes of the post-RESUME prelude still expected before the
  /// stream switches from "replay history" to "live output". Set to
  /// `lastResumeReplayBytes` (incl. trailing CAN) on every RESUME; the
  /// QUIC listener decrements per chunk and, when it hits zero,
  /// stamps `transport.recordReplayComplete()` for the `res` diagnostic
  /// row. Independent of [preludeSwallowRemaining] (which exists for
  /// alt-buffer suppression only).
  ///
  /// **HELLO 必须清零，不只是 RESUME 要赋值。** 这个 `SessionTab` 跨重连
  /// 复用——如果某次 RESUME 在快照放完前又断线，残值会留在这个字段上；
  /// 下一次装配如果是 HELLO（全新会话，没有快照），残值会去吃新会话开头
  /// 的字节，归零时给一个根本不存在快照的会话伪造出 `replayCompleteAt`。
  /// 唯一的装配点 `ReconnectService._installAqtTransport` 用
  /// `next.wasResumed ? next.lastResumeScreenBytes : 0` 的无条件赋值保证
  /// 这一点；新增装配路径时必须保持同样的「HELLO 也要显式赋 0」写法。
  int preludeReplayRemaining = 0;

  /// 快照**渲染完成**时的回调。参数是这一刻的墙钟毫秒。
  ///
  /// 与 [preludeReplayRemaining] 归零（快照字节全部**收到**）是两件事：
  /// 输出走 `_pendingOutput` 的 vsync 批处理，`terminal.write()` 返回时
  /// 像素还没上屏。用户「看见」的时刻要等下一帧，所以这个回调在
  /// `addPostFrameCallback` 里触发。
  ///
  /// 由 `ReconnectService` 装上，用于闭合恢复样本的 ⑤ 段。
  ///
  /// **至多触发一次：快照末字节落地那一刻就地捕获走，不等 `_flushOutput`
  /// 甚至 postFrame 跑完。** 调用方会把一个 span 对象闭包进来，重复触发
  /// 就是重复闭合同一个 span（双重计数 + 用错误的时刻归因）。
  ///
  /// 捕获点在 stdout 监听器里、`preludeReplayRemaining` 归零的那个同步块
  /// （见 [_capturedRenderCompleteCb]），不是这里——本字段只是"当前武装的
  /// 回调"，会在下一次恢复到来时被 `ReconnectService` 覆盖；真正保证"至多
  /// 一次"的是它在被覆盖之前已经被搬到 `_capturedRenderCompleteCb` 里。
  ///
  /// 已知局限：`ReconnectService` 重新赋值本字段无法撤销**已经被捕获走**
  /// 的那次调用 —— 语义是「至多调度一次」，不是「可随时取消」。
  void Function(int nowMs)? onResumeRenderComplete;

  /// 快照末字节落地那一刻**就地捕获**的渲染完成回调。
  ///
  /// 为什么不是一个 bool 标志 + 事后回读 [onResumeRenderComplete]：
  /// 置位发生在 stdout 监听器里（同步），但 `_flushOutput` 不一定同步跑
  /// —— 小于 32KB 的批次会推迟到下一 vsync 帧。回读发生在 `_flushOutput`
  /// 执行的那一刻，中间隔着的这段窗口里，`ReconnectService` 完全可能为
  /// **下一次**恢复重新赋值回调。那样一来：上一次恢复的完成时刻会被拿去
  /// 闭合下一次恢复的 span（错误甚至负数归因），上一次的样本永久丢失，
  /// 而下一次真正完成时字段已被提前消费成 null，事件被静默丢弃。
  ///
  /// 就地捕获把消费点钉在链路最早的同步点上，两段窗口一起消失。
  void Function(int nowMs)? _capturedRenderCompleteCb;

  // _updateRingHash 已删除：它维护的 ringTailHash 是 RESUME 帧里用来校验
  // 「客户端报的 offset 与服务端 ring 是否同步」的滚动哈希。恢复不再携带
  // 位置信息，没有什么需要校验了。

  // Output batching: accumulate SSH chunks within a vsync window before
  // calling terminal.write(). Claude CLI streaming can deliver dozens of
  // small chunks per second; without batching each one triggers a full
  // Flutter repaint, saturating the UI thread.
  final _pendingOutput = StringBuffer();
  // For QUIC/transport path: accumulate raw bytes and decode as a batch in
  // _flushOutput. utf8.decoder transform creates async events that schedule
  // multiple vsync flushes → "line by line" scan artifact.
  final _pendingRawBytes = <List<int>>[];
  bool _hasPendingRaw = false;
  // UTF-8 跨 vsync 残留：上次 flush 时末尾不完整的多字节字节序列。
  // 下次 flush 时 prepend 到 allBytes，防止 emoji/CJK 被 vsync 边界
  // 截断后被 allowMalformed:true 替换为 U+FFFD（菱形问号）。
  List<int>? _utf8Residue;
  // Strips tmux DCS passthrough (ESC P tmux; ... ESC \) from incoming text
  // before it reaches xterm. Required when running Claude Code (or any
  // tmux-aware CLI) inside tmux on the server — they emit colors and
  // hyperlinks wrapped in passthrough. Without unwrap, xterm's DCS parser
  // discards them and styling is lost / garbled.
  final _tmuxUnwrapper = TmuxPassthroughUnwrapper();

  /// Sample of the most-recent escape sequences seen (for the debug overlay).
  /// Increased to 50 to fit a fuller window of SGR history.
  final List<String> _recentEscapes = <String>[];
  List<String> get recentEscapes => List.unmodifiable(_recentEscapes);

  /// FNV-1a hash of all bytes that ever reached terminal.write(), and the
  /// byte count. Diagnostic for comparing compressed vs uncompressed runs:
  /// if the hash diverges for the same upstream input, decompression is
  /// re-chunking or corrupting bytes downstream. If hashes match but the
  /// rendering looks different, the issue is in xterm.dart or timing.
  int xtermByteHash = 0xcbf29ce484222325; // FNV-1a 64-bit seed
  int xtermByteCount = 0;
  void _updateXtermHash(String text) {
    // Hash on the UTF-8 byte form so behavior matches what xterm.dart's
    // parser actually sees (it operates on code units, all sub-128 for ASCII).
    final units = text.codeUnits;
    var h = xtermByteHash;
    for (final c in units) {
      h ^= c & 0xff;
      h = (h * 0x100000001b3) & 0xffffffffffffffff;
    }
    xtermByteHash = h;
    xtermByteCount += units.length;
  }

  /// Running tallies of SGR events affecting cursor.attrs UNDERLINE bit.
  /// If `setU > unsetU + reset0`, an underline emit went un-cleared and
  /// xterm's cursor state is stuck with UNDER active — every subsequent
  /// glyph inherits the attribute even though no sequence is "to blame".
  int sgrSetU = 0;     // \x1b[4m, \x1b[4;…m, …
  int sgrUnsetU = 0;   // \x1b[24m, \x1b[…24m
  int sgrReset0 = 0;   // \x1b[0m, \x1b[m
  int sgrSetUnderlineColor = 0; // \x1b[58:…m / 58;… (some terms enable U)

  /// "Caught in the act" log: every time terminal.write transitions the
  /// cursor's UNDER bit 0→1, capture the input text (escaped). Reveals
  /// what byte sequence caused the bit to flip when no \x1b[4m was seen.
  final List<String> _underlineSetCapture = <String>[];
  List<String> get underlineSetCapture =>
      List.unmodifiable(_underlineSetCapture);

  void _captureEscapes(String text) {
    // Extract CSI / OSC / DCS sequences for the overlay log.
    final pattern = RegExp(r'\x1b\[[0-9;:?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1bP[^\x1b]*(\x1b\x1b)*\x1b\\');
    for (final m in pattern.allMatches(text)) {
      final raw = m.group(0)!;
      final readable = raw
          .replaceAll('\x1b', r'^[')
          .replaceAll('\x07', r'^G');
      _recentEscapes.add(readable);
      while (_recentEscapes.length > 50) {
        _recentEscapes.removeAt(0);
      }
    }
    // Separately tally SGR events that affect underline state.
    // Only sequences ending in `m` are SGR.
    final sgrRe = RegExp(r'\x1b\[([0-9;:]*)m');
    for (final m in sgrRe.allMatches(text)) {
      final params = m.group(1) ?? '';
      final list = params.isEmpty ? <String>[''] : params.split(';');
      for (final p in list) {
        final n = int.tryParse(p);
        if (n == 0 || (n == null && p.isEmpty)) {
          sgrReset0++;
        } else if (n == 4) {
          sgrSetU++;
        } else if (n == 24) {
          sgrUnsetU++;
        } else if (n == 58) {
          sgrSetUnderlineColor++;
        }
      }
    }
  }
  bool _outputFlushPending = false;
  bool _microtaskPending = false;
  bool _framePending = false;
  int _pendingOutputBytes = 0;

  /// Wall-clock ms of the last transport resize. Used by [_scheduleOutputFlush]
  /// to suppress the 32 KB synchronous flush during a 300 ms "resize recovery"
  /// window so the SIGWINCH-triggered full-screen redraw lands atomically in
  /// one vsync frame instead of revealing top-to-bottom as chunks arrive.
  int _lastTransportResizeAt = 0;

  /// Called by TerminalWidget._shellResize after sending SIGWINCH to remote.
  /// Starts a 300 ms window during which any large QUIC output bursts (the
  /// likely server redraw response) are vsync-batched rather than fast-pathed.
  void onTransportResized() {
    _lastTransportResizeAt = DateTime.now().millisecondsSinceEpoch;
    resizeBurstFrames = 0;
    resizeBurstBytes = 0;
    resizeBurstFastPaths = 0;
    resizeBurstFirstMs = -1;
    resizeBurstLastMs = -1;
  }

  /// SIGWINCH 之后要观察多久的重绘。1500 ms 是被下游时序逼出来的下界：
  /// 应用自己的 SIGWINCH 重绘约 200–320 ms 落地（RTT 80–120 + 重绘
  /// 100–200），而 `_scheduleKeyboardCtrlEndAfterResize` 还会在 600 ms 时
  /// 补一个 Ctrl+End，它引发的**第二波**重绘要到 700–900 ms 才到。窗口短于
  /// 这个跨度就会把两波看成一波，恰好丢掉「到底重绘了几次」这个判据。
  static const int _resizeBurstWindowMs = 1500;

  /// 一次 resize 之后的重绘 burst 长什么形状 —— 分辨「闪一下」的两类根因，
  /// 这两类的修法相反，光看现象分不出来：
  ///
  ///   frames == 1                 重绘一帧原子落地。闪不是渲染分帧造成的，
  ///                               要往远端重绘次数 / xterm reflow 方向查。
  ///   frames > 1 且 last-first 大  逐帧显现（自上而下刷一遍）。是客户端
  ///                               批渲染没兜住，改 flush 调度。
  ///   frames 很多且 fastPaths > 0  32 KB 同步 fast-path 插了队，把一次重绘
  ///                               劈成「同步半屏 + 后续帧补完」。
  ///
  /// 每次 [onTransportResized] 归零，所以读到的永远是**最近一次** resize 的
  /// 形状，而不是累计值 —— 累计值在这个问题上没有意义，键盘反复弹收会把它
  /// 抹平成平均数。
  int resizeBurstFrames = 0;
  int resizeBurstBytes = 0;
  int resizeBurstFastPaths = 0;

  /// resize 到**首/末**次落屏的间隔（ms）。-1 = 窗口内一次都没落屏。
  /// first 反映 SIGWINCH 往返 + 应用重绘的真实耗时；last-first 就是用户
  /// 眼里「刷」这个动作持续了多久。
  int resizeBurstFirstMs = -1;
  int resizeBurstLastMs = -1;

  // Post-output refresh: fire tmux refresh-client 800 ms after the LAST output
  // chunk, so the refresh never races with active streaming.  Debounce by
  // cancelling + restarting on every flush.  SSH+tmux only — mosh self-corrects.
  Timer? _quietRefreshTimer;

  SessionTab({
    String? id,
    required this.server,
    required this.connection,
    required this.terminal,
    required this.sessionKey,
    required this.aiEngine,
  }) : id = id ?? const Uuid().v4();

  /// User-defined display name; null falls back to server.name.
  String? customName;

  String get title {
    final n = customName?.trim();
    return (n != null && n.isNotEmpty) ? n : server.name;
  }

  /// C4 诊断埋点（不是修复）：由 ReconnectService.start() 接线到它已有的
  /// _logResume（进 debug overlay 的 verbose 日志）。只在 AQT tab 触发，用于
  /// 验证"冷 RESUME 装好、prelude 还没 flush 完时，同一个 tab 被二次调用
  /// startStreaming() 导致静默丢字节"这个假设——是否真的发生了二次装配、
  /// 两次调用间隔多久、第二次的调用方是谁。见任务 #53 / #55。
  ///
  /// 不改变任何行为：只读取现有字段并转发给 hook，不做任何判断/拦截。
  static void Function(
    String tabId,
    String source,
    int? sentLastOutOff,
    int lastResumeReplayBytes,
  )? debugAqtStartStreamingHook;

  /// Start forwarding shell stdout/stderr into the terminal buffer.
  /// Safe to call again after reconnect — cancels any prior subscriptions.
  ///
  /// **对同一个输出源重复调用是 no-op**（见 [_streamingSource]）：换流时才
  /// 需要重订阅，而"同一条流再订一次"在单订阅 stream 上是致命的，且无论
  /// 如何都会连带丢掉在途字节。调用方因此不必再自己去判断"这个 tab 是不是
  /// 已经在流了" —— 六个装配点里没有一个有能力可靠地回答那个问题。
  ///
  /// [source] and [sentLastOutOff] are diagnostic-only (see
  /// [debugAqtStartStreamingHook] above) — they do not affect behavior.
  void startStreaming({String source = 'unspecified', int? sentLastOutOff}) {
    final diagTransport = transport;
    if (diagTransport is AqtTransport) {
      SessionTab.debugAqtStartStreamingHook?.call(
        id,
        source,
        0,
        diagTransport.lastResumeScreenBytes,
      );
    }
    // 幂等闸门。放在 hook 之后：hook 是"谁调了我"的诊断记录，抑制掉的那次
    // 调用同样要留痕，否则真机上二次装配的时序就再也看不见了。
    final newSource = transport ?? moshShell ?? connection.shell;
    if (_stdoutSub != null &&
        newSource != null &&
        identical(newSource, _streamingSource)) {
      return;
    }
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    const decoder = Utf8Decoder(allowMalformed: true);

    final t = transport;
    if (t != null) {
      // QUIC/transport path: buffer raw bytes to avoid utf8.decoder async split.
      // utf8.decoder.transform() turns one synchronous poll burst (N chunks) into
      // N async string events → N separate _scheduleOutputFlush() calls → multiple
      // vsync frames each rendering a partial screen ("line-by-line scan" artifact).
      // Instead: buffer raw bytes synchronously, decode all-at-once in _flushOutput.
      //
      // 已经进了 _pendingRawBytes 但还没 flush 的字节先冲出去，不要直接丢。
      //
      // ⚠ 这**不足以**修掉"二次 startStreaming 丢字节"那个 bug。真正更主要的
      // 丢失点是本函数第一行的 `_stdoutSub?.cancel()` —— StreamController 投递
      // 给监听器是异步的，取消订阅会丢弃流里还没投递的事件，那些字节压根没机会
      // 进到 _pendingRawBytes 来被这里救。见
      // test/ssh/cold_start_prelude_render_test.dart 场景 5b（仍然是失败态，
      // 如实记录现状）。
      //
      // 这一段只覆盖较窄的那个窗口：字节已经投递到监听器、进了缓冲、
      // _scheduleOutputFlush 排的帧回调还没落地（前台约 16 ms，冷启动首帧未画出
      // 时更长），此时被再调一次 startStreaming。
      //
      // 保留它的理由：这个窗口是真实存在的，丢的是服务端已 ack、不会重发的字节，
      // 而且没有任何一层能发现（watchdog 查的是 QUIC 连接存活，不是"屏幕上该有
      // 内容"）。修掉一半比不修好；剩下的一半需要重新设计"换流时如何不丢在途
      // 事件"，那是更大的改动，见任务 #53。
      if (_hasPendingRaw && _pendingRawBytes.isNotEmpty) {
        _flushOutput();
      }
      _pendingRawBytes.clear();
      _hasPendingRaw = false;
      // NOTE: _utf8Residue NOT cleared here (改动 A, 2026-05-29).
      // Residue may hold the leading byte of a CJK / emoji char that was
      // split across a chunk boundary by the previous transport. RESUME
      // continues the remote PTY stream byte-for-byte, so the next chunk's
      // continuation bytes need to splice onto that leading byte. Clearing
      // it here causes 4-byte tofu (□) after every reconnect (d5.jpg).
      // NOTE: serverRingOff and ringTailHash are NOT reset here so that proactive
      // RESUME on network switch uses the accumulated position from the previous
      // transport. They are only reset when a completely new session is created
      // (HELLO, not RESUME) — which happens in connect() success path.
      // alt buffer 下吞吃 prelude 历史字节，避免污染 TUI（b3.jpg）——但**一旦
      // 遇到 kAltScreenEnter 就停止吞吃**，因为标记之后是服务端组装的自包含
      // 恢复负载，正是用来把屏幕画回来的。详见 swallowUntilAltEnter 的文档。
      //
      // serverRingOff / ringTailHash 仍累加，保证下次 RESUME offset 一致。
      //
      // 预算用尽仍未见标记时退回原行为，其中包含改动 B (2026-05-29) 的 UTF-8
      // 边界对齐：swallow 的字节数不保证落在 char 边界，切到 CJK / emoji 中间
      // 会让剩余流以 continuation byte (0x80-0xBF) 开头，
      // Utf8Decoder(allowMalformed:true) 会替换为 U+FFFD → tofu 方块。
      List<int> swallowAndStrip(List<int> bytes) {
        if (preludeSwallowRemaining <= 0) return bytes;
        final r = SessionTab.swallowUntilAltEnter(
          bytes,
          preludeSwallowRemaining,
          preludeAltEnterMatched,
        );
        preludeSwallowRemaining = r.swallowRemaining;
        preludeAltEnterMatched = r.altEnterMatched;
        return r.kept;
      }

      // 兜底：装订阅这件事本身失败，就意味着这个 tab 从此收不到任何输出，
      // 而 `onDone` 也永远不会来 —— 重连链、watchdog、UI 全都不会察觉（前者
      // 只看 QUIC 连接存活，后者只看 tab.transport 非空）。上面的幂等闸门已经
      // 挡掉了已知的那条触发路径（同源二次调用），这里挡的是"还没想到的那条"：
      // 与其静默黑屏，不如当作会话已死上报，让重连链换一条新 transport ——
      // 新 transport 自带新的 controller，重新订阅一定能成功。
      try {
        _stdoutSub = t.output.listen(
          (bytes) {
            // 这里曾经 `serverRingOff += bytes.length` 并滚动更新 ringTailHash，
            // 为的是下次 RESUME 能报出「我读到哪了」。恢复不再携带位置信息，
            // 客户端也就不必跟踪它 —— 少一个每字节都要维护、且在六个发起点之间
            // 无法保持一致的状态。
            // Capture first N bytes of the post-swap stream as the prelude
            // head hex dump (diag overlay). preludeCaptureRemaining is set
            // to 16 by _swapTransport after the primary-buffer clear; here
            // we append the leading bytes of whatever chunks come next until
            // the budget is exhausted. See lastPreludeHexHead docstring.
            if (preludeCaptureRemaining > 0) {
              final take = preludeCaptureRemaining > bytes.length
                  ? bytes.length
                  : preludeCaptureRemaining;
              final buf = StringBuffer(lastPreludeHexHead);
              for (var i = 0; i < take; i++) {
                if (buf.isNotEmpty) buf.write(' ');
                buf.write((bytes[i] & 0xff).toRadixString(16).padLeft(2, '0'));
              }
              lastPreludeHexHead = buf.toString();
              preludeCaptureRemaining -= take;
            }
            // P2: decrement RESUME replay byte budget; stamp replayComplete
            // on the transport once the full prelude (incl. trailing CAN)
            // has streamed in. transport may be SSH/Mosh too, so guard
            // with isAqtTransport before calling AqtTransport-only mutator.
            if (preludeReplayRemaining > 0) {
              preludeReplayRemaining -= bytes.length;
              if (preludeReplayRemaining <= 0) {
                preludeReplayRemaining = 0;
                final tr = transport;
                if (tr is AqtTransport) {
                  tr.recordReplayComplete();
                }
                // 就地捕获并消费：必须与「快照末字节落地」同一个同步块。
                // 推迟到 _flushOutput 里回读字段，就会撞上那段调度窗口
                // （见 _capturedRenderCompleteCb 的文档）。
                _capturedRenderCompleteCb = onResumeRenderComplete;
                onResumeRenderComplete = null;
              }
            }
            final kept = swallowAndStrip(bytes);
            if (kept.isEmpty) return;
            _pendingRawBytes.add(kept);
            _hasPendingRaw = true;
            _pendingOutputBytes += kept.length;
            _scheduleOutputFlush();
          },
          onDone: () {
            _flushOutput();
            onSessionDead?.call();
          },
          cancelOnError: false,
        );
        _stderrSub = t.stderr.listen(
          (bytes) {
            // 同上：不再跟踪 ring 位置。
            final kept = swallowAndStrip(bytes);
            if (kept.isEmpty) return;
            _pendingRawBytes.add(kept);
            _hasPendingRaw = true;
            _pendingOutputBytes += kept.length;
            _scheduleOutputFlush();
          },
          cancelOnError: false,
        );
        _streamingSource = t;
      } catch (e) {
        _stdoutSub?.cancel();
        _stderrSub?.cancel();
        _stdoutSub = null;
        _stderrSub = null;
        _streamingSource = null;
        streamAttachFailures++;
        lastStreamAttachError = '$source: $e';
        dlog('SessionTab', 'output listen failed ($source): $e');
        // 异步上报：调用方（_installAqtTransport）在本方法返回后还要跑
        // registerAqtTab —— 那正是 onSessionDead 的接线点。同步 call 会打在
        // 还没接线的 null 上，白丢一次自愈机会。
        scheduleMicrotask(() => onSessionDead?.call());
      }
      return;
    }

    // Legacy path — kept for existing SSH/Mosh connections not using TransportFactory.
    //
    // Strict guard for QUIC tabs: 如果用户配置的是 QUIC，但 tab.transport 因任何
    // 原因变成 null（首次连接 QUIC 失败 / reconnect 中 transport 被清空且
    // FULLRECONN 还没完成），绝不能 fallback 订阅 connection.shell —— 那会让
    // 用户输入/输出真的走 SSH PTY，构成"真实降级"。让 startStreaming 安静返回，
    // 等待 ReconnectService 装上新 transport 后再次显式调用本方法。
    if (server.transport == Transport.quic) return;
    final shell = (moshShell ?? connection.shell) as dynamic;
    if (shell == null) return;
    // cancelOnError:false prevents the subscription from being permanently
    // cancelled on any exception in the callback chain (e.g. a transient
    // terminal.write error or a ValueNotifier listener throwing).  Without
    // this the terminal silently stops updating and the user perceives it as
    // "input has stopped working" because nothing they type appears on screen.
    _stdoutSub = shell.stdout
        .cast<List<int>>()
        .transform(decoder)
        .listen(
          (text) {
            // OSC-7 跟踪移到 _flushOutput 里统一处理（覆盖 QUIC + SSH/Mosh）
            _pendingOutput.write(text);
            _pendingOutputBytes += (text as String).length;
            _scheduleOutputFlush();
          },
          onDone: () {
            _flushOutput(); // drain buffer before signalling session end
            onSessionDead?.call();
          },
          cancelOnError: false,
        );
    _stderrSub = shell.stderr.cast<List<int>>().transform(decoder).listen((
      text,
    ) {
      _pendingOutput.write(text);
      _pendingOutputBytes += (text as String).length;
      _scheduleOutputFlush();
    }, cancelOnError: false);
    // legacy 路径订阅的是 shell 对象的流。记下来源同样有意义：mosh 软重连
    // 的 probe / phase2 两段会对**同一个** moshShell 各调一次本方法，之前那
    // 次重订阅会连带清掉 _pendingRawBytes（丢在途字节）。MoshShellV2 的
    // stdout 是 broadcast，重订阅不会抛，所以这条一直是"只丢字节、不报错"。
    _streamingSource = shell as Object;
  }

  // OSC 7 format: \e]7;file://hostname/path\a  or  \e]7;file://hostname/path\e\\
  // The hostname part may be empty (file:///path) or present (file://host/path).
  // Group 1 captures everything after the first slash (URI-encoded path sans leading /).
  static final _osc7Re = RegExp(
    r'\x1b\]7;file://[^/\x07\x1b]*/([^\x07\x1b]*)(?:\x07|\x1b\\)',
  );

  void _trackOsc7(String text) {
    // 用 allMatches 取最后一个 OSC-7：一个 flush batch 里可能有多个 OSC-7
    // （服务端 CWD-poll 推 + shell vte 集成 + 用户 cd 多次），firstMatch 会
    // 卡在最早的 CWD，cwd 就过期了。最后一个才是最新的实际目录。
    Match? last;
    for (final m in _osc7Re.allMatches(text)) {
      last = m;
    }
    if (last == null) return;
    try {
      final decoded = Uri.decodeFull('/${last.group(1)!}');
      if (decoded.startsWith('/')) cwd = decoded;
    } catch (_) {}
  }

  void _scheduleOutputFlush() {
    // Always flush on vsync (≤16 ms / 60 fps).
    //
    // Previously a microtask path caused the first 1-2 chunks to flush
    // immediately, before vsync could accumulate the rest of a TUI screen
    // refresh (opencode/Claude sends ~5-10 × 4 KB chunks per redraw).
    // This produced "water ripple" or "block rendering" artifacts.
    //
    // Vsync-only ensures ALL chunks that arrive within one 16 ms frame are
    // batched into a single terminal.write() → smooth, atomic screen update.
    // Max typing-echo latency: 16 ms — imperceptible on mobile.
    //
    // Very large bursts (>32 KB already accumulated and frame not pending yet)
    // flush immediately to avoid lag when scrolling through huge outputs.
    //
    // EXCEPTION — resize-recovery window: within 300 ms of a SIGWINCH the
    // first chunks of the server's full-screen redraw response often cross
    // 32 KB on big screens. Fast-pathing then renders the top portion
    // synchronously while later chunks arrive over subsequent vsync frames,
    // producing the "top-to-bottom block reveal" artifact. Force vsync
    // batching during this window so the redraw lands atomically.
    final inResizeRecovery =
        DateTime.now().millisecondsSinceEpoch - _lastTransportResizeAt < 300;
    if (_pendingOutputBytes > 32768 && !_framePending && !inResizeRecovery) {
      // 诊断（只计数，不改条件）：窗口内走到这里就是一次插队的同步落屏。
      // inResizeRecovery 只护住 300 ms，而重绘往返 + Ctrl+End 二次重绘要到
      // 900 ms —— 300 ms 之后的那几波是否走了 fast-path，正是要量的东西。
      if (DateTime.now().millisecondsSinceEpoch - _lastTransportResizeAt <
          _resizeBurstWindowMs) {
        resizeBurstFastPaths++;
      }
      _microtaskPending = false;
      _outputFlushPending = false;
      _flushOutput();
      return;
    }
    if (_framePending) return;
    _framePending = true;
    _microtaskPending = false;
    _outputFlushPending = false;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _framePending = false;
      _flushOutput();
    });
  }

  void _flushOutput() {
    _outputFlushPending = false;
    _framePending = false;
    // Decode raw bytes (QUIC path) and string buffer (SSH/Mosh path) together.
    String text;
    if (_hasPendingRaw && _pendingRawBytes.isNotEmpty) {
      // prepend 上次 flush 剩余的 incomplete UTF-8 bytes（跨 vsync 续接）
      final allBytes = _pendingRawBytes.fold<List<int>>(
        _utf8Residue != null ? List<int>.from(_utf8Residue!) : <int>[],
        (acc, b) => acc..addAll(b),
      );
      _pendingRawBytes.clear();
      _hasPendingRaw = false;
      _utf8Residue = null;
      // 检查末尾是否有不完整的 UTF-8 序列（emoji/CJK 被 QUIC chunk 截断）。
      // 若有，保存到 _utf8Residue 等下次 flush 续接，不送进 decoder。
      // 否则 Utf8Decoder(allowMalformed:true) 会直接把残缺字节替换为 U+FFFD。
      final tail = trailingIncompleteUtf8Bytes(allBytes);
      final decodeBytes = tail > 0 ? allBytes.sublist(0, allBytes.length - tail) : allBytes;
      if (tail > 0) _utf8Residue = allBytes.sublist(allBytes.length - tail);
      const decoder = Utf8Decoder(allowMalformed: true);
      text = _tmuxUnwrapper.process(decoder.convert(decodeBytes));
      _captureEscapes(text);
      if (_pendingOutput.isNotEmpty) {
        text = _pendingOutput.toString() + text;
        _pendingOutput.clear();
      }
    } else {
      if (_pendingOutput.isEmpty) return;
      // SSH/Mosh path: run the same sanitizer as QUIC so xterm.dart bugs
      // (private CSI \x1b[>4;2m → mis-parsed as SGR 4+2; SGR 22 only
      // clearing FAINT; colon sub-params, etc.) don't manifest differently
      // depending on the transport. With this, SSH and QUIC render
      // visually identical output for the same upstream byte stream.
      text = _tmuxUnwrapper.process(_pendingOutput.toString());
      _captureEscapes(text);
      _pendingOutput.clear();
    }
    _pendingOutputBytes = 0;
    // Strip CAN (0x18, U+0018). The AQT server appends a CAN byte at the
    // end of the RESUME prelude (connection.rs:174) so xterm aborts any
    // in-progress escape sequence. ECMA-48 says CAN should cancel the
    // current escape and produce no visible glyph, but xterm.dart 4.0.0
    // has no special case and routes CAN through the printable path —
    // it lands in a cell as codepoint U+0018, which no font has a glyph
    // for, rendering as a tofu box (k8.jpg: curCell:U0018 [00] …). CAN
    // through the PTY is almost never an intentional "display me" byte,
    // so dropping it is safe and matches xterm behaviour.
    text = text.replaceAll('\x18', '');
    // OSC-7 CWD 跟踪：必须统一在解码后做，否则 QUIC 路径漏跟踪 ——
    // QUIC listener (line 413+) 直接缓存原始字节、return，从不解码字符串，
    // 导致 tab.cwd 永远为 null，SFTP 无法进入当前目录。
    _trackOsc7(text);
    _trackRemoteTui(text);
    _updateXtermHash(text);
    // Count U+FFFD (UNICODE REPLACEMENT CHARACTER) glyphs produced by the
    // utf8 decoder. Each one is a wire byte that couldn't be decoded; high
    // count = byte-stream truncation / corruption escaping our protections.
    // See fffdRenderCount docstring.
    for (final cp in text.runes) {
      if (cp == 0xFFFD) fffdRenderCount++;
    }
    final attrsBefore = terminal.cursor.attrs;
    terminal.write(text);
    final attrsAfter = terminal.cursor.attrs;
    // Catch-in-the-act: which byte sequence flipped UNDER 0→1?
    if ((attrsBefore & 0x08) == 0 && (attrsAfter & 0x08) != 0) {
      // Render escaped ASCII; truncate to 120 chars for the overlay.
      final escaped = text
          .replaceAll('\x1b', r'^[')
          .replaceAll('\x07', r'^G');
      _underlineSetCapture.add(
        escaped.length > 120 ? '${escaped.substring(0, 120)}…' : escaped,
      );
      while (_underlineSetCapture.length > 5) {
        _underlineSetCapture.removeAt(0);
      }
    }
    renderedOutputBytes += text.length;
    // resize 之后这一波重绘的形状（见 [resizeBurstFrames]）。放在 write 之后
    // 而不是 _scheduleOutputFlush 里：要量的是**落屏**次数，排了帧却被后续
    // 调用合并掉的那些不算一次视觉刷新。
    final sinceResize =
        DateTime.now().millisecondsSinceEpoch - _lastTransportResizeAt;
    if (sinceResize < _resizeBurstWindowMs) {
      resizeBurstFrames++;
      resizeBurstBytes += text.length;
      if (resizeBurstFirstMs < 0) resizeBurstFirstMs = sinceResize;
      resizeBurstLastMs = sinceResize;
    }
    // ⑤ 段终点：快照写进终端之后的**首帧**。
    //
    // 取 postFrame 而不是 write() 返回，是因为输出走 vsync 批处理 ——
    // write() 返回时像素还没上屏，而「用户无感」量的是用户看见的时刻。
    //
    // 已知限制：后台期间不出帧，这个回调会一直等到回前台的第一帧才触发。
    // 也就是说「后台期间完成的恢复」，其 ⑤ 段会把等待出帧的时间算进去。
    // 这是可接受的 —— 用户确实是在那一刻才看见的。
    final cb = _capturedRenderCompleteCb;
    if (cb != null) {
      _capturedRenderCompleteCb = null;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        // 埋点绝不能连累渲染，但也不能无声无息。
        try {
          cb(DateTime.now().millisecondsSinceEpoch);
        } catch (e) {
          dlog('SessionTab', 'onResumeRenderComplete 抛异常: $e');
        }
      });
    }
    appendOutput(text);
    if (inTmux && !isMosh) {
      _quietRefreshTimer?.cancel();
      // 800 ms debounce: fires after streaming stops, resets tmux differential
      // rendering state so CJK residuals are cleared before the user scrolls.
      // Uses the control pipe (not exec-channel) to avoid 2-RTT SSH overhead.
      _quietRefreshTimer = Timer(const Duration(milliseconds: 800), () {
        _quietRefreshTimer = null;
        backend.refreshClient();
      });
    }
  }

  /// 返回 [bytes] 末尾不完整的 UTF-8 字节数（0–3）。
  /// 从末尾向前扫描：遇到 ASCII (<0x80) 则无残留；遇到 leading byte (>=0xC0)
  /// 则计算期望字节数 needed，若实际到末尾只有 got < needed 个字节则返回 got。
  static int trailingIncompleteUtf8Bytes(List<int> bytes) {
    final len = bytes.length;
    for (var i = 1; i <= 4 && i <= len; i++) {
      final b = bytes[len - i] & 0xFF;
      if (b < 0x80) return 0;    // ASCII：前面不可能有不完整序列
      if (b >= 0xC0) {           // leading byte
        final needed = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2;
        return i < needed ? i : 0;
      }
      // 0x80–0xBF：continuation byte，继续往前找 leading byte
    }
    return 0;
  }

  /// 从 [bytes] 的 [start] 位置开始，向后跳过所有 UTF-8 continuation bytes
  /// (0x80–0xBF)，返回对齐后的 index（指向下一个 leading byte 或 ASCII，或 length）。
  ///
  /// 用于：`swallowAndStrip` 在按字节数吞掉 alt-buffer prelude 之后，避免剩余
  /// 字节流以半字符（continuation byte）开头进入 xterm decoder → U+FFFD tofu。
  /// 最多丢 3 个字节（破损一个 4-byte UTF-8 char），换取后续流不级联错位。
  static int alignToUtf8CharStart(List<int> bytes, int start) {
    while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
      start++;
    }
    return start;
  }

  // Tracked separately from remoteTuiHint so we can re-derive the hint
  // whenever either signal changes. Initial state = visible cursor, main
  // buffer (matches a fresh terminal).
  bool _trackerCursorHidden = false;
  bool _trackerAltBufferOn = false;

  /// Returns the byte offset of the LAST occurrence of [pattern] in [text],
  /// or -1 if not present. Plain-text search, no regex overhead.
  static int _lastIndexOf(String text, String pattern) {
    return text.lastIndexOf(pattern);
  }

  void _trackRemoteTui(String text) {
    // Find the LAST hide-vs-show signal in the chunk; the last one wins.
    // The old code OR'd `contains('?25l')` against `contains('?25h')` and
    // applied them independently, which latched remoteTuiHint=true for any
    // chunk that briefly toggled the cursor (bash prompts redrawing, tmux
    // status-line updates, fzf-style transient menus). Once latched, SGR
    // mouse-wheel events flowed straight into bash and rendered as visible
    // garbage like `^[[<64;1;1M`. The position-based comparison below
    // correctly resolves "?25l ... ?25h" (final = visible) vs
    // "?25h ... ?25l" (final = hidden) within the same chunk.
    final lastHide = _lastIndexOf(text, '\x1b[?25l');
    final lastShow = _lastIndexOf(text, '\x1b[?25h');
    if (lastHide >= 0 || lastShow >= 0) {
      _trackerCursorHidden = lastHide > lastShow;
    }
    final lastAltEnter = _lastIndexOf(text, '\x1b[?1049h');
    final lastAltExit = _lastIndexOf(text, '\x1b[?1049l');
    if (lastAltEnter >= 0 || lastAltExit >= 0) {
      _trackerAltBufferOn = lastAltEnter > lastAltExit;
    }
    remoteTuiHint = _trackerCursorHidden || _trackerAltBufferOn;
  }

  void stopStreaming({bool discardPending = false}) {
    onSessionDead = null; // prevent callback after deliberate teardown
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _streamingSource = null;
    // Flush any buffered output so the last chunk is not silently dropped.
    _quietRefreshTimer?.cancel();
    _quietRefreshTimer = null;
    _outputFlushPending = false;
    _microtaskPending = false;
    _framePending = false;
    _pendingOutputBytes = 0;
    if (discardPending) {
      _pendingOutput.clear();
    } else if (_pendingOutput.isNotEmpty) {
      final text = _pendingOutput.toString();
      _pendingOutput.clear();
      _pendingOutputBytes = 0;
      terminal.write(text);
      appendOutput(text);
    }
  }

  /// Clear TUI-hint flags when a new QUIC transport is established.
  ///
  /// After RESUME the server replays the ring buffer which may contain `?25l`
  /// (cursor-hide) from the old Claude Code session.  Without this reset,
  /// `remoteTuiHint` stays `true` for the new bash session, causing scroll
  /// gestures to incorrectly send SGR mouse events to bash → garbled output.
  void clearRemoteTuiHintForNewTransport() {
    remoteTuiHint = false;
    _trackerCursorHidden = false;
    _trackerAltBufferOn = false;
  }

  void resetProtocolStateForSshFallback() {
    remoteTuiHint = false;
    _trackerCursorHidden = false;
    _trackerAltBufferOn = false;
    backend.dispose();
    backend = NoneBackend();
    lastSgrSendAt = null;
    scrollSgrSendTimes.clear();
    // The \x1b[3J at the end wipes xterm's scrollback ring. Critical for the
    // mosh→SSH fallback path: mosh renders TUI apps (opencode/claude CLI)
    // into the MAIN buffer because mosh strips ?1049h, so the scrollback
    // ring accumulates thousands of redraw fragments (absolute cursor
    // moves, partial repaint columns). Without [3J the user scrolls up
    // post-fallback and sees stale mosh-era TUI debris ("滚动乱码").
    terminal.write(
      '\x1b[?1049l'
      '\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l'
      '\x1b[?2004l\x1b[?25h'
      '\x1b[r\x1b[m\x1b[2J\x1b[H\x1b[!p\x1b[3J',
    );
  }

  @visibleForTesting
  void testWriteAndFlush(String text) {
    _pendingOutput.write(text);
    _pendingOutputBytes += text.length;
    _scheduleOutputFlush();
  }

  @visibleForTesting
  bool get testPendingOutputEmpty => _pendingOutput.isEmpty;

  /// Append raw output text to the rolling context buffer.
  void appendOutput(String text) {
    final lines = text.split('\n');
    _contextLines.addAll(lines);
    if (_contextLines.length > _maxContextLines) {
      _contextLines = _contextLines.sublist(
        _contextLines.length - _maxContextLines,
      );
    }
  }

  /// Number of lines currently in the rolling context buffer.
  int get contextLineCount => _contextLines.length;

  /// Lines appended to the context buffer since index [from].
  /// [from] is typically a snapshot of [contextLineCount] taken before a command ran.
  List<String> contextLinesFrom(int from) {
    final start = from.clamp(0, _contextLines.length);
    return List<String>.unmodifiable(_contextLines.sublist(start));
  }

  /// Last up-to-200 lines of terminal output, for AI context.
  String get terminalContext => _contextLines.join('\n');
}

/// 解析「这台服务器上，用户此刻最可能在看的那个 tab」。
///
/// ## 为什么需要它：agent 会话绑服务器，而目录绑 tab
///
/// `AgentSessionManager` 按 `serverId` 持有 agent 会话，这是对的：agent 用的是
/// 独立的 exec channel，不在任何 tab 的 PTY 里跑命令；而「nginx 为什么 502」
/// 这个问题是关于**机器**的，用户为了并行做几件事开的三个 tab 不该对应三段
/// 互相看不见的排查历史。
///
/// 但「当前目录」和「终端里显示什么」天然属于 tab。早先的实现让 agent loop 的
/// 闭包直接捕获**首次创建它的那个 SessionTab**，于是两个问题：
///
/// - 在 tab A（`/var/log`）开过面板，切到 tab B（`/etc/nginx`）再开 —— 复用的是
///   同一个 loop，agent 执行命令时 `cd` 的仍然是 `/var/log`
/// - 关掉 tab A 之后 cwd 冻结在关闭那一刻，而那个已经死掉的 `SessionTab` 被
///   闭包一直持有、回收不掉
///
/// 把「具体哪个 tab」变成每次现算，两个问题一起消失。
///
/// ## 解析顺序
///
/// 1. 当前活动 tab，**前提是它属于这台服务器且还在列表里** —— 用户正在看的
///    那个最能代表他关心的上下文
/// 2. 否则该服务器最早的那个 tab —— 面板可以在切到别的服务器之后才打开（会话
///    绑服务器不绑 tab），此时拿它自己的任意一个目录，总好过拿一个属于**别的
///    机器**的目录去 `cd`
/// 3. 都没有则 null，调用方回退到 `$HOME`
SessionTab? resolveActiveTabForServer(
  List<SessionTab> tabs,
  SessionTab? activeTab,
  String serverId,
) {
  // `tabs.contains` 不能省：tab 被关掉之后调用方可能还持有它的引用，而那个
  // tab 的 cwd 停在关闭那一刻，早就不代表用户此刻在哪。
  if (activeTab != null &&
      activeTab.server.id == serverId &&
      tabs.contains(activeTab)) {
    return activeTab;
  }
  for (final t in tabs) {
    if (t.server.id == serverId) return t;
  }
  return null;
}

class SessionManager extends ChangeNotifier {
  final TabSessionRepository? _tabSessionRepo;
  final SharedPreferences _prefs;
  // ignore: unused_field  // will be used in Stage 3 for QUIC transport dispatch
  final TransportFactory _transportFactory;

  /// C4 — Pool of background-prewarmed transports from cold-start.
  /// Populated by `main.dart::_prewarmAqtSession`; consumed by
  /// `terminal_screen.dart::_connectServer` when entering a matching tab.
  final PrewarmPool prewarmPool = PrewarmPool();

  /// RESUME 的唯一发起入口。由 main.dart 在能拿到 host / 会话状态之后注入。
  ///
  /// 放在这里而不是各发起点各持一个：合并只有在**共享同一个实例**时才成立。
  /// 它与 [prewarmPool] 分工明确 —— coordinator 合并「发起」，pool 管
  /// transport 的所有权移交（`store` / `take`，取走即归属调用方）。
  ///
  /// 为 null 时各发起点退回自己直接发 RESUME 的老路：那仍然是**正确**的
  /// （协议幂等，重复 RESUME 无害），只是浪费。测试路径不必构造它。
  SessionResumeCoordinator? resumeCoordinator;

  SessionManager({
    required SharedPreferences prefs,
    TabSessionRepository? tabSessionRepo,
    TransportFactory? transportFactory,
  }) : _prefs = prefs,
       _tabSessionRepo = tabSessionRepo,
       _transportFactory = transportFactory ?? CompositeTransportFactory();

  final List<SessionTab> _tabs = [];
  int _activeIndex = 0;

  final List<void Function(String tabId)> _tabClosedListeners = [];
  void addTabClosedListener(void Function(String tabId) cb) =>
      _tabClosedListeners.add(cb);
  void removeTabClosedListener(void Function(String tabId) cb) =>
      _tabClosedListeners.remove(cb);

  /// Bridge for server-pushed Notify events, mirroring the
  /// [_tabClosedListeners] pattern above. [SessionManager] is constructed
  /// in `main()` (outside the widget tree) but stays alive for the whole
  /// app lifetime and is also reachable inside the widget tree via
  /// Provider, so it is the natural hand-off point between
  /// [ReconnectService] (which wires [AqtTransport.onNotify] per-tab, also
  /// outside the widget tree) and the widget-layer orchestrator that
  /// actually has access to [SplitManager] for visibility checks. Kept
  /// deliberately separate from [_tabClosedListeners] rather than a shared
  /// generic event bus — this is a small, closed set of listener kinds and
  /// a generic bus would add indirection without a second consumer to
  /// justify it.
  final List<void Function(SessionTab tab, NotifyPayload payload)>
      _notifyListeners = [];
  void addNotifyListener(
          void Function(SessionTab tab, NotifyPayload payload) cb) =>
      _notifyListeners.add(cb);
  void removeNotifyListener(
          void Function(SessionTab tab, NotifyPayload payload) cb) =>
      _notifyListeners.remove(cb);

  /// Called by [ReconnectService] when a tab's transport fires
  /// [AqtTransport.onNotify]. Fans out to all registered listeners —
  /// currently just the widget-layer notify orchestrator.
  void publishNotify(SessionTab tab, NotifyPayload payload) {
    for (final cb in _notifyListeners) {
      cb(tab, payload);
    }
  }

  List<SessionTab> get tabs => List.unmodifiable(_tabs);
  int get activeIndex => _activeIndex;
  SessionTab? get activeTab => _tabs.isEmpty ? null : _tabs[_activeIndex];

  /// 见 [resolveActiveTabForServer]。agent 会话绑服务器，而它需要的目录与
  /// 终端内容绑 tab —— 这个方法是两者之间的桥。
  SessionTab? activeTabForServer(String serverId) =>
      resolveActiveTabForServer(_tabs, activeTab, serverId);

  // ---------------------------------------------------------------------------
  // 一次性待执行命令
  // ---------------------------------------------------------------------------

  /// serverId → 等着送进终端的那一条命令。
  ///
  /// 用途：全局 AI tab 里点代码块的「执行」。那一页不在终端里，拿不到
  /// `SessionTab.shell`，而且**也不该**自己往 shell 写 —— 真正的发送路径
  /// （`terminal_screen.dart` 的 `_runCommand`）带高危命令拦截，绕过它复制
  /// 一份发送逻辑是安全回归。所以这里只投槽，由 `TerminalScreen` 取走并
  /// 走它自己那条带拦截的路。
  ///
  /// 与 `AgentSessionManager` 的 staged prompt 同构但分开存：那个投的是给
  /// 模型的话，这个投的是给 shell 的命令，混在一起迟早有人取错。
  final Map<String, String> _stagedCommands = {};

  /// 投一条命令，等目标机器的终端就绪时执行。后投的覆盖先投的。
  ///
  /// **不 notifyListeners**：投槽本身不改变任何已渲染的状态，而消费是由
  /// 连接完成时的 `notifyTabChanged()` 驱动的。在这里 notify 会让消费者在
  /// 终端还没起来时就被叫醒一次，白跑。
  void stageCommand(String serverId, String command) {
    _stagedCommands[serverId] = command;
  }

  /// 取走并清空。没有则返回 null。
  String? takeStagedCommand(String serverId) =>
      _stagedCommands.remove(serverId);

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Writes current tab list to [TabSessionRepository].
  /// Fire-and-forget — must never be awaited on the UI path.
  void _persist() {
    if (_tabSessionRepo == null || _tabs.isEmpty) {
      _tabSessionRepo?.clear();
      return;
    }
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < _tabs.length; i++) {
      rows.add({
        'id': _tabs[i].id,
        'server_id': _tabs[i].server.id,
        'tmux_key': _tabs[i].sessionKey,
        'position': i,
        'is_active': i == _activeIndex ? 1 : 0,
        'sftp_last_path': _tabs[i].sftpCwd,
      });
    }
    _tabSessionRepo.save(rows); // intentionally unawaited
  }

  // ---------------------------------------------------------------------------
  // Restore
  // ---------------------------------------------------------------------------

  /// Bulk-restores tabs from saved state without triggering individual persists.
  /// Called once from main() before runApp.  Each entry must correspond to a
  /// server that still exists in the DB (callers must filter missing ones).
  void restoreFromSaved(List<TabRestoreEntry> entries, int activeIdx) {
    for (final e in entries) {
      final tab = SessionTab(
        id: e.tabId,
        server: e.server,
        connection: SSHConnection(),
        terminal: Terminal(maxLines: 3000),
        sessionKey: e.tmuxKey,
        aiEngine: AIEngine(_prefs, serverId: e.server.id),
      );
      // Restored tabs are treated as previously connected: show TerminalWidget
      // (not a spinner) while reconnecting, and display "[重新连接中...]" banner.
      tab.isFirstConnection = false;
      tab.isMosh = e.server.transport == Transport.mosh && e.server.jumpHostId == null;
      // Restore last SFTP directory so the next SFTP open resumes there.
      // viewMode is intentionally NOT restored — cold start always lands in
      // terminal.
      tab.sftpCwd = e.sftpLastPath;
      _tabs.add(tab);
    }
    if (_tabs.isNotEmpty) {
      _activeIndex = activeIdx.clamp(0, _tabs.length - 1);
    }
    // No _persist() here — we just read from DB, no point writing it back.
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  /// Creates and appends a new tab.  [tabId] and [tmuxKey] are used when
  /// restoring a specific saved tab; omit them for normal new-tab creation.
  /// 新开一个 tab。
  ///
  /// [activate] = false 时**不把焦点切过去** —— 新 tab 在后台建好，用户
  /// 留在当前界面。给 `session_open` 用：AI 在全局页面说「帮你连上 prod 了」
  /// 然后把用户从正在做的事里弹走，是在抢用户的屏幕。
  ///
  /// 默认 true，现有调用点（用户自己点「新建会话」）行为不变 —— 那种场景
  /// 用户的意图本来就是「我现在要用这个」。
  SessionTab addTab(
    Server server, {
    String? tabId,
    String? tmuxKey,
    bool activate = true,
  }) {
    final isFirst = !_tabs.any((t) => t.server.id == server.id);
    final key = tmuxKey ?? (isFirst ? server.id : const Uuid().v4());
    final tab = SessionTab(
      id: tabId,
      server: server,
      connection: SSHConnection(),
      terminal: Terminal(maxLines: 3000),
      sessionKey: key,
      aiEngine: AIEngine(_prefs, serverId: server.id),
    );
    _tabs.add(tab);
    if (activate) _activeIndex = _tabs.length - 1;
    _persist();
    notifyListeners();
    return tab;
  }

  void closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    // UUID-keyed sessions (second+ tabs to the same server) have no recovery
    // value — kill them now so they don't accumulate on the server.
    // server.id-keyed sessions are kept alive for reconnect/recovery.
    final tab = _tabs[index];
    if (tab.inTmux && tab.sessionKey != tab.server.id) {
      if (tab.backend is TmuxBackend) {
        final tmuxB = tab.backend as TmuxBackend;
        tmuxB.controlPipe.send(
          'tmux kill-session -t ${TmuxHelper.sessionName(tab.sessionKey)}',
        );
      }
    }
    final closingTab = _tabs[index];
    closingTab.stopStreaming();
    closingTab.aiEngine.dispose();
    closingTab.backend.dispose();
    // Mark pending_kill immediately so the PID is never stuck as 'active' if
    // SSH is unreachable during the kill attempt below. Startup cleanup retries
    // any PID that stays in pending_kill across app restarts.
    closingTab.onClosing?.call();
    // Fire the kill: if moshShell is gone use the saved pendingServerKill lambda.
    // Promote pending_kill → killed only when the kill command actually executes.
    final moshShell = closingTab.moshShell as dynamic;
    if (moshShell == null) {
      closingTab.pendingServerKill?.call().then((killed) {
        if (killed) closingTab.onClose?.call();
      });
    } else {
      moshShell.close().then((killed) {
        if (killed == true) closingTab.onClose?.call();
      });
    }
    // Also close typed transport if present.
    closingTab.transport?.close();
    // Dispose SFTP service so its owned SSH client (if any) is closed promptly.
    closingTab.invalidateSftpSvc();
    // Do not clear persisted mosh_pid until the kill command has actually been
    // sent. If SSH is unavailable, keeping the PID lets startup cleanup retry.
    closingTab.connection.close();
    for (final cb in _tabClosedListeners) {
      cb(closingTab.id);
    }
    _tabs.removeAt(index);
    if (_tabs.isEmpty) {
      _activeIndex = 0;
    } else if (_activeIndex >= _tabs.length) {
      _activeIndex = _tabs.length - 1;
    }
    _persist();
    notifyListeners();
  }

  void setActiveTab(int index) {
    if (index >= 0 && index < _tabs.length && index != _activeIndex) {
      _activeIndex = index;
      _persist();
      notifyListeners();
    }
  }

  void nextTab() {
    if (_tabs.length <= 1) return;
    _activeIndex = (_activeIndex + 1) % _tabs.length;
    _persist();
    notifyListeners();
  }

  void prevTab() {
    if (_tabs.length <= 1) return;
    _activeIndex = (_activeIndex - 1 + _tabs.length) % _tabs.length;
    _persist();
    notifyListeners();
  }

  void renameTab(int index, String name) {
    if (index < 0 || index >= _tabs.length) return;
    final trimmed = name.trim();
    _tabs[index].customName = trimmed.isEmpty ? null : trimmed;
    notifyListeners();
  }

  void moveTab(int from, int to) {
    if (from < 0 || from >= _tabs.length) return;
    if (to < 0 || to > _tabs.length) return;
    if (to == from || to == from + 1) return;
    final activeTab = _tabs[_activeIndex];
    final tab = _tabs.removeAt(from);
    final insertAt = (to > from ? to - 1 : to).clamp(0, _tabs.length);
    _tabs.insert(insertAt, tab);
    _activeIndex = _tabs.indexOf(activeTab).clamp(0, _tabs.length - 1);
    _persist();
    notifyListeners();
  }

  /// Call after mutating a [SessionTab]'s display state (e.g. inTmux).
  void notifyTabChanged() => notifyListeners();

  /// Toggle [tab].viewMode between terminal and sftp, then notify.
  void toggleViewMode(SessionTab tab) {
    tab.viewMode = tab.viewMode == TabViewMode.terminal
        ? TabViewMode.sftp
        : TabViewMode.terminal;
    notifyListeners();
    _persist();
  }

  /// Set [tab].viewMode to a specific mode. No-op if already there.
  void setViewMode(SessionTab tab, TabViewMode mode) {
    if (tab.viewMode == mode) return;
    tab.viewMode = mode;
    notifyListeners();
    _persist();
  }

  /// Update the SFTP browsing path for [tab] and persist so the next launch
  /// resumes from the same directory. Per-tab: two tabs to the same server
  /// each have independent SFTP paths stored in tab_sessions.
  void setSftpCwd(SessionTab tab, String path) {
    tab.sftpCwd = path;
    _persist();
  }

  /// Called by ReconnectService after a tab's connection is restored.
  void notifyReconnected() => notifyListeners();

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.stopStreaming();
      tab.aiEngine.dispose();
      tab.backend.dispose();
      (tab.moshShell as dynamic)?.close();
      tab.connection.close();
    }
    super.dispose();
  }
}
