// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

/// Why a paste was refused, or [none] when it should proceed.
enum PasteRejection {
  /// Clipboard held no text (empty, or non-text content such as an image).
  empty,

  /// Neither a transport nor a shell is attached — bytes would be dropped.
  disconnected,

  /// Payload exceeds [kMaxPasteBytes]. Refused rather than truncated: a
  /// half-pasted private key or command is worse than an explicit failure.
  tooLarge,

  /// Paste may proceed.
  none,
}

/// Maximum clipboard payload accepted for a single paste, in UTF-8 bytes.
///
/// Real payloads are far smaller (private key ~3 KB, config ~10 KB, stack
/// trace ~50 KB). The cap exists to stop a multi-megabyte clipboard from
/// blocking the main isolate on encode and flooding the PTY in one write.
const int kMaxPasteBytes = 256 * 1024;

/// Decide whether [text] from the clipboard may be pasted.
///
/// Checks run in a fixed order so the message shown is deterministic:
/// empty → disconnected → tooLarge.
PasteRejection classifyPaste(
  String? text, {
  required bool connected,
  int maxBytes = kMaxPasteBytes,
}) {
  if (text == null || text.isEmpty) return PasteRejection.empty;
  if (!connected) return PasteRejection.disconnected;
  // UTF-8 length is always >= UTF-16 code-unit length, so a String.length
  // over the cap is definitely over it — short-circuit before allocating an
  // encoded copy of a pathologically large clipboard.
  if (text.length > maxBytes) return PasteRejection.tooLarge;
  if (pasteByteSize(text) > maxBytes) return PasteRejection.tooLarge;
  return PasteRejection.none;
}

/// UTF-8 byte size of [text], for the "too large" message.
int pasteByteSize(String text) => utf8.encode(text).length;
