import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `PanelHeader` 的溢出菜单交互助手。
///
/// ## 这个菜单现在装什么（2026-10 二次 IA 改动后）
///
/// 「分析错误 / 会话总结」两个**直连模式**专有项。它们没有替代路径，所以
/// 只能留在菜单里。而「历史会话」已经从菜单挪回头部裸图标，「导出」则
/// 彻底移出头部（只留在历史列表每行）—— agent 模式下这个菜单里一项都不剩，
/// 整个 `more_vert` 按钮都不会渲染，所以针对 agent 模式的测试不能再用这些
/// 助手方法。
///
/// 菜单项带**文字**（见 `panel_chrome.dart` 里 `_MenuRow` 的文档）：纯图标
/// 在手机上得长按才看得到 tooltip，用户点一下什么都不会发生，与「App 坏了」
/// 无法区分。
extension PanelHeaderMenu on WidgetTester {
  /// 打开头部溢出菜单。
  Future<void> openPanelMenu() async {
    await tap(find.byIcon(Icons.more_vert));
    await pumpAndSettle();
  }

  /// 打开菜单并点选其中一项（按图标定位）。
  Future<void> tapPanelMenuItem(IconData icon) async {
    await openPanelMenu();
    await tap(find.byIcon(icon).last);
    await pumpAndSettle();
  }
}

/// 溢出菜单里是否包含某个操作（**不打开菜单**，只看菜单本身是否存在）。
///
/// 只适用于直连模式（菜单存在的情况）。agent 模式根本没有 `more_vert`，
/// 调它会因为找不到按钮而超时。
Future<bool> panelMenuContains(WidgetTester t, IconData icon) async {
  await t.openPanelMenu();
  final found = find.byIcon(icon).evaluate().isNotEmpty;
  // 关掉菜单，避免影响后续断言。
  await t.tapAt(const Offset(5, 5));
  await t.pumpAndSettle();
  return found;
}
