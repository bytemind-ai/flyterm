// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../../data/activity_tracker.dart';
import '../../data/terminal_settings.dart';
import '../../ssh/completion_suggestion.dart';
import '../../ssh/local_shell.dart';
import '../../ssh/transport/remote_transport.dart';
import '../../l10n/l10n.dart';
import 'completion_popup.dart';
import 'hold_repeat.dart';
import 'debug_log.dart';
import 'paste_guard.dart';
import 'scroll_correction.dart';
import 'selection_controller.dart';
import 'selection_geometry.dart';
import 'selection_overlay.dart';
import 'terminal_themes.dart';

class TerminalWidget extends StatefulWidget {
  final Terminal terminal;
  // Typed as dynamic to support both SSHSession (plain SSH) and MoshShell (UDP SSP).
  // Both expose the same duck-type interface: stdin, resizeTerminal(), done.
  final dynamic shell;

  /// True when this tab is the one currently visible in the IndexedStack.
  /// Used to re-request focus when the user switches tabs.
  final bool isActive;

  /// True when the session supports copy-mode scroll (e.g. running inside tmux).
  /// Used to choose the correct scroll strategy: copy-mode via exec channel
  /// rather than SGR mouse-wheel via stdin.
  final bool copyModeScroll;

  /// Called to exit copy-mode via exec channel (e.g. `send-keys -X cancel`).
  /// Provide this when copyModeScroll is true. Using an exec channel instead of
  /// sending 'q' through shell stdin prevents the key from leaking to the
  /// foreground app (e.g. Claude CLI) when not actually in copy-mode.
  final Future<void> Function()? onExitScrollMode;

  /// Called once when the user first swipes up and enters copy-mode scroll.
  /// Triggers a backend refresh-client before the first scroll so xterm's model
  /// is up-to-date and no stale CJK residuals appear in the scrollback view.
  final VoidCallback? onRefreshClient;

  /// Scroll up [lines] lines via exec channel.
  /// Replaces SGR `\x1b[<64;1;1M` so events never reach the foreground app.
  final void Function(int lines)? onScrollUp;

  /// Scroll down [lines] lines via exec channel.
  /// Replaces SGR `\x1b[<65;1;1M` so events never reach the foreground app.
  final void Function(int lines)? onScrollDown;

  /// Called with each raw keyboard input string BEFORE it is sent to the shell.
  /// Return true to intercept the input (it will NOT be forwarded to the shell).
  /// Return false (or null) to let the input pass through normally.
  final bool Function(String)? interceptInput;

  /// Called with each raw keyboard input string before it is sent to the shell.
  /// Used by TerminalScreen to track the current input line and detect commands.
  final void Function(String)? onUserInput;

  /// True when this tab is running a mosh (SSP/UDP) connection.
  /// Skips the `tmuxEnterCopyMode` refresh-client call on first scroll because
  /// mosh sends full-frame repaints every ~100ms and self-corrects any residuals,
  /// whereas the extra RTT hurts scroll responsiveness.
  final bool isMosh;

  /// Typed transport — when set, used for capability-based method dispatch.
  /// Non-null for sessions opened via TransportFactory.
  final RemoteTransport? transport;

  /// Called with input that has no destination — both [transport] and [shell]
  /// are null, which is exactly the window ReconnectService opens while it
  /// rebuilds a QUIC session over SSH. The owner buffers these bytes and
  /// replays them once a new transport is installed; without it every
  /// keystroke typed during that 5-25 s window disappears without a trace.
  final void Function(List<int> bytes)? onOrphanedInput;

  /// Heuristic signal that the foreground process is a TUI and should receive
  /// transparent SGR mouse events through tmux.
  final bool remoteTuiHint;

  /// When true, suppresses the automatic requestKeyboard() that fires when this
  /// tab transitions from inactive to active (isActive false → true).
  /// Set by TerminalScreen during a swipe-triggered tab switch so the keyboard
  /// does not pop up on the newly visible tab uninvited.
  final bool suppressKeyboardOnActivation;

  /// External scroll controller so TerminalScreen can programmatically scroll
  /// (e.g. to navigate search hits). If null, TerminalView manages its own.
  final ScrollController? scrollController;

  /// Controls how a tap opens the software keyboard.
  /// [KeyboardTriggerMode.singleTap]: any tap opens the keyboard (default).
  /// [KeyboardTriggerMode.doubleTap]: requires two taps within 350 ms.
  /// [KeyboardTriggerMode.iconButton]: keyboard opened only via KeyBar icon.
  final KeyboardTriggerMode keyboardTriggerMode;

  /// Called when text-selection mode changes.
  /// true = entered selection mode (tab swipe should be disabled).
  /// false = exited selection mode.
  final void Function(bool active)? onSelectionModeChanged;

  /// Returns the current smoothed network RTT for the session, used by the
  /// mosh RTT-paced gate to compute the inter-SGR delay. Null means unknown.
  final Duration? Function()? getNetworkRtt;

  /// Fired on every actual SGR scroll write from `_flushSgr`. The argument
  /// is the number of lines packed into that write. DebugOverlay uses this
  /// to compute the live SGR-per-second rate as proof that the ungated
  /// (Plan A) flush is in effect. Optional — only wired when a debug
  /// overlay or a test wants to observe the rate.
  final void Function(int lines)? onSgrSent;

  /// Fired right after a SIGWINCH-equivalent resize is delivered to the
  /// transport/shell. Receivers (SessionTab) use this to open a 300 ms
  /// "resize recovery" window that suppresses the 32 KB fast-path flush so
  /// the server's full-screen redraw lands atomically in one vsync frame.
  final VoidCallback? onTransportResize;

  /// Active command-completion suggestions, rendered as a floating popup
  /// anchored to the cursor (see [CompletionPopup]). Empty list renders
  /// nothing. TerminalScreen owns the debounce/fetch logic
  /// (`_scheduleCompletion`/`_fetchCompletions`) and passes the current
  /// result down here.
  final List<CompletionSuggestion> completions;

  /// Called when the user taps a suggestion in the completion popup.
  /// The popup only renders when this AND [completions] are non-empty —
  /// TerminalScreen leaves this null for tabs other than the active one.
  final void Function(CompletionSuggestion)? onAcceptCompletion;

  /// The command line typed so far, used by [CompletionPopup] to dim the
  /// prefix of each suggestion that matches what's already been typed.
  final String completionInput;

  const TerminalWidget({
    super.key,
    required this.terminal,
    required this.shell,
    this.isActive = false,
    this.copyModeScroll = false,
    this.isMosh = false,
    this.transport,
    this.onOrphanedInput,
    this.remoteTuiHint = false,
    this.onExitScrollMode,
    this.onRefreshClient,
    this.onScrollUp,
    this.onScrollDown,
    this.interceptInput,
    this.onUserInput,
    this.suppressKeyboardOnActivation = false,
    this.scrollController,
    this.keyboardTriggerMode = KeyboardTriggerMode.singleTap,
    this.onSelectionModeChanged,
    this.getNetworkRtt,
    this.onSgrSent,
    this.onTransportResize,
    this.completions = const [],
    this.onAcceptCompletion,
    this.completionInput = '',
  });

  @override
  State<TerminalWidget> createState() => TerminalWidgetState();
}

enum _SelectionPhase { idle, dragging, active, handleDragging }

enum _HandleSide { begin, end }

class TerminalWidgetState extends State<TerminalWidget>
    with WidgetsBindingObserver {
  final _controller = TerminalController();
  final _terminalViewKey = GlobalKey<TerminalViewState>();

  // Pointer tracking (raw events, bypasses gesture arena).
  final Map<int, Offset> _activePointers = {};

  // Pinch-to-zoom state.
  double _pinchBaseFontSize = 0;
  double _pinchBaseDistance = 0;

  // ViewInset hysteresis: treat any inset ≤ this as "keyboard hidden" for
  // SHOW/HIDE transition detection. 50 px is well below any real keyboard
  // (always ≥ 200 px) but above stray system-bar transient bumps so a brief
  // IME blip doesn't trigger a false hide-transition that would clear the
  // SHOW chain's _pendingKeyboardCtrlEnd.
  static const double _kbHysteresisPx = 50;

  /// True when running on a plain SSH connection (no Mosh, no QUIC transport).
  /// Extracted to avoid the triple-duplicate `!widget.isMosh && widget.transport == null`
  /// across open-fallback / close-fallback / normalize paths.
  bool get _isPureSsh => !widget.isMosh && widget.transport == null;

  // ── 长按退格自重复 ────────────────────────────────────────────────────────
  //
  // 输入法按住退格时走 `sendKeyEvent(KEYCODE_DEL)`，而它的连发用的是
  // `ACTION_MULTIPLE` —— Flutter 引擎的 KeyChannelResponder 只处理
  // ACTION_DOWN/ACTION_UP，其余 action 在进 Dart 之前就被丢掉。于是真机表现
  // 就是“点一下删一个字，按住没反应”。我们自己补：DOWN 之后等 initialDelay
  // 仍无 UP 就开始重复写退格，收到 UP / 任何其它按键 / 真键盘的 repeat 立刻停。
  //
  // 只在收到 KeyDownEvent 时才上膛，所以走 `deleteSurroundingText` 的那条路
  // （根本没有按键事件）永远不会被打双份。
  late final HoldRepeat _holdRepeat = HoldRepeat(onFire: _fireHoldRepeat);

  /// 最近一次退格 KeyDown 的时刻 —— 用于开发者浮层里量 down→up 的间隔。
  DateTime? _imeBackspaceDownAt;

  void _fireHoldRepeat() {
    if (!mounted) return;
    termDebug.imeHold++;
    // 走 terminal.onOutput 而不是 _writeToShell：ActivityTracker、命令历史
    // 累积、mosh 滚动惯性撤销这一整套都挂在 onOutput 上，绕过它们会让
    // “打字退出滚动模式”这条链路失效。
    final seq = widget.terminal.encodeKey(TerminalKey.backspace) ?? '\x7f';
    widget.terminal.onOutput?.call(seq);
  }

  KeyEventResult _onHardwareKey(FocusNode node, KeyEvent event) {
    // 任何非退格键都意味着手指换了目标，立刻收手。
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      _holdRepeat.stop();
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _imeBackspaceDownAt = DateTime.now();
    } else if (event is KeyUpEvent && _imeBackspaceDownAt != null) {
      termDebug.imeKeyGapMs = DateTime.now()
          .difference(_imeBackspaceDownAt!)
          .inMilliseconds;
      _imeBackspaceDownAt = null;
    }
    final consumed = _holdRepeat.handleKeyEvent(event);
    // 按键本身永远交回 xterm 处理（单击/系统重复的语义完全不变）；
    // 只有在 UP 恰好收尾了我们自己补的那串时才吞掉它。
    return consumed ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // Debounce timer for terminal resize — prevents sending dozens of intermediate
  // sizes to the server during keyboard open/close animation (~300 ms).
  Timer? _resizeDebounce;


  // Alt-buffer (tmux) scroll state.
  // We handle this in the Listener because the inner terminal Scrollable wins
  // Flutter's gesture arena even in alt-buffer mode (maxScrollExtent = 0),
  // preventing InfiniteScrollView from ever receiving the drag gesture.
  // The Listener bypasses the arena and always fires on raw pointer events.
  double _scrollAccum = 0;

  // Last known keyboard inset — used to decide whether to dismiss the keyboard
  // on a scroll gesture (only dismiss when keyboard is actually visible).
  double? _prevViewInset;

  // Keyboard-dismiss-on-scroll state.
  // When the user starts a vertical scroll gesture we hide the keyboard so the
  // full terminal area is available for reading history. On a plain tap (no
  // scroll intent detected) we restore the keyboard so the user can type.
  //
  // _pointerDownPos: position at first PointerDown of a single-finger gesture.
  // _scrollIntentDetected: true once the gesture is classified as a scroll
  //   (cumulative dy > 12 px AND dy/dx ratio > 1.5).
  Offset? _pointerDownPos;
  bool _scrollIntentDetected = false;
  // Snapshot of keyboard visibility at the moment the finger touched down.
  // Checked in _onPointerMove to avoid a race with didChangeDependencies.
  bool _keyboardVisibleAtDown = false;
  // Solution B: timestamp of the most recent scroll gesture (set whenever
  // _scrollIntentDetected goes true or scrollByFinalPos fires).  Tap detection
  // is suppressed for _kScrollCooldown after any scroll to prevent the
  // "multi-pass scroll" pattern — finger lifts, replaces, barely moves —
  // from being misclassified as a tap and opening the keyboard.
  DateTime? _lastScrollTime;
  static const _kScrollCooldown = Duration(milliseconds: 350);

  // ── Scroll state: tmux vs non-tmux are tracked separately ─────────────────
  //
  // tmux path uses exec channel (send-keys -X scroll-up/down) — never stdin.
  // _tmuxInCopyMode: true once we've sent at least one scroll-up to tmux.
  // _tmuxScrollOffset: net lines we've scrolled UP (0 = at live view).
  //   Tracked client-side so we know when the user scrolls back to live view.
  //   When offset reaches 0 during a downward scroll, we call exitCopyMode
  //   immediately rather than waiting for a tap — this prevents excess
  //   scroll-down commands from briefly re-entering copy-mode and causing
  //   Claude CLI TUI redraw corruption.
  //   On tap we also call exitCopyMode whenever _tmuxInCopyMode is true,
  //   regardless of isUsingAltBuffer (Claude CLI uses normal buffer).
  bool _tmuxInCopyMode = false;
  int _tmuxScrollOffset = 0;

  // Non-tmux alt-buffer path (vim, less, mosh TUI) uses SGR mouse wheel via stdin.
  // _nonTmuxScrollLines: net upward lines sent; used on tap to send matching
  //   scroll-down SGRs so the app returns to the live output position.
  int _nonTmuxScrollLines = 0;
  // Set when _onPointerUp (tap) pre-emptively sends SGR scroll-down to mosh
  // before the keyboard opens.  _onKeyboardShow checks this to still send
  // Ctrl+End even though _nonTmuxScrollLines has already been zeroed.
  bool _tapSentSgrDown = false;

  // ── SGR wheel scroll: protocol-specific sending + inertia ─────────────────
  //   • SSH: NO gating — each accumulated batch from _onPointerMove writes
  //     immediately. Matches xterm's InfiniteScrollView path for pure SSH
  //     alt-buffer scrolling, which also writes per-line without waiting for
  //     server response. Result: smooth ~60Hz event rate during drag.
  //     (Plan A — fix for "SSH+tmux scroll feels laggier than pure SSH":
  //      the previous response-gated mode batched events into one-per-RTT,
  //      visible as a step-by-step stutter.)
  //   • Mosh: RTT-paced timer between batches. Mosh's UDP transport is
  //     sensitive to burst input, and the SRTT-based interval keeps server
  //     redraw queue at depth 1 without losing responsiveness.
  //   • On finger lift, exit velocity drives an addPostFrameCallback inertia
  //     loop (factor 0.88/frame ≈ 0.5 s to stop) that feeds _flushSgr each frame.
  int _pendingSgrUp = 0;
  int _pendingSgrDown = 0;
  int _sgrCol = 1; // 1-based cell column for SGR events
  int _sgrRow = 1; // 1-based cell row for SGR events
  Timer? _sgrFallback;
  Timer? _delayedTmuxSgrExit;
  bool _sgrInertiaRunning = false;
  double _sgrInertiaVelocity = 0.0; // px per 16 ms frame; negative = scroll up
  double _sgrInertiaAccum = 0.0;
  double _sgrLastLineH = 20.0;
  // Velocity sampling: accumulate pointer moves from the last 80 ms to compute
  // exit speed for inertia.
  final _recentMoves = <({double dy, DateTime time})>[];
  bool _lastUseSgrWheel = false; // whether last gesture used SGR wheel path
  bool _lastSgrWasRemoteTui = false;

  // One-shot guard: KeyboardVisibilty.didChangeMetrics fires on every pixel of
  // keyboard animation (~18× per open).  Without this flag the inTmux branch
  // would send Ctrl+End 18 times per open — first one exits Claude CLI scroll
  // mode, subsequent ones arrive in normal mode and may corrupt the display.
  // Reset when keyboard fully closes (viewInsets.bottom → 0).
  bool _keyboardShowHandled = false;
  // Latched flag: set true on any SHOW transition (inset crosses
  // hysteresis going up), cleared on HIDE. Solves the "stepwise hide"
  // problem where Android IME closes via inset sequence 230→…→30→0 —
  // the final 30→0 frame has prev≤hysteresis so the old `prev > 50`
  // gate skipped HIDE entirely. With this latch, any inset==0 while
  // we've seen a real show counts as HIDE.
  bool _keyboardFullyShown = false;
  bool _pendingKeyboardCtrlEnd = false;
  bool _pendingKeyboardSuppressEcho = false;
  /// Sticky timestamp tracking when a TUI/alt-buffer state was last observed.
  /// Claude (and other TUIs) briefly drop alt-buffer during SIGWINCH-driven
  /// redraws — if the close-fallback timer fires exactly during that window,
  /// `widget.terminal.isUsingAltBuffer` reads false and the Ctrl+End +
  /// refresh-client chain is skipped (f13.jpg: closeSkip cms=N tui=N hint=N
  /// alt=N while the very next frame shows alt=Y). Treating any state
  /// observed within the last 5 s as still-in-TUI eliminates this race.
  DateTime? _lastTuiObservedAt;
  Timer? _keyboardNormalizeTimer;
  // Symmetric fallback for keyboard hide: when the keyboard fully closes,
  // xterm's onResize may not fire on the final padding-animation frame
  // (the 220 ms easeOutCubic curve and Flutter's frame schedule sometimes
  // produce a tail of pixel-level changes that don't cross a cell boundary
  // → Terminal.rows stays unchanged → no notification). Without an explicit
  // post-animation resize, the shell continues serving the smaller (with-
  // keyboard) viewport and OpenCode/Claude renders into the upper portion
  // while the newly-exposed rows stay blank.
  Timer? _keyboardCloseResizeTimer;
  // Mirror of _keyboardCloseResizeTimer for the SHOW path. Same root cause:
  // xterm.onResize is gated on cell-count change, so when keyboardInset
  // shrinks the viewport by < 1 cellHeight (typical in landscape / large
  // font), the SHOW path's whole Ctrl+End + refresh-client chain is skipped
  // and the TUI input box stays at the old (now hidden) bottom row.
  Timer? _keyboardOpenResizeTimer;
  // Pinch watchdog: if pointerUp gets dropped (multi-touch confused, view
  // unmount mid-pinch), _pinchBaseDistance > 0 sticks forever and silently
  // suppresses every subsequent onResize. This timer force-clears it after
  // 3 s of no pointer activity.
  Timer? _pinchWatchdog;

  // vsync-rate throttle for tmux copy-mode scroll: accumulate lines between
  // frames and flush once per frame via addPostFrameCallback. Without this, a
  // fast scroll gesture opens 30–60 exec channels per second.
  int _pendingScrollUp = 0;
  int _pendingScrollDown = 0;
  bool _scrollFlushScheduled = false;

  // True when the user first enters copy-mode this gesture sequence.
  // Triggers tmuxEnterCopyMode before the first scroll command so xterm's
  // model gets a full repaint (clearing stale CJK residuals) before the
  // copy-mode view is rendered.
  bool _needsCopyModeRefresh = false;
  // Adaptive refresh: during fast scrolling (>_kFastScrollThreshold lines/frame)
  // we alternate between sending and skipping the post-scroll refresh-client
  // call, halving SSH bandwidth while keeping residuals imperceptible.
  // Reset to false whenever copy-mode is exited so the next entry always starts
  // with a refresh on the first frame.
  bool _skipRefreshNextFlush = false;
  static const _kFastScrollThreshold = 10;

  // Last tap timestamp for double-tap keyboard trigger mode.
  DateTime? _lastTapTime;

  // ── Long-press menu state ───────────────────────────────────────────────────
  Timer? _longPressTimer;
  Offset? _longPressPosition;

  /// Non-null while the long-press menu is showing; the value is the finger
  /// position in Stack-local coordinates, used as the menu's anchor.
  Offset? _longPressMenuAt;

  /// Set when a gesture showed or dismissed the long-press menu, so the
  /// matching pointer-up is not also treated as a tap (which would open the
  /// keyboard and resize the layout out from under the menu).
  bool _suppressTapAfterMenu = false;

  // ── Text selection ──────────────────────────────────────────────────────────
  /// The single source of truth for the selection. Not `final`: it is bound to
  /// a specific [Terminal] at construction time, so a tab whose terminal object
  /// is swapped underneath it (see [didUpdateWidget]) needs a fresh one —
  /// otherwise the next `selectWordAt` would build anchors in the old buffer.
  late TerminalSelectionController _selection;

  /// Whether the selection overlay (handles + Copy toolbar) is on screen right
  /// now. Read live by TerminalScreen through the widget's GlobalKey.
  ///
  /// `_selection.isActive` is a *computed* property — an anchor detaching or
  /// the buffer switching makes it flip to false without any notification. So
  /// the `onSelectionModeChanged` mirror TerminalScreen keeps can go stale
  /// mid-gesture; this getter cannot.
  bool get isSelectionActive => _selection.isActive;

  /// Handle positions. Updated every frame while dragging, and drives ONLY the
  /// overlay's own repaint — not a full TerminalWidget rebuild.
  final _handlePositions = ValueNotifier<HandlePositions>(HandlePositions.zero);

  /// Which end is being dragged; null = not dragging.
  HandleHit? _draggingHandle;

  /// Difference between the handle anchor and the finger at the moment of
  /// touch-down. See selection_geometry.dart — without it the handle teleports
  /// to the finger the instant it is grabbed.
  Offset _grabOffset = Offset.zero;

  /// Whether the lifted touch point is currently flipped BELOW the finger
  /// (hysteresis state for [liftedTouchPoint]).
  bool _liftFlipped = false;

  /// True when a handle-position refresh is already queued for this frame.
  bool _handleFrameScheduled = false;

  /// Pixel rect of the cursor cell, in this widget's own Stack-local
  /// coordinates. Feeds [CompletionPopup]'s anchor. A ValueNotifier (like
  /// [_handlePositions]) so recomputing it only rebuilds the popup, not the
  /// whole TerminalView subtree.
  final _completionAnchor = ValueNotifier<Rect?>(null);

  /// True when a completion-anchor refresh is already queued for this frame.
  bool _completionAnchorFrameScheduled = false;

  /// True once the user scrolls the terminal while a completion popup is
  /// showing. See [_onCompletionScroll].
  bool _completionHiddenByScroll = false;

  /// Guards the first pointer-up after entering selection mode so it does not
  /// immediately dismiss the selection again. Selection is entered from the
  /// long-press menu, whose own pointer-up can still be in flight.
  bool _suppressTapDismiss = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wireInput();
    widget.terminal.addListener(_onTerminalChanged);
    _selection = TerminalSelectionController(widget.terminal, _controller);
    _selection.addListener(_onSelectionChanged);
    widget.scrollController?.addListener(_onScrollUpdateHandles);
    widget.scrollController?.addListener(_onCompletionScroll);
    if (widget.completions.isNotEmpty) _scheduleCompletionAnchorSync();
    // Restore the mosh watchdog foreground state on (re-)mount so that tabs
    // coming back after a HomeScreen round-trip have the correct suppression.
    _setForeground(widget.shell, widget.isActive);
    if (widget.isActive) {
      // Immediately ACK the server so it delivers the latest state within
      // 1 RTT instead of waiting up to 3 s for the next scheduled heartbeat.
      _shellHeartbeat();
      // Auto-open keyboard on first activation unless a TUI (Claude CLI, vim,
      // htop…) is already running — in that case the keyboard would cover the
      // TUI output. iconButton mode: always user-controlled.
      if (widget.keyboardTriggerMode != KeyboardTriggerMode.iconButton &&
          !_isTuiActive()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _terminalViewKey.currentState?.requestKeyboard();
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _processViewInsetChange(MediaQuery.of(context).viewInsets.bottom);
  }

  /// Process a new keyboard-inset value from either side:
  ///   • [didChangeDependencies] — MediaQuery path (normal Flutter route)
  ///   • [didChangeMetrics] — PlatformDispatcher.onMetricsChanged direct path
  /// Idempotent: short-circuits when [inset] equals the last seen value, so
  /// duplicate invocations from both sources are safe.
  void _processViewInsetChange(double inset) {
    final prev = _prevViewInset ?? 0;
    // Latch — both observers (didChangeDependencies + didChangeMetrics) hit
    // the same transition; bail when there's no real change.
    if ((inset - prev).abs() < 0.5) return;

    // ── Keyboard SHOW transition: inset 0 → > kbHysteresisPx ────────────────
    // Re-arm _keyboardShowHandled here (not only on full hide) so that a
    // keyboard that briefly toggled (IME flicker, split-screen rotate,
    // SnackBar focus change) without going fully back to 0 still gets a
    // chance to run _onKeyboardShow's Ctrl+End + refresh-client chain on the
    // next show.
    if (prev <= _kbHysteresisPx && inset > _kbHysteresisPx) {
      _keyboardFullyShown = true;
      _keyboardShowHandled = false;
      // Capture TUI state at kb show — used by close-fallback to override
      // transient "alt=N" readings caused by Claude's mid-redraw state.
      if (widget.terminal.isUsingAltBuffer || widget.remoteTuiHint) {
        _lastTuiObservedAt = DateTime.now();
      }
      // Fallback resize timer for the SHOW path. Same root cause as the
      // _keyboardCloseResizeTimer (hide path): xterm.onResize is gated on
      // cell-count change, so a small inset that doesn't cross a cell
      // boundary leaves the chain dangling. After 300 ms force a resize and
      // a Ctrl+End + tmux refresh-client so the TUI input box reaches the
      // new bottom even when onResize silently skipped.
      _keyboardOpenResizeTimer?.cancel();
      _keyboardOpenResizeTimer = Timer(
        const Duration(milliseconds: 300),
        () {
          if (!mounted) return;
          final w = widget.terminal.viewWidth;
          final h = widget.terminal.viewHeight;
          if (w <= 0 || h <= 0) return;
          // Symmetric with debounce→cancel-open-timer (line ~1068): if the
          // fallback fires first, cancel any pending onResize debounce so
          // _shellResize isn't called a second time ~60 ms later. SSH+bash
          // would otherwise receive two SIGWINCH back-to-back, causing bash
          // to redraw its prompt twice (visible as keyboard show/hide flicker).
          _resizeDebounce?.cancel();
          _resizeDebounce = null;
          _shellResize(w, h);
          final tui = _isTuiActive();
          if (widget.copyModeScroll && (tui || widget.remoteTuiHint)) {
            // BUG-1 fix: clear the normalize pending flag and cancel the
            // normalize timer before sending. Without this, if _onKeyboardShow
            // runs slightly late (>80 ms after the SHOW transition) it schedules
            // a normalize timer that fires AFTER this open-fallback already sent
            // Ctrl+End — resulting in a second Ctrl+End reaching the TUI.
            _pendingKeyboardCtrlEnd = false;
            _pendingKeyboardSuppressEcho = false;
            _keyboardNormalizeTimer?.cancel();
            _keyboardNormalizeTimer = null;
            if (widget.isMosh) _shellSuppressNextLocalEcho();
            _writeToShell('\x1b[1;5F');
            if (!_isPureSsh) widget.onRefreshClient?.call();
          } else if ((widget.terminal.isUsingAltBuffer ||
                  widget.remoteTuiHint) &&
              // Non-tmux TUI fallback (alt-buffer OR remoteTuiHint).
              // OPT-2: guard with _pendingKeyboardCtrlEnd — if normalize timer
              // already fired (cleared the flag) before this 300 ms fallback,
              // don't send a second Ctrl+End.
              _pendingKeyboardCtrlEnd) {
            _pendingKeyboardCtrlEnd = false;
            _pendingKeyboardSuppressEcho = false;
            _keyboardNormalizeTimer?.cancel();
            _keyboardNormalizeTimer = null;
            _writeToShell('\x1b[1;5F');
          }
        },
      );
    }

    // ── Keyboard HIDE transition: inset → 0 with latched _keyboardFullyShown ──
    // The earlier hysteresis-only check (`prev > kbHysteresisPx`) missed
    // stepwise close animations on Android, where the final frame before
    // inset==0 may be small (e.g. 30→0 or 5→0). hmH counter went up by 10
    // in a single session for an a6.jpg user; close-fallback timer never
    // got armed so no Ctrl+End was emitted on keyboard dismissal.
    //
    // New gate: HIDE fires whenever inset reaches 0 AND we previously saw
    // a real SHOW transition. The latch is cleared here, so the next SHOW
    // must re-arm it. IME-flicker mid-show (rare on modern Android) now
    // produces a transient HIDE+SHOW pair instead of being silently
    // suppressed — acceptable trade-off for fixing the common stepwise-
    // close miss.
    if (inset == 0 && _keyboardFullyShown) {
      _keyboardFullyShown = false;
      _keyboardShowHandled = false;
      _tapSentSgrDown = false;
      _pendingKeyboardCtrlEnd = false;
      _pendingKeyboardSuppressEcho = false;
      _keyboardNormalizeTimer?.cancel();
      _keyboardNormalizeTimer = null;
      _keyboardOpenResizeTimer?.cancel();
      _keyboardOpenResizeTimer = null;
      // Schedule a redundant resize after the padding animation settles.
      // _KeyboardAwareBody uses a 220 ms easeOutCubic; wait 300 ms so the
      // last animation frame has rendered and xterm.Terminal.viewHeight
      // reflects the now-full viewport. If xterm did fire onResize at the
      // end, this is a no-op (same dimensions). If it didn't, this catches
      // the missed resize so the foreground TUI gets SIGWINCH and reflows.
      // Only schedule the close-fallback if no timer is already running.
      // Android IME animation often emits rapid inset bounces (e.g.
      // 350→0→60→0 within < 300 ms). With the old cancel+reschedule logic
      // the timer kept getting pushed back and NEVER fired (b4.jpg: cT:0,
      // close-fallback never ran, TUI permanently stuck at keyboard-open
      // viewport). The SHOW block above already cancels this timer when the
      // keyboard re-opens for real, so we don't need to cancel here.
      // Only schedule if no close-timer is already running. IME animations
      // emit rapid inset bounces (e.g. 350→0→60→0 many times). With
      // cancel+reschedule the timer was perpetually deferred and never fired
      // (b4.jpg: cT:0). ??= lets the FIRST HIDE schedule the timer and
      // subsequent HIDE bounces skip it.
      //
      // We do NOT cancel this timer in the SHOW block. Cancelling in SHOW
      // just perpetuates the same problem when there are many SHOW/HIDE
      // bounces (b6.jpg: gS:223 ≈ 12 bounces, still cT:0). Instead the
      // timer callback checks _keyboardFullyShown at fire time: if the
      // keyboard re-opened before 300 ms elapsed, skip the resize (keyboard
      // is open → viewHeight is reduced, sending that to server is wrong).
      _keyboardCloseResizeTimer ??= Timer(
        const Duration(milliseconds: 300),
        () {
          // BUG-2 fix: null the variable AFTER all work (not at the start).
          // Nulling early lets a HIDE bounce racing on the same event-loop turn
          // see null and schedule a second timer — two close-fallbacks could
          // both send Ctrl+End. Delaying the null until the end keeps ??= valid
          // throughout the callback body and prevents spurious re-scheduling.
          if (!mounted) return;
          // Keyboard re-opened before the 300 ms window elapsed. viewHeight
          // would reflect the keyboard-reduced size; sending that to the
          // server would undo the TUI's position. Bail out — when this
          // keyboard show eventually hides, a new close-timer will fire.
          if (_keyboardFullyShown) return;
          final w = widget.terminal.viewWidth;
          final h = widget.terminal.viewHeight;
          if (w <= 0 || h <= 0) return;
          // Same race-mitigation as the open path: cancel pending onResize
          // debounce so SSH+bash doesn't get two SIGWINCH back-to-back on
          // keyboard hide (which would cause prompt to redraw twice).
          _resizeDebounce?.cancel();
          _resizeDebounce = null;
          _shellResize(w, h);
          // Mirror of _onKeyboardShow: when viewport grows after keyboard
          // dismissal, TUIs (Claude/vim/less) need a Ctrl+End to re-anchor at
          // the new bottom. Without it, the prompt stays at the row it
          // occupied when keyboard was open; newly-exposed rows below stay
          // blank.
          //
          // Same gating as _onKeyboardShow:
          //   • tmux + TUI: send Ctrl+End (Claude lives in tmux pane)
          //   • non-tmux alt-buffer: send Ctrl+End (vim/less direct)
          // Plain bash/zsh in tmux: skip — readline handles cursor itself,
          // adding Ctrl+End would cause flicker without benefit.
          final tui = _isTuiActive();
          if (tui || widget.terminal.isUsingAltBuffer ||
              widget.remoteTuiHint) {
            _lastTuiObservedAt = DateTime.now();
          }
          // Sticky TUI: Claude/Vim/etc. briefly drop alt-buffer during
          // SIGWINCH-driven redraws. close-fallback can fire exactly in
          // that race window and read alt=N even though we're squarely
          // in a TUI session (f13.jpg: cms=N tui=N hint=N alt=N at fire
          // time but mux:tmux + alt:Y in the very next frame). Treating
          // any TUI state observed within the last 5 s as still-in-TUI
          // closes the race without affecting non-TUI shells.
          final stickyTui = _lastTuiObservedAt != null &&
              DateTime.now().difference(_lastTuiObservedAt!) <
                  const Duration(seconds: 5);
          final inTuiCheck = tui || widget.remoteTuiHint || stickyTui;
          final inAltCheck = widget.terminal.isUsingAltBuffer ||
              widget.remoteTuiHint || stickyTui;
          if (widget.copyModeScroll && inTuiCheck) {
            // 对称 open-fallback（L449-452）：发 Ctrl+End 前清 pending 标志
            // 并取消 normalize timer。否则同一次 HIDE 周期里，close-fallback
            // 300ms 后发了一次 Ctrl+End，normalize timer 600ms 后又发一次
            // → ce 计数翻倍 + 双重 refresh-client → 视觉上 TUI 反复跳到底
            // 再被拉回 + line-by-line wipe（c1.jpg ce:19 / nrm:11）。
            _pendingKeyboardCtrlEnd = false;
            _pendingKeyboardSuppressEcho = false;
            _keyboardNormalizeTimer?.cancel();
            _keyboardNormalizeTimer = null;
            if (widget.isMosh) _shellSuppressNextLocalEcho();
            _writeToShell('\x1b[1;5F');
            // tmux refresh-client: force pane redraw so the TUI prompt
            // lands at the new bottom row immediately. SSH window-change
            // + tmux SIGWINCH alone leave a window where Claude's input
            // box stays drawn at the old row until the app itself
            // schedules a redraw. See _runKeyboardCtrlEndNormalize.
            //
            // SSH-flicker mitigation: skip refresh-client for pure SSH
            // (TUI's own SIGWINCH redraw is sufficient; refresh-client's
            // retransmit causes visible line-by-line wipe on xterm).
            if (!_isPureSsh) widget.onRefreshClient?.call();
          } else if (inAltCheck) {
            // Non-tmux TUI (alt-buffer or remoteTuiHint): send Ctrl+End so
            // the TUI re-anchors at the new larger bottom after keyboard
            // dismissal.  _scheduleKeyboardCtrlEndAfterResize only fires for
            // tmux; for non-tmux the close-fallback is the sole mechanism.
            // 同上：清 pending + cancel normalize，避免双发 Ctrl+End。
            _pendingKeyboardCtrlEnd = false;
            _pendingKeyboardSuppressEcho = false;
            _keyboardNormalizeTimer?.cancel();
            _keyboardNormalizeTimer = null;
            _writeToShell('\x1b[1;5F');
          }
          // Null at the end so ??= was valid throughout the callback.
          _keyboardCloseResizeTimer = null;
        },
      );
    }
    // Track keyboard inset so _onPointerMove can decide whether to dismiss it.
    _prevViewInset = inset;
  }

  @override
  void didUpdateWidget(TerminalWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.terminal != oldWidget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
      // The selection controller is bound to one Terminal for its whole life
      // (it creates anchors in that terminal's buffer), so it has to be
      // replaced wholesale rather than kept and re-pointed.
      final wasActive = _selection.isActive;
      _selection.removeListener(_onSelectionChanged);
      _selection.clear();
      _selection.dispose();
      _selection = TerminalSelectionController(widget.terminal, _controller);
      _selection.addListener(_onSelectionChanged);
      _handlePositions.value = HandlePositions.zero;
      _draggingHandle = null;
      _liftFlipped = false;
      if (wasActive) widget.onSelectionModeChanged?.call(false);
    }
    if (widget.scrollController != oldWidget.scrollController) {
      oldWidget.scrollController?.removeListener(_onScrollUpdateHandles);
      widget.scrollController?.addListener(_onScrollUpdateHandles);
      oldWidget.scrollController?.removeListener(_onCompletionScroll);
      widget.scrollController?.addListener(_onCompletionScroll);
    }
    if (!identical(widget.completions, oldWidget.completions)) {
      _completionHiddenByScroll = false;
      if (widget.completions.isNotEmpty) {
        _scheduleCompletionAnchorSync();
      } else {
        _completionAnchor.value = null;
      }
    }
    // QUIC reconnect: transport changes but shell stays null, so the shell-change
    // block below never fires.  Reset all scroll/SGR state so stale values from
    // the previous Claude Code session (e.g. _nonTmuxScrollLines > 0,
    // _lastUseSgrWheel = true) don't send garbled SGR mouse events to the new
    // bash session when the user types.
    if (widget.transport != oldWidget.transport) {
      _scrollAccum = 0;
      _nonTmuxScrollLines = 0;
      _pendingScrollUp = 0;
      _pendingScrollDown = 0;
      _pendingSgrUp = 0;
      _pendingSgrDown = 0;
      _sgrInertiaRunning = false;
      _sgrFallback?.cancel();
      _lastUseSgrWheel = false;
      _lastSgrWasRemoteTui = false;
      _recentMoves.clear();
      // Menu anchor (and the tap it captured) refer to the pre-reconnect
      // buffer/layout; a stale menu here would apply _enterSelectionMode's
      // position against the post-reconnect buffer. QUIC reconnect changes
      // transport but not shell, so this block — not the shell-change block
      // below — is what fires for it.
      _longPressMenuAt = null;
      _suppressTapAfterMenu = false;
      // Send current terminal size to the new QUIC transport immediately.
      // For QUIC, widget.shell is always null so the shell-change block
      // below never fires — the resize must be sent here instead.
      // xterm.viewWidth/Height already reflect the keyboard-reduced size
      // (if keyboard is open), so this sends the CORRECT current size.
      // Without this, after RESUME the server keeps using the pre-RESUME
      // size (e.g. full-screen 74×46) even when the keyboard is visible,
      // leaving the viewport 32 rows too tall (e.jpg symptom).
      final w = widget.terminal.viewWidth;
      final h = widget.terminal.viewHeight;
      if (w > 0 && h > 0) _shellResize(w, h);
      // OPT-3: after RESUME, if a TUI is running and the keyboard is hidden,
      // send Ctrl+End so the TUI re-anchors to the bottom of the full viewport.
      // Without this, Claude Code / vim can stay at a stale cursor position
      // until the user manually triggers a redraw.
      final kbHidden = (_prevViewInset ?? 0) <= _kbHysteresisPx;
      if (kbHidden &&
          (widget.terminal.isUsingAltBuffer || widget.remoteTuiHint)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _writeToShell('\x1b[1;5F');
        });
      }
    }
    if (widget.shell != oldWidget.shell) {
      _wireInput();
      // Send current terminal size to the new shell immediately.  onResize
      // only fires when the dimensions *change*; if the phone orientation
      // didn't change between connections the callback stays silent and the
      // new server session would never learn the correct size.
      final w = widget.terminal.viewWidth;
      final h = widget.terminal.viewHeight;
      if (w > 0 && h > 0) _shellResize(w, h);
      // Inform old shell it has left the foreground; new shell inherits the
      // current tab visibility so the watchdog activates immediately if visible.
      _setForeground(oldWidget.shell, false);
      _setForeground(widget.shell, widget.isActive);
      // Keyboard is NOT auto-reopened on reconnect. If the keyboard was open
      // before the reconnect, the kbAlreadyOpen path below re-attaches it when
      // isActive fires; otherwise the user opens it explicitly.
      // New shell (reconnect) — clear all gesture/scroll state so stale
      // sequences aren't sent to the new bash session before tmux attaches.
      _scrollAccum = 0;
      _activePointers.clear();
      _pinchBaseDistance = 0;
      _pointerDownPos = null;
      _scrollIntentDetected = false;
      _lastScrollTime = null;
      _tmuxInCopyMode = false;
      _tmuxScrollOffset = 0;
      termDebug.tmuxInCopyMode = false;
      _needsCopyModeRefresh = false;
      _skipRefreshNextFlush = false;
      _nonTmuxScrollLines = 0;
      _pendingScrollUp = 0;
      _pendingScrollDown = 0;
      _scrollFlushScheduled = false;
      _pendingSgrUp = 0;
      _pendingSgrDown = 0;
      _sgrFallback?.cancel();
      _sgrInertiaRunning = false;
      _pendingKeyboardCtrlEnd = false;
      _pendingKeyboardSuppressEcho = false;
      _keyboardNormalizeTimer?.cancel();
      _keyboardNormalizeTimer = null;
      _recentMoves.clear();
      _lastUseSgrWheel = false;
      _lastSgrWasRemoteTui = false;
      _lastTapTime = null;
      _exitSelectionMode();
      _longPressTimer?.cancel();
      _longPressTimer = null;
      // Same staleness concern as the QUIC transport-change block above —
      // this is the other reconnect path (shell object itself changes).
      _longPressMenuAt = null;
      _suppressTapAfterMenu = false;
    }
    // Tab became active — re-establish keyboard so typing works immediately
    // without requiring a tap. Using a post-frame callback because IndexedStack's
    // Offstage/onstage transition completes after the current build.
    if (widget.isActive != oldWidget.isActive) {
      _setForeground(widget.shell, widget.isActive);
      _lastTapTime = null;
      if (widget.isActive) {
        // Immediately ACK so the server learns our current _recvSeq before
        // sending the next diff.  Without this, the server may send D(stale→new)
        // against a base state the terminal no longer has → garbled output.
        _shellHeartbeat();
      }
    }
    if (widget.isActive && !oldWidget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final kbAlreadyOpen = MediaQuery.of(context).viewInsets.bottom > 10;
        // If keyboard was already visible (e.g. typing while swiping tabs),
        // re-attach IME regardless of mode so input keeps working.
        if (kbAlreadyOpen) {
          _terminalViewKey.currentState?.requestKeyboard();
          return;
        }
        // Swipe switch: never auto-open.
        if (widget.suppressKeyboardOnActivation) return;
        // TUI active (Claude CLI, vim, htop…): keyboard would cover output.
        // _isTuiActive covers both SSH alt-buffer and mosh (which strips the
        // alt-buffer escape but exposes moshTuiActive from cursor-hide events).
        if (_isTuiActive()) return;
        // iconButton mode: keyboard controlled via icon only.
        if (widget.keyboardTriggerMode != KeyboardTriggerMode.iconButton) {
          _terminalViewKey.currentState?.requestKeyboard();
        }
      });
    }
  }

  /// True when the session supports local echo prediction.
  /// Derived from transport capabilities when available; falls back to isMosh.
  bool get supportsLocalEcho =>
      widget.transport?.capabilities.contains(
        TransportCapability.localEchoPrediction,
      ) ??
      widget.isMosh;

  /// Route heartbeat to transport when present, otherwise to legacy shell.
  void _shellHeartbeat() {
    widget.transport?.heartbeat();
    if (widget.transport == null) {
      try {
        widget.shell?.heartbeat();
      } catch (_) {}
    }
  }

  /// Route resize to transport when present, otherwise to legacy shell.
  void _shellResize(int w, int h) {
    widget.transport?.resize(w, h);
    // Always call shell.resizeTerminal regardless of transport presence.
    // After SSH reconnect, tab.transport is an SshTransport whose
    // _session is the channel opened by SshTransportFactory.reconnect,
    // which differs from t.connection.shell (opened by the main
    // reconnect flow). Without this unconditional call, the actual
    // running shell (with the tmux / TUI) never receives SIGWINCH and
    // the viewport stays permanently at the pre-resize size (b1.jpg).
    // For QUIC/Mosh, shell is null so the call is a no-op.
    widget.shell?.resizeTerminal(w, h);
    termDebug.gridW = w;
    termDebug.gridH = h;
    // Notify session so it can open a brief vsync-batching window for the
    // SIGWINCH-triggered server redraw (avoids "top-to-bottom" chunk reveal).
    widget.onTransportResize?.call();

    // Proactive viewport correction: after a resize event (keyboard
    // show/hide), xterm.dart can leave scrollPixels pointing into a
    // scrollback region that the new viewport height makes invalid.
    // The reactive fix at _enterSelection (~line 2117) corrects this
    // only when the user starts a selection — too late for h.jpg
    // (visible multi-prompt residue until tap). Schedule the same
    // correction for the next layout pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sc = widget.scrollController;
      if (sc == null || !sc.hasClients) return;
      if (ScrollCorrection.shouldResetAfterResize(
        offset: sc.offset,
        lineCount: widget.terminal.buffer.lines.length,
        viewHeight: widget.terminal.viewHeight,
      )) {
        sc.jumpTo(0);
      }
    });
  }

  /// Suppress next local echo — only when the session supports local echo prediction.
  void _shellSuppressNextLocalEcho() {
    if (!supportsLocalEcho) return;
    widget.transport?.suppressNextLocalEcho();
    if (widget.transport == null) {
      try {
        widget.shell?.suppressNextLocalEcho();
      } catch (_) {}
    }
  }

  /// Call setForeground on [shell] if it supports it (i.e. MoshShell).
  /// Uses dynamic dispatch so SSH shells (which have no watchdog) are silently skipped.
  void _setForeground(dynamic shell, bool active) {
    widget.transport?.setForeground(active);
    try {
      shell?.setForeground(active);
    } catch (_) {}
  }

  /// Returns true when a TUI app is currently running in the terminal.
  /// For SSH sessions this is isUsingAltBuffer (\x1b[?1049h); for mosh
  /// sessions alt-buffer is always false (mosh strips the escape), so we
  /// fall back to moshTuiActive (\x1b[?25l cursor-hide detection in the
  /// SSP transport — covers both tmux and non-tmux mosh).
  bool _isTuiActive() {
    if (widget.terminal.isUsingAltBuffer) return true;
    if (widget.isMosh) {
      final tuiActive =
          widget.transport?.metrics.extra['moshTuiActive'] as bool?;
      if (tuiActive != null) return tuiActive;
      try {
        return (widget.shell?.moshTuiActive as bool?) ?? false;
      } catch (_) {}
    }
    return false;
  }

  /// Called by TerminalView when the soft keyboard becomes visible.
  /// Ensures the terminal is at its live bottom so the user sees current output.
  ///
  /// inTmux: exitTmuxCopyMode (control pipe) and Ctrl+End (PTY stdin) are
  ///   independent channels — copy-mode only intercepts tmux-client keyboard
  ///   events, not PTY stdin.  Do both:
  ///   • exitTmuxCopyMode → no-op if not in copy-mode; exits it if active
  ///     (main-buffer scroll case).
  ///   • Ctrl+End via stdin → reaches Claude Code (alt-buffer scroll case);
  ///     harmless to bash (readline ignores it).
  ///
  /// mosh: isUsingAltBuffer is always false (mosh strips alt-buffer escapes),
  ///   so fall back to widget.isMosh as the signal.
  void _onKeyboardShow() {
    if (widget.copyModeScroll) {
      // One-shot guard: KeyboardVisibilty fires on every frame of the keyboard
      // animation (~18×).  Without this, 18 Ctrl+End events reach Claude CLI:
      // the first exits scroll mode, subsequent ones arrive in normal input mode
      // and may corrupt the display (e.g. readline treats Ctrl+End as end-of-
      // line, causing cursor jumps that interleave with Claude CLI's repaint).
      if (_keyboardShowHandled) {
        return;
      }
      _keyboardShowHandled = true;
      // Cancel any in-flight SGR scroll state before requesting live view.
      _sgrInertiaRunning = false;
      _sgrFallback?.cancel();
      _pendingSgrUp = 0;
      _pendingSgrDown = 0;
      final wasScrolled = _nonTmuxScrollLines > 0;
      _nonTmuxScrollLines = 0;
      if (_isTuiActive() || widget.remoteTuiHint) {
        // Claude/OpenCode/vim/less in tmux need Ctrl+End after keyboard-induced
        // resize to keep the TUI viewport anchored at the bottom. Send it after
        // resize settles (see onResize debounce), not immediately on keyboard
        // show. Do not refresh tmux here; tmux is just a transparent router.
        if (_tmuxInCopyMode || _tmuxScrollOffset > 0) {
          widget.onExitScrollMode?.call();
        }
        // Eager Ctrl+End is a mosh-specific optimization: v2 mosh flushes
        // resize on the same tick (connection.dart _sendCurrentDiff), and
        // if the server reflows while Claude is still in its scrollback
        // view the bottom rows get pushed off-screen (e19.jpg). SSH paths
        // don't share that timing — the eager byte just arrives at the
        // OLD viewport size and can briefly anchor Claude to the
        // soon-to-be-stale bottom row, which is exactly the "input box
        // didn't move above the keyboard" symptom for ssh+tmux. Gate
        // eager send on mosh and rely on _requestKeyboardCtrlEndAfterResize
        // (which fires after onResize + 300 ms) for ssh+tmux.
        if (wasScrolled) _shellSuppressNextLocalEcho();
        if (widget.isMosh) _writeToShell('\x1b[1;5F');
        _requestKeyboardCtrlEndAfterResize(
          suppressEcho: widget.isMosh && wasScrolled,
        );
      } else {
        // Plain tmux shell (bash/zsh/fish): keyboard show/hide only needs the
        // normal PTY resize. Avoid unconditional refresh-client and Ctrl+End;
        // both cause an extra remote redraw and visible flicker.
        if (_tmuxInCopyMode || _tmuxScrollOffset > 0) {
          widget.onExitScrollMode?.call();
        }
      }
    } else if (widget.terminal.isUsingAltBuffer || widget.remoteTuiHint) {
      // Non-tmux alt-buffer TUI (e.g. claude on QUIC direct, mux:off).
      // Two race-mitigations vs the legacy `isUsingAltBuffer`-only gate:
      //
      // 1. `remoteTuiHint` fallback: xterm-dart parses ?1049h
      //    asynchronously, so isUsingAltBuffer flips a few ms after the
      //    server has clearly entered TUI mode. The server-side hint
      //    flips first. a6.jpg shows the race: 3 consecutive
      //    _onKeyboardShow events all saw alt=false → noop branch →
      //    no Ctrl+End sent, even though tuiHint:true the whole time.
      //
      // 2. One-shot guard: keyboard animation fires _onKeyboardShow
      //    18× per show. Without the guard, 18 Ctrl+Ends would race
      //    each other and corrupt the TUI cursor position (same
      //    reasoning as the copyModeScroll branch above).
      if (_keyboardShowHandled) {
        return;
      }
      _keyboardShowHandled = true;
      // Wait for resize to settle before sending Ctrl+End so the TUI
      // anchors at the bottom of the new (keyboard-open) viewport, not
      // the old (pre-keyboard) one.  Immediate send caused the prompt to
      // land at row N of the old tall viewport, hidden behind the keyboard.
      _requestKeyboardCtrlEndAfterResize(suppressEcho: false);
    } else if (widget.isMosh && (_nonTmuxScrollLines > 0 || _tapSentSgrDown)) {
      // Send Ctrl+End when the user scrolled up before opening the keyboard.
      // Two paths arrive here:
      //   A) Normal swipe + keyboard: _nonTmuxScrollLines > 0 (SGR not yet sent)
      //   B) Tap path: _onPointerUp pre-emptively sent SGR scroll-down and
      //      zeroed _nonTmuxScrollLines; _tapSentSgrDown preserves the intent.
      _sgrInertiaRunning = false;
      _sgrFallback?.cancel();
      _nonTmuxScrollLines = 0;
      _tapSentSgrDown = false;
      // See tmux branch: send Ctrl+End now so it races ahead of v2's
      // immediate resize flush; the after-resize repeat is the safety net.
      _shellSuppressNextLocalEcho();
      _writeToShell('\x1b[1;5F');
      _requestKeyboardCtrlEndAfterResize(suppressEcho: true);
    } else {
      _tapSentSgrDown = false;
    }
  }

  void _requestKeyboardCtrlEndAfterResize({required bool suppressEcho}) {
    _pendingKeyboardCtrlEnd = true;
    _pendingKeyboardSuppressEcho = _pendingKeyboardSuppressEcho || suppressEcho;
    // OPT-1: update _lastTuiObservedAt here so all paths (tmux + non-tmux
    // QUIC direct) get sticky-TUI coverage. Previously only the copyModeScroll
    // SHOW-transition block (L398) updated this, leaving QUIC mux:off paths
    // without a sticky guard when SIGWINCH briefly drops alt-buffer.
    _lastTuiObservedAt = DateTime.now();
    _keyboardNormalizeTimer?.cancel();
    // Fallback for cases where opening the keyboard does not change terminal
    // rows/cols (or xterm does not emit onResize). If resize does happen, the
    // onResize debounce below cancels this and reschedules Ctrl+End after the
    // resize has been delivered to the shell.
    _keyboardNormalizeTimer = Timer(const Duration(milliseconds: 220), () {
      _runKeyboardCtrlEndNormalize('fallback');
    });
  }

  void _scheduleKeyboardCtrlEndAfterResize() {
    if (!_pendingKeyboardCtrlEnd) return;
    _keyboardNormalizeTimer?.cancel();
    // 600 ms (was 300, originally 80). The 300 ms window was still landing
    // before Claude/vim/etc had finished their self-driven SIGWINCH redraw
    // (RTT 80-120 ms + app redraw 100-200 ms ≈ 200-320 ms total). When the
    // explicit Ctrl+End + refresh-client landed mid-app-redraw, xterm
    // applied another wave of erase+repaint sequences ON TOP of the app's
    // own — visible as keyboard show/hide flicker for SSH+tmux+TUI.
    //
    // 600 ms lets the app's self-redraw fully land first; the subsequent
    // refresh-client then retransmits identical content, so xterm's
    // diff-paint is a near-noop. Costs a perceived ~300 ms delay before
    // tmux pane redraw completes, but stops the visible flicker.
    _keyboardNormalizeTimer = Timer(const Duration(milliseconds: 600), () {
      _runKeyboardCtrlEndNormalize('after-resize');
    });
  }

  void _runKeyboardCtrlEndNormalize(String reason) {
    if (!_pendingKeyboardCtrlEnd) {
      return;
    }
    final suppressEcho = _pendingKeyboardSuppressEcho;
    _pendingKeyboardCtrlEnd = false;
    _pendingKeyboardSuppressEcho = false;
    _keyboardNormalizeTimer?.cancel();
    _keyboardNormalizeTimer = null;
    if (suppressEcho) _shellSuppressNextLocalEcho();
    _writeToShell('\x1b[1;5F');
    // refresh-client retransmits the entire pane (erase + redraw). Modern
    // TUIs (vim, less, htop, claude, opencode) all install a SIGWINCH handler
    // and self-redraw based on the new winsize; refresh-client therefore
    // sends near-identical content RIGHT AFTER the app's own redraw landed.
    //
    // For Mosh/QUIC: their state-sync layer absorbs the duplicate update
    // cleanly (mosh prediction, QUIC vt100 snapshot) — no visible flicker.
    //
    // For pure SSH: xterm receives the raw erase+paint stream from
    // refresh-client. Even when content matches the prior self-redraw,
    // xterm processes each `\x1b[K` (erase-to-EOL) line-by-line, briefly
    // blanking each row before the new bytes fill it. Visible as a top-
    // to-bottom "wipe" — the user's flicker complaint (f9.jpg / f10.jpg).
    //
    // Trade-off: tmux's status bar may stay stale for ~100 ms longer
    // (until tmux's own refresh tick) — imperceptible compared to the
    // current line-by-line erase sweep.
    if (widget.copyModeScroll) {
      if (!_isPureSsh) {
        widget.onRefreshClient?.call();
      }
    }
    // The open fallback timer is moot now — normalize already fired.
    _keyboardOpenResizeTimer?.cancel();
    _keyboardOpenResizeTimer = null;
  }

  /// Routes a string to the active shell, handling both SSH (stdin sink) and
  /// local PTY (LocalShell.write) without a NoSuchMethodError on dynamic dispatch.
  void _writeToShell(String data) {
    final t = widget.transport;
    if (t != null) {
      t.write(Uint8List.fromList(utf8.encode(data)));
      return;
    }
    final sh = widget.shell;
    if (sh is LocalShell) {
      sh.write(data);
      return;
    }
    if (sh == null) {
      // Nowhere to send: a QUIC tab whose transport was nulled for the
      // duration of the SSH reconnect chain. Hand the bytes to the tab so
      // they can be replayed once a new transport arrives, instead of
      // dropping them on the floor below.
      widget.onOrphanedInput?.call(utf8.encode(data));
      return;
    }
    try {
      sh.stdin.add(utf8.encode(data));
    } catch (_) {}
  }

  /// Wire keyboard input and resize only.
  /// stdout/stderr are owned by SessionTab.startStreaming() — no subscriptions here.
  void _wireInput() {
    widget.terminal.onOutput = (data) {
      // xterm's TerminalScrollGestureHandler generates SGR mouse-wheel sequences
      // (\x1b[<64;...M up / \x1b[<65;...M down) in alt-buffer mode and routes
      // them through terminal.onOutput → shell.stdin.  When inTmux is true,
      // tmux with "mouse on" forwards those events to the foreground app
      // (e.g. Claude CLI) — causing garbled output.  We handle tmux scrolling
      // exclusively via TmuxHelper exec channel, so drop these sequences here.
      // Block when inTmux (primary) OR when in alt-buffer before tmux detection
      // completes — the inTmux flag has a race window at tab open time where it
      // is still false even though tmux is already running and would forward
      // these events to Claude CLI.  Alt-buffer means a TUI app is active;
      // our Listener handles scroll via exec channel or manual SGR instead.
      // Drop xterm-generated scroll-wheel SGR unconditionally — our outer
      // Listener owns the scroll-SGR pipeline. Keeping this filter ahead of
      // the tmux/altBuf one means a stale mouse-tracking mode (from an
      // exited TUI) never leaks `\x1b[<64;...M` bytes into bash on the
      // next scroll gesture.
      if (_isScrollWheelSgr(data)) return;
      if ((widget.copyModeScroll || widget.terminal.isUsingAltBuffer) &&
          _isMouseReportEvent(data)) {
        return;
      }
      if (widget.interceptInput?.call(data) == true) return;
      // Typing while in mosh TUI scroll mode: cancel inertia and reset the
      // scroll counter BEFORE sending the keystroke.  The inertia timer fires
      // every 16 ms on a background thread and sends SGR scroll-up events that
      // interleave with keystrokes at the server — Claude CLI then alternates
      // between history-scroll mode and input mode on each event, placing typed
      // characters at the wrong cursor row (错行).  Claude CLI auto-exits scroll
      // mode on any keypress, so no return-to-live SGRs are needed here; just
      // stop all further scroll events so only clean keystrokes reach the server.
      if ((_sgrInertiaRunning || _nonTmuxScrollLines > 0) &&
          (widget.isMosh || _lastUseSgrWheel)) {
        _sgrInertiaRunning = false;
        _sgrFallback?.cancel();
        _pendingSgrUp = 0;
        _pendingSgrDown = 0;
        if (_nonTmuxScrollLines > 0) {
          // Suppress the next local echo so the prediction isn't written at
          // the scroll-history cursor row before the server confirms the return
          // to live view.  Applies to all mosh paths including inTmux — the
          // original !widget.copyModeScroll guard incorrectly excluded tmux+mosh.
          _shellSuppressNextLocalEcho();
          final evt = '\x1b[<65;$_sgrCol;${_sgrRow}M';
          _writeToShell(evt * _nonTmuxScrollLines);
          _nonTmuxScrollLines = 0;
        }
      }
      ActivityTracker.instance.recordInput();
      _writeToShell(data);
      widget.onUserInput?.call(data);
    };
    widget.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      // Debounce: keyboard animation and pinch-zoom both emit many intermediate
      // sizes within ~300 ms.  The window only needs to be long enough to
      // collapse a single user-driven event into one PTY SIGWINCH.
      //
      // During active pinch-zoom, suppress resize entirely — the shell would
      // clear+redraw on every intermediate size, causing a blank screen.
      // The final resize is sent when pinch ends (pointer up clears
      // _pinchBaseDistance, next onResize fires normally).
      if (_pinchBaseDistance > 0) {
        _resizeDebounce?.cancel();
        _resizeDebounce = null;
        return;
      }
      // 220 ms 覆盖整个 Android IME 动画时长（fast easeOutCubic ~220ms）。
      // 旧值 60 ms 不足以聚合动画 → onResize 在动画多个关键帧之间间隔
      // > 60ms 时各自触发 fire → 一次 SHOW/HIDE 周期就有 ~10 次 _shellResize
      // → ~10 次 SSH window-change → tmux+TUI 反复 SIGWINCH 重绘（c1.jpg
      // dbc:120 / shR:143 / 闪烁的主因）。220 ms 让整个动画收敛为 1 次
      // _shellResize：稳态 size 才发出去，tmux/TUI 只重绘一次。
      //
      // 代价：键盘弹起→TUI reflow 延迟从原 60ms+RTT 增到 220ms+RTT；动画期
      // 间用户感知的 PTY 反应慢约 160ms，但视觉抖动消失。
      _resizeDebounce?.cancel();
      _resizeDebounce = Timer(const Duration(milliseconds: 220), () {
        _shellResize(width, height);
        _scheduleKeyboardCtrlEndAfterResize();
        // Once xterm actually emits a resize, the SHOW fallback timer is
        // redundant — let the debounced path handle Ctrl+End so we don't
        // double-send a refresh-client when the user does eventually use
        // the keyboard normally.
        if (_keyboardOpenResizeTimer?.isActive ?? false) {
          _keyboardOpenResizeTimer?.cancel();
          _keyboardOpenResizeTimer = null;
        }
      });
    };
  }

  // Block all mouse-reporting escape sequences when inTmux:
  //   SGR  (?1006h): ESC [ < digits ; digits ; digits M/m  ← Claude CLI uses this
  //   Normal/UTF:    ESC [ M <3-bytes>                     ← defensive
  //   urxvt (?1015h):ESC [ digits ; digits ; digits M      ← defensive
  // xterm-dart wheelUp=68 (64+4), wheelDown=69 (64+5) — NOT the standard 64/65.
  static bool _isMouseReportEvent(String data) {
    if (data.length < 4) return false;
    // SGR and urxvt both contain ';' and end with M or m after ESC [
    if (data.startsWith('\x1b[') &&
        data.contains(';') &&
        (data.endsWith('M') || data.endsWith('m'))) {
      return true;
    }
    // Normal/UTF-8 encoding: ESC [ M + 3 payload bytes
    if (data.startsWith('\x1b[M') && data.length >= 6) return true;
    return false;
  }

  /// True only when [data] is an SGR mouse wheel event (button code 64/65).
  /// xterm.flutter's TerminalScrollGestureHandler generates these whenever its
  /// internal mouse mode is enabled (set by a previous `\x1b[?1000h` / `1003h`
  /// from a TUI app). Our outer Listener already produces the authoritative
  /// SGR scroll stream via `_flushSgr`, so xterm's parallel pipeline doubles
  /// the rate (in TUI) or — worse — leaks raw `\x1b[<64;X;YM` bytes into bash
  /// when the foreground app exits without clearing mouse mode and the user
  /// scrolls in a non-TUI context.
  static bool _isScrollWheelSgr(String data) {
    if (!data.startsWith('\x1b[<') || data.length < 7) return false;
    final semi = data.indexOf(';', 3);
    if (semi < 4) return false;
    final btn = int.tryParse(data.substring(3, semi));
    return btn == 64 || btn == 65;
  }

  double _currentPinchDistance() {
    final pts = _activePointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onPointerDown(PointerDownEvent e, TerminalSettings settings) {
    // Is this touch grabbing a selection handle? The test lives here, in the
    // outer Listener, rather than in the handle widget itself: Flutter does not
    // hit-test past a parent's bounds, so a handle drawn near a viewport edge
    // would be visible but ungrabbable.
    if (_selection.isActive) {
      final pos = _handlePositions.value;
      final hit = nearestHandle(
        touch: e.localPosition,
        start: pos.start,
        end: pos.end,
      );
      if (hit != null) {
        _beginHandleDrag(hit, e.localPosition);
        return; // skip all scroll / long-press logic
      }
    }
    if (_draggingHandle != null) return;
    // A touch anywhere outside the menu dismisses it. Taps ON the menu never
    // reach here: the menu is a later Stack child, and RenderStack hit-tests
    // children topmost-first and stops at the first hit.
    if (_longPressMenuAt != null) {
      _dismissLongPressMenu();
      _suppressTapAfterMenu = true;
    }
    termDebug.tmuxInCopyMode = _tmuxInCopyMode;
    final cursorHiddenAtDown = !widget.terminal.cursorVisibleMode;
    bool moshTuiActiveAtDown = false;
    if (widget.isMosh) {
      try {
        moshTuiActiveAtDown = (widget.shell?.moshTuiActive as bool?) ?? false;
      } catch (_) {}
    }
    // remoteTuiHint is only meaningful for copyModeScroll sessions (tmux):
    // tmux forwards SGR mouse events to the foreground app (e.g. Claude Code).
    // In non-tmux sessions (QUIC, plain SSH) there is no such forwarding layer,
    // so remoteTuiHint must NOT gate scroll events — otherwise Claude Code's
    // cursor-hide pulses (?25l/?25h) cause SGR events to reach the PTY,
    // suppressing xterm's normal-buffer scrollback.
    // cursorHidden/moshTuiActive are mosh-specific heuristics (mosh strips
    // alt-buffer escapes); exclude them for non-mosh non-tmux transports.
    final useSgrAtDown = widget.terminal.isUsingAltBuffer ||
        (widget.copyModeScroll && widget.remoteTuiHint) ||
        (widget.isMosh && (moshTuiActiveAtDown || cursorHiddenAtDown));
    // Self-heal on touch: if TUI is now active and we're stuck in tmux
    // copy-mode (because earlier scrolls happened pre-TUI), exit copy-mode
    // immediately so the user's next interaction lands in opencode/etc.
    // Without this, the user must trigger a scroll or terminal update to
    // unstick — keyboard show/hide is the only other recovery path.
    if (useSgrAtDown && widget.copyModeScroll &&
        (_tmuxInCopyMode || _tmuxScrollOffset > 0)) {
      widget.onExitScrollMode?.call();
      _tmuxInCopyMode = false;
      _tmuxScrollOffset = 0;
      _needsCopyModeRefresh = false;
      termDebug.tmuxInCopyMode = false;
    }
    // Cancel any in-progress inertia on new touch; clear gate so the fresh
    // gesture starts clean without inheriting state from the previous swipe.
    _sgrInertiaRunning = false;
    _pendingSgrUp = 0;
    _pendingSgrDown = 0;
    _sgrFallback?.cancel();
    _recentMoves.clear();
    _lastUseSgrWheel = false;
    _lastSgrWasRemoteTui = false;
    _activePointers[e.pointer] = e.position;
    if (_activePointers.length == 1) {
      // First finger: record start position for scroll-intent classification.
      _pointerDownPos = e.position;
      _scrollIntentDetected = false;
      // Snapshot keyboard state now — _prevViewInset may change mid-gesture.
      _keyboardVisibleAtDown = (_prevViewInset ?? 0) > 10;
      // Start long-press timer for text selection (500ms, single finger only).
      if (!_selection.isActive) {
        _longPressTimer?.cancel();
        _longPressPosition = e.localPosition;
        _longPressTimer = Timer(const Duration(milliseconds: 500), () {
          _showLongPressMenu(_longPressPosition!);
        });
      }
    }
    if (_activePointers.length == 2) {
      _pinchBaseFontSize = settings.fontSize;
      _pinchBaseDistance = _currentPinchDistance();
      _scrollAccum = 0; // cancel any in-progress single-finger scroll
      // Pinch overrides single-finger scroll detection.
      _pointerDownPos = null;
      _scrollIntentDetected = false;
      _lastTapTime = null;
      _longPressTimer?.cancel(); // pinch cancels long-press
      _longPressTimer = null;
      // Watchdog: if both PointerUp events get dropped (PointerCancel,
      // platform-view interception, widget unmount mid-pinch), the
      // _pinchBaseDistance > 0 guard at the top of onResize would silently
      // suppress every subsequent resize. 3 s of total inactivity force-
      // clears the pinch state and sends the latest viewport size.
      _pinchWatchdog?.cancel();
      _pinchWatchdog = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        if (_pinchBaseDistance <= 0) return;
        _pinchBaseDistance = 0;
        _pinchBaseFontSize = 0;
        final w = widget.terminal.viewWidth;
        final h = widget.terminal.viewHeight;
        if (w > 0 && h > 0) _shellResize(w, h);
      });
    }
  }

  void _onPointerMove(PointerMoveEvent e, TerminalSettings settings) {
    // Sync scrollController liveness on every move so the overlay reflects
    // whether xterm's native Scrollable is wired up at the moment a gesture
    // is being processed (fall-through path for non-tmux non-mosh).
    final sc = widget.scrollController;
    termDebug.scHasController = sc != null;
    if (sc != null && sc.hasClients) {
      termDebug.scHasClients = true;
      termDebug.scOffset = sc.offset;
      termDebug.scMaxExtent = sc.position.maxScrollExtent;
    } else {
      termDebug.scHasClients = false;
    }
    // Handle drag in progress — skip all scroll logic.
    if (_draggingHandle != null) {
      _onHandleDrag(e.localPosition);
      return;
    }
    final prev = _activePointers[e.pointer];
    _activePointers[e.pointer] = e.position;

    // Cancel long-press if the finger moved more than 8px from the down position.
    if (_longPressTimer != null && _longPressPosition != null) {
      final moved = (e.localPosition - _longPressPosition!).distance;
      if (moved > 8.0) {
        _longPressTimer?.cancel();
        _longPressTimer = null;
      }
    }

    if (_activePointers.length == 2 && _pinchBaseDistance > 0) {
      final scale = _currentPinchDistance() / _pinchBaseDistance;
      settings.setFontSize(_pinchBaseFontSize * scale);
      return;
    }

    // Scroll-intent detection (single finger only).
    // Accumulate displacement from the gesture's start point; once the motion
    // is clearly vertical (dy > 12 px, dy/dx > 1.5) we classify it as a
    // scroll and hide the keyboard so the full screen is available for reading.
    if (_activePointers.length == 1 &&
        _pointerDownPos != null &&
        !_scrollIntentDetected) {
      final total = e.position - _pointerDownPos!;
      final absDy = total.dy.abs();
      final absDx = total.dx.abs();
      // Stricter thresholds: require clearly vertical movement (dy > dx * 2.5,
      // ~68° from horizontal) and at least 16px travel to avoid misclassifying
      // a slightly-drifting tap as a scroll intent.
      if (absDy > 16 && absDy > absDx * 2.5) {
        _scrollIntentDetected = true;
        _lastScrollTime = DateTime.now(); // B: start cooldown
        // Only dismiss keyboard on scroll when NOT in a TUI (alt-buffer or
        // remoteTuiHint). In TUI mode the scroll goes to SGR wheel → the
        // TUI (Claude, opencode, vim, htop) handles its own scrollback.
        // Calling TextInput.hide here caused a 12-cycle bounce: every scroll
        // intent hid the keyboard, user re-tapped, it appeared briefly and
        // hid again (b7.jpg: gS:223 ≈ 12 SHOW/HIDE cycles per session).
        // In non-TUI mode (bash/zsh prompt) the hide is desirable so the
        // full screen is available for reading scrollback.
        final inTuiMode = widget.terminal.isUsingAltBuffer ||
            widget.remoteTuiHint;
        if (_keyboardVisibleAtDown && !inTuiMode) {
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        }
      }
    }

    // Scroll handling for alt-buffer / tmux.
    //
    // Alt-buffer (any transport — Claude with NO_FLICKER, vim, less, htop):
    //   SGR mouse-wheel via stdin. tmux's `mouse on` (set in attachOrCreate)
    //   transparently forwards these to the foreground app, which already
    //   handles its own scrollback semantics. tmux copy-mode is the wrong
    //   tool here because it operates on main-buffer scrollback — alt
    //   content isn't there to begin with.
    //
    // Main-buffer in tmux: tmux copy-mode via exec channel — sending SGR
    //   to stdin in this case would leak to the foreground app. send-keys
    //   -X scroll-up/down stays inside tmux and walks the scrollback.
    //
    // Main-buffer non-tmux: falls through to xterm's native Scrollable.
    if (_activePointers.length == 1 && prev != null) {
      final lineH = settings.fontSize * 1.5;
      // Remote TUI (Claude/OpenCode/vim/less/htop/etc.) should receive SGR
      // wheel directly. If it is inside tmux, tmux acts as a transparent mouse
      // router (`mouse on`) and forwards the event to the foreground TUI.
      //
      // Plain shell inside tmux (bash/zsh/fish) should NOT receive SGR wheel;
      // it has no internal scrollback UI. In that case we explicitly drive
      // tmux copy-mode via the control pipe below.
      //
      // mosh strips alt-buffer toggles, so `terminal.isUsingAltBuffer` is not
      // reliable there. Use moshTuiActive as the TUI signal for mosh sessions.
      bool moshTuiActive = false;
      if (widget.isMosh) {
        try {
          moshTuiActive = (widget.shell?.moshTuiActive as bool?) ?? false;
        } catch (_) {}
      }
      // Live cursor-hide signal: when Claude/OpenCode (or any TUI) sends
      // `?25l`, xterm updates `cursorVisibleMode` synchronously. This avoids
      // the staleness window where `widget.remoteTuiHint` is from the last
      // build and `moshTuiActive` is waiting on TuiDetector's row threshold —
      // both reasons scroll didn't work immediately after a mosh connect
      // until keyboard show/hide forced a rebuild.
      final cursorHidden = !widget.terminal.cursorVisibleMode;
      // Same scoping as useSgrAtDown above: remoteTuiHint only for tmux,
      // cursorHidden/moshTuiActive only for mosh. In QUIC/SSH non-tmux,
      // only isUsingAltBuffer triggers SGR — so Claude Code's ?25l/?25h
      // pulses don't intercept scroll events meant for normal-buffer
      // scrollback.
      final useSgrWheel =
          widget.terminal.isUsingAltBuffer ||
          (widget.copyModeScroll && widget.remoteTuiHint) ||
          (widget.isMosh && (moshTuiActive || cursorHidden));
      termDebug.tmuxInCopyMode = _tmuxInCopyMode;
      if (useSgrWheel) {
        // If we entered tmux copy-mode during the brief post-reconnect window
        // (before TUI signals were restored), exit it now so SGR events reach
        // the remote app instead of being intercepted by copy-mode.
        if (widget.copyModeScroll && (_tmuxInCopyMode || _tmuxScrollOffset > 0)) {
          widget.onExitScrollMode?.call();
          _tmuxInCopyMode = false;
          _tmuxScrollOffset = 0;
          _needsCopyModeRefresh = false;
          termDebug.tmuxInCopyMode = false;
        }
        _scrollAccum += e.position.dy - prev.dy;
        // Track pointer cell position for SGR coordinate encoding.
        final rt = _terminalViewKey.currentState?.renderTerminal;
        if (rt != null) {
          final local = rt.globalToLocal(e.position);
          final cell = rt.getCellOffset(local);
          _sgrCol = cell.x + 1;
          _sgrRow = (cell.y - (rt.scrollPixels / lineH).floor()) + 1;
          if (_sgrCol < 1) _sgrCol = 1;
          if (_sgrRow < 1) _sgrRow = 1;
          if (_sgrRow > widget.terminal.viewHeight)
            _sgrRow = widget.terminal.viewHeight;
        }
        int upCount = 0;
        int downCount = 0;
        while (_scrollAccum.abs() >= lineH) {
          final up = _scrollAccum < 0;
          _scrollAccum += up ? lineH : -lineH;
          if (up) {
            upCount++;
            _nonTmuxScrollLines++;
          } else {
            // No gate on down events: the TUI is authoritative for "bottom"
            // semantics. opencode's internal pager auto-scrolls up when new
            // chat content pushes lines past the viewport — the user then
            // swipes down to follow live, but our client's
            // _nonTmuxScrollLines is 0 because we never sent the ups. With
            // a counter-based gate the down event was eaten and the user
            // got stuck. Always forward gesture-driven downs; TUIs ignore
            // them at their internal bottom-of-buffer.
            downCount++;
            if (_nonTmuxScrollLines > 0) _nonTmuxScrollLines--;
          }
        }
        _pendingSgrUp += upCount;
        _pendingSgrDown += downCount;
        _sgrLastLineH = lineH;
        // Velocity sampling: keep all pointer moves from the last 80 ms so
        // _onPointerUp can compute a clean exit speed for inertia.
        final now = DateTime.now();
        _recentMoves.add((dy: e.position.dy - prev.dy, time: now));
        while (_recentMoves.isNotEmpty &&
            now.difference(_recentMoves.first.time).inMilliseconds > 80) {
          _recentMoves.removeAt(0);
        }
        if (upCount > 0 || downCount > 0) _flushSgr();
        // RemoteTui path: tmux is transparent. Do not run copy-mode cleanup
        // here; cancel/refresh belongs to the explicit tmux copy-mode path.
        _lastUseSgrWheel = true;
        _lastSgrWasRemoteTui = true;
      } else if (widget.isMosh) {
        // mosh + none: AbsorbPointer prevents xterm's Scrollable from
        // receiving gestures (needed to block accidental word-select on double
        // tap). Drive scrollController manually so main-buffer scrollback works.
        // Do NOT touch _nonTmuxScrollLines — that counter drives the SGR path;
        // mixing paths would send spurious SGR scroll-down on tap.
        _scrollAccum += e.position.dy - prev.dy;
        int upLines = 0, downLines = 0;
        while (_scrollAccum.abs() >= lineH) {
          final goUp = _scrollAccum < 0;
          _scrollAccum += goUp ? lineH : -lineH;
          if (goUp) upLines++;
          else downLines++;
        }
        final sc = widget.scrollController;
        if (sc != null && sc.hasClients && (upLines > 0 || downLines > 0)) {
          // offset=0 → live view (bottom); maxScrollExtent → oldest content
          final delta = (upLines - downLines) * lineH;
          final newOfs = (sc.offset + delta).clamp(
              0.0, sc.position.maxScrollExtent);
          sc.jumpTo(newOfs);
        }
      }
      // Main buffer, non-tmux, non-mosh (QUIC / plain SSH): fall through —
      // xterm's inner Scrollable handles scroll naturally because
      // scrollPhysics is null.
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_draggingHandle != null) {
      _endHandleDrag();
      return;
    }
    _longPressTimer?.cancel();
    _longPressTimer = null;
    // Supplement PointerMove-based detection: if the finger lifted with clear
    // vertical displacement but _scrollIntentDetected was never set (quick
    // flick / sparse move events / slightly diagonal gesture), treat as scroll.
    // Threshold: dy > 16px and primarily vertical (dy > dx * 2.5, ~68°).
    final displacement =
        _pointerDownPos != null
            ? (e.position - _pointerDownPos!).distance
            : double.infinity;
    final scrollByFinalPos =
        !_scrollIntentDetected &&
        _pointerDownPos != null &&
        _activePointers.length == 1 &&
        (() {
          final d = e.position - _pointerDownPos!;
          return d.dy.abs() > 16 && d.dy.abs() > d.dx.abs() * 2.5;
        })();
    final wasScroll = _scrollIntentDetected || scrollByFinalPos;
    // B: if this gesture was itself a scroll, refresh the cooldown timestamp.
    if (wasScroll) _lastScrollTime = DateTime.now();
    // A+B: keyboard opens only on a genuine tap — two guards must both pass:
    //
    //   A. Displacement < 5 dp (down from 10 dp).  True finger-tap tremor is
    //      < 3 dp; the old 10 dp budget was catching "finger placement before a
    //      multi-pass scroll" as a false tap.
    //
    //   B. No recent scroll within _kScrollCooldown (350 ms).  The "multi-pass
    //      scroll" pattern — scroll, lift, re-place, barely move — produces a
    //      new pointer sequence with near-zero displacement that still triggered
    //      a false tap with the old logic.  The cooldown bridges the gap between
    //      consecutive scroll passes.
    final recentScroll =
        _lastScrollTime != null &&
        DateTime.now().difference(_lastScrollTime!) < _kScrollCooldown;
    final isTap = !wasScroll && !recentScroll && displacement < 5.0;
    // A pointer-down that showed or dismissed the long-press menu must not
    // let this matching pointer-up also register as a tap: opening the
    // keyboard here would resize the layout out from under the menu's
    // captured anchor (or, for the dismissing tap, defeat "不穿透到终端" by
    // letting the same touch that closed the menu also focus the terminal).
    // Consumed here (not inside the `isTap` block below) so every other
    // pointer-up bookkeeping step — active-pointer removal, pinch-end resize,
    // scroll/inertia cleanup — still runs unconditionally for this pointer.
    final suppressTap = _suppressTapAfterMenu;
    _suppressTapAfterMenu = false;
    _activePointers.remove(e.pointer);
    if (_activePointers.length < 2) {
      if (_pinchBaseDistance > 0) {
        // Pinch ended — send the deferred resize now.
        final w = widget.terminal.viewWidth;
        final h = widget.terminal.viewHeight;
        if (w > 0 && h > 0) {
          _shellResize(w, h);
        }
        // A pinch changed the font size → cellSize changed → the handles'
        // pixel positions have to be recomputed from their cells.
        if (_selection.isActive) _scheduleHandleSync();
      }
      _pinchBaseDistance = 0;
      _pinchWatchdog?.cancel();
      _pinchWatchdog = null;
    }
    if (_activePointers.isEmpty) {
      _scrollAccum = 0;
      // Plain tap (no scroll intent): re-establish the keyboard via xterm's
      // requestKeyboard() which handles both the "already focused" fast path
      // (opens input connection directly) and the "focus lost" path
      // (requestFocus → _onFocusChange → open connection).
      if (isTap && !suppressTap) {
        if (_selection.isActive) {
          if (_suppressTapDismiss) {
            _suppressTapDismiss = false;
          } else {
            _exitSelectionMode();
            _pointerDownPos = null;
            _scrollIntentDetected = false;
            _keyboardVisibleAtDown = false;
            return;
          }
        }
        if (widget.keyboardTriggerMode == KeyboardTriggerMode.singleTap) {
          _terminalViewKey.currentState?.requestKeyboard();
        } else if (widget.keyboardTriggerMode ==
            KeyboardTriggerMode.doubleTap) {
          final now = DateTime.now();
          if (_lastTapTime != null &&
              now.difference(_lastTapTime!) <=
                  const Duration(milliseconds: 350)) {
            _terminalViewKey.currentState?.requestKeyboard();
            _lastTapTime = null;
          } else {
            _lastTapTime = now;
          }
        }
        // iconButton: keyboard triggered only via KeyBar icon, not tap
        if (widget.copyModeScroll &&
            _lastUseSgrWheel &&
            !_lastSgrWasRemoteTui &&
            _nonTmuxScrollLines > 0) {
          // SSH/mosh+tmux SGR path: tmux auto-entered copy-mode from our SGR
          // wheel events. Exit copy-mode via control pipe and clear scroll state.
          _sgrInertiaRunning = false;
          _sgrFallback?.cancel();
          _pendingSgrUp = 0;
          _pendingSgrDown = 0;
          _nonTmuxScrollLines = 0;
          widget.onExitScrollMode?.call();
        } else if (widget.copyModeScroll && !_lastUseSgrWheel) {
          // Main-buffer tmux copy-mode: send cancel + refresh via pipe.
          _exitTmuxAndSync();
        } else if (widget.isMosh &&
                !widget.copyModeScroll &&
                !_lastUseSgrWheel) {
          // mosh + none manual scroll: tap returns to live view.
          final sc = widget.scrollController;
          if (sc != null && sc.hasClients && sc.offset > 0) {
            sc.jumpTo(0);
          }
        } else if ((widget.terminal.isUsingAltBuffer ||
                widget.isMosh ||
                _lastUseSgrWheel) &&
            _nonTmuxScrollLines > 0) {
          // Alt-buffer (Claude CLI, vim, htop) or mosh TUI — covers both
          // non-tmux and inTmux+alt-buffer (SSH+tmux+Claude). Send SGR
          // scroll-down to return to live view; do NOT send copy-mode cancel.
          _sgrInertiaRunning = false;
          _sgrFallback?.cancel();
          _pendingSgrUp = 0;
          _pendingSgrDown = 0;
          _shellSuppressNextLocalEcho();
          final evt = '\x1b[<65;$_sgrCol;${_sgrRow}M';
          _writeToShell(evt * _nonTmuxScrollLines);
          _nonTmuxScrollLines = 0;
          // Mark that we pre-emptively scrolled back; _onKeyboardShow will
          // still send Ctrl+End even though _nonTmuxScrollLines is now 0.
          if (widget.isMosh && !widget.copyModeScroll) _tapSentSgrDown = true;
        }
      }
      // Inertia: if the SGR wheel path was active and the finger had meaningful
      // exit velocity, coast the scroll to a natural stop.
      if (wasScroll &&
          _lastUseSgrWheel &&
          !(widget.isMosh && _lastSgrWasRemoteTui) &&
          _recentMoves.length >= 2) {
        final totalDy = _recentMoves.fold(0.0, (s, m) => s + m.dy);
        final ms =
            _recentMoves.last.time
                .difference(_recentMoves.first.time)
                .inMilliseconds;
        if (ms > 0) {
          final v = totalDy / ms * 16; // px/ms → px/frame (16 ms)
          if (v.abs() > 2.0) _startSgrInertia(v);
        }
      }
      _recentMoves.clear();
      _pointerDownPos = null;
      _scrollIntentDetected = false;
      _keyboardVisibleAtDown = false;
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (_draggingHandle != null) {
      _endHandleDrag();
      return;
    }
    _longPressTimer?.cancel();
    _longPressTimer = null;
    // Mirror _onPointerUp: this cancel is the end of the gesture that armed
    // the flag (menu shown or dismissed), so the flag must not survive to
    // suppress a later, unrelated tap's keyboard-open.
    _suppressTapAfterMenu = false;
    _activePointers.remove(e.pointer);
    if (_activePointers.length < 2) {
      if (_pinchBaseDistance > 0) {
        final w = widget.terminal.viewWidth;
        final h = widget.terminal.viewHeight;
        if (w > 0 && h > 0) {
          _shellResize(w, h);
        }
        // Same as _onPointerUp: font size changed under a pinch, so the
        // handles' pixel positions no longer match their cells.
        if (_selection.isActive) _scheduleHandleSync();
      }
      _pinchBaseDistance = 0;
      _pinchWatchdog?.cancel();
      _pinchWatchdog = null;
    }
    if (_activePointers.isEmpty) {
      _scrollAccum = 0;
      _pointerDownPos = null;
      _scrollIntentDetected = false;
      _keyboardVisibleAtDown = false;
      _sgrInertiaRunning = false;
      _recentMoves.clear();
      _lastUseSgrWheel = false;
      _lastSgrWasRemoteTui = false;
    }
  }

  void _scheduleScrollFlush() {
    if (_scrollFlushScheduled) return;
    _scrollFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollFlushScheduled = false;
      final up = _pendingScrollUp;
      final down = _pendingScrollDown;
      _pendingScrollUp = 0;
      _pendingScrollDown = 0;
      // Re-check TUI state at frame time for mosh sessions. A mosh state diff
      // may have arrived between the pointer event and this frame callback,
      // activating TuiDetector. Redirect from copy-mode to SGR instead of
      // sending scroll-up/-down events to tmux — prevents accidentally entering
      // tmux copy-mode when the user scrolls right as Claude/OpenCode renders.
      if (widget.isMosh && (up > 0 || down > 0)) {
        bool tuiNowActive = false;
        try {
          tuiNowActive = (widget.shell?.moshTuiActive as bool?) ?? false;
        } catch (_) {}
        // Cursor-hidden is the same TUI signal that activates SGR routing in
        // _onPointerMove. Use it here too so a copy-mode batch accumulated
        // before the TuiDetector row threshold is met still re-routes to SGR.
        if (!tuiNowActive) tuiNowActive = !widget.terminal.cursorVisibleMode;
        if (tuiNowActive) {
          if (_tmuxInCopyMode || _tmuxScrollOffset > 0) {
            widget.onExitScrollMode?.call();
          }
          _tmuxInCopyMode = false;
          _tmuxScrollOffset = 0;
          _needsCopyModeRefresh = false;
          termDebug.tmuxInCopyMode = false;
          if (up > 0) {
            _nonTmuxScrollLines += up;
            _pendingSgrUp += up;
          }
          if (down > 0) {
            final d = down.clamp(0, _nonTmuxScrollLines);
            _pendingSgrDown += d;
            _nonTmuxScrollLines -= d;
          }
          _lastUseSgrWheel = true;
          _lastSgrWasRemoteTui = true;
          _flushSgr();
          return;
        }
      }
      if (up > 0) {
        if (_needsCopyModeRefresh) {
          _needsCopyModeRefresh = false;
          // Pre-first-scroll refresh: clear any live-output residuals before
          // the copy-mode view is rendered. mosh self-corrects via full frames.
          if (!widget.isMosh) widget.onRefreshClient?.call();
        }
        widget.onScrollUp?.call(up);
        // Post-scroll refresh: correct CJK residuals from tmux differential
        // rendering (ESC[1L] shifts rows, skips "unchanged" cells).
        // Adaptive: during fast scroll (>_kFastScrollThreshold lines/frame)
        // alternate sending the refresh to halve SSH traffic.  At high speed
        // residuals flash by imperceptibly; on slow scroll always refresh.
        if (!widget.isMosh) {
          final fast = up > _kFastScrollThreshold;
          if (!fast || !_skipRefreshNextFlush) widget.onRefreshClient?.call();
          _skipRefreshNextFlush = fast && !_skipRefreshNextFlush;
        }
      }
      if (down > 0) {
        widget.onScrollDown?.call(down);
        if (!widget.isMosh) {
          final fast = down > _kFastScrollThreshold;
          if (!fast || !_skipRefreshNextFlush) widget.onRefreshClient?.call();
          _skipRefreshNextFlush = fast && !_skipRefreshNextFlush;
        }
      }
    });
  }

  // ── SGR wheel: unified ungated flush ─────────────────────────────────────

  /// Flush all accumulated SGR scroll lines as _writeToShell calls.
  ///
  /// Both SSH and mosh write immediately — every accumulated batch from a
  /// pointer event drains in one call. There is no in-flight gate and no
  /// fallback timer. Pointer events fire at ~60 Hz so the server gets a
  /// steady event stream that matches the user's drag tempo without
  /// RTT-induced step-wise pauses.
  ///
  /// Why mosh is also ungated (Plan A — extended from SSH):
  ///   • mosh-server runs its own ~50 Hz frame scheduler — multiple input
  ///     events between frames are coalesced server-side regardless of how
  ///     fast the client sends them. Burst-input does not generate burst-
  ///     output diffs.
  ///   • The Synchronizer computes diffs against the last-acked client
  ///     state, but each diff is bounded by the visible cell grid (80×24);
  ///     it cannot grow unboundedly even under burst input.
  ///   • SGR mouse events are ~10 byte payloads → tiny UDP packets even at
  ///     60 Hz the bandwidth impact is negligible (~2.4 KB/s).
  ///   • The previous RTT-paced gate (clamp 16-500 ms) caused visible
  ///     step-wise scrolling on cellular (RTT 30-80 ms): pointer events
  ///     buffered behind the gate produced "5 lines waiting for 5 RTTs"
  ///     instead of "5 lines streaming at gesture tempo".
  void _flushSgr() {
    if (_pendingSgrUp == 0 && _pendingSgrDown == 0) return;
    // Re-derive the TUI condition at flush time. Without this, SGR events
    // accumulated in the pending counter while a TUI signal was briefly
    // true (e.g. tmux status-line cursor-hide window) still get written
    // moments later when no foreground TUI is reading them — bash gets
    // raw `\x1b[<64;...M` and displays it as visible garbage.
    bool moshTuiActive = false;
    if (widget.isMosh) {
      try {
        moshTuiActive = (widget.shell?.moshTuiActive as bool?) ?? false;
      } catch (_) {}
    }
    // Same scoping as the two useSgr decision sites: remoteTuiHint only for
    // tmux (copyModeScroll), cursorHidden/moshTuiActive only for mosh.
    // In QUIC/SSH non-tmux, only isUsingAltBuffer keeps the SGR flush alive —
    // so pending events get discarded when alt-buffer is off, even if
    // ?25l is still latched (e.g. fzf/bash transient cursor-hide).
    final stillTui = widget.terminal.isUsingAltBuffer ||
        (widget.copyModeScroll && widget.remoteTuiHint) ||
        (widget.isMosh && (moshTuiActive || !widget.terminal.cursorVisibleMode));
    if (!stillTui) {
      _pendingSgrUp = 0;
      _pendingSgrDown = 0;
      _sgrInertiaRunning = false;
      _sgrFallback?.cancel();
      return;
    }
    final maxLines = _sgrBatchLimit();
    if (maxLines <= 0) {
      if (_sgrInertiaRunning) {
        _pendingSgrUp = 0;
        _pendingSgrDown = 0;
        _sgrInertiaRunning = false;
      }
      return;
    }
    final col = _sgrCol;
    final row = _sgrRow;
    if (_pendingSgrUp > 0) {
      final lines = _pendingSgrUp.clamp(0, maxLines);
      final evt = '\x1b[<64;$col;${row}M';
      _writeToShell(evt * lines);
      _pendingSgrUp -= lines;
      widget.onSgrSent?.call(lines);
    }
    if (_pendingSgrDown > 0) {
      final lines = _pendingSgrDown.clamp(0, maxLines);
      final evt = '\x1b[<65;$col;${row}M';
      _writeToShell(evt * lines);
      _pendingSgrDown -= lines;
      widget.onSgrSent?.call(lines);
    }
  }

  int _sgrBatchLimit() {
    if (!widget.isMosh) {
      // QUIC / SSH non-tmux: cap SGR events per vsync frame the same as the
      // mosh stable-state limit (3). Without a cap, all pending SGR up-scroll
      // events flush in a single frame — e.g. a slow swipe can queue 138 events
      // that all land in Claude Code TUI at once, corrupting its state (f23.jpg).
      // tmux paths (copyModeScroll) are exempt: they use copy-mode, not SGR.
      if (!widget.copyModeScroll) return 3;
      return 1 << 20;
    }
    final pending = _moshPendingDiffsCount();
    final max = _moshMaxPendingDiffs();
    if (max <= 0) return 3;
    if (pending >= (max * 0.75).floor()) return 0;
    if (pending >= (max * 0.50).floor()) return 1;
    if (pending >= (max * 0.25).floor()) return 2;
    return 3;
  }

  int _moshPendingDiffsCount() {
    try {
      return (widget.shell?.pendingDiffsCount as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  int _moshMaxPendingDiffs() {
    try {
      return (widget.shell?.maxPendingDiffs as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Called whenever xterm's terminal state changes (new server content).
  ///
  /// Self-heal for mosh+tmux copy-mode race: a new MoshV2Connection starts with
  /// TuiDetector inactive. If the user scrolls before the first diff arrives,
  /// the scroll takes the tmux copy-mode path (_tmuxInCopyMode=true). When the
  /// diff lands (terminal changes), TuiDetector activates. We detect this state
  /// here and auto-exit copy-mode, replaying the accumulated offset as SGR so
  /// the scroll reaches Claude/OpenCode instead of tmux history.
  void _onTerminalChanged() {
    // Anchor liveness check first — a TUI repaint / scrollback trim that
    // detached the selection must drop it before anything else runs.
    _selection.onTerminalChanged();
    // Cursor moves on every keystroke (and server echo), so the completion
    // popup's anchor needs the same live tracking as the selection handles.
    if (widget.completions.isNotEmpty) _scheduleCompletionAnchorSync();
    if (!widget.isMosh || !widget.copyModeScroll || !_tmuxInCopyMode) return;
    bool tuiActive = false;
    try {
      tuiActive = (widget.shell?.moshTuiActive as bool?) ?? false;
    } catch (_) {}
    if (!tuiActive) tuiActive = !widget.terminal.cursorVisibleMode;
    // Also use SessionTab.remoteTuiHint — driven by _trackRemoteTui scanning
    // ESC[?25l/h history. moshTuiActive may briefly latch off after a
    // partial frame; remoteTuiHint is the more durable signal once a TUI
    // app is known to be in front.
    if (!tuiActive) tuiActive = widget.remoteTuiHint;
    if (!tuiActive) return;
    // TUI just activated while we were stuck in copy-mode. Exit and replay.
    final capturedOffset = _tmuxScrollOffset;
    _exitTmuxAndSync();
    if (capturedOffset > 0) {
      _nonTmuxScrollLines += capturedOffset;
      _pendingSgrUp += capturedOffset;
      _lastUseSgrWheel = true;
      _lastSgrWasRemoteTui = true;
      _flushSgr();
    }
  }

  // ── SGR wheel: inertia after finger lift ──────────────────────────────────

  void _startSgrInertia(double velocityPxPerFrame) {
    _sgrInertiaVelocity = velocityPxPerFrame;
    _sgrInertiaAccum = 0.0;
    _sgrInertiaRunning = true;
    _scheduleSgrInertiaFrame();
  }

  void _scheduleSgrInertiaFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sgrInertiaRunning) return;
      _sgrInertiaVelocity *= 0.88; // exponential decay: ~0.5 s to stop
      if (_sgrInertiaVelocity.abs() < 0.5) {
        _sgrInertiaRunning = false;
        return;
      }
      _sgrInertiaAccum += _sgrInertiaVelocity;
      final lineH = _sgrLastLineH;
      while (_sgrInertiaAccum.abs() >= lineH) {
        final up = _sgrInertiaAccum < 0;
        _sgrInertiaAccum += up ? lineH : -lineH;
        if (up) {
          _pendingSgrUp++;
          _nonTmuxScrollLines++;
        } else if (_nonTmuxScrollLines > 0 || widget.copyModeScroll) {
          _pendingSgrDown++;
          if (_nonTmuxScrollLines > 0) _nonTmuxScrollLines--;
        }
      }
      _flushSgr();
      if (widget.copyModeScroll &&
          widget.isMosh &&
          _pendingSgrUp == 0 &&
          _pendingSgrDown == 0 &&
          _nonTmuxScrollLines == 0 &&
          _sgrInertiaVelocity > 0) {
        _scheduleDelayedTmuxSgrExit(extraWheelDown: 6);
      }
      _scheduleSgrInertiaFrame();
    });
  }

  void _scheduleDelayedTmuxSgrExit({int extraWheelDown = 0}) {
    if (!widget.copyModeScroll) return;
    _delayedTmuxSgrExit?.cancel();
    if (extraWheelDown > 0) {
      final evt = '\x1b[<65;$_sgrCol;${_sgrRow}M';
      _writeToShell(evt * extraWheelDown);
    }
    _delayedTmuxSgrExit = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _exitTmuxAndSync();
    });
  }

  void _exitTmuxAndSync() {
    _tmuxInCopyMode = false;
    _tmuxScrollOffset = 0;
    _needsCopyModeRefresh = false;
    _skipRefreshNextFlush = false;
    // Discard any scroll commands that haven't fired yet — sending them after
    // cancel would briefly re-enter copy-mode and leave a visible residual.
    _pendingScrollUp = 0;
    _pendingScrollDown = 0;
    _pendingSgrUp = 0;
    _pendingSgrDown = 0;
    _sgrFallback?.cancel();
    _delayedTmuxSgrExit?.cancel();
    widget.onExitScrollMode?.call();
    termDebug.tmuxInCopyMode = false;
  }

  /// Show the long-press menu at [localPosition]. Replaces the old behaviour of
  /// entering selection mode directly — selection is now one of the menu's
  /// actions, so paste can live alongside it.
  void _showLongPressMenu(Offset localPosition) {
    if (!mounted) return;
    _longPressTimer = null;
    // Haptic belongs here, not in _enterSelectionMode: this is the moment the
    // long-press actually takes effect.
    HapticFeedback.mediumImpact();
    // Deliberately does NOT hide the keyboard — the user may paste and keep
    // typing. Only _enterSelectionMode hides it (its existing
    // SystemChannels.textInput 'TextInput.hide' call stays where it is).
    // This gesture's own pointer-up must not also count as a tap — that would
    // reopen the keyboard right as the menu appears, resizing the layout out
    // from under the menu's just-captured anchor.
    _suppressTapAfterMenu = true;
    setState(() => _longPressMenuAt = localPosition);
  }

  void _dismissLongPressMenu() {
    if (!mounted || _longPressMenuAt == null) return;
    setState(() => _longPressMenuAt = null);
  }

  /// Enter selection mode by selecting the word under [localPosition]
  /// (TerminalWidget Stack-local coordinates).
  void _enterSelectionMode(Offset localPosition) {
    if (!mounted) return;
    _longPressTimer = null;
    // 清掉来路不明的残留选区（幽灵高亮）。
    //
    // **只在我们自己没有选区时清**：clearSelection() 会 dispose 掉 controller
    // 持有的那对 anchor，而选区活跃时那正是 _selection._state 里 _Anchored
    // 持有的同一批对象 —— 无条件清等于把自己的选区先拆了。幽灵的定义本来就是
    // "我们空、xterm 不空"，条件式才对得上。
    if (!_selection.isActive) _controller.clearSelection();
    // Hide keyboard without unfocusing — unfocus triggers a resize which can
    // dispose buffer lines and detach the anchors we are about to create.
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    final rt = _terminalViewKey.currentState?.renderTerminal;
    if (rt == null) return;
    final stackBox = context.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;

    final rtLocal = rt.globalToLocal(stackBox.localToGlobal(localPosition));
    final cell = rt.getCellOffset(rtLocal);
    _selection.selectWordAt(cell);
    if (!_selection.isActive) return;

    _syncHandlePositions();
    _suppressTapDismiss = true;
    setState(() {});
    widget.onSelectionModeChanged?.call(true);
  }

  void _exitSelectionMode() {
    if (!_selection.isActive) return;
    // Everything else (handle state, the onSelectionModeChanged callback, the
    // rebuild that removes the overlay) is done by _onSelectionChanged.
    _selection.clear();
  }

  /// The selection changed: recompute handle pixels, or tear the overlay down.
  ///
  /// This is the ONLY consumer of selection state. It never writes back into
  /// the controller — that back-edge is exactly what the rewrite removed.
  void _onSelectionChanged() {
    if (!mounted) return;
    if (!_selection.isActive) {
      _draggingHandle = null;
      _liftFlipped = false;
      _suppressTapDismiss = false;
      _handlePositions.value = HandlePositions.zero;
      widget.onSelectionModeChanged?.call(false);
      // The overlay disappears entirely, so this setState IS needed — unlike
      // the position updates below, which the ValueNotifier delivers.
      setState(() {});
      return;
    }
    _scheduleHandleSync();
  }

  /// Refresh the handle positions at most once per frame.
  ///
  /// A drag can produce several pointer-move events within one frame; running
  /// the pixel derivation for each of them is wasted work.
  void _scheduleHandleSync() {
    if (_handleFrameScheduled) return;
    _handleFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleFrameScheduled = false;
      if (!mounted) return;
      _syncHandlePositions();
    });
  }

  /// Cells → pixels. Pure derivation, no side effects.
  ///
  /// The old `_updateHandlePositions` called `scrollController.jumpTo(0)` from
  /// in here — a coordinate calculation that quietly moved the viewport, and
  /// then needed a `fromScroll` flag to avoid re-entering itself. That was the
  /// real cause of "handles misplaced after the keyboard opens": the keyboard
  /// only changes the viewport height, it does not reflow, so the anchors were
  /// fine all along; the pixel derivation was what was broken.
  void _syncHandlePositions() {
    final begin = _selection.begin;
    final end = _selection.end;
    if (begin == null || end == null) return;
    final rt = _terminalViewKey.currentState?.renderTerminal;
    if (rt == null) return;
    final renderObj = context.findRenderObject();
    if (renderObj == null || !renderObj.attached) return;
    final stackBox = renderObj as RenderBox;
    if (!stackBox.hasSize) return;

    final cellH = rt.cellSize.height;
    final startLocal = rt.getOffset(begin);
    final endLocal = rt.getOffset(end) + Offset(0, cellH);

    _handlePositions.value = HandlePositions(
      stackBox.globalToLocal(rt.localToGlobal(startLocal)),
      stackBox.globalToLocal(rt.localToGlobal(endLocal)),
      dragging: _draggingHandle != null,
    );
  }

  /// Refresh the completion popup's anchor at most once per frame.
  ///
  /// Mirrors [_scheduleHandleSync]: [_onTerminalChanged] can fire on every
  /// byte of server output, far more often than the popup's position
  /// actually needs to move.
  void _scheduleCompletionAnchorSync() {
    if (_completionAnchorFrameScheduled) return;
    _completionAnchorFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _completionAnchorFrameScheduled = false;
      if (!mounted) return;
      _syncCompletionAnchor();
    });
  }

  /// Cursor cell → pixel rect, in this widget's own Stack-local coordinates.
  ///
  /// Mirrors the global→local conversion in [_syncHandlePositions], but reads
  /// the position via xterm's own [TerminalViewState.globalCursorRect]
  /// (`renderTerminal.localToGlobal(cursorOffset) & cellSize`, built from
  /// `buffer.absoluteCursorY` — the buffer-absolute row, not the
  /// viewport-relative `buffer.cursorY` — so it stays correct once scrollback
  /// exists) rather than re-deriving it from a raw CellOffset, since there is
  /// no selection anchor to reuse here.
  void _syncCompletionAnchor() {
    if (widget.completions.isEmpty) return;
    final viewState = _terminalViewKey.currentState;
    if (viewState == null) return;
    final renderObj = context.findRenderObject();
    if (renderObj == null || !renderObj.attached) return;
    final stackBox = renderObj as RenderBox;
    if (!stackBox.hasSize) return;
    final globalRect = viewState.globalCursorRect;
    final topLeft = stackBox.globalToLocal(globalRect.topLeft);
    _completionAnchor.value = topLeft & globalRect.size;
  }

  /// Hides the completion popup the instant the user scrolls the terminal.
  ///
  /// The popup's anchor is only valid for the cursor's current on-screen
  /// position; continuously re-pinning it across a scroll would need the same
  /// machinery as the selection handles ([_scheduleHandleSync]). The popup's
  /// lifetime is just the few seconds it takes to type one command — unlike
  /// the handles, which must survive indefinitely — so closing it outright on
  /// scroll is the simpler tradeoff. It reappears on the next keystroke, via
  /// [didUpdateWidget] resetting [_completionHiddenByScroll] when
  /// TerminalScreen pushes a fresh [TerminalWidget.completions] list.
  void _onCompletionScroll() {
    if (_completionHiddenByScroll || widget.completions.isEmpty) return;
    setState(() => _completionHiddenByScroll = true);
  }

  /// 开始拖拽某一端。两条命中路径共用：外层 Listener 的 [nearestHandle]，
  /// 以及 handle 自己收到的 pointerDown（见 `selection_overlay.dart` 里
  /// `_SelectionHandle` 的"两道命中"注释）。
  ///
  /// [local] 是 TerminalWidget Stack 的局部坐标。
  void _beginHandleDrag(HandleHit hit, Offset local) {
    final pos = _handlePositions.value;
    _draggingHandle = hit;
    _liftFlipped = false;
    final anchor = hit == HandleHit.start ? pos.start : pos.end;
    _grabOffset = anchor - local;
    _selection.beginDrag(
      hit == HandleHit.start ? SelectionEnd.start : SelectionEnd.end,
    );
    // Republish so the overlay sees dragging=true and hides the menu.
    _syncHandlePositions();
  }

  /// 结束拖拽。同样被两条路径共用。
  void _endHandleDrag() {
    if (_draggingHandle == null) return;
    _draggingHandle = null;
    _liftFlipped = false;
    _selection.endDrag();
    // Republish so the overlay sees dragging=false and brings the menu back.
    _syncHandlePositions();
  }

  /// 把全局坐标换成 Stack 局部坐标。handle 自己收到的事件带的是全局坐标。
  Offset? _toStackLocal(Offset globalPosition) {
    final stackBox = context.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return null;
    return stackBox.globalToLocal(globalPosition);
  }

  /// Dragging: pixels → cell → controller. Both ends take the same path.
  ///
  /// The old code split this into _onStartHandleDrag / _onEndHandleDrag, one
  /// calling getCellOffset (floor) and the other getSelectionEndOffset (ceil).
  /// That asymmetry, hidden inside two apparently symmetric methods, is where
  /// the off-by-one-cell and whole-cell jumps came from.
  void _onHandleDrag(Offset localPosition) {
    final rt = _terminalViewKey.currentState?.renderTerminal;
    final stackBox = context.findRenderObject() as RenderBox?;
    if (rt == null || stackBox == null || !stackBox.hasSize) return;

    final lifted = liftedTouchPoint(
      finger: localPosition,
      grabOffset: _grabOffset,
      cellHeight: rt.cellSize.height,
      wasFlipped: _liftFlipped,
    );
    _liftFlipped = lifted.flipped;

    final rtLocal = rt.globalToLocal(stackBox.localToGlobal(lifted.point));
    // Row: getCellOffset's y is a plain integer division, no floor/ceil
    // ambiguity, and it already accounts for padding and scroll offset.
    final row = rt.getCellOffset(rtLocal).y;
    // Column: our own round-based formula. RenderTerminal's padding is private,
    // but getOffset(0,0).dx IS padding.left — without subtracting it the column
    // is off by 4px, i.e. up to half a cell at typical font sizes.
    final originX = rt.getOffset(const CellOffset(0, 0)).dx;
    final col = cellColumnAt(
      x: rtLocal.dx - originX,
      cellWidth: rt.cellSize.width,
    );
    _selection.updateDrag(CellOffset(col, row));
    _scheduleHandleSync();
  }

  /// Keep the handles pinned to their text while the view scrolls.
  ///
  /// Handle positions are pixels derived from the current scroll offset
  /// (`rt.getOffset` is viewport-relative), so without this they keep their old
  /// pixels and visibly drift away from the selected text as the user scrolls.
  void _onScrollUpdateHandles() {
    if (!mounted || !_selection.isActive) return;
    if (_draggingHandle != null) return; // the drag path owns the positions
    _scheduleHandleSync();
  }

  Future<void> _copySelection() async {
    final text = _selection.readText();
    // The old code had two bare `return`s here (selection == null / empty
    // text), so tapping Copy in an alt buffer could do nothing at all — not
    // even a message. Silence is reserved for the happy path.
    if (text == null || text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.selectionExpired),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      _exitSelectionMode();
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.selectionCopied(text.length)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    _exitSelectionMode();
  }

  /// Read the clipboard and send it to the shell.
  ///
  /// The clipboard is read only when the user taps Paste — probing it up front
  /// to enable/disable the menu item would fire the iOS 14+ "pasted from"
  /// banner on every single long-press.
  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      // Clipboard.getData can throw PlatformException on some Android
      // configurations. An unreadable clipboard and an empty one look the
      // same to the user, so reuse pasteClipboardEmpty rather than adding a
      // new l10n string for a rare platform error.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.pasteClipboardEmpty),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!mounted) return;
    final text = data?.text;
    // Mirror _writeToShell's writability condition exactly (see its body):
    // a transport OR a shell must be attached, otherwise bytes are dropped.
    final connected = widget.transport != null || widget.shell != null;
    final rejection = classifyPaste(text, connected: connected);
    if (rejection != PasteRejection.none) {
      final l = context.l10n;
      final message = switch (rejection) {
        PasteRejection.empty => l.pasteClipboardEmpty,
        PasteRejection.disconnected => l.pasteNotConnected,
        PasteRejection.tooLarge =>
          l.pasteTooLarge('${(pasteByteSize(text!) / 1024).round()} KB'),
        PasteRejection.none => '',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    // Route through terminal.paste(), NOT _writeToShell(): paste() applies
    // bracketed-paste wrapping when the remote enabled ?2004, and going
    // through terminal.onOutput keeps ActivityTracker.recordInput() and the
    // onUserInput line accumulation (command history) working. _writeToShell
    // would bypass both.
    //
    // NOT preserved — the dangerous-command guard does NOT inspect pastes.
    // `_interceptTerminalInput` bails on `data != '\r'` (terminal_screen.dart),
    // and a paste always arrives as ONE multi-character payload, never a lone
    // CR, so the guard cannot fire for it no matter how we route. Consequence:
    //   • ?2004 on  (bash/zsh/fish/Claude Code default) — the payload is inert
    //     literal text; a trailing newline does NOT execute. Safe.
    //   • ?2004 off (old sh, some TUIs) — a trailing newline executes the
    //     command immediately, unguarded.
    // Extending the guard to inspect paste payloads is deliberately out of
    // scope here; see the design doc's "多行粘贴" section.
    widget.terminal.paste(text!);
  }

  /// Programmatically open the software keyboard.
  /// Called by TerminalScreen's KeyBar icon button when
  /// keyboardTriggerMode is [KeyboardTriggerMode.iconButton].
  void requestKeyboard() {
    _terminalViewKey.currentState?.requestKeyboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.terminal.removeListener(_onTerminalChanged);
    _selection.removeListener(_onSelectionChanged);
    widget.scrollController?.removeListener(_onScrollUpdateHandles);
    widget.scrollController?.removeListener(_onCompletionScroll);
    _completionAnchor.dispose();
    _sgrFallback?.cancel();
    _sgrInertiaRunning = false;
    _resizeDebounce?.cancel();
    _keyboardNormalizeTimer?.cancel();
    _keyboardCloseResizeTimer?.cancel();
    _keyboardOpenResizeTimer?.cancel();
    _pinchWatchdog?.cancel();
    _longPressTimer?.cancel();
    _holdRepeat.dispose();
    // Must precede _controller.dispose(): the selection controller's clear()
    // calls _controller.clearSelection(), and touching a disposed
    // ChangeNotifier trips an assertion in debug builds.
    _selection.dispose();
    _handlePositions.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Authoritative keyboard-inset observer (raw, bypasses MediaQuery).
  ///
  /// [didChangeDependencies] only fires when an ancestor InheritedWidget
  /// notifies us. On Android with `windowSoftInputMode=adjustNothing`
  /// (our AndroidManifest setting), some IME transitions (multi-window,
  /// floating-keyboard, IME switch, system-bar jitter, fullscreen toggle)
  /// do not always propagate through MediaQuery and the show/hide chain
  /// silently misses them — which is the "sometimes keyboard show is not
  /// detected, no resize triggered" symptom users reported.
  ///
  /// [didChangeMetrics] is wired directly to
  /// PlatformDispatcher.onMetricsChanged, so it fires on every raw
  /// `View.viewInsets` change unconditionally. Reading viewInsets straight
  /// from the platform view bypasses the MediaQuery middleman entirely.
  /// `_processViewInsetChange` is idempotent — if the MediaQuery path
  /// already fired for this transition, the second call from here is a
  /// no-op via the inset-equality latch.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;
    // viewInsets is in physical pixels — convert to logical to match the
    // MediaQuery path which already does that conversion.
    final logicalInset = view.viewInsets.bottom / view.devicePixelRatio;
    _processViewInsetChange(logicalInset);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<TerminalSettings>();
    // Use Listener (raw pointer events) instead of GestureDetector for pinch
    // zoom and alt-buffer scroll.
    //
    // Behavior is mode-dependent:
    // • inTmux → opaque: absorbs all pointer events so xterm-dart's internal
    //   scroll handler does NOT also scroll its own buffer while we manage
    //   scrolling via tmux copy-mode exec channel.  Without this, xterm-dart's
    //   scroll buffer accumulates copy-mode historical frames and they visually
    //   overlap with live content when returning from copy-mode.
    // • otherwise → translucent: lets events through so xterm-dart's Scrollable
    //   can handle normal-buffer history scroll and alt-buffer mouse events.
    final terminalView = TerminalView(
      key: _terminalViewKey,
      widget.terminal,
      controller: _controller,
      // 选区归 FlyTerm 独占。xterm 内建的长按/双击/拖拽选词全部下线 —— 它们
      // 终点是 setSelection，会清掉我们在 alt buffer 用的 fixed range，而
      // handle 是 IgnorePointer，拖 handle 的手指必然也喂给底下的识别器。
      // 手机上真正抢走选区的是 LongPressGestureRecognizer（pan 只收鼠标），
      // 按住 handle 停顿越过 500ms 就会触发 —— 这就是"时好时坏"的来源。
      builtinSelectionGestures: false,
      scrollController: widget.scrollController,
      // isMosh: NeverScrollableScrollPhysics 阻止 xterm 对 mosh 的 AbsorbPointer
      // 绕过进行 scroll，mosh 的 scrollback 由 scrollController 手动驱动。
      // tmux（copyModeScroll）: 改用 xterm native scroll + capture-pane 历史，
      // 不再需要 NeverScrollable（与非 tmux 行为统一）。
      scrollPhysics:
          widget.isMosh ? const NeverScrollableScrollPhysics() : null,
      theme: AppTerminalThemes.withSelection(
        AppTerminalThemes.of(settings.terminalTheme),
        settings.selectionColor,
      ),
      cursorType: _toXtermCursorType(settings.cursorStyle),
      // 闪烁**不再跟光标形态绑定**。旧代码是
      // `cursorBlink: style != defaultStyle` —— 选「默认」光标就不闪，
      // 选块/下划线/竖线就闪，两者被硬编成了一件事。iTerm2 里它们是两个
      // 独立开关（形态选「块」+ 闪烁关 是常用组合），所以拆开。
      cursorBlink: settings.cursorBlink,
      forceAppCursor: settings.cursorStyle != TerminalCursorStyle.defaultStyle,
      legacyCursor: settings.cursorStyle == TerminalCursorStyle.defaultStyle,
      textStyle: TerminalStyle(
        fontSize: settings.fontSize,
        height: settings.lineHeight,
        fontFamily:
            settings.fontFamily == 'system' ? 'monospace' : settings.fontFamily,
        // Font fallback chain — Skia walks this list in order until it
        // finds a glyph for the requested codepoint. Order matters:
        //   1. APK-bundled MONOSPACED symbol font (see note below)
        //   2. APK-bundled font with extra symbol coverage
        //   3. Android system generic families (always resolvable via
        //      SkFontMgr on Android; safety net for plain Latin / NBSP
        //      / punctuation when the primary monospace font has a hole)
        //   4. CJK — remote shells often emit Chinese / Japanese
        //   5. Extra symbol blocks (box drawing, dingbats, geometric)
        //   6. Color emoji — must come last so plain-text codepoints
        //      don't accidentally pick up an emoji presentation
        //
        // DejaVuSansMono must precede NotoSansSymbols2. A terminal cell is
        // as wide as the primary font's advance (0.600 em for both
        // JetBrainsMono and CourierPrime). Neither primary has a glyph for
        // the Ballot Box range, so these codepoints always fall through —
        // and NotoSansSymbols2 is a PROPORTIONAL font: ☐/☒ (U+2610/U+2612)
        // measure 0.821 em and ✔ (U+2714) 0.930 em, i.e. 37–55 % wider than
        // the cell. The glyph gets clipped at the cell edge, which is what
        // turned Claude Code's `☒ … ☐ … ✔ Submit` header bar into ⌧/⌐
        // garbage. DejaVu Sans Mono carries the same coverage at a uniform
        // 0.602 em, so the glyph fits. NotoSansSymbols2 stays behind it to
        // cover blocks DejaVu lacks (Braille, Geometric Shapes Extended).
        fontFamilyFallback: const [
          'DejaVuSansMono',
          'NotoSansSymbols2',
          // System-resolved fallbacks (generic family names that
          // SkFontMgr on Android always maps to something). Adding
          // these makes basic Latin / NBSP / punctuation reliable
          // even if the primary monospace font ever has a hole.
          'monospace',
          'sans-serif',
          'Roboto',
          // CJK — remote PTY may emit 中文 / 日本語 / 한국어
          'Noto Sans CJK SC',
          'Noto Sans CJK',
          'Droid Sans Fallback',
          // Symbol & dingbat blocks (U+2500 box-drawing, U+2700
          // dingbats, U+1F0xx playing cards, etc.)
          'Noto Sans Symbols',
          'Noto Sans Symbols 2',
          // Color emoji last so plain glyphs (e.g. ☀) don't get the
          // emoji presentation when a monochrome glyph exists earlier
          // in the chain.
          'Noto Color Emoji',
        ],
      ),
      autofocus: false,
      backgroundOpacity: 1.0,
      padding: const EdgeInsets.all(4),
      deleteDetection: true,
      simulateScroll: false,
      // singleTap: let xterm open keyboard on tap directly.
      // doubleTap/iconButton: suppress xterm's auto-open so our _onPointerUp
      // (double-tap detection) and KeyBar icon remain the sole triggers.
      // inTmux is already guarded by AbsorbPointer so the value doesn't matter,
      // but we set it consistently to false for non-singleTap modes.
      requestKeyboardOnTap:
          widget.keyboardTriggerMode == KeyboardTriggerMode.singleTap,
      onKeyboardShow: _onKeyboardShow,
      onKeyEvent: _onHardwareKey,
      // 诊断：输入法到底有没有走文本编辑通道（deleteSurroundingText）。
      // 只写开发者浮层，不扰终端画面。
      onDeleteEvent: (count) {
        termDebug.imeDelCbs++;
        termDebug.imeDelChars += count;
      },
    );

    // Wrap TerminalView in AbsorbPointer when inTmux or isMosh so xterm-dart's
    // internal TerminalGestureDetector never participates in the gesture arena.
    //
    // isMosh: AbsorbPointer 防止 xterm 的 onDoubleTapDown 触发 selectWord()，
    // 以及防止 xterm Scrollable 与 scrollController 手动驱动冲突。
    //
    // tmux（copyModeScroll）: 不再需要 AbsorbPointer。
    // 旧原因是 xterm scrollback 里有 copy-mode ESC[1L] 帧（乱码）。
    // 现在 capture-pane 填充了干净的历史内容，xterm native scroll 是所需行为。
    // AbsorbPointer only affects hit-testing on the child subtree; the Listener
    // above still receives all pointer events. Keyboard input (TextInput channel)
    // is unaffected.
    final needsAbsorb = widget.isMosh;
    final child =
        needsAbsorb ? AbsorbPointer(child: terminalView) : terminalView;

    final listener = Listener(
      behavior:
          needsAbsorb ? HitTestBehavior.opaque : HitTestBehavior.translucent,
      onPointerDown: (e) => _onPointerDown(e, settings),
      onPointerMove: (e) => _onPointerMove(e, settings),
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: child,
    );

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: listener),
        if (_longPressMenuAt != null)
          TerminalFloatingMenu(
            anchor: Rect.fromCenter(
              center: _longPressMenuAt!,
              width: 0,
              height: 0,
            ),
            actions: [
              TerminalMenuAction(
                icon: Icons.text_fields,
                label: context.l10n.selectionSelect,
                onTap: () {
                  final pos = _longPressMenuAt!;
                  _dismissLongPressMenu();
                  _enterSelectionMode(pos);
                },
              ),
              TerminalMenuAction(
                icon: Icons.content_paste,
                label: context.l10n.selectionPaste,
                onTap: () {
                  _dismissLongPressMenu();
                  unawaited(_pasteFromClipboard());
                },
              ),
            ],
          ),
        if (_selection.isActive)
          Positioned.fill(
            child: TerminalSelectionOverlay(
              handles: _handlePositions,
              onCopy: () => unawaited(_copySelection()),
              // handle 自己收事件是第一道命中，物理隔离 —— 按在它上面时外层
              // Listener 根本收不到，不可能被误判成 tap 而退出选区。外层的
              // nearestHandle 只负责兜底 handle 画到视口外的边缘情况。
              onHandleGrab: (which, global) {
                final local = _toStackLocal(global);
                if (local != null) _beginHandleDrag(which, local);
              },
              onHandleMove: (global) {
                if (_draggingHandle == null) return;
                final local = _toStackLocal(global);
                if (local != null) _onHandleDrag(local);
              },
              onHandleRelease: _endHandleDrag,
            ),
          ),
        if (widget.completions.isNotEmpty &&
            widget.onAcceptCompletion != null &&
            !_completionHiddenByScroll)
          ValueListenableBuilder<Rect?>(
            valueListenable: _completionAnchor,
            builder: (context, anchor, _) {
              // CompletionPopup.build() already returns its own
              // Positioned.fill — wrapping it in another one here would hand
              // the same RenderObject two StackParentData-writing ancestors
              // and trip Flutter's "Incorrect use of ParentDataWidget" check
              // (see TerminalFloatingMenu above for the same pattern).
              if (anchor == null) return const SizedBox.shrink();
              return CompletionPopup(
                suggestions: widget.completions,
                input: widget.completionInput,
                anchor: anchor,
                onAccept: widget.onAcceptCompletion!,
              );
            },
          ),
      ],
    );
  }

  TerminalCursorType _toXtermCursorType(TerminalCursorStyle style) {
    switch (style) {
      case TerminalCursorStyle.defaultStyle:
        return TerminalCursorType.block;
      case TerminalCursorStyle.block:
        return TerminalCursorType.block;
      case TerminalCursorStyle.underline:
        return TerminalCursorType.underline;
      case TerminalCursorStyle.verticalBar:
        return TerminalCursorType.verticalBar;
    }
  }
}
