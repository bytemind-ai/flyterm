// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'sftp_service.dart';

/// 用户能理解、且能据此行动的失败原因。
///
/// 有限几种是刻意的 —— 分类的价值在于「同一类失败给同一套建议」，枚举继续
/// 膨胀就会退化成把原始错误换个说法。
enum SftpErrorKind {
  permissionDenied,
  notFound,
  diskFull,
  disconnected,
  alreadyExists,

  /// 无法归类的失败。呈现原始文本。
  unknown,
}

/// 一个已经分类的 SFTP 失败。
///
/// **原文必须保留。** 协议错误码（`SSH_FX_PERMISSION_DENIED`）常常是排查时
/// 唯一的线索，分类只负责「给用户一句人话 + 一个建议」，不是替换关系。
class SftpError {
  final SftpErrorKind kind;

  /// 原始错误的 `toString()`。UI 折叠展示，不丢。
  final String raw;

  const SftpError({required this.kind, required this.raw});

  factory SftpError.classify(Object e) => SftpError(
        kind: _kindOf(e),
        raw: e.toString(),
      );

  static SftpErrorKind _kindOf(Object e) {
    if (e is SftpDisconnectedException) return SftpErrorKind.disconnected;
    // 超时与 socket 异常都是「连接没了」的表现。归为一类是因为用户能做的
    // 事相同：重连。
    if (e is TimeoutException || e is SocketException) {
      return SftpErrorKind.disconnected;
    }
    if (e is SftpStatusError) {
      final msg = e.message.toLowerCase();
      // 先按文本细化 —— 错误码不够细：SSH_FX_FAILURE(4) 同时覆盖磁盘满、
      // 配额超限、只读文件系统等一串原因，只有文本能区分。
      if (msg.contains('no space') || msg.contains('quota')) {
        return SftpErrorKind.diskFull;
      }
      if (msg.contains('exist')) return SftpErrorKind.alreadyExists;
      if (msg.contains('permission') || msg.contains('denied')) {
        return SftpErrorKind.permissionDenied;
      }
      if (msg.contains('no such') || msg.contains('not found')) {
        return SftpErrorKind.notFound;
      }
      switch (e.code) {
        case SftpStatusCode.permissionDenied: // 3
          return SftpErrorKind.permissionDenied;
        case SftpStatusCode.noSuchFile: // 2
          return SftpErrorKind.notFound;
        case 11: // SSH_FX_FILE_ALREADY_EXISTS（dartssh2 未定义常量）
          return SftpErrorKind.alreadyExists;
      }
    }
    return SftpErrorKind.unknown;
  }
}