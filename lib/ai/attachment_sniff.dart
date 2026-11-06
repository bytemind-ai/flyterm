// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'attachment.dart';

/// 图片原文件大小上限。超过就降采样。
///
/// 3.5MB 而不是 5MB：base64 会膨胀 4/3，三家 API 的单图上限在 5MB 附近，
/// 3.5 × 4/3 ≈ 4.7MB 刚好压在线内。
const int kMaxImageBytes = 3500 * 1024;

/// 文本附件进 `content` 的上限。
///
/// 比工具输出的 8 KiB 宽 —— 这是用户主动给的文件，不是模型自己拉的；但不能
/// 让一个 5MB 日志撞穿 token 预算。
const int kMaxTextBytes = 64 * 1024;

enum AttachmentReject { empty, binary }

/// 嗅探结果。[kind] 为 null 表示不可用，理由在 [rejectReason]。
class AttachmentSniffResult {
  final AttachmentKind? kind;
  final String mime;
  final AttachmentReject? rejectReason;

  /// 图片超限，需要降采样后再落盘。
  final bool needsDownscale;

  /// 文本超限，读取时要截断。
  final bool needsTruncate;

  const AttachmentSniffResult({
    this.kind,
    this.mime = 'application/octet-stream',
    this.rejectReason,
    this.needsDownscale = false,
    this.needsTruncate = false,
  });
}

/// 已知图片魔数 → mime。
///
/// **按魔数而不是扩展名判断**：相册导出的文件名不可靠（有 `.jpg` 其实是
/// PNG 的情况），而判错的后果是 provider 侧 400。
const _magics = <(List<int>, String)>[
  ([0x89, 0x50, 0x4E, 0x47], 'image/png'),
  ([0xFF, 0xD8, 0xFF], 'image/jpeg'),
  ([0x47, 0x49, 0x46, 0x38], 'image/gif'),
];

bool _startsWith(Uint8List b, List<int> magic) {
  if (b.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[i] != magic[i]) return false;
  }
  return true;
}

/// WebP 的魔数是分段的：`RIFF` + 4 字节长度 + `WEBP`。
bool _isWebp(Uint8List b) =>
    b.length >= 12 &&
    _startsWith(b, [0x52, 0x49, 0x46, 0x46]) &&
    b[8] == 0x57 &&
    b[9] == 0x45 &&
    b[10] == 0x42 &&
    b[11] == 0x50;

/// 判断一个本地文件该以哪种附件形态使用。
///
/// [head] 是文件前若干字节（调用方读 512 即可），[totalBytes] 是完整大小。
///
/// 二进制判据是 **NUL 字节**，与 `web_fetch.dart` 的 `decodeWebBody` 同一个
/// 判据（那边的注释写明了理由：那是「这真是二进制」与「这只是被截断了」之间
/// 唯一便宜可靠的判据）。
AttachmentSniffResult sniffAttachment({
  required Uint8List head,
  required int totalBytes,
  required String fileName,
}) {
  if (totalBytes <= 0 || head.isEmpty) {
    return const AttachmentSniffResult(rejectReason: AttachmentReject.empty);
  }

  for (final (magic, mime) in _magics) {
    if (_startsWith(head, magic)) {
      return AttachmentSniffResult(
        kind: AttachmentKind.image,
        mime: mime,
        needsDownscale: totalBytes > kMaxImageBytes,
      );
    }
  }
  if (_isWebp(head)) {
    return AttachmentSniffResult(
      kind: AttachmentKind.image,
      mime: 'image/webp',
      needsDownscale: totalBytes > kMaxImageBytes,
    );
  }

  if (head.contains(0)) {
    return const AttachmentSniffResult(rejectReason: AttachmentReject.binary);
  }

  return AttachmentSniffResult(
    kind: AttachmentKind.text,
    mime: 'text/plain',
    needsTruncate: totalBytes > kMaxTextBytes,
  );
}
