// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'voice_diagnostics.dart';

/// One outcome of an [InlineSpeechRecognizer] session.
sealed class InlineSpeechEvent {
  const InlineSpeechEvent();
}

/// The recognizer accepted the start and the mic is open.
class InlineSpeechStarted extends InlineSpeechEvent {
  const InlineSpeechStarted();
}

/// Final recognized text. [text] is null when the recognizer returned an empty
/// result set.
class InlineSpeechResult extends InlineSpeechEvent {
  final String? text;

  const InlineSpeechResult(this.text);
}

/// The mic closed. Not a verdict — a result or an error may still follow, the
/// same ordering `speech_to_text` exhibits.
class InlineSpeechEndOfSpeech extends InlineSpeechEvent {
  const InlineSpeechEndOfSpeech();
}

/// [code] uses the same spellings as `speech_to_text` (`error_client`,
/// `error_no_match`, …) so downstream classification is backend-agnostic.
class InlineSpeechError extends InlineSpeechEvent {
  final String code;

  const InlineSpeechError(this.code);
}

/// Inline recognition against a *specific* `RecognitionService`.
///
/// Exists because `speech_to_text` cannot target one. It binds either the
/// system default or `queryIntentServices(...).firstOrNull()` — and on the ROMs
/// this was written for, those are the same broken service, while a working one
/// sits further down the list. See `InlineSpeechPlugin.kt`.
///
/// Android only. [listServices] returns empty elsewhere, which makes the
/// targeted-bind tier skip itself.
class InlineSpeechRecognizer {
  static const MethodChannel _defaultChannel = MethodChannel(
    'sh.flyterm.app/inline_speech',
  );

  final MethodChannel _channel;
  final bool Function() _isAndroid;
  final _events = StreamController<InlineSpeechEvent>.broadcast();

  InlineSpeechRecognizer({MethodChannel? channel, bool Function()? isAndroid})
    : _channel = channel ?? _defaultChannel,
      _isAndroid = isAndroid ?? (() => Platform.isAndroid) {
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  Stream<InlineSpeechEvent> get events => _events.stream;

  Future<void> _onPlatformCall(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    switch (call.method) {
      case 'onStart':
        _emit(const InlineSpeechStarted());
      case 'onResult':
        _emit(InlineSpeechResult(args['text'] as String?));
      case 'onEndOfSpeech':
        _emit(const InlineSpeechEndOfSpeech());
      case 'onError':
        _emit(InlineSpeechError(args['error'] as String? ?? 'error_unknown'));
    }
  }

  void _emit(InlineSpeechEvent event) {
    VoiceDiagnostics.instance.log('inline', event.runtimeType.toString());
    if (!_events.isClosed) _events.add(event);
  }

  /// Every installed `RecognitionService`, as `"package/class"`.
  ///
  /// Also the answer to "does this device have anything usable at all" — an
  /// empty list, or a list holding nothing but the vendor stub that already
  /// failed, is what rules the whole targeted-bind approach out.
  Future<List<String>> listServices() async {
    if (!_isAndroid()) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('listServices');
      final list = raw?.whereType<String>().toList() ?? const <String>[];
      VoiceDiagnostics.instance.log(
        'inline',
        'listServices -> ${list.isEmpty ? "(none)" : list.join(", ")}',
      );
      return list;
    } on MissingPluginException {
      VoiceDiagnostics.instance.log('inline', 'listServices: MissingPlugin');
      return const [];
    } on PlatformException catch (e) {
      VoiceDiagnostics.instance.log('inline', 'listServices: failed ${e.code}');
      return const [];
    }
  }

  /// Starts a session on [component] (`"package/class"`), or the system default
  /// when null. Outcomes arrive on [events].
  Future<bool> start({String? component, String? languageTag}) async {
    if (!_isAndroid()) return false;
    try {
      await _channel.invokeMethod<bool>('start', {
        'component': component,
        'languageTag': languageTag,
      });
      VoiceDiagnostics.instance.log(
        'inline',
        'start component=${component ?? "(default)"}',
      );
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      VoiceDiagnostics.instance.log('inline', 'start failed ${e.code}');
      return false;
    }
  }

  Future<void> stop() => _invokeQuietly('stop');

  Future<void> cancel() => _invokeQuietly('cancel');

  Future<void> _invokeQuietly(String method) async {
    if (!_isAndroid()) return;
    try {
      await _channel.invokeMethod<bool>(method);
    } on MissingPluginException {
      // nothing to stop
    } on PlatformException catch (e) {
      VoiceDiagnostics.instance.log('inline', '$method failed ${e.code}');
    }
  }

  void dispose() {
    _events.close();
  }
}
