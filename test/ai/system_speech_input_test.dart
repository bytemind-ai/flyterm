// SystemSpeechInput wraps a native MethodChannel that launches Android's
// RECOGNIZE_SPEECH intent — a fallback path for devices where
// speech_to_text's bound RecognitionService is unavailable (see
// lib/ai/system_speech_input.dart for why these are genuinely
// independent paths, not two names for the same thing).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/system_speech_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('sh.flyterm.app/system_speech');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  void mock(Future<Object?>? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  group('non-Android', () {
    test('isAvailable is false without touching the channel', () async {
      var called = false;
      mock((call) async {
        called = true;
        return true;
      });
      final fallback = SystemSpeechInput(
        channel: channel,
        isAndroid: () => false,
      );

      expect(await fallback.isAvailable(), isFalse);
      expect(called, isFalse);
    });

    test('recognize is null without touching the channel', () async {
      var called = false;
      mock((call) async {
        called = true;
        return 'text';
      });
      final fallback = SystemSpeechInput(
        channel: channel,
        isAndroid: () => false,
      );

      expect(await fallback.recognize(), isNull);
      expect(called, isFalse);
    });
  });

  group('Android', () {
    test('isAvailable reflects the native result', () async {
      mock((call) async {
        expect(call.method, 'isAvailable');
        return true;
      });
      final fallback = SystemSpeechInput(
        channel: channel,
        isAndroid: () => true,
      );

      expect(await fallback.isAvailable(), isTrue);
    });

    test('isAvailable is false when native reports false', () async {
      mock((call) async => false);
      final fallback = SystemSpeechInput(
        channel: channel,
        isAndroid: () => true,
      );

      expect(await fallback.isAvailable(), isFalse);
    });

    test('recognize returns the recognized text', () async {
      mock((call) async {
        expect(call.method, 'recognize');
        return 'hello world';
      });
      final fallback = SystemSpeechInput(
        channel: channel,
        isAndroid: () => true,
      );

      expect(await fallback.recognize(), 'hello world');
    });

    test('recognize returns null when the user cancels', () async {
      mock((call) async => null);
      final fallback = SystemSpeechInput(
        channel: channel,
        isAndroid: () => true,
      );

      expect(await fallback.recognize(), isNull);
    });

    test(
      'isAvailable degrades to false when the channel is not implemented '
      '(MissingPluginException) instead of throwing',
      () async {
        // No mock handler registered at all — invokeMethod throws
        // MissingPluginException, mirroring an old app build running
        // against a platform layer that hasn't wired this channel.
        final fallback = SystemSpeechInput(
          channel: channel,
          isAndroid: () => true,
        );

        expect(await fallback.isAvailable(), isFalse);
      },
    );

    test(
      'recognize degrades to null when the channel is not implemented '
      '(MissingPluginException) instead of throwing',
      () async {
        final fallback = SystemSpeechInput(
          channel: channel,
          isAndroid: () => true,
        );

        expect(await fallback.recognize(), isNull);
      },
    );

    test(
      'isAvailable degrades to false when the native side reports a '
      'PlatformException',
      () async {
        mock((call) async => throw PlatformException(code: 'boom'));
        final fallback = SystemSpeechInput(
          channel: channel,
          isAndroid: () => true,
        );

        expect(await fallback.isAvailable(), isFalse);
      },
    );

    // 这条原先断言 recognize() 把 PlatformException 咽成 null。那让
    // "启动不起来"和"用户取消了已经弹出的界面"在调用方眼里完全一样，
    // 而前者屏幕上什么都没出现过——静默的根源之一。现在改为抛出，由
    // toggleVoiceInput 的 catch 显示原因。
    test(
      'recognize surfaces a start failure instead of swallowing it as null',
      () async {
        mock(
          (call) async =>
              throw PlatformException(code: 'START_FAILED', message: 'no app'),
        );
        final fallback = SystemSpeechInput(
          channel: channel,
          isAndroid: () => true,
        );

        await expectLater(
          fallback.recognize(),
          throwsA(
            isA<SystemSpeechStartFailure>()
                .having((e) => e.code, 'code', 'START_FAILED'),
          ),
        );
      },
    );

    test('recognize still returns null when the user cancels the UI', () async {
      mock((call) async => null);
      final fallback = SystemSpeechInput(
        channel: channel,
        isAndroid: () => true,
      );

      expect(
        await fallback.recognize(),
        isNull,
        reason: '取消一个已经出现过的界面是正常操作，不是失败',
      );
    });
  });
}
