// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../ssh/transport/transport.dart' show Transport;
import '../../ssh/reconnect_service.dart';
import '../../ssh/session_manager.dart';
import '../../ssh/multiplexer/tmux_backend.dart';
import '../../ssh/transport/remote_transport.dart';
import '../../ssh/aqt/aqt_route.dart';
import '../../ssh/aqt/aqt_transport.dart' show AqtTransport;
import '../../ssh/aqt/resume_issue_log.dart';
import '../../ssh/aqt/resume_sample.dart';
import '../../ssh/aqt/conn/conn_machine.dart' show kBannerDelayMs;
import '../../ssh/aqt/conn/conn_silence.dart' show kPtyStallMs;
import '../../ai/agent/agent_session_manager.dart';
import 'debug_log.dart';
// termDebug is exported from debug_log.dart

/// Floating diagnostic overlay shown over the active terminal tab when
/// [TerminalSettings.debugOverlay] is enabled.
///
/// Toggled via the 7-tap secret on the version tile in settings (same
/// gesture as Android's "Developer mode"). Reads only public state from
/// [SessionTab] / its underlying terminal — no business-logic mutation.
class DebugOverlay extends StatefulWidget {
  const DebugOverlay({super.key, required this.tab});

  final SessionTab tab;

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  Timer? _ticker;

  /// agent_sessions 表里这台服务器实际有多少行。null = 还没查过。
  ///
  /// 这一项直接回答「落盘到底有没有发生」——落盘的每个失败分支都是静默的，
  /// 而 `apsv` 那行只反映**本次进程内**的最后一次尝试；冷启动后它是 never，
  /// 那时唯一能说明上一次会话有没有落盘的就是表里的行数。
  int? _agentRows;

  /// 查库不跟着 500ms 的 ticker 走 —— 那是每秒两次 SQLite 查询，为一个诊断
  /// 数字不值得。每 10 拍（5 秒）一次，对「打开面板前看一眼」这个用法足够。
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    // 500ms refresh — enough for a debug panel without burning the
    // 60 fps repaint budget on overlay text.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (_tick++ % 10 == 0) unawaited(_refreshAgentRows());
      setState(() {});
    });
    unawaited(_refreshAgentRows());
  }

  Future<void> _refreshAgentRows() async {
    // read 而不是 watch：这里是 ticker 回调，不是 build。
    final mgr = context.read<AgentSessionManager>();
    final rows = await mgr.sessionsFor(widget.tab.server.id);
    if (!mounted) return;
    _agentRows = rows.length;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tab;
    // RepaintBoundary isolates this overlay's compositing from the parent
    // Stack. Without it, Impeller (Flutter 3.29) on mosh sessions blends the
    // semi-transparent debug panel layer across the entire terminal area —
    // when the terminal triggers many small repaints (mosh diff cadence
    // ~50ms), the layer cache desyncs and the whole terminal washes out
    // light/white. The boundary forces the panel into its own offscreen
    // buffer so its saveLayer never interacts with the terminal layer.
    return RepaintBoundary(
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
            maxWidth: MediaQuery.of(context).size.width * 0.95,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xEE000000),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: const Color(0x26FFFFFF),
                width: 0.5,
              ),
            ),
            child: DefaultTextStyle(
              style: const TextStyle(
                fontSize: 9.5,
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: ['monospace'],
                color: Color(0xFFD4D4D4),
                height: 1.2,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: _buildLines(t),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLines(SessionTab t) {
    // 注意：transport==null 时优先按 server.transport 判定，避免 QUIC tab 在
    // reconnect 期间 (tab.transport 被清空) 假装"降级"到 SSH 误导用户。
    // 真正的"SSH-only tab"才显示 SSH (server.transport==Transport.ssh)。
    final proto = switch (t.transport?.kind) {
      TransportKind.aqt   => (t.transport is AqtTransport &&
              (t.transport as AqtTransport).route == AqtRoute.viaSsh)
          ? 'QUIC·SSH'
          : 'QUIC',
      TransportKind.mosh  => 'Mosh',
      TransportKind.local => 'Local',
      TransportKind.ssh   => 'SSH',
      null => t.localShell != null
          ? 'Local'
          : t.isMosh
              ? 'Mosh'
              : t.server.transport == Transport.quic
                  ? 'QUIC-?'   // QUIC tab transport 尚未装上 / 已被清空
                  : t.server.transport == Transport.mosh
                      ? 'Mosh-?' // Mosh tab handshake 中
                      : 'SSH',
    };
    final cols = t.terminal.viewWidth;
    final rows = t.terminal.viewHeight;
    final buf = t.terminal.isUsingAltBuffer ? 'alt' : 'pri';
    final totalLines = t.terminal.buffer.lines.length;
    final scrollbackRows = (totalLines - rows).clamp(0, totalLines);
    final cur = 'r${t.terminal.buffer.cursorY}c${t.terminal.buffer.cursorX}';
    final sshOpen = t.connection.client?.isClosed == false;

    // ── keybar 显隐诊断 ──
    //
    // [kbShown] 是 `terminal_screen.dart` 里那条 Keybar 渲染条件的**逐字
    // 复刻**（搜那里的「Keybar 显隐」注释）。两处必须同步改，否则这个诊断
    // 会说谎 —— 一个说谎的诊断比没有诊断更坏。
    //
    // 它回答的是一个很具体的问题：「vim 一打开 keybar 就没了」到底是
    // **条件判假**（widget 压根没建）还是**建了但看不见**（被键盘 inset
    // 顶出屏幕、或被别的层盖住）。这两者的修法毫无共同之处，而光读代码
    // 分不出来 —— 渲染路径里没有任何一处看 alt buffer。
    final kbShown = (t.moshShell != null ||
            t.connection.shell != null ||
            t.localShell != null ||
            !t.isFirstConnection) &&
        t.viewMode != TabViewMode.sftp;
    // 哪一路 shell 把条件撑住的。'-' = 三路全 null，此时条件只能靠
    // `!isFirstConnection` 成立。
    final shellTag = t.moshShell != null
        ? 'mosh'
        : t.connection.shell != null
            ? 'ssh'
            : t.localShell != null
                ? 'local'
                : '-';
    // `_KeyboardAwareBody` 拿它做 bottom padding（Scaffold 那边是
    // `resizeToAvoidBottomInset: false`，这一层是手动补的）。keybar 在
    // Column 末尾，这个值异常偏大就会把它推出可视区。
    final kbInset = MediaQuery.of(context).viewInsets.bottom.round();
    final pipeName = t.backend is TmuxBackend
        ? (t.backend as TmuxBackend).controlPipe.cachedClientName
        : null;

    // ── agent 会话持久化 ──
    // 置顶：面板外层是 IgnorePointer 包着的 SingleChildScrollView，滚不动，
    // 排在后面的行在真机上根本看不见。
    //
    // rows  = 表里这台服务器的段数（上一次会话到底有没有落盘）
    // apsv  = 本进程最后一次落盘尝试的结果（never = 一次都没触发）
    // arst  = 本进程最后一次恢复尝试的结果（never = 恢复入口没被调用过）
    final mgr = context.read<AgentSessionManager>();
    final svc = context.read<ReconnectService>();
    final agentRows = _agentRows;
    // 恢复耗时基线一行要读好几次（n/p50/p90/hit），提前算一次，避免
    // 每 500ms 的 rebuild 里对着 <=64 条样本重复跑好几遍分位数聚合。
    final resumeStats = svc.resumeSamples.statsByBucket();
    final probeHits = svc.resumeSamples.probeHits;
    final resumeAll = svc.resumeSamples.statsAll();
    final resumeSeg = svc.resumeSamples.segmentStats();
    return [
      _row([
        _cell('rows:${agentRows ?? '?'}',
            agentRows == null ? _grey : (agentRows > 0 ? _green : _red)),
        _cell('apsv:${mgr.lastPersistNote ?? 'never'}',
            mgr.lastPersistNote == null
                ? _grey
                : (mgr.lastPersistNote!.startsWith('ins') ||
                        mgr.lastPersistNote!.startsWith('upd')
                    ? _green
                    : _red)),
      ]),
      _row([
        _cell('arst:${mgr.lastRestoreNote ?? 'never'}',
            mgr.lastRestoreNote == null
                ? _grey
                : (mgr.lastRestoreNote!.startsWith('row=') ? _green : _red)),
      ]),
      // apsv:never 的歧义拆解 —— chg=0 表示回调压根没触发（listener 问题），
      // chg>0 则 st/sr 直接说明为什么那个终态条件不满足。
      _row([
        _cell('lp:${mgr.lastLoopNote ?? 'chg=0'}',
            mgr.lastLoopNote == null ? _red : _yellow),
      ]),
      _row([
        _cell(proto, t.transport?.kind == TransportKind.aqt ? _green : _cyan),
        _cell('${cols}x$rows'),
        _cell(buf, t.terminal.isUsingAltBuffer ? _green : _grey),
        _cell('sb:$scrollbackRows', scrollbackRows > 0 ? _green : _grey),
      ]),
      // keybar 显隐。判读（进 vim 前后各看一眼这一行）：
      //   kb:T 但屏幕上没有 keybar → 条件成立、widget 建了，问题在布局；
      //                              优先看 ins 是不是异常偏大
      //   kb:F                     → 条件真的判假，右边三项直接指出是哪一
      //                              项翻了（sh 全 null / 1st:T / vm:sftp）
      // 变量与理由见上面 kbShown 的注释。
      _row([
        _cell('kb:${kbShown ? 'T' : 'F'}', kbShown ? _green : _red),
        _cell('sh:$shellTag', shellTag == '-' ? _yellow : _grey),
        _cell('1st:${t.isFirstConnection ? 'T' : 'F'}',
            t.isFirstConnection ? _yellow : _grey),
        _cell('vm:${t.viewMode.name}',
            t.viewMode == TabViewMode.sftp ? _yellow : _grey),
        _cell('ins:$kbInset', kbInset > 0 ? _green : _grey),
      ]),
      _row([
        _cell('mux:${switch (t.backend) { TmuxBackend() => 'tmux', _ when t.backend.isActive => t.server.multiplexerType.name, _ => 'off' }}', t.backend.isActive ? _green : _grey),
        _cell('ssh:${sshOpen ? 'open' : 'closed'}', sshOpen ? _green : _red),
        if (pipeName != null) _cell('pipe:$pipeName', _grey),
      ]),
      // ── RESUME 发起点日志 ──
      // 放这么靠上是有意的：面板外层是 IgnorePointer 包着的 SingleChildScrollView
      // （见 build()），手势被全吞，用户滚不动——排在 0.78×屏高以下的内容永远
      // 看不见。这段是当前正在排查的目标（并发 RESUME、各带一代 lastOutOff），
      // 必须保证一定可见。查完可以下沉或删掉。
      // 判据用 server.transport 而不是 t.transport is AqtTransport：QUIC tab 在
      // 冷启动/重连期间 t.transport 恰恰是 null，而那正是这段日志唯一有用的时刻。
      // ── TUI 判据对照（2026-10-05 恢复，排查「cc 里补全仍然弹」）──
      //
      // 两个来源并排放是全部意义所在：
      //   tui    = SessionTab 自己用字符串搜索 ?25l/?1049h 维护的 latch
      //   xtCur  = xterm 解析完所有字节后的权威光标状态
      //   xtAlt  = xterm 的 alt buffer 状态
      //
      // 两者**应该恒等**。不等就说明字符串跟踪漏了事件（最可能是 ESC 序列
      // 跨 chunk 边界被切断 —— _flushOutput 只处理 UTF-8 residue，不处理
      // 被截断的 ESC 序列），那就是根因，修复方向是直接读 xterm。
      //
      // 置顶是硬要求：面板外层 IgnorePointer 包 SingleChildScrollView，
      // 手势全吞滚不动，0.78×屏高以下的内容永远看不见。
      _row([
        _cell('tui:${t.remoteTuiHint ? "T" : "F"}',
            t.remoteTuiHint ? _green : _grey),
        _cell('xtCur:${t.terminal.cursorVisibleMode ? "vis" : "HID"}',
            t.terminal.cursorVisibleMode ? _grey : _green),
        _cell('xtAlt:${t.terminal.isUsingAltBuffer ? "T" : "F"}',
            t.terminal.isUsingAltBuffer ? _green : _grey),
        // focus tracking：区分「主 buffer 里的全屏 TUI」与 bash 的关键信号。
        // bash/readline 开 ?2004h 但不开 ?1004h。
        _cell('foc:${t.terminal.reportFocusMode ? "T" : "F"}',
            t.terminal.reportFocusMode ? _green : _grey),
        // 补全实际用的判据（foregroundOwnsInputLine）。T = 不弹补全。
        _cell('inp:${t.foregroundOwnsInputLine ? "OWNED" : "free"}',
            t.foregroundOwnsInputLine ? _green : _grey),
      ]),
      if (t.server.transport == Transport.quic) ..._buildResumeIssueLog(),
      // ── QUIC RESUME debug rows (slimmed 2026-05-30: removed token/spki/
      //    ringOff/resumeAt/delta/why/ptyAge/lastDisc/chunk/lz4/tuiHint
      //    rows; restore from git if needed for deep RESUME-protocol triage)
      if (t.transport case final AqtTransport aqt) ...[
        _row([
          _cell(aqt.wasResumed ? 'RESUMED✓' : 'HELLO(new)', aqt.wasResumed ? _green : _yellow),
          _cell('qstate:${aqt.currentState.name}',
            aqt.currentState == TransportState.connected ? _green
              : aqt.currentState == TransportState.reconnecting ? _yellow : _red),
          _cell('dead:${aqt.isDead}', aqt.isDead ? _red : _green),
          _cell('pathDied:${aqt.quicPathDied}', aqt.quicPathDied ? _red : _grey),
        ]),
        // 幻影判据的现状。上面那行的四个指标在幻影下**全是绿的**
        // （RESUMED✓ / connected / dead:false / pathDied:false）—— a4.jpg 现场
        // 就是这样，光看它们会得出「连接很健康」的结论，而用户那边输入不了、
        // 渲染也不对。这一行给的是唯一能分辨的证据：
        //   noEcho  距最后一次真正发出的写入（null 表示从没发过 → 不判幻影）
        //   ptyAge  距最后一次收到 PTY 数据
        // noEcho < ptyAge 且超过阈值 = 发出去的字节没有回音 = 幻影。
        // 2026-05-30 精简时删掉的那个 ptyAge 行只有静默时长，分不出空闲和
        // 坏死，所以这次是带着判据一起加回来的，不是把旧行恢复。
        // **输入这一侧走到哪一步了。** 上面那条 noEcho 行是条件显示的
        // （`sinceLastWrite == null` 时整行不出现），而 null 有两种截然不同的
        // 成因，光看它分不出来：用户压根没打字，还是打了但字节没能离开手机。
        // a9.jpg 现场就卡在这个岔路上 —— QUIC 全绿、恢复成功，而唯一能说明
        // 「输入去哪了」的证据整行缺席。
        //
        //   wr   write() 被调用了几次；0 = 输入连 transport 都没到（UI 层断了）
        //   buf  还压在缓冲里发不出去的字节；>0 = 到了 transport 但发不出去
        //   tab  服务端分配的 tab id；null = OPEN_TAB_ACK 还没回来（恢复中）
        _row([
          _cell('wr:${aqt.debugWriteCalls}',
              aqt.debugWriteCalls > 0 ? _green : _grey),
          _cell('buf:${aqt.pendingInputBytes}B',
              aqt.pendingInputBytes > 0 ? _red : _grey),
          _cell('tab:${aqt.debugTabId ?? "null"}',
              aqt.debugTabId == null ? _red : _grey),
        ]),
        // ptyAge 独立成行、**无条件显示**：它是 2026-09-06 那次「连着却收不到
        // 数据」唯一能看见坏死的字段，而幻影那行是条件显示的（没写过输入就
        // 整行消失）。那次现场恰好两者都在，但坏死本身不需要先写过输入。
        //
        // 超过 kPtyStallMs 标红 = PTY 停流判据已具备判死条件，此时 mphase
        // 应当变成 recovering；若它仍停在 live/probing，说明接线断了。
        _row([
          _cell('ptyAge:${aqt.lastPtyDataAge.inSeconds}s',
              aqt.lastPtyDataAge.inMilliseconds >= kPtyStallMs ? _red : _grey),
          if (aqt.sinceLastWrite case final w?)
            _cell('noEcho:${w.inSeconds}s',
                aqt.isPhantomStalled ? _red : _grey),
          if (aqt.sinceLastWrite != null)
            _cell('phantom:${aqt.isPhantomStalled ? "Y" : "N"}',
                aqt.isPhantomStalled ? _red : _green),
        ]),
        if (aqt.failureReason != null)
          _row([_cell('qerr:${aqt.failureReason!.length > 40 ? "${aqt.failureReason!.substring(0, 40)}…" : aqt.failureReason!}', _red)]),
        // ── 4-phase connect timings (row 1 / conn) ──
        // tcp:  TCP socket connect
        // auth: SSH user-authentication
        // boot: exec flyterm-server + 4×AQT_* lines parsed
        // hs:   QUIC ClientHello → 0-RTT data send-ready
        // total: tcp + auth + boot + hs
        if (aqt.lastConnectTimings.totalMs > 0) ...[
          _row([
            _cell('conn', _grey),
            _cell('tcp:${aqt.lastConnectTimings.tcpMs}',
                aqt.lastConnectTimings.tcpMs > 3000 ? _red
                  : aqt.lastConnectTimings.tcpMs > 1000 ? _yellow : _grey),
            _cell('auth:${aqt.lastConnectTimings.authMs}',
                aqt.lastConnectTimings.authMs > 5000 ? _red
                  : aqt.lastConnectTimings.authMs > 2000 ? _yellow : _grey),
            _cell('boot:${aqt.lastConnectTimings.bootMs}',
                aqt.lastConnectTimings.bootMs > 3000 ? _red
                  : aqt.lastConnectTimings.bootMs > 1500 ? _yellow : _grey),
            _cell('hs:${aqt.lastConnectTimings.handshakeMs}',
                aqt.lastConnectTimings.handshakeMs > 2000 ? _red
                  : aqt.lastConnectTimings.handshakeMs > 800 ? _yellow : _grey),
            _cell('total:${aqt.lastConnectTimings.totalMs}ms', _cyan),
          ]),
        ],
        // RESUME prelude head (last 16 bytes hex). Clean = starts with `1b`
        // (ESC). Leading param byte (3x/3b) = G1 leaked CSI residue.
        if (t.lastPreludeHexHead.isNotEmpty)
          _row([
            _cell(
              'prelude:${t.lastPreludeHexHead}',
              t.lastPreludeHexHead.startsWith('1b') ? _green : _yellow,
            ),
          ]),
        // ── 黑屏判别器 ──
        //
        // 「空屏 + 光标停在左上角」有两种完全不同的成因，这两格一眼分开：
        //
        //   alt:Y + blines 很大 → 停在**空的 alt 缓冲**里，历史完好地躺在
        //                          primary 下面。恢复负载的 ?1049h 落了地，
        //                          紧随其后的快照没到。
        //   alt:N + blines 很小 → 缓冲是真的空了，服务端换了新会话。
        //   alt:N + blines 很大 → 数据在本地，只是没画出来 —— 渲染问题，
        //                          与传输层无关。
        _row([
          _cell('alt:${t.terminal.isUsingAltBuffer ? "Y" : "N"}',
              t.terminal.isUsingAltBuffer ? _cyan : _grey),
          _cell('blines:$totalLines', totalLines > 0 ? _grey : _red),
        ]),
        // Cumulative U+FFFD render count (UTF-8 decoder fallback). Spike
        // after RESUME = chunk-boundary or CSI-tail bytes leaked into xterm.
        _row([
          _cell(
            'fffd:${t.fffdRenderCount}',
            t.fffdRenderCount > 0 ? _red : _grey,
          ),
        ]),
        // ── QUIC path stats (row 3 / path) ──
        // Pulled lazily on each rebuild via refreshPathStats; safe to
        // call frequently (try_lock on RwLock, no async).
        Builder(builder: (_) { aqt.refreshPathStats(); return const SizedBox.shrink(); }),
        _row([
          _cell('path', _grey),
          _cell('rtt:${aqt.lastPathStats.rttMs}',
              aqt.lastPathStats.rttMs > 200 ? _yellow : _grey),
          _cell(
            'loss:${(aqt.lastPathStats.lossRate * 100).toStringAsFixed(1)}%',
            aqt.lastPathStats.lossRate > 0.02 ? _red
              : aqt.lastPathStats.lossRate > 0.005 ? _yellow : _grey,
          ),
          _cell('migr:${aqt.lastPathStats.migrationCount}',
              aqt.lastPathStats.migrationCount > 0 ? _yellow : _grey),
          _cell('rebind:${aqt.lastPathStats.rebindingCount}',
              aqt.lastPathStats.rebindingCount > 0 ? _yellow : _grey),
          _cell('cwnd:${aqt.lastPathStats.cwndKB}', _grey),
        ]),
        // ── RESUME 3-stage timings (row 2 / res) ──
        // ackRTT: RESUME packet flushed → RESUME_ACK parsed
        // replay: RESUME_ACK → all replay bytes (incl. CAN) received
        // bytes:  server-reported replay size (preserved from RESUME_ACK)
        // age:    seconds since replayCompleteAt
        if (aqt.lastResumeTimings.sentAt != null) ...[
          _row([
            _cell('res', _grey),
            _cell(
              'ackRTT:${aqt.lastResumeTimings.ackRttMs ?? '-'}',
              (aqt.lastResumeTimings.ackRttMs ?? 0) > 1000 ? _red
                : (aqt.lastResumeTimings.ackRttMs ?? 0) > 500 ? _yellow : _grey,
            ),
            _cell(
              'replay:${aqt.lastResumeTimings.replayMs ?? '-'}',
              (aqt.lastResumeTimings.replayMs ?? 0) > 2000 ? _red
                : (aqt.lastResumeTimings.replayMs ?? 0) > 500 ? _yellow : _grey,
            ),
            _cell(
              'screen:${aqt.lastResumeTimings.screenBytes}B',
              aqt.lastResumeTimings.screenBytes > 64 * 1024 ? _yellow : _grey,
            ),
            _cell(
              'age:${aqt.lastResumeTimings.ageSec != null ? '${aqt.lastResumeTimings.ageSec}s' : '-'}',
              _grey,
            ),
          ]),
        ],
        // 状态机阶段 + 轨迹落盘行数（single-value 指标，置顶区末尾，见
        // feedback_debug_overlay_layout.md）。mphase 取代 qstate 之外的
        // 第二判活维度——两者理应一致，出现分歧本身就是信号。
        _row([
          _cell('mphase:${svc.runnerPhaseOf(t.id) ?? '-'}',
              svc.runnerPhaseOf(t.id) == 'live' ? _green : _yellow),
          _cell('trace:${svc.lastTraceExportLines}', _grey),
        ]),
        // 样本文件落盘位置 + 条数。真机取样时要用 adb 把这个文件拉出来，而
        // getApplicationSupportDirectory() 在不同设备上映射的实际路径不同，
        // 面板直接显示路径就不用现场猜/find。
        if (svc.lastSampleExportPath != null)
          _row([
            _cell('samples', _grey),
            _cell('n:${svc.lastSampleExportCount}', _grey),
            _cell(
              svc.lastSampleExportPath!.length > 48
                  ? '…${svc.lastSampleExportPath!.substring(svc.lastSampleExportPath!.length - 45)}'
                  : svc.lastSampleExportPath!,
              _grey,
            ),
          ]),
        // ── 恢复耗时基线（按后台时长分档）──────────────────────
        // 每档一行：n / p50 / p90 / hit。n/p50/p90 只统计成功且从后台回来
        // 的样本（statsByBucket 已经滤掉 abandoned 和无档位的）；hit 是探测
        // 命中次数（见 ResumeSampleLog.probeHits）——命中意味着**没有发生
        // 恢复**，不产生样本，所以不能从 statsByBucket() 里读到它，要单独
        // 并进来。按 BackgroundBucket.values 遍历（而不是 statsByBucket()
        // 的 entries）正是为了这个：一个档位可能 0 次真实恢复、全是探测命中
        // （under90s 恰恰是探测最该生效的档位），只看 statsByBucket() 会让
        // 这一档整行消失，命中率就无从读起——这正是 90s 阈值那个赌注要看的
        // 数据。
        //
        // p50 的配色对着验收线：kBannerDelayMs，低于它用户根本看不到
        // 「重新连接中」横幅，也就是「无感」。
        for (final b in BackgroundBucket.values)
          if (resumeStats[b] != null || (probeHits[b] ?? 0) > 0)
            _row([
              _cell(_bucketLabel(b), _grey),
              _cell('n:${resumeStats[b]?.n ?? 0}', _grey),
              _cell(
                  'p50:${resumeStats[b]?.p50 ?? '-'}',
                  (resumeStats[b]?.p50 ?? 0) > kBannerDelayMs
                      ? _red
                      : (resumeStats[b]?.p50 ?? 0) > 500
                          ? _yellow
                          : _grey),
              _cell('p90:${resumeStats[b]?.p90 ?? '-'}', _grey),
              _cell('hit:${probeHits[b] ?? 0}', _grey),
            ]),
        // 不分档的整体视图。**上面那几行盖不住它**：分档只收
        // `backgroundMs != null` 的样本，而真机上大多数恢复是网络切换 /
        // 看门狗触发的（一次实测 45 个样本里 40 个无档位）。少了这一行，
        // 上面那些 `n:1` / `n:4` 的 p50 会被当成整体表现读。
        if (resumeAll != null)
          _row([
            _cell('all', _grey),
            _cell('n:${resumeAll.n}', _grey),
            _cell(
                'p50:${resumeAll.p50}',
                resumeAll.p50 > kBannerDelayMs
                    ? _red
                    : resumeAll.p50 > 500
                        ? _yellow
                        : _grey),
            _cell('p90:${resumeAll.p90}', _grey),
          ]),
        // 五段分解 —— 归因维度。总耗时超标时，这一行直接指出是哪一段吃掉的：
        // dec=决策 rty=重试 hs=握手 tx=传输 ap=应用到终端。
        //
        // 五个数**相加不等于**上面的 p50（每段独立取分位数，见
        // `ResumeSampleLog.segmentStats` 的文档），不要拿它们去对账。
        if (resumeSeg != null)
          _row([
            _cell('seg', _grey),
            _cell('dec:${resumeSeg.decideMs}', _grey),
            _cell('rty:${resumeSeg.retryMs}',
                resumeSeg.retryMs > 0 ? _yellow : _grey),
            _cell('hs:${resumeSeg.handshakeMs}', _grey),
            _cell('tx:${resumeSeg.transferMs}', _grey),
            _cell('ap:${resumeSeg.applyMs}', _grey),
          ]),
      ],
      _row([
        _cell('cur:$cur', _grey),
        _cell(
          'scroll:${t.terminal.isUsingAltBuffer ? "alt" : "pri"}',
          t.terminal.isUsingAltBuffer ? _yellow : _grey,
        ),
        _cell(
          'curVis:${t.terminal.cursorVisibleMode ? "Y" : "N"}',
          t.terminal.cursorVisibleMode ? _green : _yellow,
        ),
      ]),
      // curCell: codepoint hex of the 5 cells around the cursor (-1..+3).
      // Pinpoints which character is rendering as a tofu □ — if any cell
      // shows a high codepoint (e.g. U+E000+ PUA / Nerd Font glyph), the
      // user's font lacks that glyph and the box is a font issue, NOT
      // a byte-stream / RESUME issue. See k2.jpg analysis.
      _row([_cell('curCell:${_formatCellsAroundCursor(t)}', _cyan)]),
      // Slim stability + status row (removed 2026-05-30: rtt/ok#/le/misErr/
      // init flag; restore from git if needed). Keeps mis# and recon since
      // those are the first signs of trouble.
      _row([
        _cell('mis#:${t.networkStability.missedCount}',
            t.networkStability.missedCount > 0 ? _red : _grey),
        _cell('rcOk#:${t.networkStability.reconnectSuccessCount}', _grey),
        _cell('recon:${t.isReconnecting ? 'Y' : 'N'}',
            t.isReconnecting ? _yellow : _grey),
        if (t.connectionError != null)
          _cell(
            'err:${t.connectionError!.length > 24 ? '${t.connectionError!.substring(0, 24)}…' : t.connectionError!}',
            _red,
          ),
      ]),
      // ── Per-category error counts (row 4 / errCnt) ──
      // Only shown when at least one bucket is non-zero. sshCh > 0 alone
      // hints at MaxSessions / half-dead pool client.
      if (t.errorCounts.values.any((v) => v > 0))
        _row([
          _cell('errCnt', _grey),
          _cell('sshCh:${t.errorCounts[ErrCategory.sshChannel]}',
              (t.errorCounts[ErrCategory.sshChannel] ?? 0) > 0 ? _red : _grey),
          _cell('bootTO:${t.errorCounts[ErrCategory.bootTimeout]}',
              (t.errorCounts[ErrCategory.bootTimeout] ?? 0) > 0 ? _red : _grey),
          _cell('quicTO:${t.errorCounts[ErrCategory.quicTimeout]}',
              (t.errorCounts[ErrCategory.quicTimeout] ?? 0) > 0 ? _red : _grey),
          _cell('notInst:${t.errorCounts[ErrCategory.notInstalled]}',
              (t.errorCounts[ErrCategory.notInstalled] ?? 0) > 0 ? _yellow : _grey),
          _cell('dmnFail:${t.errorCounts[ErrCategory.daemonFail]}',
              (t.errorCounts[ErrCategory.daemonFail] ?? 0) > 0 ? _red : _grey),
          _cell('other:${t.errorCounts[ErrCategory.other]}',
              (t.errorCounts[ErrCategory.other] ?? 0) > 0 ? _yellow : _grey),
        ]),
      // 最近一次上报给远端的网格尺寸。
      _row([_cell('grid:${termDebug.gridW}x${termDebug.gridH}', _grey)]),
      // IME 长按退格：
      //   del:cbs/chars = 走文本编辑通道的删除回调数与请求字符数
      //   hold          = 自补重复发出的退格数
      //   gap           = 退格 down→up 间隔(ms)
      // 判读表见 debug_log.dart。
      _row([
        _cell('ime del:${termDebug.imeDelCbs}/${termDebug.imeDelChars}',
            termDebug.imeDelChars > 1 ? _green : _grey),
        _cell('hold:${termDebug.imeHold}',
            termDebug.imeHold > 0 ? _green : _grey),
        _cell('gap:${termDebug.imeKeyGapMs}ms',
            termDebug.imeKeyGapMs == 0
                ? _grey
                : (termDebug.imeKeyGapMs < 80 ? _yellow : _green)),
      ]),
      // ── resize 之后那一波重绘的形状 ──
      //
      // 这一行数的是「屏幕实际被刷了几次」，而「闪一下」的两类根因恰好各自
      // 只在其中一个指标上体现：
      //
      //   rbF:1              重绘一帧原子落地 → 闪不是渲染分帧造成的，
      //                      往 xterm reflow 方向查。
      //   rbF>1 且 rbS 大    逐帧显现，自上而下刷一遍 → 客户端批渲染没兜住。
      //   rbFP>0             32 KB 同步 fast-path 插了队，把一次重绘劈成
      //                      「同步半屏 + 后续帧补完」。inResizeRecovery 只
      //                      护 300 ms，护不到 Ctrl+End 在 600 ms 引发的第二波。
      //
      // rbT 是 resize→首次落屏的延迟（SIGWINCH 往返 + 应用重绘的真实耗时），
      // rbS 是首末落屏的跨度 —— 用户眼里「刷」这个动作持续了多久。
      // 每次 resize 归零，读到的是最近一次的形状，不是累计值。
      _row([
        _cell('rbF:${t.resizeBurstFrames}',
            t.resizeBurstFrames > 1 ? _red : _grey),
        _cell('rbT:${t.resizeBurstFirstMs}', _grey),
        _cell('rbS:${t.resizeBurstLastMs - t.resizeBurstFirstMs}',
            t.resizeBurstLastMs - t.resizeBurstFirstMs > 100 ? _red : _grey),
        _cell('rbB:${t.resizeBurstBytes}', _grey),
        _cell('rbFP:${t.resizeBurstFastPaths}',
            t.resizeBurstFastPaths > 0 ? _red : _grey),
      ]),
      _row([
        _cell(
          'cpMode:${termDebug.tmuxInCopyMode ? "Y" : "N"}',
          termDebug.tmuxInCopyMode ? _yellow : _grey,
        ),
        _cell(
          'sc:${!termDebug.scHasController ? "-" : !termDebug.scHasClients ? "N" : "${termDebug.scOffset.toInt()}/${termDebug.scMaxExtent.toInt()}"}',
          !termDebug.scHasController
              ? _grey
              : !termDebug.scHasClients
                  ? _red
                  : (termDebug.scMaxExtent > 0 ? _green : _yellow),
        ),
      ]),
      // ── Verbose history logs pushed to the BOTTOM (2026-05-30) ──
      // resume_log + recent_esc each occupy 6-15 rows; keeping them at
      // the top crowded out conn/path/res/errCnt on a 78%-height overlay
      // (k5.jpg). Per-frame single-value metrics now stay visible above
      // the fold; users scroll down only when investigating sequences.
      if (t.transport is AqtTransport) ..._buildResumeLog(context),
      ..._buildEscapeLog(t),
      // ── agent per-turn 耗时计量 ──
      //
      // 与上面那两段 verbose log 同区，理由也一样：面板外层是 IgnorePointer
      // 包着的 SingleChildScrollView，手势被全吞、滚不动，排在 0.78×屏高以下
      // 的内容永远看不到。每帧都在变的 single-value 指标必须留在上面，这一段
      // 是「怀疑 agent 慢」时才翻下来看的明细。
      ..._buildAgentMetricLines(mgr),
    ];
  }











  /// Reads a named field from an object via dynamic dispatch.
  static Object? _dynField(Object? obj, String key) {
    if (obj == null) return null;
    final d = obj as dynamic;
    switch (key) {
      case 'moshTuiActive': return d.moshTuiActive as Object?;
      case 'tuiBashLikeFrames': return d.tuiBashLikeFrames as Object?;
      default: return null;
    }
  }

  /// 档位的短标签。overlay 宽度有限，用最短的可辨识写法。
  static String _bucketLabel(BackgroundBucket b) => switch (b) {
        BackgroundBucket.under30s => 'bg<30s',
        BackgroundBucket.under90s => 'bg<90s',
        BackgroundBucket.under3min => 'bg<3m',
        BackgroundBucket.under30min => 'bg<30m',
        BackgroundBucket.over30min => 'bg>30m',
      };

  String _age(int seconds) {
    if (seconds > 1000000) return '--';
    if (seconds >= 3600) return '${seconds ~/ 3600}h';
    if (seconds >= 60) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  /// 最近 3 轮的 agent 耗时计量。空列表 = 这台服务器还没跑过 agent。
  ///
  /// 只显示 3 轮而不是全部：这是能塞进剩余高度的量，而这块面板滚不动
  /// （见 [build] 的 IgnorePointer）。要看完整数据走 AI 面板底部那行用量
  /// —— 开发者模式下它可点，导出整份 JSONL。
  ///
  /// `spec:命中/发起` 这一格是判断抢跑有没有真的生效的唯一信号：分母为 0
  /// 说明这一轮没有任何调用够格抢跑，分子远小于分母则说明判据快照在流式
  /// 期间频繁变化（用户在 cd，或规则被改），抢跑大量落空、白跑两遍。
  List<Widget> _buildAgentMetricLines(AgentSessionManager mgr) {
    final turns = mgr.loopFor(widget.tab.server.id)?.metrics.turns;
    if (turns == null || turns.isEmpty) return const [];
    final recent = turns.length <= 3 ? turns : turns.sublist(turns.length - 3);
    return [
      _row([_cell('─agent─', _cyan)]),
      for (final m in recent)
        _row([
          _cell('T${m.turn}', _grey),
          // 首字延迟是「模型侧到底慢不慢」最直接的一格。3 秒以上标黄 ——
          // 那时候用户已经在盯着空白面板了。
          _cell('ttft:${m.ttftMs}', m.ttftMs > 3000 ? _yellow : _green),
          _cell('str:${m.streamTotalMs}', _grey),
          _cell('tot:${m.turnTotalMs}', _grey),
          _cell('tl:${m.tools.length}', _grey),
          _cell(
            'spec:${m.tools.where((x) => x.speculativeHit).length}'
            '/${m.tools.where((x) => x.speculative).length}',
            m.tools.any((x) => x.speculative) ? _green : _grey,
          ),
          if (m.compactMs > 0) _cell('cmp:${m.compactMs}', _yellow),
          _cell('tok:${m.inputTok}/${m.cachedTok}/${m.outputTok}', _grey),
        ]),
    ];
  }

  Widget _row(List<Widget> cells) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Wrap(spacing: 6, children: cells),
  );

  Widget _cell(String text, [Color? color]) =>
      Text(text, style: color != null ? TextStyle(color: color) : null);

  static const _green = Color(0xFF6A9955);
  static const _yellow = Color(0xFFDCDC7E);
  static const _red = Color(0xFFF44747);
  static const _cyan = Color(0xFF4EC9B0);
  static const _grey = Color(0xFF808080);

  /// First 4 bytes as hex — shows enough to verify token/SPKI identity.
  /// Currently unused (slim overlay 2026-05-30); retained so the
  /// commented-out tok/spki rows above are trivial to revive.
  // ignore: unused_element
  static String _hex4(List<int> bytes) {
    if (bytes.isEmpty) return '[]';
    return bytes.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  /// Currently unused (slim overlay 2026-05-30); see comment on _hex4.
  // ignore: unused_element
  static String _fmtBytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  /// RESUME 发起点日志。与 [_buildResumeLog] 的区别：那个是 ReconnectService
  /// 内部的 verbose 流水（只有服务实例看得到），这个是**全局**的——prewarm 跑在
  /// ReconnectService 构造之前，只能走全局缓冲，而它恰恰是 fix A 要盯的那条路径。
  List<Widget> _buildResumeIssueLog() {
    if (resumeIssueLog.isEmpty) {
      return [_row([_cell('rsm-issue:(empty)', _grey)])];
    }
    const shown = 8;
    final tail = resumeIssueLog.length > shown
        ? resumeIssueLog.sublist(resumeIssueLog.length - shown)
        : resumeIssueLog;
    return [
      _row([
        _cell('── resume issue (${resumeIssueLog.length} tot,'
            ' last ${tail.length}) ──', _grey),
      ]),
      for (final entry in tail)
        _row([_cell(entry,
          // COLD 标黄：并发 cold RESUME 正是要抓的现象，得一眼看见。
          entry.contains('COLD') ? _yellow
            : entry.contains('HELLO(fellback)') ? _red
            : entry.contains('FAIL') || entry.contains('EXC') ? _red
            : entry.contains('OK') ? _green
            : _grey,
        )]),
    ];
  }

  List<Widget> _buildResumeLog(BuildContext context) {
    final svc = context.read<ReconnectService>();
    final log = svc.resumeLog;
    if (log.isEmpty) return [_row([_cell('rsm-log:(empty)', _grey)])];
    final tail = log.length > 5 ? log.sublist(log.length - 5) : log;
    return [
      _row([_cell('── resume log (last 5) ──', _grey)]),
      for (final entry in tail)
        _row([_cell(entry,
          entry.contains('OK') ? _green
            : entry.contains('FAIL') || entry.contains('EXC') ? _red
            : entry.contains('DISC') ? _yellow
            : _grey,
        )]),
    ];
  }

  List<Widget> _buildEscapeLog(SessionTab t) {
    final esc = t.recentEscapes;
    if (esc.isEmpty) return [];
    return [
      _row([_cell('── recent esc (last ${esc.length}) ──', _grey)]),
      for (final e in esc.reversed.take(10))
        _row([_cell(e.length > 60 ? '${e.substring(0, 60)}…' : e, _cyan)]),
    ];
  }

  /// Format the codepoints of the 5 cells around the cursor (cols
  /// cursor-1 to cursor+3) as a single string. Each cell shows either
  /// `..` (col OOB), `00` (empty cell), `'c'` (printable ASCII, single
  /// quote then char), or `Uxxxx` (non-ASCII codepoint hex). The cursor
  /// column itself is wrapped in `[ ]` so it's obvious at a glance.
  String _formatCellsAroundCursor(SessionTab t) {
    final buf = t.terminal.buffer;
    final cy = buf.absoluteCursorY;
    if (cy < 0 || cy >= buf.lines.length) return '-';
    final line = buf.lines[cy];
    final cx = buf.cursorX;
    final width = t.terminal.viewWidth;
    final out = StringBuffer();
    for (var i = -1; i <= 3; i++) {
      if (out.isNotEmpty) out.write(' ');
      final col = cx + i;
      String token;
      if (col < 0 || col >= width) {
        token = '..';
      } else {
        final cp = line.getCodePoint(col);
        if (cp == 0) {
          token = '00';
        } else if (cp >= 0x20 && cp < 0x7f) {
          token = "'${String.fromCharCode(cp)}'";
        } else {
          token = 'U${cp.toRadixString(16).toUpperCase().padLeft(4, '0')}';
        }
      }
      if (i == 0) {
        out.write('[$token]');
      } else {
        out.write(token);
      }
    }
    return out.toString();
  }
}
