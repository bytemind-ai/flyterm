// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/agent/error_location.dart';
import '../../ai/system_speech_input.dart';
import '../../ai/voice_diagnostics.dart';
import '../../ai/voice_input_service.dart';
import '../../l10n/l10n.dart';

/// Named stages of [toggleVoiceInput], recorded in a local variable so a
/// caught exception can say *where* it happened, not just what it was.
///
/// Values are kept as plain strings (not an enum) because they're only ever
/// interpolated into a diagnostic message, never branched on.
class _VoiceStage {
  static const cancel = 'cancelListening';
  static const systemProbe = 'systemProbe';
  static const systemRecognize = 'systemRecognize';
  static const prepare = 'prepare';
  static const startListening = 'startListening';
}

/// Shared mic-tap handler for `AgentView` and `DirectChatView` (previously
/// duplicated verbatim in both `_toggleVoice` methods).
///
/// Guarantees that tapping the mic always produces *some* perceivable
/// feedback: either the mic starts listening, or the user sees a dialog
/// explaining why not. Before this, `startListening` failing internally
/// (see below) left the mic icon flashing back to its idle state with
/// nothing else — indistinguishable from "nothing happened".
///
/// `VoiceInputService.startListening` can fail in a way its callers must
/// check for explicitly: it sets `_isListening = true` optimistically
/// *before* invoking the underlying `SpeechToText.listen()`, then resets it
/// to `false` (and sets `lastError` / flips `isAvailable` false) only if
/// that call throws. So `voice.isListening == false` right after this
/// function's `await` completed is a reliable signal that the start
/// attempt failed — `voice.issue` will already be populated with the real
/// reason, which `showVoiceInputPrompt` renders.
///
/// ## The remaining silent-failure trap: uncaught exceptions
///
/// This function is invoked as `onTap: enabled ? onMicTap : null` where
/// `onMicTap` is `() => toggleVoiceInput(...)` — i.e. Dart calls an `async`
/// function through a `VoidCallback` and never awaits the returned Future.
/// Any exception that escapes this function therefore becomes an *unhandled
/// async error*: it reaches the zone's uncaught-error handler, gets printed
/// to the console, and nothing appears on screen. That is a structural trap
/// independent of whatever bug actually threw — hence the blanket try/catch
/// below rather than fixing call sites one at a time.
///
/// Concretely, [VoiceInputService.ensurePermissions] calls
/// `Permission.microphone.request()` (and, on iOS, `Permission.speech
/// .request()`) with no try/catch of its own. Both can throw
/// (`MissingPluginException` if plugin registration didn't happen for some
/// reason on a given device/build, `PlatformException` for OEM permission
/// quirks) and that exception would propagate straight out of `prepare()`
/// through this function — with nothing wrapping it, "tapped the mic, saw
/// nothing" is exactly what a real user would observe. See
/// [showVoiceInputError] for how the catch below turns that into something
/// visible.
///
/// ## Path order: in-app recording first, system UI only as a last resort
///
/// The `speech_to_text` in-app path is primary, because the required
/// interaction is *inline*: the mic button turns active in place, the input
/// hint switches to "listening", and everything returns to normal when the
/// user stops talking — without ever leaving the current screen.
///
/// [SystemSpeechInput] (the system `ACTION_RECOGNIZE_SPEECH` UI) covers
/// only the case where in-app recording is entirely unavailable — no
/// bindable `RecognitionService` on the device. There the choice isn't
/// "inline or full-screen", it's "full-screen or no voice input at all", so
/// it stays. It was briefly promoted to the primary path and has been moved
/// back: taking over the whole screen on every tap is not the wanted
/// behaviour.
///
/// That ordering puts the layer that *can* fail silently in front, so its
/// safety nets all have to stay: synchronous failure via the post-await
/// `!voice.isListening` check, asynchronous failure via the `onFailure`
/// callback (the platform can accept the start, return normally, and report
/// the problem hundreds of milliseconds later — long after this function
/// returned), and a hung `listen()` via the watchdog in
/// [VoiceInputService.startListening].
Future<void> toggleVoiceInput(
  BuildContext context,
  VoiceInputService voice,
  TextEditingController controller, {
  SystemSpeechInput? systemInput,
}) => toggleVoiceInputWith(context, voice, (text) {
  controller.text = text;
  controller.selection = TextSelection.collapsed(offset: text.length);
}, systemInput: systemInput);

/// [toggleVoiceInput] with the destination generalized from a text field
/// to an arbitrary sink.
///
/// The keybar mic writes recognized text straight into the terminal
/// (`tab.terminal.onOutput`) rather than into a controller. It used to
/// carry its own hand-rolled copy of this flow in `terminal_screen.dart`,
/// which is how it ended up missing every one of the safety nets added
/// here — no try/catch, no post-await check, no system fallback, and no
/// asynchronous-failure callback. Routing it through this function is what
/// keeps the two entry points from drifting apart again.
Future<void> toggleVoiceInputWith(
  BuildContext context,
  VoiceInputService voice,
  void Function(String text) onText, {
  SystemSpeechInput? systemInput,
}) async {
  final system = systemInput ?? SystemSpeechInput();
  var stage = 'idle';

  // ── 静默出口兜底 ────────────────────────────────────────────────
  //
  // 这个函数有过多次"某条分支什么都不做就 return"的历史，每堵上一条又
  // 冒出另一条，用户侧看到的始终是同一个"点了没反应"。与其继续一条条
  // 猜，不如反过来定义：**每次点击都必须产生某种可感知的结果**，凡是
  // 走到头还什么都没发生的，一律弹诊断框把走过的路径摊开。
  //
  // 好处是它不依赖"猜对了是哪条分支"——现有的、以及将来新增的静默
  // return，都会自己撞上这张网。
  final trail = <String>[];
  var producedFeedback = false;

  /// 本次会话的失败是否已由 `onFailure` 回调处理过。见下方使用处。
  var failureReported = false;
  void mark(String step) {
    trail.add(step);
    VoiceDiagnostics.instance.log('ui', step);
  }

  VoiceDiagnostics.instance.beginTap();

  try {
    mark(
      'entry isListening=${voice.isListening} '
      'isAvailable=${voice.isAvailable} lastError=${voice.lastError} '
      'lastStatus=${voice.lastStatus}',
    );

    if (voice.isListening) {
      stage = _VoiceStage.cancel;
      await voice.cancelListening();
      // 停掉录音本身就是看得见的结果（图标从"正在听"回到普通态）。
      producedFeedback = true;
      return;
    }

    // ── 主路径：应用内录音（speech_to_text）────────────────────────
    //
    // 交互形态是明确要求的：麦克风原地转成激活态、输入框提示"正在听"、
    // 说完自动恢复，全程不离开当前界面。系统语音界面那条路会盖住整屏，
    // 一度被提到主路径上，已按要求撤回到兜底位置。
    //
    // 这条路径能失败得毫无声响（那是"点了没反应"的来源），所以它的安全网
    // 一个都不能少：同步失败靠下面的 !isListening 检查，异步失败靠
    // onFailure，卡死靠 VoiceInputService 里的 watchdog。
    stage = _VoiceStage.prepare;
    await voice.prepare();
    mark(
      'prepared isAvailable=${voice.isAvailable} '
      'lastError=${voice.lastError} broken=${voice.inAppPathBroken}',
    );
    if (!context.mounted) return;

    // `isAvailable && inAppPathBroken` is a real combination, and it used to
    // be a dead end: `initialize()` succeeds on these devices, so this branch
    // was taken every time, the session died in ~2 ms, and the system-UI
    // fallback below was unreachable code. See
    // `VoiceInputService.inAppPathBroken`.
    if (voice.isAvailable && !voice.inAppPathBroken) {
      stage = _VoiceStage.startListening;
      await voice.startListening(
        onResult: (words) {
          if (words.isNotEmpty) {
            onText(words);
            // 填入输入框供用户审阅，不自动发送。
          }
        },
        // 异步失败（平台已接受启动、几百毫秒后才经 onError / 空结束到达）
        // 唯一的出口。此时本函数早已返回，只能靠这个回调把原因显示出来。
        onFailure: (_) async {
          failureReported = true;
          if (!context.mounted) return;
          // 刚刚这一下就是"启动即死"——应用内录音在这台设备上自证跑不起来。
          // 不要求用户再点一次：他要的是语音输入，当场落到系统语音界面给他。
          // 之后的每次点击会在上面的分支直接跳过应用内路径，不再有这次闪绿。
          if (voice.inAppPathBroken) {
            mark('in-app demoted mid-tap -> system UI');
            await _runSystemPath(context, system, onText, voice, mark);
            return;
          }
          await showVoiceInputPrompt(context, voice);
        },
      );
      mark(
        'startListening -> isListening=${voice.isListening} '
        'isAvailable=${voice.isAvailable} lastError=${voice.lastError}',
      );
      if (!context.mounted) return;
      if (voice.isListening) {
        // 真的开始录音了——麦克风转为激活态、hint 变成"正在听"，这就是
        // 要的那个效果，反馈本身已经产生。
        producedFeedback = true;
        return;
      }
      // onFailure 已经处理过这次失败了（平台错误在 `await listen()` 返回
      // **之前**就到达的情况）。真机上观测到的顺序是错误后到，所以这里通常
      // 是 false；但那个顺序是平台决定的，不能靠它。少了这道判断，同一次
      // 失败会弹两个框——一个来自回调，一个来自下面。
      if (failureReported) {
        producedFeedback = true;
        return;
      }
      // 同步启动失败：startListening 内部捕获到异常后已经把状态复位了
      // （isAvailable=false / lastError 已设置）。把原因显示给用户，否则
      // 用户只会看到麦克风图标闪一下就跳回普通态，以为自己没点中。
      await showVoiceInputPrompt(context, voice);
      producedFeedback = true;
      return;
    }

    // ── 兜底：系统语音界面 ──────────────────────────────────────────
    //
    // 两种情况会走到这里：设备没有可绑定的 RecognitionService（isAvailable
    // 为 false），或者有但跑不起来（inAppPathBroken）。这时的选择不是
    // "内联还是全屏"，而是"全屏还是压根没有语音输入"，所以这条路留着。
    //
    // 注意这**不是**把系统界面提成主路径（那个版本已按要求撤回）：能用应用
    // 内录音的设备永远不会走到这儿。只有在应用内录音自证不可用之后才降级，
    // 那种设备上全屏是唯一的选项。
    stage = _VoiceStage.systemProbe;
    await _runSystemPath(context, system, onText, voice, mark);
    producedFeedback = true;
  } catch (error, stack) {
    if (!context.mounted) return;
    producedFeedback = true;
    await showVoiceInputError(
      context,
      stage: stage,
      error: error,
      stack: stack,
    );
  } finally {
    if (!producedFeedback && context.mounted) {
      mark('exit stage=$stage');
      await showVoiceSilentExitDiagnostic(context, voice, trail);
    }
  }
}

/// Runs the system speech UI and delivers whatever it produces.
///
/// **Never throws.** That is the whole reason it is a function rather than
/// inline code: one of its two call sites is inside
/// `VoiceInputService.startListening`'s `onFailure` callback, which the
/// service invokes as `onFailure?.call(issue)` — not awaited. An exception
/// escaping there would become an unhandled async error and put nothing on
/// screen, which is the exact failure shape this file exists to eliminate. So
/// it swallows nothing and shows everything, itself.
Future<void> _runSystemPath(
  BuildContext context,
  SystemSpeechInput system,
  void Function(String text) onText,
  VoiceInputService voice,
  void Function(String) mark,
) async {
  var stage = _VoiceStage.systemProbe;
  try {
    final systemAvailable = await system.isAvailable();
    mark('systemAvailable=$systemAvailable');
    if (!context.mounted) return;
    if (!systemAvailable) {
      // No bound recognizer *and* no speech activity — the device has no
      // voice input to offer. The recognizer-unavailable copy already points
      // at the remaining option (the keyboard's own mic key).
      await showVoiceInputPrompt(context, voice);
      return;
    }

    stage = _VoiceStage.systemRecognize;
    final text = await system.recognize();
    mark('systemRecognize=${text == null ? "null" : "${text.length} chars"}');
    if (!context.mounted) return;
    if (text != null && text.isNotEmpty) onText(text);
    // null 表示用户看到了系统语音界面又自己取消了——界面本身就是反馈，
    // 不该再弹框。真正启动不起来的情况会抛 SystemSpeechStartFailure，
    // 由下面的 catch 显示出来，不和"用户取消"混为一谈。
  } catch (error, stack) {
    if (!context.mounted) return;
    await showVoiceInputError(
      context,
      stage: stage,
      error: error,
      stack: stack,
    );
  }
}

/// 兜底诊断框：这次点击走完了全程，却没有产生任何可感知的结果。
///
/// 正常情况下永远看不到它——能看到就说明命中了一条静默路径，框里的
/// trail 就是定位它所需的全部信息（每一步的分支取值 + 服务状态快照）。
Future<void> showVoiceSilentExitDiagnostic(
  BuildContext context,
  VoiceInputService voice,
  List<String> trail,
) async {
  final l = context.l10n;
  final services = voice.recognitionServices;
  final report = [
    ...trail,
    '--',
    'issue=${voice.issue.name}',
    'isAvailable=${voice.isAvailable}',
    'isListening=${voice.isListening}',
    'lastError=${voice.lastError}',
    'lastStatus=${voice.lastStatus}',
    'engineTier=${voice.engineTier.name}',
    // 设备上装了哪些 RecognitionService，是"语音为什么不工作"最有用的
    // 一条事实，而它平时只出现在 logcat 里——能复现的机器往往没连电脑。
    'services=${services.isEmpty ? "(not probed / none)" : services.join(", ")}',
  ].join('\n');

  await showDialog<void>(
    context: context,
    builder:
        (dialogContext) => AlertDialog(
          title: Text(l.voiceErrorTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.voiceErrorHint),
                const SizedBox(height: 8),
                SelectableText(
                  report,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            const _CopyDiagnosticsButton(),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l.close),
            ),
          ],
        ),
  );
}

/// Renders an exception escaping [toggleVoiceInput] as a dialog carrying
/// enough diagnostic detail (exception type, message, which stage of the
/// toggle flow it happened in, and — when available — the first
/// `package:flyterm/...` stack frame via [describeError]) that a user can
/// select-copy it and hand it back for troubleshooting. This is the last
/// line of defense against the silent-failure trap documented on
/// [toggleVoiceInput]: an exception reaching here is, by construction, one
/// that would otherwise never have surfaced anywhere visible.
Future<void> showVoiceInputError(
  BuildContext context, {
  required String stage,
  required Object error,
  StackTrace? stack,
}) async {
  final l = context.l10n;
  final diagnostic = describeError(
    '${error.runtimeType}: $error\nstage: $stage',
    stack,
  );

  await showDialog<void>(
    context: context,
    builder:
        (dialogContext) => AlertDialog(
          title: Text(l.voiceErrorTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.voiceErrorHint),
                const SizedBox(height: 8),
                SelectableText(
                  diagnostic,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            const _CopyDiagnosticsButton(),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l.close),
            ),
          ],
        ),
  );
}

/// Copies the whole [VoiceDiagnostics] buffer to the clipboard.
///
/// The dialogs already show a snapshot of *this* tap, but the interesting
/// cases span several taps (first one behaves differently from the rest) and
/// cross layer boundaries. This hands over the full trace in a form that can
/// be pasted into a bug report — the device that reproduces this is usually
/// not the one attached to a computer running `logcat`.
class _CopyDiagnosticsButton extends StatefulWidget {
  const _CopyDiagnosticsButton();

  @override
  State<_CopyDiagnosticsButton> createState() => _CopyDiagnosticsButtonState();
}

class _CopyDiagnosticsButtonState extends State<_CopyDiagnosticsButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        await Clipboard.setData(
          ClipboardData(text: VoiceDiagnostics.instance.dump()),
        );
        if (!mounted) return;
        // 就地把按钮文案换成"已复制"，不弹 SnackBar——对话框还开着，
        // SnackBar 会被它盖住，用户根本看不到。
        setState(() => _copied = true);
      },
      child: Text(
        _copied
            ? context.l10n.voiceDiagnosticsCopied
            : context.l10n.voiceCopyDiagnostics,
      ),
    );
  }
}

Future<void> showVoiceInputPrompt(
  BuildContext context,
  VoiceInputService voice,
) async {
  final l = context.l10n;
  // 走到这个框说明内联那条路已经全试完了。把设备实际提供的识别服务补进
  // 诊断行——"没有可用服务"和"有服务但都跑不起来"要采取的下一步完全不同，
  // 而症状是一样的。
  final services = voice.recognitionServices;
  final issue = voice.issue;
  final needsSettings =
      issue == VoiceInputIssue.microphonePermissionDenied ||
      issue == VoiceInputIssue.speechPermissionDenied;
  final content = switch (issue) {
    VoiceInputIssue.microphonePermissionDenied =>
      l.voiceMicrophonePermissionContent,
    VoiceInputIssue.speechPermissionDenied => l.voiceSpeechPermissionContent,
    VoiceInputIssue.recognizerUnavailable =>
      l.voiceRecognizerUnavailableContent,
    VoiceInputIssue.microphoneMutedOrNoSpeech => l.voiceNoSpeechContent,
    VoiceInputIssue.busy => l.voiceBusyContent,
    VoiceInputIssue.network => l.voiceNetworkContent,
    VoiceInputIssue.none || VoiceInputIssue.unknown => l.voiceUnknownContent,
  };

  // 分类文案是把一堆平台错误码归拢成几句人话的结果，归拢过程本身可能
  // 归错（`error_client` 这类笼统码尤其容易）。把原始错误码原样附在下面：
  // 用户能直接把它读/复制出来，排查时不必再靠症状反推是哪条分支。
  final rawError = [
    if (voice.lastError != null && voice.lastError!.isNotEmpty) voice.lastError!,
    'tier=${voice.engineTier.name}',
    if (services.isNotEmpty) 'services: ${services.join(", ")}',
  ].join('\n');

  await showDialog<void>(
    context: context,
    builder:
        (dialogContext) => AlertDialog(
          title: Text(l.voicePermissionTitle),
          // Scrollable, like the other two voice dialogs already are. The
          // explanatory copy is short, but `rawError` is whatever the platform
          // handed us — an exception `toString()` runs to several lines and
          // overflowed the bare Column, silently clipping the very text this
          // block exists to show.
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(content),
                if (rawError.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    rawError,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: Theme.of(dialogContext).hintColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            const _CopyDiagnosticsButton(),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l.voiceLater),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                if (needsSettings) {
                  await voice.openSettings();
                } else {
                  await voice.prepare();
                }
              },
              child: Text(needsSettings ? l.voiceOpenSettings : l.voiceRetry),
            ),
          ],
        ),
  );
}
