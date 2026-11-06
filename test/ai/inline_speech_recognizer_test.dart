// InlineSpeechRecognizer：按 ComponentName 精确绑定的自有识别器。
//
// 存在的理由是 speech_to_text 只能绑到两个东西——系统默认，或
// `queryIntentServices(...).firstOrNull()`。厂商的坏 stub 一旦排在第一位，
// 那两者就是同一个服务，而列表里往后的可用服务永远碰不到。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/inline_speech_recognizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('sh.flyterm.app/inline_speech');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('listServices 返回平台给的服务列表', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listServices') {
        return <String>['com.vendor.stub/.Svc', 'com.google.app/.GoogleSvc'];
      }
      return null;
    });
    final rec = InlineSpeechRecognizer(
      channel: channel,
      isAndroid: () => true,
    );
    addTearDown(rec.dispose);

    expect(await rec.listServices(), [
      'com.vendor.stub/.Svc',
      'com.google.app/.GoogleSvc',
    ]);
  });

  test('非 Android 上 listServices 为空，让整档自己跳过', () async {
    final rec = InlineSpeechRecognizer(
      channel: channel,
      isAndroid: () => false,
    );
    addTearDown(rec.dispose);

    expect(await rec.listServices(), isEmpty);
  });

  test('MissingPluginException 当作"没有服务"，不抛给上层', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no impl');
    });
    final rec = InlineSpeechRecognizer(
      channel: channel,
      isAndroid: () => true,
    );
    addTearDown(rec.dispose);

    expect(await rec.listServices(), isEmpty);
  });

  test('start 把 component 原样传给平台', () async {
    final calls = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        calls.add(call.arguments as Map<Object?, Object?>);
        return true;
      }
      return null;
    });
    final rec = InlineSpeechRecognizer(
      channel: channel,
      isAndroid: () => true,
    );
    addTearDown(rec.dispose);

    await rec.start(component: 'com.google.app/.GoogleSvc');

    expect(calls.single['component'], 'com.google.app/.GoogleSvc');
  });

  // 平台侧是通过同一条 channel 反向 invokeMethod 推事件的，所以这里直接
  // 模拟那个方向的调用。
  group('平台事件映射', () {
    Future<void> push(String method, Map<String, Object?> args) async {
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    }

    test('onResult / onError / onEndOfSpeech / onStart 各自成型', () async {
      final rec = InlineSpeechRecognizer(
        channel: channel,
        isAndroid: () => true,
      );
      addTearDown(rec.dispose);
      final seen = <InlineSpeechEvent>[];
      final sub = rec.events.listen(seen.add);
      addTearDown(sub.cancel);

      await push('onStart', {'session': 1});
      await push('onEndOfSpeech', {'session': 1});
      await push('onResult', {'session': 1, 'text': 'deploy the app'});
      await push('onError', {'session': 1, 'error': 'error_client'});
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(4));
      expect(seen[0], isA<InlineSpeechStarted>());
      expect(seen[1], isA<InlineSpeechEndOfSpeech>());
      expect(
        seen[2],
        isA<InlineSpeechResult>().having(
          (e) => e.text,
          'text',
          'deploy the app',
        ),
      );
      expect(
        seen[3],
        isA<InlineSpeechError>().having((e) => e.code, 'code', 'error_client'),
      );
    });

    test('text 为 null 的 onResult 保持 null——那是"跑完了但零结果"', () async {
      final rec = InlineSpeechRecognizer(
        channel: channel,
        isAndroid: () => true,
      );
      addTearDown(rec.dispose);
      final seen = <InlineSpeechEvent>[];
      final sub = rec.events.listen(seen.add);
      addTearDown(sub.cancel);

      await push('onResult', {'session': 1, 'text': null});
      await Future<void>.delayed(Duration.zero);

      expect(
        seen.single,
        isA<InlineSpeechResult>().having((e) => e.text, 'text', isNull),
      );
    });
  });
}
