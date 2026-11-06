// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../sftp/sftp_entry.dart';
import '../design/fly_tokens.dart';

/// Icon and colour for a file type in the SFTP browser.
///
/// Kept out of `SftpEntry` so the data model stays free of Flutter imports,
/// and out of the view so it can be unit tested without a widget tree.
///
/// ## Why this is grayscale
///
/// `fly_tokens.dart` fixes the立场: **colour encodes state, never decoration**
/// (green=connected, amber=pending, red=failed), and everything else is a gray.
/// A file *type* is not a state, so tinting it would be exactly the kind of
/// decorative colour that立场 rules out.
///
/// The first version of this file shipped a 13-hue palette (green images,
/// purple video, orange audio…). That was wrong twice over: it broke the rule,
/// and it collided semantically — `image` green sat next to `FlyColors.active`
/// mint in the same list, reading as "this row is connected".
///
/// ## What replaces it
///
/// **Luminance encodes priority.** The three tiers are the existing
/// `FlyColors` gray tokens, whose relative contrast against
/// `FlyColors.background` is already documented in `fly_tokens.dart`
/// (4.53:1 for the mid tier, etc.) — so each tier is a measured decision, not
/// a hand-picked one.
///
/// Shape carries the finer distinction the grays deliberately drop.
IconData iconFor(FileKind kind) {
  switch (kind) {
    case FileKind.directory:
      return Icons.folder;
    case FileKind.image:
      return Icons.image_outlined;
    case FileKind.video:
      return Icons.movie_outlined;
    case FileKind.audio:
      return Icons.audiotrack_outlined;
    case FileKind.pdf:
      return Icons.picture_as_pdf_outlined;
    case FileKind.archive:
      return Icons.folder_zip_outlined;
    case FileKind.code:
      return Icons.code;
    case FileKind.text:
      return Icons.description_outlined;
    case FileKind.markdown:
      return Icons.article_outlined;
    case FileKind.config:
      return Icons.settings_suggest_outlined;
    case FileKind.font:
      return Icons.font_download_outlined;
    case FileKind.database:
      return Icons.storage_outlined;
    case FileKind.binary:
      return Icons.memory;
    case FileKind.unknown:
      return Icons.insert_drive_file_outlined;
  }
}

/// Brightness tier for a file kind.
///
/// The tiers answer one question: **is the user here for this file?**
///
/// - [FileKind.code] / [FileKind.text] / [FileKind.config] — yes, this is what
///   they opened the browser for. Highest brightness.
/// - media, documents, fonts, databases — recognisable, but usually passing
///   through. Middle.
/// - archives and opaque binaries — "not your business", nothing to show.
///   Lowest.
///
/// Returns a `FlyColors` token rather than a literal so retuning the palette
/// moves this along with everything else.
///
/// ## Directories are gray too (and why that isn't an oversight)
///
/// An earlier version gave directories `colorScheme.primary` on the reasoning
/// that "a directory is an interactive element, not a file type". That was
/// wrong on two counts:
///
/// 1. **Being enterable is a constant, not a state.** Every directory is
///    enterable, so the colour carried no information. `primary`/mint has an
///    established meaning in `fly_tokens.dart` — `active`: connected / in
///    progress / success — and spending it on a constant demotes it from state
///    encoding to decoration, which is exactly what that file rules out.
/// 2. **It collided semantically.** Mint reads as "this session is connected"
///    in the home list; mint for directories would have meant two different
///    things in the same app.
///
/// Directories are set apart by **shape** instead: `Icons.folder` is filled
/// while every file type uses an `*_outlined` glyph. Form difference is the
/// tool `fly_tokens.dart` endorses ("hierarchy through division and
/// luminance"), and it costs no colour.
///
/// There is also a practical reason: directories are typically a third or more
/// of an SFTP listing, so a coloured column would have drowned out the
/// brightness tiers that carry the actual signal.
Color colorFor(FileKind kind) {
  switch (kind) {
    case FileKind.directory:
    case FileKind.code:
    case FileKind.text:
    case FileKind.config:
    case FileKind.markdown:
      return FlyColors.textPrimary;

    case FileKind.image:
    case FileKind.video:
    case FileKind.audio:
    case FileKind.pdf:
    case FileKind.font:
    case FileKind.database:
      return FlyColors.textSecondary;

    case FileKind.archive:
    case FileKind.binary:
    case FileKind.unknown:
      return FlyColors.textTertiary;
  }
}

/// Icon for [entry]'s type. Convenience over [iconFor] for call sites that
/// already hold an entry.
IconData fileIcon(SftpEntry entry) => iconFor(entry.kind);

/// Colour for [entry]'s type.
///
/// Takes no [ColorScheme]: every tier is a fixed `FlyColors` token, which is
/// what keeps a file's colour stable when the user switches terminal themes.
/// The parameter existed while directories tracked `primary`; it would now
/// only mislead a reader into thinking the scheme affects the result.
Color fileIconColor(SftpEntry entry) => colorFor(entry.kind);

/// 软链行的角标图标。
///
/// 用**叠加在类型图标右下角的小标记**，而不是替换类型图标 —— 这样用户既
/// 知道「它是什么」（文件/目录），也知道「它是通过链接到达的」。替换掉类型
/// 图标会丢掉前一个信息。
const IconData symlinkBadgeIcon = Icons.link;

/// 角标颜色。走最低亮度灰，不引入新色相 —— 见本文件顶部关于灰阶的说明。
const Color symlinkBadgeColor = FlyColors.textTertiary;
