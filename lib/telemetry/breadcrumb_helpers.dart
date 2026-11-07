// SPDX-License-Identifier: GPL-3.0-or-later
// lib/telemetry/breadcrumb_helpers.dart
import 'package:sentry_flutter/sentry_flutter.dart';

import '../consent/consent_manager.dart';
import 'data_scrubber.dart';

/// 关键业务事件的 breadcrumb 上报 helper。
class Breadcrumbs {
  static void connection(
    String action, {
    String? hostHash,
    int? port,
    String? protocol,
  }) {
    _add(
      category: 'connection',
      message: action,
      data: {
        if (hostHash != null) 'hostHash': hostHash,
        if (port != null) 'port': port,
        if (protocol != null) 'protocol': protocol,
      },
    );
  }

  static void custom({
    required String category,
    required String message,
    Map<String, dynamic>? data,
  }) =>
      _add(category: category, message: message, data: data);

  static void _add({
    required String category,
    required String message,
    Map<String, dynamic>? data,
  }) {
    if (!ConsentManager.instance.analyticsEnabled) return;
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: category,
        message: message,
        data: DataScrubber.scrubBreadcrumbData(data),
        timestamp: DateTime.now(),
        level: SentryLevel.info,
      ),
    );
  }
}
