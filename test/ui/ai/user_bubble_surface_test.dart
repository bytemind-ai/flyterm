import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/message_bubble.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';
import 'package:flyterm/ai/ai_engine.dart';

/// 用户消息气泡必须与面板底色**可辨识地不同**。
///
/// ## 这条测试拦的是什么
///
/// 2026-xx 用户反馈「输入内容的背景色与面板背景色相近」。根因不是没设颜色，
/// 而是设错了颜色：气泡用 `colorScheme.primaryContainer`，而本主题把它显式
/// 映射成 `FlyColors.panelElevated`（见 `buildFlyTermTheme`），AI 面板自身的
/// `surfaceContainerHighest` **也是** `panelElevated` —— 两者色值一模一样，
/// 气泡等于画在和自己同色的背景上，边界只剩那个圆角。
///
/// 所以这里断言的是**关系**而不是某个具体色值：不管将来把气泡换成品红还是
/// 换回某个灰，只要它和面板同色就会被拦下。断言具体色值做不到这件事 —— 那
/// 只是把当前的 bug 值复制进测试。
///
/// 同时要求描边存在：填充负责「拉开亮度差」，描边负责「给出精确边界」，是
/// 一对（见 `FlyColors.userBubbleFill` 的文档）。只有填充时，气泡在深色面板
/// 上仍然偏软。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );

  BoxDecoration bubbleDecoration(WidgetTester t) {
    final container = t.widget<Container>(
      find
          .ancestor(
            of: find.byType(SelectableText),
            matching: find.byType(Container),
          )
          .first,
    );
    return container.decoration! as BoxDecoration;
  }

  testWidgets('用户气泡的填充不等于面板底色', (t) async {
    await t.pumpWidget(
      wrap(
        MessageBubble(
          message: AIMessage(role: 'user', content: '看一下 nginx 日志'),
        ),
      ),
    );

    final deco = bubbleDecoration(t);

    // 主题里面板底与 primaryContainer 是同一个值 —— 这条断言就是当时的
    // bug。写成「不等于 panelElevated」，而不是「等于某个新色值」。
    expect(
      deco.color,
      isNot(FlyColors.panelElevated),
      reason: '气泡与面板同色则边界消失，回到 2026-xx 那个 bug',
    );
    expect(deco.color, FlyColors.userBubbleFill);
  });

  testWidgets('用户气泡带可见描边', (t) async {
    await t.pumpWidget(
      wrap(
        MessageBubble(
          message: AIMessage(role: 'user', content: '看一下 nginx 日志'),
        ),
      ),
    );

    final deco = bubbleDecoration(t);
    final border = deco.border as Border?;

    expect(border, isNotNull, reason: '只有填充时气泡在深底上偏软');
    expect(border!.top.color, FlyColors.userBubbleBorder);
    expect(border.top.width, kHairline);
  });

  testWidgets('气泡填充本身必须真的可见（alpha 不能是 0）', (t) async {
    // 防的是「有人把 alpha 手滑改成 0，另两条断言照样通过」——那时填充全透明，
    // 描边还在，视觉上等于一个空心框。
    expect(FlyColors.userBubbleFill.a, greaterThan(0.05));
    expect(
      FlyColors.userBubbleBorder.a,
      greaterThan(FlyColors.userBubbleFill.a),
    );
  });
}
