// agent 模式的消息复制按钮。
//
// 先前只测了 direct 模式的 MessageBubble —— 而复制按钮是分别接进两套渲染的
// （agent 走 AgentView._buildEvent 的 UserTurnEvent / AssistantTextEvent
// 分支，direct 走 MessageBubble）。只测一套等于另一套没测，而 agent 那套
// 出错的后果比「复制不工作」大得多：它在 build 里，抛出来是整个面板白屏。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/widgets/message_copy_button.dart';

import '../../ai/agent/_fakes.dart';

class _FakeVoiceInputService extends VoiceInputService {
  @override
  bool get isListening => false;
  @override
  bool get isKnownUnavailable => true;
}

List<String> _captureClipboard() {
  final copied = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  return copied;
}

// `await loop.send(...)` 必须包在 [WidgetTester.runAsync] 里。
//
// testWidgets 默认跑在虚拟时钟上，而 FakeRunner 内部是真实的
// `Future.delayed(1ms)`（它刻意如此 —— 真实执行要跨一次网络往返，必然落到
// macrotask）。虚拟时钟不会推进它，于是 send 的 Future 永不完成：测试挂死
// 两分钟然后被超时杀掉，而不是给一条断言失败。
void main() {
  Future<void> pump(WidgetTester tester, dynamic loop) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangeNotifierProvider<VoiceInputService>(
          create: (_) => _FakeVoiceInputService(),
          child: Scaffold(
            body: AgentView(loop: loop, providerName: 'fake'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('一问一答之后，两条消息各有一个复制按钮', (tester) async {
    final loop = makeLoop(
      provider: FakeProvider([const AIResponse(text: 'nginx 挂了，已重启')]),
    );
    await tester.runAsync(() => loop.send('为什么 502'));
    await pump(tester, loop);

    // 用户那条 + 助手那条 = 2 个。少于 2 说明有一个分支没接上。
    expect(find.byType(MessageCopyButton), findsNWidgets(2));
  });

  testWidgets('复制助手回答拿到的是原始 markdown', (tester) async {
    final copied = _captureClipboard();
    const raw = '先看 **磁盘**：\n\n```\ndf -h\n```';
    final loop = makeLoop(provider: FakeProvider([const AIResponse(text: raw)]));
    await tester.runAsync(() => loop.send('查一下'));
    await pump(tester, loop);

    // 两个按钮，后一个是助手那条（事件按时间顺序渲染）。
    await tester.tap(find.byType(MessageCopyButton).last);
    await tester.pumpAndSettle();

    expect(copied, [raw]);
  });

  testWidgets('复制自己发的那条', (tester) async {
    final copied = _captureClipboard();
    final loop = makeLoop(
      provider: FakeProvider([const AIResponse(text: '好')]),
    );
    await tester.runAsync(() => loop.send('把 nginx 的 access log 最后 50 行发我看看'));
    await pump(tester, loop);

    await tester.tap(find.byType(MessageCopyButton).first);
    await tester.pumpAndSettle();

    expect(copied, ['把 nginx 的 access log 最后 50 行发我看看']);
  });

  testWidgets('带工具调用的一轮也能正常渲染 —— 不因加了按钮而白屏', (tester) async {
    // 这一条守的是 build 不抛。UserTurnEvent 分支从 Align 改成了 Column，
    // AssistantTextEvent 从 MarkdownBody 改成 Column 包一层 —— 两处都动了
    // 布局结构，而工具卡混在中间是最常见的真实排布。
    final loop = makeLoop(
      provider: FakeProvider([
        bashCall('c1', 'systemctl status nginx'),
        const AIResponse(text: '服务是 active 的'),
      ]),
      mode: PermissionMode.bypass,
    );
    await tester.runAsync(() => loop.send('nginx 还活着吗'));
    await pump(tester, loop);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('active'), findsWidgets);
    // 用户那条 + 助手那条；工具卡不该有复制按钮（那是命令输出，不是消息）。
    expect(find.byType(MessageCopyButton), findsNWidgets(2));
  });
}
