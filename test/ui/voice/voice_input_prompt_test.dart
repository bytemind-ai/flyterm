// toggleVoiceInput 的路径选择与反馈保证。
//
// 关键约定：**应用内录音（speech_to_text）是主路径**，交互必须是内联的
// ——麦克风原地转激活态、输入框 hint 变"正在听"、说完恢复，全程不离开
// 当前界面。系统语音界面（SystemSpeechInput / RECOGNIZE_SPEECH intent）
// 会盖住整屏，只在应用内录音完全不可用时才允许出现。
//
// 顺序一度被反转成"系统界面优先"，已按要求撤回。第一条测试就是锁这个
// 契约的：内联可用时连系统路径的可用性探测都不该发生。
//
// 主路径能失败得毫无声响（所有错误被标 permanent、initialize 短路无法
// 重置、listen 静默失败、doneNoResult 无人上报），所以它的安全网一个都
// 不能少，本文件后半部分逐条覆盖。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:flyterm/ai/system_speech_input.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/voice/voice_input_prompt.dart';

import '../../ai/voice_input_service_test.mocks.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

/// `speech_to_text`'s bound RecognitionService path failed to initialize:
/// `prepare()` returns normally (no permission problem) but `isAvailable`
/// stays false — the exact state a device with no bindable
/// RecognitionService reports.
///
/// [prepareCalls] exists to assert the *ordering*: when the system path
/// handles a tap, this fallback must not be touched at all.
class UnavailableVoiceInputService extends VoiceInputService {
  int prepareCalls = 0;

  @override
  Future<bool> prepare() async {
    prepareCalls++;
    return false;
  }
}

/// 应用内录音一切正常：`prepare()` 成功、可用，`startListening` 真的进入
/// 监听态（麦克风转激活、hint 变"正在听"）。
class WorkingVoiceInputService extends VoiceInputService {
  bool _listening = false;
  int startCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> startListening({
    required void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  }) async {
    startCalls++;
    _listening = true;
    notifyListeners();
  }

  @override
  Future<void> cancelListening() async {
    _listening = false;
    notifyListeners();
  }
}

/// 应用内录音"启动即死"：`prepare()` / `isAvailable` 都说可用（真机上
/// `initialize()` 确实成功），但会话在毫秒级带着 `error_client` 死掉，
/// 服务据此把自己降级（`inAppPathBroken`）。
///
/// 这是国产 ROM 上观测到的真实形态——声明了 RecognitionService 所以
/// `isRecognitionAvailable()` 说 yes，但不给第三方绑。
class InstantDeathVoiceInputService extends VoiceInputService {
  bool _broken = false;
  int startCalls = 0;

  /// [fireSynchronously] 用来覆盖两种平台顺序：错误在 `await listen()`
  /// 返回之后到达（真机观测到的），或之前到达（时序竞态）。两者都只能
  /// 弹一个框 / 走一次系统路径。
  InstantDeathVoiceInputService({this.fireSynchronously = false});
  final bool fireSynchronously;

  @override
  bool get isAvailable => true;

  @override
  bool get inAppPathBroken => _broken;

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> startListening({
    required void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  }) async {
    startCalls++;
    void die() {
      _broken = true;
      onFailure?.call(VoiceInputIssue.recognizerUnavailable);
    }

    if (fireSynchronously) {
      die();
    } else {
      // 真机顺序：listen() 先正常返回，几毫秒后 onError 才到
      Future.microtask(die);
    }
  }
}

/// 已经降级过的服务：`isAvailable` 仍是 true，但 `inAppPathBroken` 已置位。
/// 这是第二次及以后的每一次点击看到的状态。
class AlreadyBrokenVoiceInputService extends VoiceInputService {
  int startCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  bool get inAppPathBroken => true;

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> startListening({
    required void Function(String) onResult,
    void Function(VoiceInputIssue issue)? onFailure,
  }) async {
    startCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('sh.flyterm.app/system_speech');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  // 这条是本文件最重要的契约：应用内录音可用时，点麦克风必须原地进入
  // 监听态，**绝不**启动系统语音界面。全屏语音界面曾被提到主路径上，
  // 明确要求撤回——这条断言就是防止它再被提上去的那道闩。
  testWidgets('应用内录音可用时：原地进入监听态，一次都不碰系统语音界面', (tester) async {
    final systemCalls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      systemCalls.add(call.method);
      return call.method == 'isAvailable' ? true : 'from system UI';
    });
    final voice = WorkingVoiceInputService();
    final ctrl = TextEditingController();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (context) => ElevatedButton(
                onPressed:
                    () => toggleVoiceInput(
                      context,
                      voice,
                      ctrl,
                      // 故意让系统路径"可用"：即便它随时能接手，也不该被用到。
                      systemInput: SystemSpeechInput(
                        channel: channel,
                        isAndroid: () => true,
                      ),
                    ),
                child: const Text('mic'),
              ),
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(voice.startCalls, 1, reason: '应该原地开始录音');
    expect(voice.isListening, isTrue, reason: '麦克风进入激活态 = 那个"效果"');
    expect(systemCalls, isEmpty, reason: '内联可用时绝不能启动系统语音界面（哪怕只是探测可用性）');
    expect(find.byType(AlertDialog), findsNothing);
    expect(ctrl.text, isEmpty, reason: '还在录音，结果尚未到达');
  });

  testWidgets('再点一次麦克风：停止录音并恢复常态', (tester) async {
    final voice = WorkingVoiceInputService();
    final ctrl = TextEditingController();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (context) => ElevatedButton(
                onPressed:
                    () => toggleVoiceInput(
                      context,
                      voice,
                      ctrl,
                      systemInput: SystemSpeechInput(
                        channel: channel,
                        isAndroid: () => false,
                      ),
                    ),
                child: const Text('mic'),
              ),
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(voice.isListening, isTrue);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(voice.isListening, isFalse, reason: '结束后恢复');
    expect(find.byType(AlertDialog), findsNothing);
  });

  // 以下三条的共同前提：应用内录音不可用（UnavailableVoiceInputService），
  // 这才轮到系统语音界面兜底。
  testWidgets('兜底的系统界面启动失败时：弹出带原因的错误框，不静默', (tester) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return true;
      // MainActivity 在 startRecognize 失败时回的就是这个 code。
      throw PlatformException(
        code: 'START_FAILED',
        message: 'no activity handled ACTION_RECOGNIZE_SPEECH',
      );
    });
    final voice = UnavailableVoiceInputService();
    final ctrl = TextEditingController();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (context) => ElevatedButton(
                onPressed:
                    () => toggleVoiceInput(
                      context,
                      voice,
                      ctrl,
                      systemInput: SystemSpeechInput(
                        channel: channel,
                        isAndroid: () => true,
                      ),
                    ),
                child: const Text('mic'),
              ),
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    // 框里要能看出是哪一步、什么原因——否则又回到"看不出为什么"。
    expect(find.textContaining('SystemSpeechStartFailure'), findsOneWidget);
    expect(find.textContaining('systemRecognize'), findsOneWidget);
  });

  testWidgets('应用内录音和系统界面都不可用：弹说明框，不静默', (tester) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return false;
      return null;
    });
    final voice = UnavailableVoiceInputService();
    final ctrl = TextEditingController();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed:
                  () => toggleVoiceInput(
                    context,
                    voice,
                    ctrl,
                    systemInput: SystemSpeechInput(
                      channel: channel,
                      isAndroid: () => true,
                    ),
                  ),
              child: const Text('mic'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(ctrl.text, isEmpty);
  });

  testWidgets('用户取消兜底的系统界面：不填文本、也不弹框（界面出现过就是反馈）', (tester) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return true;
      if (call.method == 'recognize') return null;
      return null;
    });
    final voice = UnavailableVoiceInputService();
    final ctrl = TextEditingController();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed:
                  () => toggleVoiceInput(
                    context,
                    voice,
                    ctrl,
                    systemInput: SystemSpeechInput(
                      channel: channel,
                      isAndroid: () => true,
                    ),
                  ),
              child: const Text('mic'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(ctrl.text, isEmpty);
    expect(
      find.byType(AlertDialog),
      findsNothing,
      reason: '用户主动取消系统语音界面不是错误，不应弹出兜底也失败的对话框',
    );
  });

  // toggleVoiceInput 的静默出口兜底：走完全程却没产生任何可感知结果时，
  // 必须把走过的路径摊给用户。
  //
  // 说明：目前 toggleVoiceInput 里每条已知分支都显式标记了自己的反馈，
  // 所以这张网当前捞不到实际分支——它是防着**将来**新增分支忘记处理
  // 反馈的。正因为平时不会被走到，这里直接测被兜底调用的渲染函数本身，
  // 否则它就是一段谁也没验证过的代码。
  testWidgets('静默出口诊断框把 trail 和服务状态一起摊开', (tester) async {
    final voice = UnavailableVoiceInputService();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (context) => ElevatedButton(
                onPressed:
                    () => showVoiceSilentExitDiagnostic(context, voice, [
                      'entry isListening=false',
                      'prepared isAvailable=false',
                    ]),
                child: const Text('diag'),
              ),
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    // trail 每一步都要在框里，否则这个框没有诊断价值。
    expect(find.textContaining('entry isListening=false'), findsOneWidget);
    expect(find.textContaining('prepared isAvailable=false'), findsOneWidget);
    // 服务状态快照同样要在。
    expect(find.textContaining('isAvailable=false'), findsWidgets);
    expect(find.textContaining('issue='), findsOneWidget);
  });

  // 真机现象："麦克风图标闪一下就跳回灰色，什么框都不弹"（keybar 与
  // aipanel 两处一致）。图标能变绿说明 prepare() 成功、isAvailable 为
  // true、startListening 真的跑了；跳回灰色说明状态随后被复位了。
  //
  // 复位来自 SpeechRecognizer 的 **异步** onError 回调 —— 平台侧
  // listen() 已经成功启动并返回，错误是几百毫秒后才通过回调到达的。
  // 而 toggleVoiceInput 只在 `await voice.startListening(...)` 返回的
  // 那一刻做了一次同步快照检查（`if (!voice.isListening)`），那时
  // isListening 还是 true —— 检查通过，函数就此返回，之后到达的错误
  // 再没有任何监听者。这正是"闪一下、无反馈"。
  testWidgets('listen() 成功启动后异步 onError 到达：必须弹出说明原因的对话框', (tester) async {
    final stt = MockSpeechToText();
    SpeechErrorListener? errorListener;
    when(
      stt.initialize(
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
    // 平台侧启动成功：listen() 正常返回，不抛异常。
    when(
      stt.listen(
        onResult: anyNamed('onResult'),
        listenFor: anyNamed('listenFor'),
        pauseFor: anyNamed('pauseFor'),
        listenOptions: anyNamed('listenOptions'),
      ),
    ).thenAnswer((_) async {});

    final voice = VoiceInputService(stt, () async => true);
    final ctrl = TextEditingController();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (context) => ElevatedButton(
                onPressed:
                    () => toggleVoiceInput(
                      context,
                      voice,
                      ctrl,
                      systemInput: SystemSpeechInput(
                        channel: channel,
                        isAndroid: () => false,
                      ),
                    ),
                child: const Text('mic'),
              ),
        ),
      ),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(voice.isListening, isTrue, reason: '前提：平台侧启动成功，此刻确实在监听（图标变绿）');

    // 几百毫秒后识别器报错——真机上最常见的 error_no_match /
    // error_speech_timeout / error_client 都走这条回调。
    errorListener?.call(SpeechRecognitionError('error_no_match', true));
    await tester.pumpAndSettle();

    expect(voice.isListening, isFalse, reason: '状态已复位（图标跳回灰色）');
    expect(
      find.byType(AlertDialog),
      findsOneWidget,
      reason: '识别失败必须让用户看见原因，不能只是图标闪一下',
    );
  });

  // ── 启动即死 → 当场降级到系统语音界面 ──────────────────────────────
  //
  // 真机形态（国产 ROM）：initialize() 成功、isAvailable 为 true，但会话
  // 在 2ms 内带着 error_client 死掉。旧代码在这里只会弹个框，用户点一次
  // 得一个框，语音永远用不上——而系统语音界面兜底就在下面几行，永远到
  // 不了，因为它的入口条件是 `!isAvailable`。
  group('应用内录音启动即死', () {
    for (final sync in [false, true]) {
      final label = sync ? '错误先于 listen() 返回' : '错误后于 listen() 返回';
      testWidgets('$label：当场落到系统语音界面，且只走一次', (tester) async {
        final systemCalls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          systemCalls.add(call.method);
          return call.method == 'isAvailable' ? true : '降级后识别到的文本';
        });
        final voice = InstantDeathVoiceInputService(fireSynchronously: sync);
        final ctrl = TextEditingController();

        await tester.pumpWidget(
          _wrap(
            Builder(
              builder:
                  (context) => ElevatedButton(
                    onPressed:
                        () => toggleVoiceInput(
                          context,
                          voice,
                          ctrl,
                          systemInput: SystemSpeechInput(
                            channel: channel,
                            isAndroid: () => true,
                          ),
                        ),
                    child: const Text('mic'),
                  ),
            ),
          ),
        );

        await tester.tap(find.byType(ElevatedButton));
        await tester.pumpAndSettle();

        expect(voice.startCalls, 1, reason: '应用内路径仍然先试一次');
        expect(systemCalls, [
          'isAvailable',
          'recognize',
        ], reason: '自证跑不起来之后当场降级，不该让用户再点一次');
        expect(ctrl.text, '降级后识别到的文本', reason: '用户要的是语音输入，降级后必须真的拿到文字');
        expect(
          find.byType(AlertDialog),
          findsNothing,
          reason: '系统界面已经出现过并给出了结果，不该再弹框解释',
        );
      });
    }

    testWidgets('已降级的服务：后续点击直接走系统界面，不再试应用内', (tester) async {
      final systemCalls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        systemCalls.add(call.method);
        return call.method == 'isAvailable' ? true : '第二次点击的结果';
      });
      final voice = AlreadyBrokenVoiceInputService();
      final ctrl = TextEditingController();

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder:
                (context) => ElevatedButton(
                  onPressed:
                      () => toggleVoiceInput(
                        context,
                        voice,
                        ctrl,
                        systemInput: SystemSpeechInput(
                          channel: channel,
                          isAndroid: () => true,
                        ),
                      ),
                  child: const Text('mic'),
                ),
          ),
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      expect(voice.startCalls, 0, reason: '已经知道跑不起来，不该再闪一次绿灯');
      expect(systemCalls, ['isAvailable', 'recognize']);
      expect(ctrl.text, '第二次点击的结果');
    });

    testWidgets('降级后系统界面也起不来：弹错误框，不静默', (tester) async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isAvailable') return true;
        throw PlatformException(code: 'START_FAILED');
      });
      final voice = AlreadyBrokenVoiceInputService();
      final ctrl = TextEditingController();

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder:
                (context) => ElevatedButton(
                  onPressed:
                      () => toggleVoiceInput(
                        context,
                        voice,
                        ctrl,
                        systemInput: SystemSpeechInput(
                          channel: channel,
                          isAndroid: () => true,
                        ),
                      ),
                  child: const Text('mic'),
                ),
          ),
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: '两条路都断了也必须说出来——这台设备没有语音输入',
      );
      expect(ctrl.text, isEmpty);
    });
  });
}
