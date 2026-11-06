// SPDX-License-Identifier: GPL-3.0-or-later
// lib/telemetry/data_scrubber.dart
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Sentry 事件上传前的 PII 脱敏函数。
///
/// 规则：
///   - host (IP / 域名) → SHA256(host) 前 8 hex 字符
///   - username → 'len=N' （保留长度，不暴露身份）
///   - port → 保留（公开信息）
///   - SSH key bytes / output / keystrokes → 严禁出现，源码层避免传入
///
/// 此模块在 Sentry beforeSend hook 中调用，所有 breadcrumb / exception
/// event 必须经过 [scrubEvent] 处理才能上传。
class DataScrubber {
  static const _sensitiveKeys = {
    'host',
    'hostname',
    'username',
    'user',
    'ipAddress',
    'ip',
    'remoteHost',
  };

  /// 返回 [host] 的 SHA256 hash 前 8 hex 字符（小写）。
  /// 用作 breadcrumb / tag 中 host 的替代值，跨 event 可关联（同 host hash 相同）
  /// 但无法反推真实地址。
  static String hashHost(String host) {
    final bytes = utf8.encode(host);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 8);
  }

  /// 把 username 替换为 'len=N' 形式。保留长度信息便于诊断（如"是否输入截断"），
  /// 但不暴露 username 本身。
  static String redactUsername(String username) => 'len=${username.length}';

  /// 扫描 map 内的 key，遇到 [_sensitiveKeys] 中的字段时按类型替换。
  /// 返回新 map（不修改原 map）。
  static Map<String, dynamic>? scrubBreadcrumbData(
    Map<String, dynamic>? data,
  ) {
    if (data == null) return null;
    final out = <String, dynamic>{};
    data.forEach((k, v) {
      final lowerKey = k.toLowerCase();
      if (_sensitiveKeys.contains(lowerKey) && v is String && v.isNotEmpty) {
        if (lowerKey.contains('user')) {
          out[k] = redactUsername(v);
        } else {
          out[k] = hashHost(v);
        }
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  /// Sentry beforeSend hook。在每个 event 上传前调用，脱敏所有 breadcrumb data
  /// 与已知 tag。返回 null 等于丢弃 event（极端 case，目前不使用）。
  static FutureOr<SentryEvent?> scrubEvent(
    SentryEvent event,
    Hint hint,
  ) {
    // breadcrumbs
    final scrubbedBreadcrumbs = event.breadcrumbs?.map((b) {
      final scrubbedData = scrubBreadcrumbData(b.data);
      return b.copyWith(data: scrubbedData);
    }).toList();

    // tags - 同样脱敏 host / username 字段
    final scrubbedTags = <String, String>{};
    event.tags?.forEach((k, v) {
      final lowerKey = k.toLowerCase();
      if (_sensitiveKeys.contains(lowerKey) && v.isNotEmpty) {
        scrubbedTags[k] =
            lowerKey.contains('user') ? redactUsername(v) : hashHost(v);
      } else {
        scrubbedTags[k] = v;
      }
    });

    return event.copyWith(
      breadcrumbs: scrubbedBreadcrumbs,
      tags: scrubbedTags,
    );
  }
}
