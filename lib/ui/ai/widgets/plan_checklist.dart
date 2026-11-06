// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// `set_plan` 的步骤列表。
///
/// 三态而不是两态：已完成 / 正在做 / 未开始。只有勾和空框的话，用户看不出
/// 「它卡在第几步」—— 而长排查里那恰恰是唯一想知道的事。
///
/// ## 为什么没有卡片外壳
///
/// 早先是一整块带背景和圆角的 `Container`。2026-09-09 改成纯缩进列表，与
/// 同一轮把终态事件退成流水行是同一件事：清单是**当前状态**，它每更新一次
/// 就多占一块屏幕，而屏幕要留给 AI 的结论。
///
/// 三态靠字符、颜色和字重表达，不靠面积：
///   已完成 `✓` 主色 + 文字灰并加删除线
///   正在做 `▸` 主色 + 粗体
///   未开始 `☐` 灰
///
/// 用字符而不是 Material 图标，是为了跟桌面端的 agent CLI 对齐 —— 用户在
/// 两边看到的是同一件事，形状也该是同一个。
///
/// **勾号必须用 `✓`（U+2713），不能用 `☑`（U+2611）或 `✔`（U+2714）。**
/// 后两个在 Unicode 的 emoji 数据里有条目，Android 上会被 emoji 字体接管、
/// 渲染成蓝底白勾的彩色字形，而彩色字形自带颜色 —— 代码里设的 `color` 对
/// 它完全无效。2026-09-09 真机截图就是这样：一屏的「已完成」全是蓝方块，
/// 而不是这里写的主色。U+2713 不在 emoji 表里，走文本字形，颜色可控。
class PlanChecklist extends StatelessWidget {
  final List<String> steps;
  final int? current;

  const PlanChecklist({super.key, required this.steps, this.current});

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      // 水平 8 与流水行、各完整卡的 margin 对齐，混排时左边缘不跳。
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 固定宽度而不是指定等宽字体：`☑ ☐ ▸` 未必都在某一个字体
                  // 里有字形，缺字形时 fallback 到系统字体，宽度就各不相同、
                  // 三行的文字左缘会参差。给个盒子兜住，字形怎么 fallback
                  // 都不影响对齐。
                  SizedBox(
                    width: 16,
                    child: Text(
                      current == null || i > current!
                          ? '☐'
                          : i == current
                              ? '▸'
                              : '✓',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        // 做完的和正在做的都用主色 —— 这一整块是「已经推进
                        // 到的部分」，未开始的才是灰的。两者靠形状区分（✓
                        // 对号 vs ▸ 箭头），外加文字侧的删除线与字重。
                        color: current != null && i <= current!
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      steps[i],
                      // 步骤文字过长按 UI 截断，不回传给模型 —— 它自己写的
                      // 东西不需要我们再告诉它一遍。
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.35,
                        color: current != null && i < current!
                            ? theme.colorScheme.onSurfaceVariant
                            : i == current
                                ? theme.colorScheme.primary
                                : null,
                        fontWeight:
                            i == current ? FontWeight.w600 : null,
                        decoration: current != null && i < current!
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
