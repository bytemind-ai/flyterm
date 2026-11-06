// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart' show visibleForTesting;

/// UI 可见性的编译期开关。
///
/// 与 `lib/commerce/feature_flags.dart` 分开：那个管商业化（Pro 解锁与
/// Paywall），这个管「某块 UI 露不露面」。两者的决策人和生命周期都不同，
/// 混在一个文件里迟早会让「测试构建」和「功能下线」这两件事互相绊住。

/// 后台任务看板是否对用户可见。
///
/// 关掉时这些入口一并消失：
///   • 首页 AppBar 的任务按钮
///   • 服务器行内的「N 个运行中」徽标，**连同为它服务的后台扫描**
///   • 终端页 AI 面板 / 全局 AI 页的「打开任务看板」
///   • AI 面板底部的常驻任务条
///
/// 不受影响的：agent 的 `run_background` / `check_job` / `list_jobs` 工具照常
/// 工作，`JobBoardScreen` 与 `/jobs` 路由也都保留 —— 这是一次 UI 下线，不是
/// 功能删除。
///
/// 放出来：flutter build apk ... --dart-define=FLYTERM_SHOW_JOB_BOARD=true
const bool _kShowJobBoardCompileTime = bool.fromEnvironment(
  'FLYTERM_SHOW_JOB_BOARD',
  defaultValue: false,
);

/// 仅供测试覆盖。null = 用编译期值。
///
/// `bool.fromEnvironment` 在测试里恒为 `defaultValue`，而若干既有测试要断言
/// 徽标/入口存在。给一个运行时覆盖点，比为了可测把整个开关降级成普通变量
/// 要好 —— 生产路径仍然只读编译期常量。
///
/// **用完务必在 tearDown 里复位**，否则会泄漏到同一批次的其它测试。
@visibleForTesting
bool? debugShowJobBoardOverride;

bool get kShowJobBoard =>
    debugShowJobBoardOverride ?? _kShowJobBoardCompileTime;
