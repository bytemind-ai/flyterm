import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ui/ai/widgets/plan_checklist.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('渲染每一步', (t) async {
    await t.pumpWidget(_wrap(
      const PlanChecklist(steps: ['查 nginx 日志', '看 502 上游'], current: 0),
    ));
    expect(find.text('查 nginx 日志'), findsOneWidget);
    expect(find.text('看 502 上游'), findsOneWidget);
  });

  // 标记从 Material 图标换成了方框字符（2026-09-09，对齐桌面端 agent CLI
  // 的观感），断言跟着换成字符 —— 三态的语义没变。
  testWidgets('current 之前的步骤打勾，current 之后留空', (t) async {
    await t.pumpWidget(_wrap(
      const PlanChecklist(steps: ['a', 'b', 'c'], current: 1),
    ));
    expect(find.text('✓'), findsOneWidget); // a 已完成
    expect(find.text('▸'), findsOneWidget); // b 正在做
    expect(find.text('☐'), findsOneWidget); // c 未开始
  });

  testWidgets('正在做的那一步用主色加粗，与其余两态区分', (t) async {
    // 三态若只靠字符区分，色觉障碍或小字号下 ✓ 与 ☐ 很接近；「卡在第几步」
    // 是这张卡唯一要回答的问题，得有第二重编码。
    await t.pumpWidget(_wrap(
      const PlanChecklist(steps: ['a', 'b', 'c'], current: 1),
    ));
    final cur = t.widget<Text>(find.text('b'));
    expect(cur.style?.fontWeight, FontWeight.w600);

    final todo = t.widget<Text>(find.text('c'));
    expect(todo.style?.fontWeight, isNot(FontWeight.w600));
  });

  testWidgets('current 为 null 时全部留空', (t) async {
    await t.pumpWidget(_wrap(const PlanChecklist(steps: ['a', 'b'])));
    expect(find.text('✓'), findsNothing);
    expect(find.text('▸'), findsNothing);
    expect(find.text('☐'), findsNWidgets(2));
  });

  testWidgets('current 等于步骤数时全部打勾，没有「正在做」', (t) async {
    // 工具描述明确让模型收工时发 current == steps.length。钳到 length-1
    // 的话最后一步永远停在 ▸，一次排查结束了清单还在转。
    await t.pumpWidget(_wrap(
      const PlanChecklist(steps: ['a', 'b', 'c'], current: 3),
    ));
    expect(find.text('✓'), findsNWidgets(3));
    expect(find.text('▸'), findsNothing);
    expect(find.text('☐'), findsNothing);
  });

  testWidgets('完成的对号是主色，不是灰的', (t) async {
    // 真机上原来用的 ☑（U+2611）被 Android 的 emoji 字体接管，渲染成蓝底
    // 白勾的彩色字形，代码里设的 color 对它无效。换成 U+2713 后颜色才真的
    // 生效。这条断言守的是「颜色可控」这件事本身。
    // 三步而不是两步：current=1 时才同时存在「已完成 / 正在做 / 未开始」
    // 三态，少一步就没有 ☐ 可断言。
    await t.pumpWidget(_wrap(
      const PlanChecklist(steps: ['a', 'b', 'c'], current: 1),
    ));
    final ctx = t.element(find.byType(PlanChecklist));
    final primary = Theme.of(ctx).colorScheme.primary;

    expect(t.widget<Text>(find.text('✓')).style?.color, primary);
    expect(t.widget<Text>(find.text('▸')).style?.color, primary);
    expect(t.widget<Text>(find.text('☐')).style?.color, isNot(primary));
  });

  testWidgets('已完成的步骤带删除线', (t) async {
    await t.pumpWidget(_wrap(
      const PlanChecklist(steps: ['a', 'b'], current: 1),
    ));
    final done = t.widget<Text>(find.text('a'));
    expect(done.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('没有卡片外壳 —— 不占整块背景', (t) async {
    // 脱壳是这次改动的目的本身：清单每更新一次就多占一块屏幕，而屏幕要
    // 留给 AI 的结论。有人把 Container 加回来时这条会红。
    await t.pumpWidget(_wrap(
      const PlanChecklist(steps: ['a'], current: 0),
    ));
    expect(
      find.descendant(
        of: find.byType(PlanChecklist),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
  });

  testWidgets('空列表不渲染任何东西', (t) async {
    await t.pumpWidget(_wrap(const PlanChecklist(steps: [])));
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('超长步骤文字被截断，不溢出', (t) async {
    await t.pumpWidget(_wrap(PlanChecklist(steps: ['很长的步骤' * 60])));
    await t.pumpAndSettle();
    // 溢出会被 Flutter 记成一个异常，takeException 取得到就说明布局炸了
    expect(t.takeException(), isNull);
  });
}
