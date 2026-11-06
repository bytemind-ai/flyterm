import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';
import 'package:flyterm/ui/shell/app_shell.dart';

/// 底部 tab 导航栏的**选中态辨识度**。
///
/// ## 出问题的现状（可量化）
///
/// 改造前，选中与未选中的差别**只有颜色一个维度**：
///   - 未选中：`onSurface @ 45%` 叠在 `#0D0F12` 底上 → 实际 `#676869`
///   - 选中：mint `#00C896`
///
/// 实测对比度：
///   - 两者之间只有 **2.58:1** —— 低于 WCAG 对图标要求的 3:1
///   - 未选中 vs 底色 3.44:1 —— 刚过线，偏暗
///
/// 所以问题不是「颜色不好看」，是**单靠颜色分不开**，手机强光下尤其明显。
///
/// 这条测试守两件事：
///   1. 色差达到可辨阈值（数值）
///   2. **除颜色外还有第二个维度** —— 对色觉障碍用户，色差再大也只有一个
///      维度可用，必须有形态标记
void main() {
  /// sRGB 相对亮度（WCAG 2.x 定义）。
  double lum(Color c) {
    double f(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  }

  double contrast(Color a, Color b) {
    final la = lum(a), lb = lum(b);
    final hi = math.max(la, lb), lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 把前景色按 alpha 叠在背景色上，得到实际显示色。
  Color blend(Color fg, double alpha, Color bg) => Color.from(
    alpha: 1,
    red: fg.r * alpha + bg.r * (1 - alpha),
    green: fg.g * alpha + bg.g * (1 - alpha),
    blue: fg.b * alpha + bg.b * (1 - alpha),
  );

  Widget harness(int selected) => MaterialApp(
    home: Scaffold(
      bottomNavigationBar: ShellNavBar(
        selectedIndex: selected,
        onSelected: (_) {},
        items: const [
          ShellNavItem(icon: Icons.adb, activeIcon: Icons.adb, label: 'ONE'),
          ShellNavItem(
            icon: Icons.ac_unit,
            activeIcon: Icons.ac_unit,
            label: 'TWO',
          ),
          ShellNavItem(icon: Icons.abc, activeIcon: Icons.abc, label: 'THREE'),
        ],
      ),
    ),
  );

  group('对比度（数值）', () {
    test('未选中态本身不得过暗 —— 图标要看得见', () {
      const bg = FlyColors.background;
      final idle = blend(FlyColors.textPrimary, kNavIdleOpacity, bg);
      final c = contrast(idle, bg);
      expect(
        c,
        greaterThanOrEqualTo(3.0),
        reason:
            '未选中图标与底色只有 ${c.toStringAsFixed(2)}:1，'
            '低于图标最低可辨线 3:1',
      );
    });

    // 下面这条是本次改造里**最重要的一条认识**，写成测试防止将来有人
    // 「把未选中调亮一点，让对比度更好」时把选中态推进坑里。
    //
    // 实测：未选中亮度提高 → 两个颜色在中同靠近 → 「选中 vs 未选中」
    // 的对比度**反而变小**。所以这个数字天然达不到 3:1，**不是调参能修的** ——
    // 它证明了「单靠颜色区分选择态」这条路本身走不通。
    //
    // 因此这里不断言「色差 ≥ 3」而是断言「存在且不至于消失」，真正的
    // 区分力由形态维度（指示条 + 字重）承担，见下一个 group。
    test('选中与未选中的色差存在，但不指望它单独支撑区分', () {
      const bg = FlyColors.background;
      final idle = blend(FlyColors.textPrimary, kNavIdleOpacity, bg);
      final active = FlyColors.active;
      final c = contrast(idle, active);

      // 只要还能看出「这是两个不同的颜色」就行，不要求 3:1 ——
      // 否则只能把未选中压到很暗，那会让图标本身看不见（见上一条）。
      expect(
        c,
        greaterThanOrEqualTo(1.8),
        reason:
            '选中与未选中只差 ${c.toStringAsFixed(2)}:1，'
            '连「颜色不同」都看不出来了',
      );

      // 同时守住上限方向的反面：未选中不得过暗（上一条已测），
      // 也不得亮到和 mint 混同。
      expect(
        c,
        lessThan(6.0),
        reason:
            '色差 ${c.toStringAsFixed(2)}:1 异常 —— '
            '未选中是不是被改成了接近 mint 的颜色？',
      );
    });
  });

  group('形态维度（色觉障碍用户也要能分）', () {
    testWidgets('选中态必须带指示条', (t) async {
      await t.pumpWidget(harness(1));
      expect(
        find.byKey(const Key('shellNav.activeIndicator')),
        findsOneWidget,
        reason: '选中态没有形态标记 —— 色觉障碍用户无法区分当前 tab',
      );
    });

    testWidgets('指示条只画一个，且挂在被选中的那格', (t) async {
      await t.pumpWidget(harness(2));
      expect(find.byKey(const Key('shellNav.activeIndicator')), findsOneWidget);

      // 指示条必须落在第三格（选中项）的水平范围内。
      final ind = t.getRect(find.byKey(const Key('shellNav.activeIndicator')));
      final bar = t.getRect(find.byType(ShellNavBar));
      final third = bar.width / 3;
      expect(
        ind.center.dx,
        greaterThan(bar.left + third * 2 - 1),
        reason: '指示条不在第三格 —— selectedIndex=2 却画在别处',
      );
    });

    testWidgets('切换选中项时指示条跟着移动', (t) async {
      await t.pumpWidget(harness(0));
      final a = t.getRect(find.byKey(const Key('shellNav.activeIndicator')));
      await t.pumpWidget(harness(2));
      final b = t.getRect(find.byKey(const Key('shellNav.activeIndicator')));
      expect(
        b.center.dx,
        greaterThan(a.center.dx + 50),
        reason: '换 tab 后指示条没动',
      );
    });
  });
}
