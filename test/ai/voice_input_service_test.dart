import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:flyterm/ai/inline_speech_recognizer.dart';
import 'package:flyterm/ai/voice_input_service.dart';

import 'voice_input_service_test.mocks.dart';

@GenerateMocks([SpeechToText])
void main() {
  // targetedBind 那一组要 mock inline_speech 的 MethodChannel，需要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSpeechToText mockStt;
  late VoiceInputService service;

  PostExpectation<Future<bool>> whenInitialize() => when(
    mockStt.initialize(
      onError: anyNamed('onError'),
      onStatus: anyNamed('onStatus'),
      debugLogging: anyNamed('debugLogging'),
      options: anyNamed('options'),
    ),
  );

  VerificationResult verifyInitialize() => verify(
    mockStt.initialize(
      onError: anyNamed('onError'),
      onStatus: anyNamed('onStatus'),
      debugLogging: anyNamed('debugLogging'),
      options: anyNamed('options'),
    ),
  );

  setUp(() {
    mockStt = MockSpeechToText();
    service = VoiceInputService(mockStt);
  });

  test('isAvailable is false before initialize', () {
    expect(service.isAvailable, isFalse);
    expect(service.isListening, isFalse);
    expect(service.lastError, isNull);
    expect(service.lastStatus, isNull);
  });

  test('prepare stops before initialize when permissions are denied', () async {
    service = VoiceInputService(mockStt, () async => false);

    final ok = await service.prepare();

    expect(ok, isFalse);
    expect(service.isAvailable, isFalse);
    expect(service.issue, VoiceInputIssue.microphonePermissionDenied);
    verifyNever(
      mockStt.initialize(
        onError: anyNamed('onError'),
        onStatus: anyNamed('onStatus'),
        debugLogging: anyNamed('debugLogging'),
        options: anyNamed('options'),
      ),
    );
  });

  test('prepare initializes when permissions are granted', () async {
    service = VoiceInputService(mockStt, () async => true);
    whenInitialize().thenAnswer((_) async => true);

    final ok = await service.prepare();

    expect(ok, isTrue);
    expect(service.isAvailable, isTrue);
  });

  test(
    'prepare classifies unavailable recognizer separately from microphone',
    () async {
      service = VoiceInputService(mockStt, () async => true);
      whenInitialize().thenAnswer((_) async => false);

      final ok = await service.prepare();

      expect(ok, isFalse);
      expect(service.isAvailable, isFalse);
      expect(service.issue, VoiceInputIssue.recognizerUnavailable);
      expect(service.lastError, 'error_recognizer_unavailable');
    },
  );

  test(
    'initialize sets isAvailable and clears old errors when stt succeeds',
    () async {
      whenInitialize().thenThrow(Exception('initial failure'));
      await service.initialize();
      expect(service.isAvailable, isFalse);
      expect(service.lastError, contains('initial failure'));

      whenInitialize().thenAnswer((_) async => true);
      await service.initialize();
      expect(service.isAvailable, isTrue);
      expect(service.lastError, isNull);
      verifyInitialize().called(2);
    },
  );

  test('initialize sets isAvailable=false when stt fails', () async {
    whenInitialize().thenAnswer((_) async => false);
    await service.initialize();
    expect(service.isAvailable, isFalse);
    expect(service.lastError, 'error_recognizer_unavailable');
    expect(service.issue, VoiceInputIssue.recognizerUnavailable);
  });

  test('initialize can retry after unavailable result', () async {
    whenInitialize().thenAnswer((_) async => false);
    await service.initialize();
    expect(service.isAvailable, isFalse);

    whenInitialize().thenAnswer((_) async => true);
    await service.initialize();
    expect(service.isAvailable, isTrue);
    verifyInitialize().called(2);
  });

  test(
    'initialize tracks status changes and clears listening on terminal status',
    () async {
      SpeechStatusListener? statusListener;
      whenInitialize().thenAnswer((invocation) async {
        statusListener =
            invocation.namedArguments[#onStatus] as SpeechStatusListener?;
        return true;
      });
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});

      await service.initialize();
      await service.startListening(onResult: (_) {});
      expect(service.isListening, isTrue);

      statusListener?.call('done');

      expect(service.lastStatus, 'done');
      expect(service.isListening, isFalse);
    },
  );

  test('initialize records speech errors from error listener', () async {
    SpeechErrorListener? errorListener;
    when(
      mockStt.initialize(
        onError: anyNamed('onError'),
        onStatus: anyNamed('onStatus'),
        debugLogging: anyNamed('debugLogging'),
        options: anyNamed('options'),
      ),
    ).thenAnswer((invocation) async {
      errorListener =
          invocation.namedArguments[#onError] as SpeechErrorListener?;
      return true;
    });

    await service.initialize();
    errorListener?.call(SpeechRecognitionError('error_network', true));

    expect(service.lastError, 'error_network');
    // permanent=true 是 Android 端对所有错误无条件加的标记，不代表识别器
    // 真的坏了（见 _isFatalError）。网络错误恢复后还能用，不能因此把麦
    // 克风永久废掉——这条断言原先期望 isFalse，把那个缺陷当成了预期。
    expect(service.isAvailable, isTrue);
  });

  test('startListening sets isListening=true', () async {
    whenInitialize().thenAnswer((_) async => true);
    when(
      mockStt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((_) async {});
    await service.initialize();
    await service.startListening(onResult: (_) {});
    expect(service.isListening, isTrue);
    expect(service.lastError, isNull);
  });

  test('startListening clears stale error before listening succeeds', () async {
    whenInitialize().thenThrow(Exception('stale error'));
    await service.initialize();
    expect(service.lastError, contains('stale error'));

    whenInitialize().thenAnswer((_) async => true);
    when(
      mockStt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((_) async {});

    await service.initialize();
    await service.startListening(onResult: (_) {});

    expect(service.isListening, isTrue);
    expect(service.lastError, isNull);
  });

  test(
    'startListening resets state and records error when listen throws',
    () async {
      final notifications = <String>[];
      service.addListener(() {
        notifications.add(
          'available=${service.isAvailable},listening=${service.isListening},error=${service.lastError}',
        );
      });
      whenInitialize().thenAnswer((_) async => true);
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenThrow(Exception('listen failed'));

      await service.initialize();
      await service.startListening(onResult: (_) {});

      expect(service.isListening, isFalse);
      expect(service.isAvailable, isFalse);
      expect(service.lastError, contains('listen failed'));
      expect(
        notifications,
        contains(
          'available=false,listening=false,error=Exception: listen failed',
        ),
      );
    },
  );

  test('startListening watchdog resolves a stuck session when the plugin '
      'never calls back (listen() resolves without throwing, but the '
      'platform silently failed to start)', () {
    fakeAsync((async) {
      whenInitialize().thenAnswer((_) async => true);
      // Mirrors the real `speech_to_text` failure mode this watchdog
      // guards against: `SpeechToTextPlatform.instance.listen()` can
      // return `started: false` internally, in which case the public
      // `listen()` future completes normally but neither onResult nor
      // onStatus/onError is ever invoked.
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});

      service.initialize();
      async.flushMicrotasks();
      service.startListening(onResult: (_) {});
      async.flushMicrotasks();
      expect(service.isListening, isTrue);

      // Just short of the watchdog deadline: still "listening", no
      // feedback yet — a working session could still legitimately be
      // running (listenFor is 30s).
      async.elapse(const Duration(seconds: 32));
      expect(service.isListening, isTrue);

      // Past the deadline: watchdog fires, resets state and surfaces a
      // reason so the caller can show it.
      async.elapse(const Duration(seconds: 2));
      expect(service.isListening, isFalse);
      expect(service.lastError, 'error_recognizer_unavailable');
      expect(service.issue, VoiceInputIssue.recognizerUnavailable);
    });
  });

  test(
    'startListening watchdog does not fire once the session ends normally',
    () {
      fakeAsync((async) {
        SpeechStatusListener? statusListener;
        SpeechResultListener? resultListener;
        whenInitialize().thenAnswer((invocation) async {
          statusListener =
              invocation.namedArguments[#onStatus] as SpeechStatusListener?;
          return true;
        });
        when(
          mockStt.listen(
            onResult: anyNamed('onResult'),
            listenFor: anyNamed('listenFor'),
            pauseFor: anyNamed('pauseFor'),
            listenOptions: anyNamed('listenOptions'),
          ),
        ).thenAnswer((invocation) async {
          resultListener =
              invocation.namedArguments[#onResult] as SpeechResultListener?;
        });

        service.initialize();
        async.flushMicrotasks();
        service.startListening(onResult: (_) {});
        async.flushMicrotasks();

        // 一次真正干净的结束必须**先出结果**再收终态。原先这里只发了
        // 'done' 就断言 lastError 为 null——那其实是 doneNoResult（跑完
        // 零结果）的场景，恰恰不是"正常结束"。
        resultListener?.call(
          SpeechRecognitionResult([
            SpeechRecognitionWords('hello', null, 0.9),
          ], true),
        );
        statusListener?.call('done');
        expect(service.isListening, isFalse);
        expect(service.lastError, isNull);

        // Advance past the watchdog deadline — it must not clobber a
        // clean, already-completed session's state.
        async.elapse(const Duration(seconds: 40));
        expect(service.isListening, isFalse);
        expect(service.lastError, isNull);
      });
    },
  );

  test('stopListening calls stt.stop and clears isListening', () async {
    whenInitialize().thenAnswer((_) async => true);
    when(
      mockStt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((_) async {});
    when(mockStt.stop()).thenAnswer((_) async {});
    await service.initialize();
    await service.startListening(onResult: (_) {});
    await service.stopListening();
    expect(service.isListening, isFalse);
    verify(mockStt.stop()).called(1);
  });

  test(
    'stopListening clears state and records error when stop throws',
    () async {
      whenInitialize().thenAnswer((_) async => true);
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});
      when(mockStt.stop()).thenThrow(Exception('stop failed'));

      await service.initialize();
      await service.startListening(onResult: (_) {});
      await service.stopListening();

      expect(service.isListening, isFalse);
      expect(service.lastError, contains('stop failed'));
      verify(mockStt.stop()).called(1);
    },
  );

  test('cancelListening calls stt.cancel and clears isListening', () async {
    whenInitialize().thenAnswer((_) async => true);
    when(
      mockStt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((_) async {});
    when(mockStt.cancel()).thenAnswer((_) async {});

    await service.initialize();
    await service.startListening(onResult: (_) {});
    await service.cancelListening();

    expect(service.isListening, isFalse);
    verify(mockStt.cancel()).called(1);
    verifyNever(mockStt.stop());
  });

  test('cancelListening ignores late final recognition results', () async {
    void Function(SpeechRecognitionResult)? capturedOnResult;
    whenInitialize().thenAnswer((_) async => true);
    when(
      mockStt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((invocation) async {
      capturedOnResult =
          invocation.namedArguments[#onResult]
              as void Function(SpeechRecognitionResult);
    });
    when(mockStt.cancel()).thenAnswer((_) async {});
    final results = <String>[];

    await service.initialize();
    await service.startListening(onResult: results.add);
    await service.cancelListening();
    capturedOnResult?.call(
      SpeechRecognitionResult(const [
        SpeechRecognitionWords('late text', null, 1),
      ], true),
    );

    expect(service.isListening, isFalse);
    expect(results, isEmpty);
  });

  test(
    'cancelListening clears state and records error when cancel throws',
    () async {
      whenInitialize().thenAnswer((_) async => true);
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});
      when(mockStt.cancel()).thenThrow(Exception('cancel failed'));

      await service.initialize();
      await service.startListening(onResult: (_) {});
      await service.cancelListening();

      expect(service.isListening, isFalse);
      expect(service.lastError, contains('cancel failed'));
      verify(mockStt.cancel()).called(1);
      verifyNever(mockStt.stop());
    },
  );

  // ── 异步失败上报 ──────────────────────────────────────────────────
  //
  // 真机上最常见的失败形态：listen() 被平台接受、正常返回，错误几百毫秒
  // 后才经 onError 到达。调用方在 `await startListening(...)` 之后做的
  // 同步快照检查此时早已通过，所以这条路径必须由 onFailure 主动上报，
  // 否则 UI 上只剩麦克风图标闪一下——正是"点了没反应"的真实成因。

  /// 装配一个"initialize 成功、listen 正常返回"的识别器，并把 onError
  /// 监听器交出来，让测试自己决定错误何时到达。
  Future<SpeechErrorListener?> startWithCapturedErrorListener(
    void Function(VoiceInputIssue issue) onFailure,
  ) async {
    SpeechErrorListener? errorListener;
    whenInitialize().thenAnswer((invocation) async {
      errorListener =
          invocation.namedArguments[#onError] as SpeechErrorListener?;
      return true;
    });
    when(
      mockStt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((_) async {});
    await service.initialize();
    await service.startListening(onResult: (_) {}, onFailure: onFailure);
    return errorListener;
  }

  test(
    'onFailure fires when the error arrives after listen() returned',
    () async {
      final failures = <VoiceInputIssue>[];
      final errorListener = await startWithCapturedErrorListener(failures.add);

      expect(service.isListening, isTrue, reason: '前提：平台已接受启动，同步检查此刻看不出任何问题');
      expect(failures, isEmpty);

      errorListener?.call(SpeechRecognitionError('error_no_match', true));

      expect(service.isListening, isFalse);
      expect(failures, [VoiceInputIssue.microphoneMutedOrNoSpeech]);
    },
  );

  // 用 error_no_match 而不是 error_client：后者在启动窗口内属于"机器坏了"，
  // 现在会触发引擎升档而不是上报（升档对调用方是透明的，见「引擎级联」组）。
  // 这条测的是"一次会话只上报一次"，得用一个不会引起升档的错误码。
  test('onFailure fires at most once per session', () async {
    final failures = <VoiceInputIssue>[];
    final errorListener = await startWithCapturedErrorListener(failures.add);

    errorListener?.call(SpeechRecognitionError('error_no_match', true));
    errorListener?.call(SpeechRecognitionError('error_no_match', true));

    expect(failures, hasLength(1));
  });

  test('a late error from a cancelled session stays silent', () async {
    final failures = <VoiceInputIssue>[];
    final errorListener = await startWithCapturedErrorListener(failures.add);
    when(mockStt.cancel()).thenAnswer((_) async {});

    await service.cancelListening();
    // 用户主动取消后平台仍可能补一发错误——那不是需要解释给用户的失败。
    errorListener?.call(SpeechRecognitionError('error_client', true));

    expect(failures, isEmpty);
  });

  test('the watchdog reports through onFailure too', () {
    fakeAsync((async) {
      final failures = <VoiceInputIssue>[];
      whenInitialize().thenAnswer((_) async => true);
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});

      service.initialize();
      async.flushMicrotasks();
      service.startListening(onResult: (_) {}, onFailure: failures.add);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 34));

      expect(failures, [VoiceInputIssue.recognizerUnavailable]);
    });
  });

  // ── 一次"没听清"不能废掉整个识别器 ─────────────────────────────
  //
  // speech_to_text 的 Android 端对**每一个**错误都写死 permanent=true
  // （SpeechToTextPlugin.kt 的 sendError）。照字面信它，一次普通的
  // error_no_match 就会把 isAvailable 永久钉成 false，麦克风此后再也起
  // 不来——真机症状正是"第一次闪一下，以后点了纹丝不动"。
  test(
    'a no-match error keeps the recognizer usable for the next tap',
    () async {
      final failures = <VoiceInputIssue>[];
      final errorListener = await startWithCapturedErrorListener(failures.add);

      // permanent=true 就是 Android 端实际发出来的样子。
      errorListener?.call(SpeechRecognitionError('error_no_match', true));

      expect(service.isListening, isFalse);
      expect(failures, [VoiceInputIssue.microphoneMutedOrNoSpeech]);
      expect(service.isAvailable, isTrue, reason: '没听清是每次说话都可能发生的正常结果，不是识别器坏了');
    },
  );

  test('genuinely fatal errors still disable the recognizer', () async {
    final errorListener = await startWithCapturedErrorListener((_) {});

    errorListener?.call(
      SpeechRecognitionError('error_language_not_supported', true),
    );

    expect(service.isAvailable, isFalse);
    expect(service.issue, VoiceInputIssue.recognizerUnavailable);
  });

  // ── 会话跑完但零结果 ───────────────────────────────────────────
  //
  // 麦克风关了，然后什么都没来——既没有最终结果也没有错误。判定要等一个
  // 短宽限期，因为终止状态本身不是结论：`onEndOfSpeech` 关麦克风的时候
  // `resultSent` 还是 false，成功的一次说话也会先发 done 再送结果。所以
  // 不能在 done 那一刻断言为空，只能等一下看有没有东西跟上来。
  test('a terminal status with no result reports through onFailure', () {
    fakeAsync((async) {
      SpeechStatusListener? statusListener;
      final failures = <VoiceInputIssue>[];
      whenInitialize().thenAnswer((invocation) async {
        statusListener =
            invocation.namedArguments[#onStatus] as SpeechStatusListener?;
        return true;
      });
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});

      service.initialize();
      async.flushMicrotasks();
      service.startListening(onResult: (_) {}, onFailure: failures.add);
      async.flushMicrotasks();

      statusListener?.call('done');

      // 灯要立刻灭——麦克风确实关了，这一步不该等。
      expect(service.isListening, isFalse);
      expect(failures, isEmpty, reason: '宽限期内不下结论，结果可能还在路上');

      async.elapse(const Duration(seconds: 2));

      expect(failures, [
        VoiceInputIssue.microphoneMutedOrNoSpeech,
      ], reason: '识别器跑完却什么都没给出来，必须让用户知道');
    });
  });

  // ── 真机上「说了话没识别出来」的完整序列 ──────────────────────────
  //
  // 这是用户报的"点了没反应"的确切形状：图标闪一下绿又立刻回灰，然后
  // 什么提示都没有。之前三条上报通道全挂在 `_isListening` 上，而序列的
  // 第一条事件就把它清了：
  //
  //   SpeechToTextPlugin.kt:692  onEndOfSpeech() = notifyListening(false)
  //   SpeechToTextPlugin.kt:387  notifyListening(false) 连发两条 status：
  //                                notListening，紧接着 doneNoResult
  //   speech_to_text.dart:721    doneNoResult 映射成 done 后原样转发
  //   SpeechToTextPlugin.kt:718  onError() 先 sendError 才 notifyListening
  //                                （此时 listening 已 false，不再重发）
  //
  // 于是 notListening 关灯 → done 撞 `!_isListening` 返回 → error 撞
  // `wasListening == false` 返回 → watchdog 也撞 `!_isListening` 返回。
  // 一个信号掐灭三张网。现在守卫改看"会话是否已结算"，与灯无关。
  test('真机序列 notListening→done→error：错误必须仍然上报', () async {
    SpeechStatusListener? statusListener;
    SpeechErrorListener? errorListener;
    final failures = <VoiceInputIssue>[];
    whenInitialize().thenAnswer((invocation) async {
      statusListener =
          invocation.namedArguments[#onStatus] as SpeechStatusListener?;
      errorListener =
          invocation.namedArguments[#onError] as SpeechErrorListener?;
      return true;
    });
    when(
      mockStt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((_) async {});

    await service.initialize();
    await service.startListening(onResult: (_) {}, onFailure: failures.add);
    expect(service.isListening, isTrue, reason: '图标此时是绿的');

    statusListener?.call('notListening');
    expect(service.isListening, isFalse, reason: '图标在这一步回灰');

    statusListener?.call('done');
    errorListener?.call(SpeechRecognitionError('error_no_match', true));

    expect(failures, [
      VoiceInputIssue.microphoneMutedOrNoSpeech,
    ], reason: '闪绿又回灰之后必须有东西解释原因，否则就是"点了没反应"');
    // 错误已经结算了会话，宽限定时器必须被撤掉，不能再补一发。
    expect(service.lastError, 'error_no_match');
  });

  // 同一次会话只结算一次：错误上报之后，宽限期到点不该再报第二遍。
  test('错误结算之后宽限定时器不再补发', () {
    fakeAsync((async) {
      SpeechStatusListener? statusListener;
      SpeechErrorListener? errorListener;
      final failures = <VoiceInputIssue>[];
      whenInitialize().thenAnswer((invocation) async {
        statusListener =
            invocation.namedArguments[#onStatus] as SpeechStatusListener?;
        errorListener =
            invocation.namedArguments[#onError] as SpeechErrorListener?;
        return true;
      });
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});

      service.initialize();
      async.flushMicrotasks();
      service.startListening(onResult: (_) {}, onFailure: failures.add);
      async.flushMicrotasks();

      statusListener?.call('notListening');
      statusListener?.call('done');
      errorListener?.call(SpeechRecognitionError('error_no_match', true));
      expect(failures, hasLength(1));

      async.elapse(const Duration(seconds: 40));

      expect(failures, hasLength(1), reason: '宽限期和 watchdog 都不该二次上报');
    });
  });

  // ── 启动即死 → 应用内路径降级 ─────────────────────────────────────
  //
  // 真机 trace（国产 ROM，装了 Google 服务，输入法麦克风正常）：
  //   09:37:48.645  onStatus listening
  //   09:37:48.647  onStatus notListening     ← 2ms
  //   09:37:48.647  onError  error_client
  // initialize() 成功、isAvailable 为 true，所以每次点击都走应用内路径、
  // 每次都在 2ms 内死掉，而系统语音界面兜底成了永远到不了的死代码。
  group('启动即死检测', () {
    late SpeechStatusListener? statusListener;
    late SpeechErrorListener? errorListener;

    void wireListeners() {
      whenInitialize().thenAnswer((invocation) async {
        statusListener =
            invocation.namedArguments[#onStatus] as SpeechStatusListener?;
        errorListener =
            invocation.namedArguments[#onError] as SpeechErrorListener?;
        return true;
      });
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) async {});
    }

    test('启动窗口内的 error_client 触发升档，而不是直接放弃内联', () {
      fakeAsync((async) {
        wireListeners();
        service.initialize();
        async.flushMicrotasks();
        expect(service.engineTier, VoiceEngineTier.platformDefault);
        expect(service.inAppPathBroken, isFalse);

        service.startListening(onResult: (_) {}, onFailure: (_) {});
        async.flushMicrotasks();

        // 真机的时序：毫秒级，远在 1s 启动窗口之内
        async.elapse(const Duration(milliseconds: 2));
        statusListener?.call('notListening');
        statusListener?.call('done');
        errorListener?.call(SpeechRecognitionError('error_client', true));
        async.flushMicrotasks();

        expect(
          service.engineTier,
          VoiceEngineTier.onDevice,
          reason: '麦克风都没打开过就死了——先换下一档引擎再说',
        );
        expect(
          service.inAppPathBroken,
          isFalse,
          reason:
              '还有档位没试，不该现在就把整屏交给系统界面'
              '（三档穷尽的情形由「引擎级联」组覆盖）',
        );
      });
    });

    test('启动窗口之外的 error_client 不降级', () {
      fakeAsync((async) {
        wireListeners();
        service.initialize();
        async.flushMicrotasks();
        service.startListening(onResult: (_) {}, onFailure: (_) {});
        async.flushMicrotasks();

        // 会话跑了 5 秒才出错——识别器确实工作过，可能只是偶发
        async.elapse(const Duration(seconds: 5));
        errorListener?.call(SpeechRecognitionError('error_client', true));

        expect(
          service.engineTier,
          VoiceEngineTier.platformDefault,
          reason: '跑过一阵才失败的是偶发，不该换引擎',
        );
        expect(service.inAppPathBroken, isFalse);
      });
    });

    test('no_match 再快也不降级——它恰恰证明识别器跑起来了', () {
      fakeAsync((async) {
        wireListeners();
        service.initialize();
        async.flushMicrotasks();
        service.startListening(onResult: (_) {}, onFailure: (_) {});
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 2));
        errorListener?.call(SpeechRecognitionError('error_no_match', true));

        expect(service.engineTier, VoiceEngineTier.platformDefault);
        expect(service.inAppPathBroken, isFalse);
      });
    });

    test('busy / network 属于偶发，不降级', () {
      fakeAsync((async) {
        wireListeners();
        service.initialize();
        async.flushMicrotasks();

        for (final code in ['error_busy', 'error_network']) {
          service.startListening(onResult: (_) {}, onFailure: (_) {});
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 2));
          errorListener?.call(SpeechRecognitionError(code, true));
          expect(service.inAppPathBroken, isFalse, reason: '$code 是偶发');
        }
      });
    });
  });

  // ── 三级引擎级联 ────────────────────────────────────────────────────
  //
  // speech_to_text 有三条互斥的识别器创建路径，我们原先只用第一条：
  //   platformDefault  createSpeechRecognizer(ctx)            ← 系统默认服务
  //   intentLookup     createSpeechRecognizer(ctx, 枚举出的第一个)
  //   onDevice         createOnDeviceSpeechRecognizer(ctx)    ← Android 12+
  //
  // 国产 ROM 上第一条常常绑得上、跑不起来（error_client，2ms 内死）。级联
  // 就是在放弃内联、把整屏交给系统语音界面**之前**，把另外两条也试一遍。
  //
  // 顺序刻意让 platformDefault 打头：今天能用内联的设备第一档就成功，
  // 后面两档永远不会被碰到，不存在回归风险。
  group('引擎级联', () {
    /// 每档一个独立 mock，由工厂按调用次序发出——这样测试能规定"第 N 档
    /// 的行为是什么"，正是级联要验的东西。
    late List<MockSpeechToText> engines;
    late List<SpeechStatusListener?> statusListeners;
    late List<SpeechErrorListener?> errorListeners;

    /// [failFast] 里为 true 的档位会在启动窗口内抛 error_client。
    VoiceInputService buildService(List<bool> failFast) {
      engines = [];
      statusListeners = [];
      errorListeners = [];
      var created = 0;

      MockSpeechToText makeEngine() {
        final index = created++;
        final engine = MockSpeechToText();
        statusListeners.add(null);
        errorListeners.add(null);
        when(
          engine.initialize(
            onError: anyNamed('onError'),
            onStatus: anyNamed('onStatus'),
            debugLogging: anyNamed('debugLogging'),
            options: anyNamed('options'),
          ),
        ).thenAnswer((invocation) async {
          statusListeners[index] =
              invocation.namedArguments[#onStatus] as SpeechStatusListener?;
          errorListeners[index] =
              invocation.namedArguments[#onError] as SpeechErrorListener?;
          return true;
        });
        when(
          engine.listen(
            onResult: anyNamed('onResult'),
            listenFor: anyNamed('listenFor'),
            pauseFor: anyNamed('pauseFor'),
            listenOptions: anyNamed('listenOptions'),
          ),
        ).thenAnswer((_) async {
          if (index < failFast.length && failFast[index]) {
            // 真机形态：listen() 正常返回，紧接着 onError 到达
            Future.microtask(
              () => errorListeners[index]?.call(
                SpeechRecognitionError('error_client', true),
              ),
            );
          }
        });
        engines.add(engine);
        return engine;
      }

      final first = makeEngine();
      return VoiceInputService(first, () async => true, makeEngine);
    }

    test('第一档就能用：不升档，也不碰系统语音界面', () async {
      final service = buildService([false]);
      final failures = <VoiceInputIssue>[];

      await service.prepare();
      await service.startListening(onResult: (_) {}, onFailure: failures.add);
      await Future<void>.delayed(Duration.zero);

      expect(service.engineTier, VoiceEngineTier.platformDefault);
      expect(engines, hasLength(1), reason: '没有理由重建引擎');
      expect(service.inAppPathBroken, isFalse);
      expect(failures, isEmpty);
      expect(service.isListening, isTrue);
    });

    test('第一档启动即死 → 自动升到第二档并成功，用户不知情', () async {
      final service = buildService([true, false]);
      final failures = <VoiceInputIssue>[];

      await service.prepare();
      await service.startListening(onResult: (_) {}, onFailure: failures.add);
      // 让 microtask 里的 onError + 随后的重建/initialize/listen 跑完
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.engineTier, VoiceEngineTier.onDevice);
      expect(engines, hasLength(2), reason: '换档必须换一个新的 SpeechToText');
      expect(service.inAppPathBroken, isFalse, reason: '内联路径救回来了，不该降级到系统界面');
      expect(failures, isEmpty, reason: '中途换档对调用方是透明的，不弹框');
      expect(
        service.isListening,
        isTrue,
        reason: '绿灯在整个级联期间不断——否则就是 green→grey→green 闪烁',
      );
    });

    test('前两档都死 → 升到 onDevice 并成功', () async {
      final service = buildService([true, true, false]);
      final failures = <VoiceInputIssue>[];

      await service.prepare();
      await service.startListening(onResult: (_) {}, onFailure: failures.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.engineTier, VoiceEngineTier.intentLookup);
      expect(engines, hasLength(3));
      expect(service.inAppPathBroken, isFalse);
      expect(failures, isEmpty);
      expect(service.isListening, isTrue);
    });

    // 三个 speech_to_text 档全死之后，还会落到第四档（targetedBind）。这里
    // 没有给它装假 channel，所以枚举拿不到任何服务、那一档自己也不可用，
    // 于是内联整体到此为止。targetedBind 自身的行为见下面的组。
    test('四档全部走完 → 才标记 inAppPathBroken，交给系统语音界面', () async {
      final service = buildService([true, true, true]);
      final failures = <VoiceInputIssue>[];

      await service.prepare();
      await service.startListening(onResult: (_) {}, onFailure: failures.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        service.engineTier,
        VoiceEngineTier.targetedBind,
        reason: '停在最后一档',
      );
      expect(
        engines,
        hasLength(3),
        reason: 'speech_to_text 只重建两次；第四档换的是后端，不是它的实例',
      );
      expect(service.inAppPathBroken, isTrue, reason: '内联所有路都试过了，这才轮到系统界面');
      expect(failures, hasLength(1), reason: '穷尽之后必须上报一次，且只一次');
      expect(service.isListening, isFalse, reason: '彻底失败，绿灯要灭');
    });

    // ── 两个不变量，各自锁一条真实踩过的坑 ────────────────────────────
    //
    // 这两条不测我们自己的逻辑，测的是"我们发给插件的参数组合能不能真的
    // 让它换识别器"。第一版级联两条都违反了，结果第二档整档空转、第三档
    // 走错分支，而所有单元测试当时都是绿的——因为假引擎不模拟
    // createRecognizer 的跳过条件。所以这两条必须显式断言参数本身。
    test('不变量一：onDevice 必须逐档翻转，否则平台不重建识别器', () async {
      final service = buildService([true, true, false]);

      await service.prepare();
      await service.startListening(onResult: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      SpeechListenOptions listenOptionsOf(MockSpeechToText engine) =>
          verify(
                engine.listen(
                  onResult: anyNamed('onResult'),
                  listenFor: anyNamed('listenFor'),
                  pauseFor: anyNamed('pauseFor'),
                  listenOptions: captureAnyNamed('listenOptions'),
                ),
              ).captured.last
              as SpeechListenOptions;

      final onDeviceFlags = engines.map(listenOptionsOf).map((o) => o.onDevice);
      expect(
        onDeviceFlags,
        [false, true, false],
        reason:
            'createRecognizer 只比较 onDevice：值不变就 return，'
            '那一档等于没换引擎',
      );
    });

    test('不变量二：intentLookup 每档都显式传值，不能省略', () async {
      final service = buildService([true, true, false]);

      await service.prepare();
      await service.startListening(onResult: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      List<SpeechConfigOption> optionsOf(MockSpeechToText engine) =>
          verify(
                engine.initialize(
                  onError: anyNamed('onError'),
                  onStatus: anyNamed('onStatus'),
                  debugLogging: anyNamed('debugLogging'),
                  options: captureAnyNamed('options'),
                ),
              ).captured.last
              as List<SpeechConfigOption>;

      final flags = engines.map(optionsOf).map((opts) {
        final match = opts.where((o) => o.name == 'intentLookup');
        expect(
          match,
          hasLength(1),
          reason:
              'Kotlin 侧 `if (null != iOpt)` 会保留上次的值，'
              '省略等于继承——每档都必须显式给',
        );
        return match.single.value as bool;
      });
      expect(
        flags,
        [false, false, true],
        reason:
            'intentLookup 在 createRecognizer 里优先级最高，一旦置 true '
            '后面所有档位都只能走它那条分支',
      );
    });

    // 蓝牙每档都关：插件否则会把 BLUETOOTH_CONNECT 加进它请求的权限列表
    // （SpeechToTextPlugin.kt:477），而这个权限我们压根没声明。
    test('noBluetooth 每档都带上', () async {
      final service = buildService([true, true, false]);

      await service.prepare();
      await service.startListening(onResult: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 每个 engine 只 verify 一次——mockito 的 verify 会把匹配到的调用标记
      // 为已验证，同一次调用再 verify 会报 No matching calls。
      List<SpeechConfigOption> optionsOf(MockSpeechToText engine) =>
          verify(
                engine.initialize(
                  onError: anyNamed('onError'),
                  onStatus: anyNamed('onStatus'),
                  debugLogging: anyNamed('debugLogging'),
                  options: captureAnyNamed('options'),
                ),
              ).captured.last
              as List<SpeechConfigOption>;

      for (final opts in engines.map(optionsOf)) {
        expect(opts.contains(SpeechToText.androidNoBluetooth), isTrue);
      }
    });

    // ── 第四档：按 ComponentName 逐个绑定 ────────────────────────────
    //
    // 前三档只可能碰到两个服务（系统默认、枚举首个）。厂商坏 stub 排第一
    // 时那两者是同一个，列表里往后的可用服务用任何 speech_to_text 选项都
    // 表达不出来。这一档换成自有后端，把整个列表走一遍。
    group('targetedBind 档', () {
      /// 装一个假的 inline channel：[failing] 里的 component 会立刻回
      /// error_client，其余的回一个成功结果。
      InlineSpeechRecognizer buildInline({
        required List<String> services,
        required Set<String> failing,
        List<String>? attempts,
      }) {
        const channel = MethodChannel('sh.flyterm.app/inline_speech');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'listServices':
              return services;
            case 'start':
              final args = call.arguments as Map<Object?, Object?>;
              final component = args['component'] as String?;
              attempts?.add(component ?? '(default)');
              // 真机形态：start 正常返回，随后平台反向推事件。
              Future.microtask(() async {
                final method =
                    failing.contains(component) ? 'onError' : 'onResult';
                final payload =
                    failing.contains(component)
                        ? {'session': 1, 'error': 'error_client'}
                        : {'session': 1, 'text': 'hello from $component'};
                await messenger.handlePlatformMessage(
                  channel.name,
                  channel.codec.encodeMethodCall(MethodCall(method, payload)),
                  (_) {},
                );
              });
              return true;
            default:
              return null;
          }
        });
        return InlineSpeechRecognizer(channel: channel, isAndroid: () => true);
      }

      /// 前三档全部启动即死，于是必然落到 targetedBind。
      VoiceInputService buildServiceOnTargetedTier(
        InlineSpeechRecognizer inline,
      ) {
        var created = 0;
        final errorListeners = <SpeechErrorListener?>[];
        MockSpeechToText makeEngine() {
          final index = created++;
          final engine = MockSpeechToText();
          errorListeners.add(null);
          when(
            engine.initialize(
              onError: anyNamed('onError'),
              onStatus: anyNamed('onStatus'),
              debugLogging: anyNamed('debugLogging'),
              options: anyNamed('options'),
            ),
          ).thenAnswer((invocation) async {
            errorListeners[index] =
                invocation.namedArguments[#onError] as SpeechErrorListener?;
            return true;
          });
          when(
            engine.listen(
              onResult: anyNamed('onResult'),
              listenFor: anyNamed('listenFor'),
              pauseFor: anyNamed('pauseFor'),
              listenOptions: anyNamed('listenOptions'),
            ),
          ).thenAnswer((_) async {
            Future.microtask(
              () => errorListeners[index]?.call(
                SpeechRecognitionError('error_client', true),
              ),
            );
          });
          return engine;
        }

        return VoiceInputService(
          makeEngine(),
          () async => true,
          makeEngine,
          inline,
        );
      }

      test('第一个服务就能用：拿到结果，不再往后试', () async {
        final attempts = <String>[];
        final inline = buildInline(
          services: ['com.google.app/.Good', 'com.vendor/.Stub'],
          failing: const {},
          attempts: attempts,
        );
        final service = buildServiceOnTargetedTier(inline);
        addTearDown(service.dispose);
        final results = <String>[];

        await service.prepare();
        await service.startListening(onResult: results.add);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(service.engineTier, VoiceEngineTier.targetedBind);
        expect(attempts, ['com.google.app/.Good'], reason: '第一个就成了，不该继续');
        expect(results, ['hello from com.google.app/.Good']);
        expect(service.inAppPathBroken, isFalse, reason: '内联救回来了');
      });

      // 这条就是整个第四档存在的理由：坏 stub 排第一，可用服务排第二。
      // 前三档任何配置都只能碰到第一个。
      test('坏 stub 排第一时，跳到第二个服务并成功', () async {
        final attempts = <String>[];
        final inline = buildInline(
          services: ['com.vendor/.Stub', 'com.google.app/.Good'],
          failing: const {'com.vendor/.Stub'},
          attempts: attempts,
        );
        final service = buildServiceOnTargetedTier(inline);
        addTearDown(service.dispose);
        final results = <String>[];
        final failures = <VoiceInputIssue>[];

        await service.prepare();
        await service.startListening(
          onResult: results.add,
          onFailure: failures.add,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(attempts, ['com.vendor/.Stub', 'com.google.app/.Good']);
        expect(results, ['hello from com.google.app/.Good']);
        expect(failures, isEmpty, reason: '换服务对调用方透明，不弹框');
        expect(service.inAppPathBroken, isFalse);
      });

      test('所有服务都死 → 这才标记 inAppPathBroken', () async {
        final attempts = <String>[];
        final inline = buildInline(
          services: ['com.vendor/.A', 'com.vendor/.B'],
          failing: const {'com.vendor/.A', 'com.vendor/.B'},
          attempts: attempts,
        );
        final service = buildServiceOnTargetedTier(inline);
        addTearDown(service.dispose);
        final failures = <VoiceInputIssue>[];

        await service.prepare();
        await service.startListening(onResult: (_) {}, onFailure: failures.add);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(attempts, ['com.vendor/.A', 'com.vendor/.B'], reason: '每个都试过');
        expect(service.inAppPathBroken, isTrue);
        expect(failures, hasLength(1), reason: '穷尽之后上报一次');
      });

      test('设备上一个服务都没有：这一档直接不可用', () async {
        final inline = buildInline(services: const [], failing: const {});
        final service = buildServiceOnTargetedTier(inline);
        addTearDown(service.dispose);
        final failures = <VoiceInputIssue>[];

        await service.prepare();
        await service.startListening(onResult: (_) {}, onFailure: failures.add);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(service.recognitionServices, isEmpty);
        expect(
          service.inAppPathBroken,
          isTrue,
          reason: '没有任何可绑定服务——内联到此为止，交给系统界面',
        );
      });

      // 服务列表要能被诊断框读到：那是"该修哪一层"唯一的判据，
      // 而它平时只出现在 logcat 里。
      test('recognitionServices 暴露给诊断用', () async {
        final inline = buildInline(
          services: ['com.vendor/.A', 'com.google.app/.Good'],
          failing: const {'com.vendor/.A'},
        );
        final service = buildServiceOnTargetedTier(inline);
        addTearDown(service.dispose);

        await service.prepare();
        await service.startListening(onResult: (_) {});
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(service.recognitionServices, [
          'com.vendor/.A',
          'com.google.app/.Good',
        ]);
      });
    });

    // ── 小米 ROM（Android 16）实测形态 ───────────────────────────────
    //
    // 整台设备只有一个 RecognitionService：
    //   com.xiaomi.mibrain.speech/...asr.AsrService
    // 它接受启动（InlineSpeechStarted 到了），随后吐一串轮换的错误码：
    //   +29ms  error_permission
    //   +3.0s  error_network
    //          空结果
    // 而下一次点击又换成 error_server_disconnected。
    //
    // 两个必须成立的性质：
    //  1. error_permission 不能被译成"用户没给麦克风权限"——我们几毫秒前
    //     刚验过 RECORD_AUDIO 是有的，那个提示只会把用户送去一个开关已经
    //     打开的设置页；
    //  2. 这种引擎必须能被判定为不可用，从而落到能用的系统语音界面。
    //     否则每次点击都在重试同一个死引擎，连弹窗都到不了。
    group('小米 ROM 轮换错误码', () {
      late SpeechErrorListener? errorListener;

      VoiceInputService buildVerifiedService() {
        errorListener = null;
        whenInitialize().thenAnswer((invocation) async {
          errorListener =
              invocation.namedArguments[#onError] as SpeechErrorListener?;
          return true;
        });
        when(
          mockStt.listen(
            onResult: anyNamed('onResult'),
            listenFor: anyNamed('listenFor'),
            pauseFor: anyNamed('pauseFor'),
            listenOptions: anyNamed('listenOptions'),
          ),
        ).thenAnswer((_) async {});
        // permissionChecker 返回 true = 我们确实持有 RECORD_AUDIO
        return VoiceInputService(mockStt, () async => true);
      }

      test('权限已验证过时，error_permission 不再谎报成"用户没给权限"', () async {
        final service = buildVerifiedService();
        await service.prepare();
        await service.startListening(onResult: (_) {});

        errorListener?.call(SpeechRecognitionError('error_permission', true));

        expect(
          service.issue,
          VoiceInputIssue.recognizerUnavailable,
          reason: '我们刚验过权限是有的，这条错误说的是识别器自己',
        );
        expect(
          service.issue,
          isNot(VoiceInputIssue.microphonePermissionDenied),
          reason: '不能再把用户送去一个开关已经打开的设置页',
        );
      });

      test('权限未验证时，error_permission 仍然按真的缺权限处理', () async {
        // permissionChecker 缺省（null）→ 走真实权限流程，测试里没验过
        whenInitialize().thenAnswer((_) async => true);
        SpeechErrorListener? listener;
        whenInitialize().thenAnswer((invocation) async {
          listener =
              invocation.namedArguments[#onError] as SpeechErrorListener?;
          return true;
        });
        final service = VoiceInputService(mockStt);
        await service.initialize();

        listener?.call(SpeechRecognitionError('error_permission', true));

        expect(
          service.issue,
          VoiceInputIssue.microphonePermissionDenied,
          reason: '没验过权限，这条错误就该按字面理解',
        );
      });

      test('连续三次引擎级失败 → 判定内联不可用，交给系统界面', () async {
        final service = buildVerifiedService();
        await service.prepare();

        // 小米那台机跨点击轮换的正是这几个码，没有一个单独够判定
        for (final code in [
          'error_server_disconnected',
          'error_network',
          'error_server',
        ]) {
          await service.startListening(onResult: (_) {});
          errorListener?.call(SpeechRecognitionError(code, true));
        }

        expect(
          service.inAppPathBroken,
          isTrue,
          reason:
              '连续失败说明这引擎就是不工作——必须落到能用的系统界面，'
              '否则每次点击都在重试死引擎',
        );
      });

      // 这条是主路径：权限已验证过之后收到 error_permission，就该按"机器
      // 坏了"处理——立刻升档，而不是攒够三次才动，也不是弹权限框。
      // （四档全都失败因而落到系统界面的情形，由「四档全部走完」覆盖。）
      test('启动窗口内的 error_permission 立刻触发升档', () async {
        final service = buildVerifiedService();

        await service.prepare();
        await service.startListening(onResult: (_) {});
        expect(service.engineTier, VoiceEngineTier.platformDefault);

        errorListener?.call(SpeechRecognitionError('error_permission', true));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          service.engineTier,
          isNot(VoiceEngineTier.platformDefault),
          reason:
              '权限已验证过还报权限错，就是引擎自己坏了——'
              '该换引擎，而不是让用户去开一个已经开着的开关',
        );
      });

      test('中间成功一次就重置计数，不会被历史失败拖累', () async {
        final service = buildVerifiedService();
        SpeechResultListener? resultListener;
        when(
          mockStt.listen(
            onResult: anyNamed('onResult'),
            listenFor: anyNamed('listenFor'),
            pauseFor: anyNamed('pauseFor'),
            listenOptions: anyNamed('listenOptions'),
          ),
        ).thenAnswer((invocation) async {
          resultListener =
              invocation.namedArguments[#onResult] as SpeechResultListener?;
        });

        await service.prepare();
        await service.startListening(onResult: (_) {});
        errorListener?.call(SpeechRecognitionError('error_network', true));

        // 成功一次
        await service.startListening(onResult: (_) {});
        resultListener?.call(
          SpeechRecognitionResult([
            SpeechRecognitionWords('ok', null, 0.9),
          ], true),
        );

        // 再失败一次——计数已被成功清零，不该达到阈值
        await service.startListening(onResult: (_) {});
        errorListener?.call(SpeechRecognitionError('error_network', true));

        expect(service.inAppPathBroken, isFalse);
      });

      test('no_match 连续多次也不判定引擎坏——那是用户没说话', () async {
        final service = buildVerifiedService();

        await service.prepare();
        for (var i = 0; i < 4; i++) {
          await service.startListening(onResult: (_) {});
          errorListener?.call(SpeechRecognitionError('error_no_match', true));
        }

        expect(
          service.inAppPathBroken,
          isFalse,
          reason: 'no_match 恰恰证明识别器在正常工作',
        );
      });
    });

    test('no_match 不触发升档——它证明识别器跑起来了', () async {
      final service = buildService([false]);
      final failures = <VoiceInputIssue>[];

      await service.prepare();
      await service.startListening(onResult: (_) {}, onFailure: failures.add);
      errorListeners[0]?.call(SpeechRecognitionError('error_no_match', true));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.engineTier, VoiceEngineTier.platformDefault);
      expect(engines, hasLength(1), reason: '不该因为没听清就换引擎');
      expect(failures, [VoiceInputIssue.microphoneMutedOrNoSpeech]);
    });

    test('级联途中用户取消：挂起的重试不再起新会话', () async {
      final service = buildService([true, false]);
      final failures = <VoiceInputIssue>[];

      await service.prepare();
      await service.startListening(onResult: (_) {}, onFailure: failures.add);
      // onError 已经排进 microtask，但换档后的 initialize 还没跑完
      await service.cancelListening();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.isListening, isFalse, reason: '用户取消了，不能被换档偷偷重新打开');
      expect(failures, isEmpty, reason: '主动取消不是失败');
    });
  });

  // isAvailable 在首次探测前的 false 只是"还没问过"。UI 拿它当"不可用"
  // 渲染，会让麦克风开机就是灰的 mic_off——看着坏了，其实点得动。
  test('isKnownUnavailable 区分"还没探测"和"探测过且不可用"', () async {
    expect(service.isKnownUnavailable, isFalse, reason: '还没探测过，不该宣称不可用');

    whenInitialize().thenAnswer((_) async => false);
    await service.initialize();

    expect(service.isKnownUnavailable, isTrue, reason: '探测过了并且确实不可用');
  });

  // notListening 只表示麦克风关了，final result 紧随其后才到。它一度
  // 既复位 isListening、又让 onResult 的 !_isListening 守卫把随后到达的
  // 结果丢掉——用户说的话就此凭空消失，界面上什么都不发生。
  test(
    'a final result arriving after notListening is still delivered',
    () async {
      SpeechStatusListener? statusListener;
      SpeechResultListener? resultListener;
      final delivered = <String>[];
      final failures = <VoiceInputIssue>[];
      whenInitialize().thenAnswer((invocation) async {
        statusListener =
            invocation.namedArguments[#onStatus] as SpeechStatusListener?;
        return true;
      });
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((invocation) async {
        resultListener =
            invocation.namedArguments[#onResult] as SpeechResultListener?;
      });

      await service.initialize();
      await service.startListening(
        onResult: delivered.add,
        onFailure: failures.add,
      );

      // 平台的真实顺序：先关麦克风，再送最终结果。
      statusListener?.call('notListening');
      expect(service.isListening, isFalse);

      resultListener?.call(
        SpeechRecognitionResult([
          SpeechRecognitionWords('deploy the app', null, 0.9),
        ], true),
      );

      expect(delivered, ['deploy the app']);

      // 结果已经送到，随后的 done 不该再被当成"零结果"上报。
      statusListener?.call('done');
      expect(failures, isEmpty);
    },
  );

  // listen() 本身挂起（平台调用永不 resolve）时，watchdog 必须已经装上。
  // 它一度装在 `await _stt.listen(...)` 之后——那一行在这种场景下根本
  // 执行不到，防卡死的兜底自己也被卡住了。
  test('the watchdog is armed even if listen() never resolves', () {
    fakeAsync((async) {
      final failures = <VoiceInputIssue>[];
      whenInitialize().thenAnswer((_) async => true);
      when(
        mockStt.listen(
          onResult: anyNamed('onResult'),
          listenFor: anyNamed('listenFor'),
          pauseFor: anyNamed('pauseFor'),
          listenOptions: anyNamed('listenOptions'),
        ),
      ).thenAnswer((_) => Completer<void>().future);

      service.initialize();
      async.flushMicrotasks();
      service.startListening(onResult: (_) {}, onFailure: failures.add);
      async.flushMicrotasks();
      expect(service.isListening, isTrue);

      async.elapse(const Duration(seconds: 34));

      expect(service.isListening, isFalse);
      expect(failures, [VoiceInputIssue.recognizerUnavailable]);
    });
  });
}
