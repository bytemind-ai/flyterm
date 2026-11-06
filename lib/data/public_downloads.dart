// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Where a published file landed in the public Downloads collection.
class PublishResult {
  /// Human-readable public location, e.g. `Download/FlyTerm/backup.json`
  /// (API 29+) or an absolute path (API 24-28).
  final String publicPath;

  /// content:// URI on API 29+, null on the legacy path.
  final String? uri;

  const PublishResult({required this.publicPath, this.uri});
}

/// Thrown when the user denies the storage permission required on API 24-28.
class PublicDownloadsPermissionException implements Exception {
  const PublicDownloadsPermissionException();
  @override
  String toString() => 'Storage permission denied';
}

/// Publishes an already-written private file into the user-visible public
/// Downloads collection (`Download/FlyTerm/…`) via a native MediaStore channel.
/// See `android/.../MediaStorePlugin.kt`.
class PublicDownloads {
  static const MethodChannel _defaultChannel =
      MethodChannel('sh.flyterm.app/media_store');

  /// Overridable in tests.
  @visibleForTesting
  static MethodChannel channel = _defaultChannel;

  /// Overridable in tests to avoid the real platform check.
  @visibleForTesting
  static bool? debugIsAndroid;

  /// Overridable in tests to avoid the real permission_handler channel.
  /// Returns whether the storage permission is granted.
  @visibleForTesting
  static Future<bool> Function()? debugRequestStorage;

  static bool get _isAndroid => debugIsAndroid ?? Platform.isAndroid;

  /// Publishes [source] into public `Download/FlyTerm` under [fileName].
  ///
  /// Returns null on non-Android platforms (no-op). Throws
  /// [PublicDownloadsPermissionException] if the API 24-28 storage permission
  /// is denied, or a [PlatformException] for other native failures.
  static Future<PublishResult?> publish({
    required File source,
    required String fileName,
    String? mimeType,
  }) async {
    if (!_isAndroid) return null;

    // API < 29 needs WRITE_EXTERNAL_STORAGE up front.
    final sdkInt = await _sdkInt();
    if (sdkInt != null && sdkInt < 29) {
      if (!await _requestStorage()) {
        throw const PublicDownloadsPermissionException();
      }
    }

    try {
      return await _invokePublish(source, fileName, mimeType);
    } on PlatformException catch (e) {
      // Native reports it needs the permission (edge: sdkInt probe failed).
      if (e.code == 'PERMISSION_REQUIRED') {
        if (await _requestStorage()) {
          return await _invokePublish(source, fileName, mimeType);
        }
        throw const PublicDownloadsPermissionException();
      }
      rethrow;
    }
  }

  static Future<PublishResult?> _invokePublish(
      File source, String fileName, String? mimeType) async {
    final res = await channel.invokeMapMethod<String, dynamic>(
      'publishToDownloads',
      {
        'sourcePath': source.path,
        'fileName': fileName,
        'mimeType': mimeType,
      },
    );
    if (res == null) return null;
    return PublishResult(
      publicPath: res['publicPath'] as String? ?? fileName,
      uri: res['uri'] as String?,
    );
  }

  static Future<bool> _requestStorage() async {
    if (debugRequestStorage != null) return debugRequestStorage!();
    final status = await Permission.storage.request();
    return status.isGranted;
  }

  static Future<int?> _sdkInt() async {
    try {
      return await channel.invokeMethod<int>('getAndroidSdkInt');
    } catch (_) {
      return null;
    }
  }
}
