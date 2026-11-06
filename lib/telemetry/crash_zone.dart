// SPDX-License-Identifier: GPL-3.0-or-later
// lib/telemetry/crash_zone.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 用 runZonedGuarded 包住 runApp，捕获所有未处理的同步/异步异常并发到
/// Sentry。即使 Sentry 未 init（debug / 无 DSN），Sentry.captureException
/// 也是 no-op 不会抛错。
Future<void> runWithCrashCapture(FutureOr<void> Function() appRunner) async {
  await runZonedGuarded(() async {
    FlutterError.onError = (details) {
      Sentry.captureException(details.exception, stackTrace: details.stack);
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      Sentry.captureException(error, stackTrace: stack);
      return true;
    };

    await appRunner();
  }, (error, stack) {
    Sentry.captureException(error, stackTrace: stack);
  });
}
