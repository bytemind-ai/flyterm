import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/message_bubble.dart';
import 'package:flyterm/ui/ai/widgets/message_copy_button.dart';

/// 拦下 Clipboard.setData，把写进剪贴板的文本记下来。
///
/// 不能靠 `Clipboard.getData` 回读：测试环境里没有真的剪贴板，那个调用
/// 返回 null，断言会永远通过 —— 一个不会失败的测试比没有测试更糟。
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

Future<void> _pump(WidgetTester tester, AIMessage m,
    {bool isStreaming = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MessageBubble(message: m, isStreaming: isStreaming),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('助手消息复制的是原始 markdown，不是渲染后的纯文本', (tester) async {
    // 转发给同事时对面多半也在 markdown 环境里。丢掉围栏和列表记号等于
    // 让对方自己重排一遍。
    final copied = _captureClipboard();
    const raw = '先看 **磁盘**：\n\n```\ndf -h\n```';
    await _pump(tester, const AIMessage(role: 'assistant', content: raw));

    await tester.tap(find.byType(MessageCopyButton));
    await tester.pumpAndSettle();

    expect(copied, [raw]);
  });

  testWidgets('流式输出中不出现复制按钮', (tester) async {
    // 那时复制到的是半句话，而用户要的几乎总是完整回答。
    await _pump(
      tester,
      const AIMessage(role: 'assistant', content: '正在检查磁'),
      isStreaming: true,
    );

    expect(find.byType(MessageCopyButton), findsNothing);
  });

  testWidgets('定稿后复制按钮出现', (tester) async {
    await _pump(
      tester,
      const AIMessage(role: 'assistant', content: '磁盘还有 40% 空间。'),
    );

    expect(find.byType(MessageCopyButton), findsOneWidget);
  });

  testWidgets('用户消息复制 content，不复制 displayText', (tester) async {
    // displayText 是展示用的改写（比如把一大段终端上下文折成一句话）。
    // 复制出来粘回输入框应该得到原文，否则复制这个动作就是静默丢数据。
    final copied = _captureClipboard();
    await _pump(
      tester,
      const AIMessage(
        role: 'user',
        content: '这是完整原文，包含一大段终端上下文',
        displayText: '分析上面的报错',
      ),
    );

    // 屏幕上显示的是改写版本。
    expect(find.text('分析上面的报错'), findsOneWidget);

    await tester.tap(find.byType(MessageCopyButton));
    await tester.pumpAndSettle();

    expect(copied, ['这是完整原文，包含一大段终端上下文']);
  });

  testWidgets('点过之后图标变成对勾，并在 1.5 秒后复位', (tester) async {
    // 面板活在 showModalBottomSheet 里，SnackBar 会落到 sheet 底下被挡住。
    // 图标自己变才是唯一一定看得见的反馈。
    _captureClipboard();
    await _pump(
      tester,
      const AIMessage(role: 'assistant', content: '好了'),
    );

    expect(find.byIcon(Icons.copy), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);

    await tester.tap(find.byType(MessageCopyButton));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.byIcon(Icons.copy), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('复制完立刻关掉面板不该炸', (tester) async {
    // 1.5 秒的复位 timer 会在已经 unmount 的 State 上 setState。
    _captureClipboard();
    await _pump(
      tester,
      const AIMessage(role: 'assistant', content: '好了'),
    );
    await tester.tap(find.byType(MessageCopyButton));
    await tester.pump();

    // 把整棵树换掉 = 面板被关闭。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 1600));

    expect(tester.takeException(), isNull);
  });
}
