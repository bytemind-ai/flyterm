import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/ai/widgets/code_block.dart';

/// `aiProseStyle` 的回归护栏。
///
/// ## 为什么需要它
///
/// `MarkdownStyleSheet.fromTheme` 的默认值是给**浅色**主题设计的，其中
/// blockquote 的背景是硬编码的 `Colors.blue.shade100`（不看传进去的 theme），
/// 分隔线是 5px 粗线，表格字号比正文大一圈。
///
/// 这类漏洞的共同特征是：**不编译报错、不让任何既有测试变红**，只在模型
/// 恰好输出那种 markdown 元素时才暴露在用户屏幕上。项目已经踩过两次
/// （2026-09-08 的 `##` 标题、2026-09-13 的 blockquote），两次都是靠真机
/// 截图发现的。
///
/// 所以这里逐项钉住已知的四类。**它拦不住「将来新增的第五类」** —— 那种
/// 只能靠截图，但至少这四类不会回退。
void main() {
  late MarkdownStyleSheet ss;

  setUp(() {
    ss = _dummy;
  });

  Future<void> build(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(builder: (ctx) {
        ss = aiProseStyle(ctx);
        return const SizedBox.shrink();
      }),
    ));
  }

  testWidgets('blockquote 背景不是 flutter_markdown 硬编码的浅蓝', (tester) async {
    await build(tester);
    final bg = (ss.blockquoteDecoration as BoxDecoration).color!;

    expect(bg, isNot(Colors.blue.shade100),
        reason: '这正是 2026-09-13 真机截图里白字印在浅蓝底上的那个默认值');

    // **必须先做 alpha 合成再量亮度。** `computeLuminance()` 不看 alpha ——
    // 直接量 `Colors.white.withValues(alpha: 0.05)` 会得到 1.0，把一个正确
    // 的叠加色误判成刺眼的白底。真正要回答的问题是「它铺在深色面板上之后
    // 是什么颜色」。
    final onPanel = Color.alphaBlend(bg, const Color(0xFF121212));
    expect(onPanel.computeLuminance(), lessThan(0.3),
        reason: '深色面板上的块背景必须是暗的，否则白字读不出来');
  });

  testWidgets('blockquote 文字与正文同字号', (tester) async {
    await build(tester);
    expect(ss.blockquote!.fontSize, ss.p!.fontSize);
  });

  testWidgets('表格文字与正文同字号', (tester) async {
    // 模型输出表格是常态（它在对比几个选项）。字号不一致会让表格前后的
    // 排版跳一下。
    await build(tester);
    expect(ss.tableBody!.fontSize, ss.p!.fontSize);
    expect(ss.tableHead!.fontSize, ss.p!.fontSize);
  });

  testWidgets('分隔线不超过 1px —— 默认的 5px 比正文还重', (tester) async {
    await build(tester);
    final hr = ss.horizontalRuleDecoration as BoxDecoration;
    expect(hr.border!.top.width, lessThanOrEqualTo(1.0));
  });

  testWidgets('表格内边距适配窄屏 —— 默认 16px 左右各吃掉一截', (tester) async {
    await build(tester);
    expect(ss.tableCellsPadding!.horizontal, lessThanOrEqualTo(20));
  });
}

/// `setUp` 里给 `ss` 一个非空初值，免得 `late` 在某条测试跳过时炸。
final MarkdownStyleSheet _dummy = MarkdownStyleSheet();
