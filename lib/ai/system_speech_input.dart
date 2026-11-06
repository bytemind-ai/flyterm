// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'voice_diagnostics.dart';

/// **Last-resort** voice-input path: the system speech UI, launched via
/// `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`.
///
/// Reached only when in-app recording is entirely unavailable — no bindable
/// `RecognitionService` on the device. There the choice is not "inline or
/// full-screen", it is "full-screen or no voice input at all".
///
/// This was briefly promoted to the primary path and moved back: taking over
/// the whole screen on every tap is not the wanted interaction. See
/// `toggleVoiceInputWith` in `ui/voice/voice_input_prompt.dart` for the
/// ordering that actually ships — this comment claimed the opposite for a
/// while, which is its own small contribution to how long the mic bug took
/// to pin down.
///
/// ## Why this path is nonetheless the structurally reliable one
///
/// `speech_to_text` binds a long-lived `RecognitionService` and keeps a
/// state machine on both the Dart and Kotlin sides. That design has several
/// properties we could not work around from the outside:
///
///  * its Android plugin stamps `permanent: true` on *every* error, so one
///    ordinary "didn't catch that" is indistinguishable from a dead
///    recognizer (`SpeechToTextPlugin.kt`, `sendError`);
///  * `initialize()` short-circuits on `if (_initWorked) return`, so once
///    the session is poisoned there is no way to reset it;
///  * `listen()` can fail internally (`started: false`) without throwing or
///    invoking any callback.
///
/// Five successive rounds of patching on top of it did not stop users
/// seeing "tapped the mic, nothing happened".
///
/// This path, by contrast, cannot fail silently *by construction*:
///
///  * the system draws its own full-screen speech UI — the UI appearing is
///    itself the feedback, so there is no state for us to get wrong;
///  * exactly three outcomes exist, all handled: text, user cancelled
///    (null), failed to launch ([SystemSpeechStartFailure]);
///  * every invocation is a fresh `startActivityForResult` round trip, so a
///    failed attempt cannot poison the next one;
///  * no `RECORD_AUDIO` permission needed — the system UI owns the mic.
///
/// The trade-off is no streaming/partial results. For this app's usage
/// (dictating one command or one line of intent) that is acceptable, and
/// arguably better: the user can see unambiguously that recording is live.
///
/// Android only. On iOS `speech_to_text` goes through Apple's Speech
/// framework and there is no equivalent intent, so [isAvailable] and
/// [recognize] are no-ops there and the `speech_to_text` path still serves
/// as the implementation (see `toggleVoiceInputWith`).
class SystemSpeechInput {
  static const MethodChannel _defaultChannel = MethodChannel(
    'sh.flyterm.app/system_speech',
  );

  final MethodChannel _channel;
  final bool Function() _isAndroid;

  /// [channel] and [isAndroid] are injectable so tests can drive this
  /// without touching the real platform channel or `dart:io.Platform`.
  SystemSpeechInput({MethodChannel? channel, bool Function()? isAndroid})
    : _channel = channel ?? _defaultChannel,
      _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  /// Whether a system speech-recognition UI is resolvable on this device
  /// (i.e. some app can handle `ACTION_RECOGNIZE_SPEECH`).
  ///
  /// A `MissingPluginException` (old app build running against a platform
  /// layer that hasn't wired this channel, or a non-Android build that
  /// somehow reaches here) is treated as "not available", not a crash — the
  /// caller then falls through to the `speech_to_text` path.
  Future<bool> isAvailable() async {
    if (!_isAndroid()) {
      VoiceDiagnostics.instance.log('sys', 'isAvailable: not android');
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      VoiceDiagnostics.instance.log('sys', 'isAvailable -> $result');
      return result ?? false;
    } on MissingPluginException {
      VoiceDiagnostics.instance.log('sys', 'isAvailable: MissingPlugin');
      return false;
    } on PlatformException catch (e) {
      VoiceDiagnostics.instance.log('sys', 'isAvailable: PlatformException ${e.code}');
      return false;
    }
  }

  /// Launches the system speech-recognition UI and returns the recognized
  /// text, or null when the user dismissed it without speaking.
  ///
  /// **null means "the user saw a speech UI and cancelled it"** — a normal
  /// outcome that needs no explanation, because the UI appearing *was* the
  /// feedback. Failing to launch at all is a different thing entirely and
  /// throws [SystemSpeechStartFailure] instead: nothing appeared on screen,
  /// so silently returning null there is indistinguishable from "the mic
  /// button is dead", which is exactly the complaint this fallback was
  /// added to fix.
  ///
  /// A [MissingPluginException] still degrades to null — an app build whose
  /// platform layer predates this channel has nothing to launch, and the
  /// caller has already been told this path is unavailable.
  Future<String?> recognize() async {
    if (!_isAndroid()) return null;
    try {
      final text = await _channel.invokeMethod<String>('recognize');
      VoiceDiagnostics.instance.log(
        'sys',
        'recognize -> ${text == null ? "null (cancelled)" : "${text.length} chars"}',
      );
      return text;
    } on MissingPluginException {
      VoiceDiagnostics.instance.log('sys', 'recognize: MissingPlugin');
      return null;
    } on PlatformException catch (e) {
      VoiceDiagnostics.instance.log(
        'sys',
        'recognize: FAILED ${e.code} ${e.message}',
      );
      throw SystemSpeechStartFailure(e.code, e.message);
    }
  }
}

/// The system speech UI could not be started (no activity handled the
/// intent, launching threw, or a previous request is still in flight).
///
/// Distinct from a null return, which means the user cancelled a UI that
/// did appear.
class SystemSpeechStartFailure implements Exception {
  final String code;
  final String? message;

  SystemSpeechStartFailure(this.code, this.message);

  @override
  String toString() =>
      'SystemSpeechStartFailure($code)${message == null ? '' : ': $message'}';
}
