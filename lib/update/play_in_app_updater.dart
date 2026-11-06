// SPDX-License-Identifier: GPL-3.0-or-later
// lib/update/play_in_app_updater.dart
import 'package:in_app_update/in_app_update.dart';

import 'update_checker.dart';

class PlayInAppUpdater implements UpdateChecker {
  PlayInAppUpdater();

  factory PlayInAppUpdater.androidDefault() => PlayInAppUpdater();

  AppUpdateInfo? _cachedInfo;

  @override
  Future<UpdateInfo?> check() async {
    try {
      final result = await InAppUpdate.checkForUpdate();
      _cachedInfo = result;
      if (result.updateAvailability != UpdateAvailability.updateAvailable) {
        return null;
      }
      // Play Core 不告诉我们当前/最新版本号。包一个占位。
      final staleness = result.clientVersionStalenessDays ?? 0;
      return UpdateInfo(
        latestVersion: 'Play Store',
        currentVersion: 'current',
        isMandatory: staleness >= 14,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> launchUpdateFlow() async {
    final info = _cachedInfo;
    if (info == null) {
      await check();
    }
    final cached = _cachedInfo;
    if (cached?.updateAvailability != UpdateAvailability.updateAvailable) {
      return;
    }
    // 优先 IMMEDIATE（全屏阻塞），失败 fallback FLEXIBLE
    if (cached!.immediateUpdateAllowed) {
      await InAppUpdate.performImmediateUpdate();
    } else if (cached.flexibleUpdateAllowed) {
      await InAppUpdate.startFlexibleUpdate();
      await InAppUpdate.completeFlexibleUpdate();
    }
  }
}
