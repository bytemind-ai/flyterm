// SPDX-License-Identifier: GPL-3.0-or-later
// lib/update/update_checker.dart

/// 新版本元信息。
class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.isMandatory,
    this.releaseNotes,
  });

  final String latestVersion;
  final String currentVersion;

  /// true → 弹强制 dialog（仅 [Update] 按钮）。
  /// iOS：release notes 含 `[MANDATORY]` 标签 → true
  /// Android：Play Core staleness ≥ 14 天 → true
  final bool isMandatory;

  final String? releaseNotes;
}

/// 平台无关的更新检查抽象。
abstract class UpdateChecker {
  /// null = 无新版本 / 检查失败（静默）；非 null = 有新版本
  Future<UpdateInfo?> check();

  /// 打开更新流程：iOS = launchUrl(AppStore URL)；Android = appUpdateManager.startUpdateFlow()
  Future<void> launchUpdateFlow();

  /// 工厂：按平台选实现。HomeScreen 启动时调，测试可手动实例化 mock。
  /// iOS / Android 实现分别在 github_release_checker.dart / play_in_app_updater.dart
  /// 但本抽象文件不 import 它们 — 调用方通过 platform check 在自己模块里 new 出来。
  /// 此 factory 仅是占位，真实创建在 home_screen.dart 里做 platform branch。
  static UpdateChecker noop() => _NoopChecker();
}

class _NoopChecker implements UpdateChecker {
  @override
  Future<UpdateInfo?> check() async => null;
  @override
  Future<void> launchUpdateFlow() async {}
}
