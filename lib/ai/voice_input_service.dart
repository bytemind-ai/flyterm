// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'inline_speech_recognizer.dart';
import 'voice_diagnostics.dart';

enum VoiceInputIssue {
  none,
  microphonePermissionDenied,
  speechPermissionDenied,
  recognizerUnavailable,
  microphoneMutedOrNoSpeech,
  busy,
  network,
  unknown,
}

/// How the underlying `SpeechRecognizer` gets created.
///
/// `speech_to_text` offers three mutually exclusive creation paths and we used
/// only the first. On some devices that one binds a service that accepts the
/// bind and then refuses to run — `error_client`, milliseconds in, every time.
/// The other two are different enough at the platform level to be worth trying
/// before giving up on inline recording and handing the screen over to the
/// system speech UI:
///
/// ```kotlin
/// // SpeechToTextPlugin.kt, createRecognizer()
/// if (intentLookup) {
///     createSpeechRecognizer(ctx, ctx.findComponentName())   // ← intentLookup
/// } else {
///     if (SDK >= S && onDevice) createOnDeviceSpeechRecognizer(ctx)  // ← onDevice
///     if (null == speechRecognizer) createSpeechRecognizer(ctx)      // ← platformDefault
/// }
/// ```
///
/// ## Why the order is what it is
///
/// [platformDefault] is first by choice: devices where inline recording already
/// works succeed on it and never see the rest, so escalation carries no
/// regression risk.
///
/// The *rest* of the order is not a choice — the plugin forces it. Creation is
/// skipped entirely unless `onDevice` changed since last time:
///
/// ```kotlin
/// private fun createRecognizer(onDevice: Boolean, listenMode: ListenMode) {
///     if (null != speechRecognizer && onDevice == lastOnDevice) {
///         return                        // ← nothing is rebuilt
///     }
///     lastOnDevice = onDevice
///     speechRecognizer?.destroy(); speechRecognizer = null
///     ...
/// ```
///
/// `onDevice` is the *only* value it compares, and the Kotlin plugin is a
/// per-engine singleton whose `initialize()` never clears `speechRecognizer`.
/// So a tier that does not flip `onDevice` silently keeps running on the
/// previous tier's recognizer — which is exactly what an earlier version of
/// this cascade did: `intentLookup` sat in slot 2 with `onDevice` false on both
/// sides, so it never rebuilt anything and the whole tier was a no-op.
///
/// Flipping `onDevice` on every escalation (false → true → false) is therefore
/// mandatory, and since `onDevice` also *selects* the on-device factory, the
/// tier that has it set must be the one that wants it. Hence: default, then
/// on-device, then intent-lookup.
enum VoiceEngineTier {
  /// Binds whatever `Settings.Secure.VOICE_RECOGNITION_SERVICE` points at.
  /// The plugin's default, and what every working device uses.
  /// `intentLookup=false`, `onDevice=false`.
  platformDefault,

  /// Android 12+ on-device recognizer — a separate platform factory
  /// (`createOnDeviceSpeechRecognizer`), not just a different service binding.
  /// `intentLookup=false`, `onDevice=true`.
  ///
  /// Degrades to [platformDefault] when `isOnDeviceRecognitionAvailable()` is
  /// false (common off Pixel), in which case it fails the same way and the
  /// cascade moves on. The flip still forces the rebuild the next tier needs.
  onDevice,

  /// Enumerates *all* installed `RecognitionService`s and binds the first.
  /// `intentLookup=true`, `onDevice=false`.
  ///
  /// Works around the vendor-ROM case where the system default points at a
  /// component that won't serve third-party binds while a usable service
  /// (e.g. Google's) sits right next to it in the list. The plugin documents
  /// this option as being for "Android builds [that] do not properly define
  /// the default speech recognition intent".
  ///
  /// Note `intentLookup` wins over `onDevice` inside `createRecognizer`, so
  /// this tier must come last **among the `speech_to_text` tiers**: with it
  /// set, no later one could reach any other creation path.
  intentLookup,

  /// Our own recognizer ([InlineSpeechRecognizer]), bound to each installed
  /// `RecognitionService` in turn by explicit `ComponentName`.
  ///
  /// The previous three tiers can only ever reach two services: the system
  /// default, and `queryIntentServices(...).firstOrNull()`. When the vendor's
  /// broken stub *is* the first entry, those are the same service and a working
  /// one further down the list is unreachable — no `speech_to_text` option can
  /// express "try that other one". This tier walks the whole list.
  ///
  /// Unaffected by the plugin-singleton problems above: a different backend
  /// entirely, with a fresh `SpeechRecognizer` per attempt.
  targetedBind,
}

class VoiceInputService extends ChangeNotifier {
  /// Rebuilt on each tier escalation: `intentLookup` is an *initialize-time*
  /// option and `SpeechToText.initialize()` short-circuits on
  /// `if (_initWorked) return`, so a tier change cannot be applied to an
  /// instance that has already initialized. Hence a factory rather than a
  /// single injected object.
  SpeechToText _stt;
  final SpeechToText Function() _sttFactory;
  final Future<bool> Function()? _permissionChecker;
  bool _isAvailable = false;
  bool _isListening = false;
  String? _lastError;
  String? _lastStatus;
  bool _permissionDenied = false;
  int _listenGeneration = 0;

  /// Cascade order. See [VoiceEngineTier] — the `onDevice` flag must alternate
  /// across consecutive entries or the platform skips rebuilding the
  /// recognizer and the tier does nothing.
  static const List<VoiceEngineTier> _tiers = [
    VoiceEngineTier.platformDefault, // onDevice: false
    VoiceEngineTier.onDevice, //        onDevice: true   ← forces rebuild
    VoiceEngineTier.intentLookup, //    onDevice: false  ← forces rebuild
    VoiceEngineTier.targetedBind, //    our own backend, walks every service
  ];

  int _tierIndex = 0;

  VoiceEngineTier get engineTier => _tiers[_tierIndex];

  /// Every installed `RecognitionService`, fetched when the [targetedBind] tier
  /// is entered, plus a cursor into it.
  ///
  /// Failing services are stepped through *within* the tier, so this cursor is
  /// a second dimension of escalation under [_tierIndex].
  List<String> _targetedServices = const [];
  int _targetedIndex = 0;

  static bool _usesSpeechToText(VoiceEngineTier tier) =>
      tier != VoiceEngineTier.targetedBind;

  String? get _currentTargetedService =>
      _targetedIndex < _targetedServices.length
          ? _targetedServices[_targetedIndex]
          : null;

  /// Snapshot for the diagnostics dump — what the device actually offers is the
  /// single most useful fact when voice input doesn't work, and it is otherwise
  /// only visible in `logcat`.
  List<String> get recognitionServices => List.unmodifiable(_targetedServices);

  /// [stt] is the first engine instance; [sttFactory] builds replacements when
  /// escalating tiers. Passing only [stt] (as existing tests do) keeps the old
  /// single-instance behaviour: escalation then reuses that same object, which
  /// is fine for fakes since they don't care about initialize-time options.
  VoiceInputService([
    SpeechToText? stt,
    Future<bool> Function()? permissionChecker,
    SpeechToText Function()? sttFactory,
    InlineSpeechRecognizer? inline,
  ]) : _stt = stt ?? sttFactory?.call() ?? SpeechToText(),
       _sttFactory = sttFactory ?? (() => stt ?? SpeechToText()),
       _permissionChecker = permissionChecker,
       _inline = inline ?? InlineSpeechRecognizer() {
    _inlineSub = _inline.events.listen(_handleInlineEvent);
  }

  /// Backend for the [VoiceEngineTier.targetedBind] tier.
  final InlineSpeechRecognizer _inline;
  StreamSubscription<InlineSpeechEvent>? _inlineSub;

  /// Generation the inline subscription is serving, so a late event from a
  /// superseded session is dropped exactly as the `speech_to_text` callbacks
  /// are.
  int _inlineGeneration = -1;

  /// Translates inline events onto the *same* two handlers the
  /// `speech_to_text` backend uses.
  ///
  /// Deliberately not a parallel state machine. Error classification, the
  /// startup-window "died before it listened" check, tier escalation, the empty
  /// grace period and the stuck watchdog all live in those handlers; routing
  /// through them means the new backend inherits every one of them instead of
  /// re-deriving (and re-breaking) them.
  void _handleInlineEvent(InlineSpeechEvent event) {
    if (_inlineGeneration != _listenGeneration) return;
    switch (event) {
      case InlineSpeechStarted():
        // Already reflected optimistically by `_beginSession`.
        break;
      case InlineSpeechEndOfSpeech():
        // Same meaning as the plugin's `notListening`: mic closed, verdict
        // still outstanding.
        _handleSpeechStatus('notListening');
      case InlineSpeechResult(:final text):
        final words = text ?? '';
        if (words.isEmpty) {
          // Ran and produced nothing — the same outcome `doneNoResult`
          // describes on the other backend.
          _handleSpeechStatus('done');
          return;
        }
        final generation = _listenGeneration;
        _sessionGotResult = true;
        _consecutiveEngineFailures = 0;
        _isListening = false;
        _settleSession(generation);
        notifyListeners();
        _activeOnResultForInline?.call(words);
      case InlineSpeechError(:final code):
        _handleSpeechError(SpeechRecognitionError(code, true));
    }
  }

  /// The inline backend delivers results through a stream rather than a
  /// per-call closure, so the active session's sink is held here.
  void Function(String)? _activeOnResultForInline;

  bool get isAvailable => _isAvailable;
  bool get isListening => _isListening;
  String? get lastError => _lastError;
  String? get lastStatus => _lastStatus;
  VoiceInputIssue get issue => _classifyIssue(_lastError, _isAvailable);

  /// Whether the recognizer has actually been probed yet.
  ///
  /// Voice input is initialized lazily, on the first mic tap (see the
  /// comment in `main.dart`) — so before that, [isAvailable] is `false`
  /// simply because nobody has asked, not because anything is wrong.
  bool _probed = false;

  /// Set once [ensurePermissions] has confirmed we actually hold
  /// `RECORD_AUDIO`.
  ///
  /// Exists to disambiguate `error_permission`
  /// (`SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS`), which a recognition
  /// service can raise about *its own* internals. Observed on a Xiaomi ROM,
  /// milliseconds after the same service reported a successful start and
  /// milliseconds after our own permission check passed:
  ///
  /// ```text
  /// [inline] InlineSpeechStarted
  /// [stt] onError error_permission     ← +29 ms
  /// [stt] onError error_network         ← +3 s
  /// ```
  ///
  /// Taken at face value that produced "grant FlyTerm microphone access in
  /// system settings" on a device where the permission was already granted —
  /// advice the user can only follow to no effect. Once this flag is set, a
  /// bare `error_permission` is a statement about the engine, not about us.
  bool _permissionVerified = false;

  /// `true` only once the recognizer has been probed *and* came back
  /// unusable.
  ///
  /// UI must render the mic against this, not against `!isAvailable`.
  /// Those differ exactly during the window that matters: at app start
  /// `isAvailable` is `false`, so a button styled off it draws itself as
  /// [Icons.mic_off] in disabled colours — while still being perfectly
  /// tappable. The icon claimed the feature was broken before anyone had
  /// touched it, which is its own half of "语音不可用".
  bool get isKnownUnavailable => _probed && !_isAvailable;

  /// In-app recording has proven, on this device, that it cannot run at all.
  ///
  /// Distinct from [isKnownUnavailable], and that distinction is the whole
  /// point: `initialize()` *succeeds* on the devices this covers, so
  /// [isAvailable] stays `true` and every tap looks like it should work. The
  /// session then dies in single-digit milliseconds, before the mic is ever
  /// opened:
  ///
  /// ```text
  /// 09:37:48.645  onStatus listening        ← recognizer says it started
  /// 09:37:48.647  onStatus notListening     ← 2 ms later it's over
  /// 09:37:48.647  onError  error_client
  /// ```
  ///
  /// Typical on vendor ROMs where a `RecognitionService` is *declared* (so
  /// `isRecognitionAvailable()` answers yes) but refuses to serve third-party
  /// binds. Such a device usually still has perfectly good speech recognition
  /// reachable through the system UI / the keyboard's mic key — just not
  /// through the bound-service API `speech_to_text` uses.
  ///
  /// Set only from the startup-window check in [_handleSpeechError], and only
  /// for errors that describe the *machinery* failing. It is deliberately not
  /// persisted: it lasts the app run, so a device that gets its speech stack
  /// fixed is re-probed on next launch.
  bool _inAppPathBroken = false;

  bool get inAppPathBroken => _inAppPathBroken;

  Future<bool> ensurePermissions() async {
    final injected = _permissionChecker;
    if (injected != null) {
      final ok = await injected();
      if (!ok) {
        _isAvailable = false;
        _permissionDenied = true;
        _lastError = 'error_permission_microphone';
        notifyListeners();
      } else {
        _permissionDenied = false;
        _permissionVerified = true;
      }
      return ok;
    }

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _isAvailable = false;
      _permissionDenied = true;
      _permissionVerified = false;
      _lastError = 'error_permission_microphone';
      notifyListeners();
      return false;
    }
    _permissionDenied = false;
    _permissionVerified = true;

    // Android SpeechRecognizer only needs RECORD_AUDIO. iOS/iPadOS also
    // requires the separate Speech Recognition permission.
    if (Platform.isIOS || Platform.isMacOS) {
      final speech = await Permission.speech.request();
      if (!speech.isGranted) {
        _isAvailable = false;
        _permissionDenied = true;
        _lastError = 'error_permission_speech';
        notifyListeners();
        return false;
      }
    }
    return true;
  }

  Future<bool> prepare() async {
    if (!await ensurePermissions()) return false;
    if (!_isAvailable) {
      await initialize();
    }
    return _isAvailable;
  }

  Future<void> openSettings() => openAppSettings();

  Future<void> initialize() async {
    try {
      if (_permissionDenied) {
        _lastError = 'error_permission_microphone';
        notifyListeners();
        return;
      }
      _lastError = null;
      if (engineTier == VoiceEngineTier.targetedBind) {
        _targetedServices = await _inline.listServices();
        _targetedIndex = 0;
        _isAvailable = _targetedServices.isNotEmpty;
        _probed = true;
        VoiceDiagnostics.instance.log(
          'stt',
          'initialize tier=targetedBind -> ${_targetedServices.length} '
              'service(s): ${_targetedServices.isEmpty ? "(none)" : _targetedServices.join(", ")}',
        );
        if (!_isAvailable) _lastError = 'error_recognizer_unavailable';
        notifyListeners();
        return;
      }
      _isAvailable = await _stt.initialize(
        onError: _handleSpeechError,
        onStatus: _handleSpeechStatus,
        // 打开插件自己的日志：它的 Android 端会把每一步打进 logcat
        // （"Notify status:…"、"Error N after start at Nms …"、以及
        // findComponentName() 枚举出的 RecognitionService 列表），那是唯一
        // 能看到绑定式识别器内部时序的地方。日志比省下的一点开销值钱。
        debugLogging: true,
        options: _initOptionsFor(engineTier),
      );
      _probed = true;
      VoiceDiagnostics.instance.log(
        'stt',
        'initialize tier=${engineTier.name} -> isAvailable=$_isAvailable',
      );
      if (!_isAvailable) {
        _lastError = 'error_recognizer_unavailable';
      }
    } catch (e) {
      _isAvailable = false;
      _probed = true;
      _lastError = e.toString();
    }
    notifyListeners();
  }

  /// Initialize-time options for [tier].
  ///
  /// `androidNoBluetooth` is set unconditionally, on every tier, and is *not*
  /// part of the escalation: the plugin otherwise appends `BLUETOOTH_CONNECT`
  /// to the permissions it requests (`SpeechToTextPlugin.kt:477`), a permission
  /// this app never declares — so the request can only be denied. It also
  /// probes the Bluetooth headset profile on setup. None of that can succeed
  /// here and none of it is wanted; this is hygiene, not a fix, and it will
  /// not by itself make a broken tier work.
  /// `intentLookup` is sent on *every* tier, with an explicit value, never
  /// omitted. The Kotlin side keeps it in a per-engine singleton field and only
  /// overwrites it when the key is present:
  ///
  /// ```kotlin
  /// var iOpt = call.argument<Boolean>("intentLookup")
  /// if (null != iOpt) { intentLookup = iOpt == true }
  /// ```
  ///
  /// Omitting it therefore *inherits* whatever a previous tier set. Once any
  /// tier had turned it on, `createRecognizer`'s `if (intentLookup)` branch won
  /// from then on and every other creation path — including [onDevice] — became
  /// unreachable for the rest of the app run.
  static List<SpeechConfigOption> _initOptionsFor(VoiceEngineTier tier) => [
    SpeechToText.androidNoBluetooth,
    SpeechConfigOption(
      'android',
      'intentLookup',
      tier == VoiceEngineTier.intentLookup,
    ),
  ];

  static const Duration _listenFor = Duration(seconds: 30);
  static const Duration _pauseFor = Duration(seconds: 3);

  // `speech_to_text`'s public `listen()` awaits the platform channel call
  // and only throws if that call itself throws. Internally, though, the
  // platform side can report `started: false` (mic held by another app,
  // transient recognizer-busy state) without surfacing anything to us: no
  // exception, and none of onResult/onStatus/onError ever fire because the
  // plugin never arms its own pause/listen timers in that case. Left alone,
  // `_isListening` would then be stuck at `true` forever — the mic looks
  // like it's listening and nothing the user does will ever change that.
  // This grace period (a little past `_listenFor`, which is the longest a
  // *working* session can legitimately run) bounds that stuck state so a
  // failed start always resolves into visible feedback.
  static const Duration _stuckWatchdogGrace = Duration(seconds: 3);

  /// Failure callback for the currently-running listen session, plus the
  /// generation it belongs to.
  ///
  /// A listen session can fail in two structurally different ways, and
  /// only one of them is observable by the caller at the point where
  /// `await startListening(...)` resolves:
  ///
  ///  * **Synchronously** — `SpeechToText.listen()` itself throws. The
  ///    catch below has already reset state by the time this method
  ///    returns, so a caller checking `isListening == false` right after
  ///    the await sees the failure.
  ///  * **Asynchronously** — `listen()` starts fine and returns normally;
  ///    the platform `SpeechRecognizer` reports the problem hundreds of
  ///    milliseconds later through [_handleSpeechError]. By then the
  ///    caller's post-await check has long since passed. This is the
  ///    common case on real devices (`error_no_match`,
  ///    `error_speech_timeout`, `error_client`, `error_audio`, …), and
  ///    with nothing listening for it the user saw only the mic icon
  ///    blink green and drop back to grey — no explanation anywhere.
  ///
  /// [_activeOnFailure] closes that second hole: the session hands the
  /// service a callback up front, and whoever ends the session for real
  /// (error listener or watchdog) invokes it. Guarded by generation so a
  /// late error from a cancelled/superseded session can't fire a stale
  /// callback.
  void Function(VoiceInputIssue issue)? _activeOnFailure;

  /// Generation of the session that has not been *accounted for* yet, or
  /// -1 when none is outstanding.
  ///
  /// ## Why this is not just `_isListening`
  ///
  /// It used to be. `_isListening` was doing two unrelated jobs at once:
  ///
  ///  1. **the light** — is the mic open, should the icon be green;
  ///  2. **the ledger** — has this session produced a verdict yet
  ///     (text, an error, or nothing at all).
  ///
  /// Those two end at different moments, and conflating them is what made
  /// the mic "flash green and go grey with no explanation". The platform
  /// closes the mic *before* it decides the outcome:
  ///
  /// ```kotlin
  /// // SpeechToTextPlugin.kt
  /// override fun onEndOfSpeech() = notifyListening(isRecording = false)
  ///
  /// private fun notifyListening(isRecording: Boolean) {        // :387
  ///     ...                                                    // → "notListening"
  ///     if (!isRecording) {
  ///         val doneStatus = when (resultSent) {
  ///             false -> SpeechToTextStatus.doneNoResult.name  // → mapped to "done"
  ///             else  -> SpeechToTextStatus.done.name
  ///         }
  ///         channel?.invokeMethod(notifyStatus.name, doneStatus)
  ///     }
  /// }
  ///
  /// override fun onError(errorCode: Int) {                     // :694
  ///     sendError(errorMsg)                                    // ← arrives LAST
  ///     if (isListening()) notifyListening(false)              // already false — no-op
  /// }
  /// ```
  ///
  /// So a failed utterance reaches us as `notListening`, then `done`, and
  /// only then `error_no_match`. With one flag for both jobs, the first of
  /// those three cleared it and the other two — plus the watchdog — all
  /// guarded on it and returned early. Three independent reporting paths,
  /// switched off by a single signal that only ever meant "the mic closed".
  ///
  /// Job 1 stays on [_isListening]; job 2 lives here. Terminal statuses may
  /// turn the light off, but only a real verdict settles the ledger.
  int _unsettledGeneration = -1;

  bool get _sessionUnsettled =>
      _unsettledGeneration >= 0 && _unsettledGeneration == _listenGeneration;

  /// Starts a listen session.
  ///
  /// [onFailure] fires when the session dies *asynchronously* — see
  /// [_activeOnFailure]. It is deliberately not invoked for a synchronous
  /// `listen()` throw: that path already leaves `isListening == false`
  /// before this future resolves, so callers handle it inline and firing
  /// both would show the user two dialogs for one failure.
  Future<void> startListening({
    required void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  }) async {
    if (!_isAvailable || _isListening) return;
    await _beginSession(onResult, onFailure);
  }

  /// [startListening] without the entry guard.
  ///
  /// A tier escalation re-enters this while `_isListening` is still `true` —
  /// deliberately, so the mic light stays on across the whole cascade. Letting
  /// it drop between tiers would show the user green → grey → green, which is
  /// indistinguishable from the "flashed and died" bug this all exists to fix.
  Future<void> _beginSession(
    void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  ) async {
    // A previous session can still have an empty-grace timer in flight: the
    // mic closes (light off, grace armed) and the user taps again inside
    // that window. The generation guard already makes it a no-op, but an
    // orphaned timer keeps a closure alive and makes widget tests fail on
    // pending timers, so drop it here rather than leaving it to expire.
    _disarmTimers();
    final generation = ++_listenGeneration;
    _armStartupWindow();
    _lastError = null;
    _isListening = true;
    _sessionGotResult = false;
    _activeOnFailure = onFailure;
    // Held so a tier escalation can transparently re-run the same session on
    // the next engine without the caller ever learning the first attempt
    // happened. See [_escalateTier].
    _activeOnResult = onResult;
    _unsettledGeneration = generation;
    notifyListeners();
    // Armed *before* awaiting `listen()`, not after: the platform call can
    // itself hang without ever resolving, and a watchdog installed on the
    // line after the await would in that case never be installed at all —
    // precisely the stuck state it exists to bound.
    _armStuckWatchdog(generation);

    if (engineTier == VoiceEngineTier.targetedBind) {
      _inlineGeneration = generation;
      _activeOnResultForInline = onResult;
      final component = _currentTargetedService;
      VoiceDiagnostics.instance.log(
        'stt',
        'targetedBind -> ${component ?? "(default)"} '
            '[${_targetedIndex + 1}/${_targetedServices.length}]',
      );
      final started = await _inline.start(component: component);
      if (!started) {
        // Could not even hand the request over. Same shape as a machinery
        // error so the cascade treats it identically.
        _handleSpeechError(SpeechRecognitionError('error_client', true));
      }
      return;
    }

    try {
      await _stt.listen(
        onResult: (result) {
          // Guarded on generation only — deliberately *not* on
          // `_isListening`. The Android plugin emits `notListening` when
          // the mic closes, which already flipped `_isListening` to false,
          // and the final result arrives after that. Also gating on
          // `_isListening` here silently dropped exactly the results the
          // user had just finished speaking. Generation alone still keeps
          // a cancelled session's late result from being delivered.
          if (generation != _listenGeneration) return;
          if (result.finalResult) {
            _sessionGotResult = true;
            _consecutiveEngineFailures = 0;
            _isListening = false;
            _settleSession(generation);
            notifyListeners();
            onResult(result.recognizedWords);
          }
        },
        listenFor: _listenFor,
        pauseFor: _pauseFor,
        // `onDevice` is a listen-time option, unlike `intentLookup`. Note the
        // plugin treats the two as mutually exclusive — `intentLookup` wins
        // and `onDevice` is ignored — which is why they are separate tiers
        // rather than a combination.
        listenOptions: SpeechListenOptions(
          onDevice: engineTier == VoiceEngineTier.onDevice,
        ),
      );
    } catch (e) {
      _isListening = false;
      _isAvailable = false;
      _lastError = e.toString();
      _settleSession(generation);
      notifyListeners();
    }
  }

  /// How long after the mic closes we wait for a verdict before calling the
  /// session empty.
  ///
  /// A terminal status is *not* a verdict — the platform closes the mic in
  /// `onEndOfSpeech` and only afterwards delivers either the recognized text
  /// or an error (see [_unsettledGeneration]). Judging emptiness the instant
  /// `done` arrives would fire "didn't catch that" a moment before the
  /// correct transcript landed; never judging it at all is the silent failure
  /// this whole class exists to prevent. So: wait briefly, and let whichever
  /// real outcome shows up settle the ledger first.
  ///
  /// Short enough to still feel like a response to the tap, long enough to
  /// cover the gap between `done` and the trailing `onResults`/`onError`.
  static const Duration _emptyGrace = Duration(milliseconds: 1200);

  Timer? _emptyGraceTimer;

  /// Armed when the mic closes with the ledger still open.
  ///
  /// Cancelled — via [_settleSession] — by a final result or an error
  /// arriving first, which is the common case. Firing means the recognizer
  /// closed the mic and then said nothing at all about how it went.
  void _armEmptyGrace(int generation) {
    _emptyGraceTimer?.cancel();
    _emptyGraceTimer = Timer(_emptyGrace, () {
      if (generation != _listenGeneration || !_sessionUnsettled) return;
      VoiceDiagnostics.instance.log(
        'stt',
        'empty-grace expired -> reporting no_result',
      );
      _lastError ??= 'error_no_result';
      final onFailure = _settleSession(generation);
      notifyListeners();
      onFailure?.call(issue);
    });
  }

  /// Closes the ledger on [generation] and hands back its failure callback
  /// so the caller can fire it — exactly once, by construction.
  ///
  /// Every way a session can end funnels through here: a final result, an
  /// error, the empty-grace timer, the stuck watchdog, and an explicit
  /// stop/cancel. Callers that are settling a *success* simply discard the
  /// returned callback.
  ///
  /// Returns null when [generation] is not the outstanding session — a late
  /// event from a cancelled or superseded one, or an error arriving outside
  /// any session at all (e.g. left over from `initialize`). Such an event
  /// still updates `lastError`/`issue`; there is just nobody waiting to be
  /// told, and no dialog to raise.
  void Function(VoiceInputIssue issue)? _settleSession(int generation) {
    if (_unsettledGeneration != generation) return null;
    _unsettledGeneration = -1;
    final cb = _activeOnFailure;
    _activeOnFailure = null;
    _activeOnResult = null;
    _disarmTimers();
    return cb;
  }

  /// Held so a session that ends normally can cancel it. The generation
  /// guard inside already makes a leftover timer harmless, but leaving one
  /// armed for 33 s after every single utterance keeps a closure alive for
  /// no reason — and makes widget tests fail on pending timers.
  Timer? _stuckWatchdog;

  void _disarmTimers() {
    _stuckWatchdog?.cancel();
    _stuckWatchdog = null;
    _emptyGraceTimer?.cancel();
    _emptyGraceTimer = null;
    _startupWindowTimer?.cancel();
    _startupWindowTimer = null;
    _withinStartupWindow = false;
  }

  /// How soon after starting a session an error still counts as "it never
  /// started" rather than "it ran and didn't understand".
  ///
  /// A session that actually listens cannot end this fast: `pauseFor` alone
  /// is 3 s, and even the quickest genuine `error_no_match` follows some
  /// amount of audio. An error inside this window means the mic was never
  /// opened, which is a statement about the device, not about the user.
  static const Duration _startupWindow = Duration(seconds: 1);

  /// Expressed as a timer rather than a `DateTime.now()` delta so tests can
  /// drive it with `fakeAsync` — `elapse()` moves timers, not the wall clock.
  bool _withinStartupWindow = false;
  Timer? _startupWindowTimer;

  void _armStartupWindow() {
    _startupWindowTimer?.cancel();
    _withinStartupWindow = true;
    _startupWindowTimer = Timer(_startupWindow, () {
      _withinStartupWindow = false;
      _startupWindowTimer = null;
    });
  }

  /// Callback of the in-flight session, so [_escalateTier] can re-run it.
  void Function(String)? _activeOnResult;

  /// Moves to the next thing worth trying, returning false when nothing is
  /// left.
  ///
  /// Two nested dimensions: inside [VoiceEngineTier.targetedBind] each
  /// installed `RecognitionService` is its own attempt, and only once they are
  /// all spent does the tier itself advance. Every step retries the caller's
  /// session transparently — the user tapped once.
  bool _advanceEngine(String cause) {
    if (engineTier == VoiceEngineTier.targetedBind &&
        _targetedIndex < _targetedServices.length - 1) {
      final from = _currentTargetedService;
      _targetedIndex++;
      VoiceDiagnostics.instance.log(
        'stt',
        'targeted service $from -> $_currentTargetedService (cause: $cause)',
      );
      // No re-initialize: the service list is already in hand, only the bind
      // target changes.
      final onResult = _activeOnResult;
      final onFailure = _activeOnFailure;
      _settleSession(_listenGeneration);
      if (onResult == null) return false;
      unawaited(_beginSession(onResult, onFailure));
      return true;
    }
    if (_tierIndex < _tiers.length - 1) {
      _escalateTier(cause);
      return true;
    }
    return false;
  }

  /// Moves to the next [VoiceEngineTier] and retries the current session on it,
  /// invisibly to the caller.
  ///
  /// The user tapped once and asked for voice input; they should not have to
  /// tap again for each engine we try, nor see a dialog per failed tier. On the
  /// devices this exists for the whole cascade costs a few milliseconds — the
  /// failing tier dies in ~2 ms — so a successful escalation just looks like
  /// the mic starting normally.
  ///
  /// A fresh [SpeechToText] is required rather than a re-`initialize()` of the
  /// current one: `intentLookup` is an initialize-time option and the plugin's
  /// `initialize()` opens with `if (_initWorked) return`.
  void _escalateTier(String cause) {
    final from = engineTier;
    _tierIndex++;
    VoiceDiagnostics.instance.log(
      'stt',
      'engine tier ${from.name} -> ${engineTier.name} (cause: $cause)',
    );

    // Tear the old session down without reporting it: nothing failed from the
    // caller's point of view yet.
    final onResult = _activeOnResult;
    final onFailure = _activeOnFailure;
    _settleSession(_listenGeneration);
    // `_isListening` deliberately left alone — see [_beginSession]. The light
    // stays on for the few milliseconds the cascade takes, so a successful
    // escalation is indistinguishable from the mic just starting.
    _lastError = null;
    // Only the `speech_to_text` tiers need a fresh instance (its `initialize()`
    // short-circuits, so options can't be changed on a used one). The
    // targetedBind tier runs on a different backend entirely and would just be
    // allocating an object nobody calls.
    if (_usesSpeechToText(engineTier)) _stt = _sttFactory();

    // Fire-and-forget: this runs from inside the plugin's error callback, so
    // awaiting here would re-enter it. Failures of the retry come back through
    // this same handler on the new tier, which either escalates again or, at
    // the last tier, reports for real.
    unawaited(_retryOnCurrentTier(_listenGeneration, onResult, onFailure));
  }

  /// [generation] is the session being escalated. The cascade spans an
  /// `await initialize()`, and `cancelListening`/`stopListening` (or another
  /// tap) bump the generation — without this guard, a user who cancels
  /// mid-cascade would get a brand-new listen session started on top of the
  /// cancellation.
  Future<void> _retryOnCurrentTier(
    int generation,
    void Function(String)? onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  ) async {
    await initialize();
    if (generation != _listenGeneration) {
      VoiceDiagnostics.instance.log(
        'stt',
        'escalation abandoned: session superseded during initialize',
      );
      return;
    }
    if (!_isAvailable) {
      // The new tier cannot even initialize. Escalate again if there is
      // anywhere left to go, otherwise report unavailable as usual.
      if (_tierIndex < _tiers.length - 1) {
        _activeOnResult = onResult;
        _activeOnFailure = onFailure;
        _unsettledGeneration = generation;
        _escalateTier('initialize failed');
        return;
      }
      _inAppPathBroken = true;
      _isListening = false;
      VoiceDiagnostics.instance.log(
        'stt',
        'all engine tiers exhausted at initialize — system speech UI',
      );
      notifyListeners();
      onFailure?.call(issue);
      return;
    }
    if (onResult == null) {
      _isListening = false;
      notifyListeners();
      return;
    }
    await _beginSession(onResult, onFailure);
  }

  /// Errors that mean the recognition *machinery* failed, as opposed to a
  /// normal per-utterance outcome.
  ///
  /// `busy` and the network/server codes stay out: those are transient and must
  /// not demote the path — the mic will work on the next tap.
  /// `no_match`/`speech_timeout` prove the recognizer ran at all, so they are
  /// the strongest possible evidence *against* demoting.
  ///
  /// `error_permission` is included *only* once [_permissionVerified] — see
  /// that field. We asked for `RECORD_AUDIO` and were told we have it, so a
  /// recognizer still claiming insufficient permissions is describing itself,
  /// and no amount of retrying or user action will change it. Without this the
  /// tier neither escalated nor gave up: every tap re-tried the same dead
  /// engine and raised a permission dialog that could not possibly help.
  bool _isMachineryError(String errorMsg) {
    final e = errorMsg.toLowerCase();
    if (e.contains('error_client') || e.contains('audio_error')) return true;
    return _permissionVerified &&
        e.contains('permission') &&
        !e.contains('permission_microphone') &&
        !e.contains('permission_speech');
  }

  void _armStuckWatchdog(int generation) {
    _stuckWatchdog?.cancel();
    _stuckWatchdog = Timer(_listenFor + _stuckWatchdogGrace, () {
      // Guarded on the ledger, not on `_isListening`: by this point the mic
      // has almost certainly been reported closed, which used to disqualify
      // the watchdog from ever firing — the one case it exists for (nothing
      // ever calls back) was also the case it could not see.
      if (generation != _listenGeneration || !_sessionUnsettled) return;
      _isListening = false;
      _lastError ??= 'error_recognizer_unavailable';
      final onFailure = _settleSession(generation);
      notifyListeners();
      onFailure?.call(issue);
    });
  }

  Future<void> stopListening() async {
    if (!_isListening) return;
    // Stopping/cancelling on purpose is not a failure — settle the ledger
    // so a late platform error from this session stays silent.
    _settleSession(_listenGeneration);
    final inline = engineTier == VoiceEngineTier.targetedBind;
    try {
      // Must follow the backend the session was actually started on, or a
      // stop lands on an idle recognizer while the live one keeps the mic.
      await (inline ? _inline.stop() : _stt.stop());
    } catch (e) {
      _lastError = e.toString();
    } finally {
      _isListening = false;
      notifyListeners();
    }
  }

  Future<void> cancelListening() async {
    if (!_isListening) return;
    _settleSession(_listenGeneration);
    _listenGeneration++;
    _isListening = false;
    notifyListeners();
    final inline = engineTier == VoiceEngineTier.targetedBind;
    try {
      await (inline ? _inline.cancel() : _stt.cancel());
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _inlineSub?.cancel();
    _inlineSub = null;
    _inline.dispose();
    _disarmTimers();
    super.dispose();
  }

  /// `speech_to_text`'s Android plugin hard-codes `permanent: true` on
  /// *every* error it forwards:
  ///
  /// ```kotlin
  /// // SpeechToTextPlugin.kt, sendError()
  /// speechError.put("permanent", true)
  /// ```
  ///
  /// So the flag says nothing about whether the recognizer is actually
  /// dead. Taking it at face value meant one ordinary `error_no_match`
  /// ("didn't catch that") latched `isAvailable = false` and the mic never
  /// came back for the rest of the session — tap once, see it blink, then
  /// nothing ever again.
  ///
  /// Only errors that describe the recognizer or its permissions being
  /// unusable are treated as fatal. Everything else (no match, timeout,
  /// busy, network, audio glitch, server hiccup) is a normal per-utterance
  /// outcome and must leave the service ready for the next tap.
  /// Outcomes that describe *what was said* rather than a broken engine.
  ///
  /// Reaching one of these proves the recognizer ran, so it resets the failure
  /// streak below.
  static bool _isUserOutcome(String errorMsg) {
    final e = errorMsg.toLowerCase();
    return e.contains('no_match') ||
        e.contains('speech_timeout') ||
        e.contains('no_result');
  }

  /// Consecutive sessions that failed for a reason the user cannot influence.
  /// Reset by any delivered result or user-level outcome.
  int _consecutiveEngineFailures = 0;

  /// Three, not one: a couple of odd failures on an otherwise working engine
  /// (mic briefly held elsewhere, a dropped network call) must not cost the
  /// user their inline experience for the rest of the app run. `error_busy`
  /// followed by `error_network` is a plausible transient pair and stays under
  /// this bar.
  ///
  /// This is only the backstop. An engine that dies inside the startup window
  /// with a machinery error — the Xiaomi case — is demoted on the very first
  /// tap by the branch above, without waiting for a streak.
  static const int _maxConsecutiveEngineFailures = 3;

  static bool _isFatalError(String errorMsg) {
    final e = errorMsg.toLowerCase();
    return e.contains('permission') ||
        e.contains('language_not_supported') ||
        e.contains('language_unavailable') ||
        e.contains('recognizer_unavailable');
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    VoiceDiagnostics.instance.log(
      'stt',
      'onError ${error.errorMsg} permanent=${error.permanent} '
          'fatal=${_isFatalError(error.errorMsg)}',
    );
    _lastError = error.errorMsg;
    if (_isFatalError(error.errorMsg)) {
      _isAvailable = false;
    }
    // Died before it could have listened to anything, with an error about the
    // machinery rather than about what was said → this *engine tier* cannot
    // run here. Try the next one before giving up on inline recording; only
    // when all of them are exhausted does the caller get told, at which point
    // it hands over to the system speech UI.
    if (_withinStartupWindow && _isMachineryError(error.errorMsg)) {
      if (_advanceEngine(error.errorMsg)) return;
      _inAppPathBroken = true;
      VoiceDiagnostics.instance.log(
        'stt',
        'all engine tiers exhausted: ${error.errorMsg} — falling back to '
            'system speech UI',
      );
    }

    // Past the escalation branch, so this failure is really being handed to the
    // user. Counted here and *not* above on purpose: the attempts a cascade
    // burns through while hunting for a working engine are expected, invisible,
    // and must not accumulate — an earlier version counted them and demoted
    // the whole path on a tap that went on to succeed on its third tier.
    //
    // Safety net for engines that fail with a *rotating* set of codes rather
    // than one recognisable machinery error: the Xiaomi service cycled
    // `error_permission`, `error_server_disconnected` and `error_network`
    // across taps. No transient code may demote the path by itself, yet the
    // engine plainly never works, and without this every tap re-tried it and
    // the working system UI stayed out of reach.
    if (!_isUserOutcome(error.errorMsg)) {
      _consecutiveEngineFailures++;
      if (_consecutiveEngineFailures >= _maxConsecutiveEngineFailures) {
        _inAppPathBroken = true;
        VoiceDiagnostics.instance.log(
          'stt',
          'in-app path demoted after $_consecutiveEngineFailures consecutive '
              'engine failures (latest: ${error.errorMsg})',
        );
      }
    } else {
      // The recognizer ran and merely didn't understand — proof it works.
      _consecutiveEngineFailures = 0;
    }
    _isListening = false;
    // Guarded on the ledger, not on whether the mic happened to still be
    // open. `SpeechToTextPlugin.onError` calls `sendError` *before* its
    // `notifyListening(false)` — and on the common path `onEndOfSpeech`
    // already closed the mic even earlier. So by the time an error gets
    // here, `_isListening` is routinely already false, and keying off it
    // dropped the single most informative event of the whole session
    // (`error_no_match`, `error_speech_timeout`, …) on the floor.
    //
    // `_settleSession` still returns null for an error outside any session
    // (e.g. left over from `initialize`): `lastError`/`issue` update, but
    // there is nobody waiting and no dialog to raise.
    final onFailure = _settleSession(_listenGeneration);
    notifyListeners();
    // After notifyListeners so the icon has already dropped back to its
    // idle state by the time the dialog explaining why appears.
    onFailure?.call(issue);
  }

  /// Set once this session has delivered a final result, so a terminal
  /// status can tell "finished normally" from "finished with nothing".
  bool _sessionGotResult = false;

  /// `onStatus` handler.
  ///
  /// Both terminal statuses mean the same thing here, and it is a narrow
  /// thing: **the mic closed**. Neither is a verdict on the session.
  /// `notifyListening(false)` fires them back to back, from
  /// `onEndOfSpeech` — i.e. *before* the recognizer has decided anything:
  ///
  /// ```kotlin
  /// // SpeechToTextPlugin.kt, notifyListening()
  /// channel?.invokeMethod(notifyStatus.name, "notListening")
  /// if (!isRecording) {
  ///     val doneStatus = when (resultSent) {
  ///         false -> SpeechToTextStatus.doneNoResult.name   // → "done"
  ///         else  -> SpeechToTextStatus.done.name
  ///     }
  ///     channel?.invokeMethod(notifyStatus.name, doneStatus)
  /// }
  /// ```
  ///
  /// This method therefore does exactly two things — turn the light off,
  /// and start the clock — and deliberately reaches no conclusion of its
  /// own. Reading `done` as "ended empty" was wrong in both directions:
  /// `resultSent` is still false at `onEndOfSpeech` even on a *successful*
  /// utterance, so `done` cannot distinguish success from silence, and the
  /// `!_isListening` guard that papered over that false positive then ate
  /// the genuine one. The verdict now comes from whatever actually shows
  /// up next — result, error, or nothing (see [_armEmptyGrace]).
  void _handleSpeechStatus(String status) {
    VoiceDiagnostics.instance.log(
      'stt',
      'onStatus $status (isListening=$_isListening '
          'gotResult=$_sessionGotResult unsettled=$_sessionUnsettled)',
    );
    _lastStatus = status;
    final terminal = status == 'done' || status == 'notListening';
    if (!terminal) return;

    final wasLit = _isListening;
    _isListening = false;
    if (_sessionUnsettled) _armEmptyGrace(_listenGeneration);
    if (wasLit) notifyListeners();
  }

  VoiceInputIssue _classifyIssue(String? error, bool isAvailable) {
    if (isAvailable && error == null) return VoiceInputIssue.none;
    final e = error?.toLowerCase() ?? '';
    if (e.contains('permission_microphone')) {
      return VoiceInputIssue.microphonePermissionDenied;
    }
    if (e.contains('permission_speech')) {
      return VoiceInputIssue.speechPermissionDenied;
    }
    if (e.contains('error_permission') || e.contains('permission')) {
      // A recognizer complaining about permissions *after* we confirmed we hold
      // `RECORD_AUDIO` is describing its own internals, not our grant state.
      // Reporting it as "grant FlyTerm microphone access" sent users to a
      // settings screen where the toggle was already on — see
      // [_permissionVerified].
      return _permissionVerified
          ? VoiceInputIssue.recognizerUnavailable
          : VoiceInputIssue.microphonePermissionDenied;
    }
    if (e.contains('speech_timeout') ||
        e.contains('no_match') ||
        // 会话跑完但零结果——识别器听到了东西却没能转成文字，或者压根
        // 没收到音频。对用户来说和"没听清"是同一件事。
        e.contains('no_result')) {
      return VoiceInputIssue.microphoneMutedOrNoSpeech;
    }
    if (e.contains('busy')) return VoiceInputIssue.busy;
    if (e.contains('network')) return VoiceInputIssue.network;
    if (e.contains('not available') ||
        e.contains('notavailable') ||
        e.contains('not initialized') ||
        e.contains('notinitialized') ||
        e.contains('recognizer') ||
        e.contains('client') ||
        e.contains('language_unavailable') ||
        e.contains('language_not_supported')) {
      return VoiceInputIssue.recognizerUnavailable;
    }
    if (!isAvailable) return VoiceInputIssue.recognizerUnavailable;
    return VoiceInputIssue.unknown;
  }
}
