// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

class FontPreview extends StatelessWidget {
  final String fontFamily;
  final double fontSize;
  final double height;

  const FontPreview({
    super.key,
    required this.fontFamily,
    required this.fontSize,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    // Match TerminalWidget's TerminalStyle: xterm requires non-nullable
    // fontFamily, so 'system' maps to 'monospace' — Flutter's generic alias
    // that resolves to the platform default (Roboto Mono on Android, Menlo
    // on iOS). Keeping preview consistent with actual terminal rendering.
    final style = TextStyle(
      fontFamily: fontFamily == 'system' ? 'monospace' : fontFamily,
      // Mirrors TerminalWidget's chain head: DejaVuSansMono first so symbol
      // glyphs stay inside the cell (see the note there), NotoSansSymbols2
      // behind it for the blocks DejaVu doesn't cover.
      fontFamilyFallback: const [
        'DejaVuSansMono',
        'NotoSansSymbols2',
        'Noto Sans Symbols',
      ],
      fontSize: fontSize,
      height: height,
    );

    // Determine display name for font family label
    final displayName = fontFamily == 'system' ? 'System (monospace)' : fontFamily;
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            displayName,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
              width: 0.5,
            ),
          ),
          child: Text(
            'const x = 42;\n'
            'if (x > 0) { print("hello, 中文"); }\n'
            'fn ⇒ {} != [] => 0xFF\n'
            // Neither primary font has these, so they always exercise the
            // fallback chain — the row stays aligned only while a MONOSPACED
            // symbol font wins it. Cheap visual check for the clipping bug.
            '☐ ☒ ✔ ✗ ❯ │ ├ └',
            style: style,
          ),
        ),
      ],
    );
  }
}
