// 代码块底部那一行动作按钮（复制 / 解释 / 收藏 / 执行）的可见性。
//
// 起因是 2026-09-09 的真机截图：模型把一段带 ✓ ○ 的中文计划用 ``` 围栏
// 输出，agent 面板照样在下面挂了「复制 收藏 执行」。点「执行」会把那段
// 中文原样送进终端 —— 因为是否显示按钮只看「有没有回调」，不看 language。
//
// agent 模式下命令由模型发起、走审批卡，这一行整体不该出现；直连模式没有
// 工具调用也没有审批，它是把命令送进终端的唯一入口，必须留着。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/code_block.dart';

Widget wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  const code = 'systemctl restart nginx';

  testWidgets('默认显示动作按钮 —— 直连模式靠它执行', (t) async {
    await t.pumpWidget(wrap(CodeBlock(
      code: code,
      onRun: (_) {},
      onSave: (_) {},
    )));

    expect(find.byType(PanelActionChip), findsNWidgets(3));
  });

  testWidgets('showActions=false 时整行消失，复制也不留', (t) async {
    // 复制一并去掉：消息级已经有复制按钮，代码块再挂一个是重复的。
    await t.pumpWidget(wrap(const CodeBlock(
      code: code,
      showActions: false,
    )));

    expect(find.byType(PanelActionChip), findsNothing);
  });

  testWidgets('showActions=false 时代码本身照常可读可选', (t) async {
    // 去掉的只是按钮，内容一个字都不能少。
    await t.pumpWidget(wrap(const CodeBlock(
      code: code,
      showActions: false,
    )));

    final txt = t.widget<SelectableText>(find.byType(SelectableText));
    expect(txt.data, code);
  });

  testWidgets('传了回调但 showActions=false 时仍然不显示', (t) async {
    // 防的是「以为传了回调就该有按钮」的直觉：判据是 showActions，
    // 回调只决定那一行里有哪几个。
    var ran = false;
    await t.pumpWidget(wrap(CodeBlock(
      code: code,
      showActions: false,
      onRun: (_) => ran = true,
    )));

    expect(find.byType(PanelActionChip), findsNothing);
    expect(ran, isFalse);
  });

  testWidgets('builder 把 showActions 传下去', (t) async {
    // CodeBlockBuilder 是 agent_view / message_bubble 实际用的入口，
    // 漏传的话上面几条都白测。
    final builder = CodeBlockBuilder(showActions: false);
    expect(builder.showActions, isFalse);
    expect(CodeBlockBuilder().showActions, isTrue);
  });
}
