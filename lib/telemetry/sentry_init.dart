// SPDX-License-Identifier: GPL-3.0-or-later
// lib/telemetry/sentry_init.dart
import 'package:flutter/foundation.dart';
import '../util/dlog.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../consent/consent_manager.dart';
import 'data_scrubber.dart';

/// Sentry SDK 初始化。仅在以下条件全部满足时实际 init：
///   - kReleaseMode 或 kProfileMode（debug build 自动 skip，避免开发噪音）
///   - SENTRY_DSN 编译时变量非空
///   - ConsentManager.crashReportingEnabled = true
///
/// 调用顺序：main() → ConsentManager.load() → 本函数 → runApp()。
///
/// DSN 通过 --dart-define=SENTRY_DSN=https://xxx@sentry.io/yyy 注入，
/// 不入仓。debug build 时 SENTRY_DSN 为空字符串，本函数直接 return。
Future<void> initSentryIfAllowed() async {
  if (kDebugMode) return;
  if (!ConsentManager.instance.crashReportingEnabled) return;

  const dsn = String.fromEnvironment('SENTRY_DSN');
  if (dsn.isEmpty) {
    dlog('Sentry', 'SENTRY_DSN not set, skipping init');
    return;
  }

  await SentryFlutter.init((options) {
    options.dsn = dsn;
    options.debug = false;
    options.tracesSampleRate = 0.1;
    options.environment = kReleaseMode ? 'production' : 'staging';
    options.attachScreenshot = false;
    options.attachViewHierarchy = false;
    options.sendDefaultPii = false;
    options.beforeSend = DataScrubber.scrubEvent;
  });
}
