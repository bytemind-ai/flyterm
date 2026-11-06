// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../ssh/completion_suggestion.dart';

/// Height of a single suggestion row, pre-wrap. Rows that need to wrap grow
/// to accommodate a second line; the overall list height is still clamped to
/// [kCompletionMaxVisible] * [kCompletionRowHeight] via [ConstrainedBox] +
/// `shrinkWrap`, so we never need to predict exact per-row heights up front.
const double kCompletionRowHeight = 36;

/// Maximum number of rows visible before the list scrolls.
const int kCompletionMaxVisible = 5;

/// Maximum width of the popup; it otherwise sizes to its content.
const double kCompletionMaxWidth = 320;

const Color _mint = Color(0xFF00C896);

/// A floating completion popup anchored to the terminal cursor, iTerm-style.
///
/// Unlike the old bottom-docked `CompletionBar`, this overlays the terminal
/// content rather than pushing it up — the terminal and keybar never resize.
/// Positioning mirrors `TerminalFloatingMenu` in `selection_overlay.dart`:
/// prefer above the anchor, flip below when there's no room, clamp to the
/// parent Stack's bounds.
class CompletionPopup extends StatelessWidget {
  const CompletionPopup({
    super.key,
    required this.suggestions,
    required this.input,
    required this.anchor,
    required this.onAccept,
  });

  /// Candidate suggestions. Empty list renders nothing.
  final List<CompletionSuggestion> suggestions;

  /// The currently typed line, used for prefix highlighting.
  final String input;

  /// Cursor rect in the parent Stack's local coordinates (one glyph cell).
  /// The popup positions itself relative to this.
  final Rect anchor;

  final void Function(CompletionSuggestion) onAccept;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _CompletionPopupLayout(anchor: anchor),
        child: _CompletionPanel(
          suggestions: suggestions,
          input: input,
          onAccept: onAccept,
        ),
      ),
    );
  }
}

class _CompletionPanel extends StatelessWidget {
  const _CompletionPanel({
    required this.suggestions,
    required this.input,
    required this.onAccept,
  });

  final List<CompletionSuggestion> suggestions;
  final String input;
  final void Function(CompletionSuggestion) onAccept;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      key: const ValueKey('completion_popup_body'),
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kCompletionMaxWidth),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(color: cs.onSurface.withOpacity(0.12)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: kCompletionMaxVisible * kCompletionRowHeight,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: suggestions.length,
              itemBuilder: (_, i) => _SuggestionRow(
                suggestion: suggestions[i],
                input: input,
                onTap: () => onAccept(suggestions[i]),
                showDivider: i < suggestions.length - 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.input,
    required this.onTap,
    required this.showDivider,
  });

  final CompletionSuggestion suggestion;
  final String input;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isHistory = suggestion.source == CompletionSource.history;

    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kCompletionRowHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    isHistory ? Icons.history : Icons.flash_on,
                    size: 13,
                    color: cs.onSurface.withOpacity(0.35),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _HighlightedText(
                      text: suggestion.text,
                      input: input,
                      matchedColor: cs.onSurface.withOpacity(0.45),
                    ),
                  ),
                ],
              ),
            ),
            if (showDivider)
              Divider(
                height: 0.5,
                thickness: 0.5,
                color: cs.onSurface.withOpacity(0.12),
              ),
          ],
        ),
      ),
    );
  }
}

/// Renders [text] with the matched [input] prefix dimmed and the remainder in
/// mint, or the whole string in mint when [text] doesn't start with [input].
/// Wraps up to 2 lines instead of truncating — the differentiating part of a
/// completion is almost always at the tail.
class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.input,
    required this.matchedColor,
  });

  final String text;
  final String input;
  final Color matchedColor;

  static const _baseStyle = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: 13,
    height: 1.3,
  );

  @override
  Widget build(BuildContext context) {
    final matches = input.isNotEmpty && text.startsWith(input);

    final span = matches
        ? TextSpan(
            children: [
              TextSpan(
                text: input,
                style: _baseStyle.copyWith(color: matchedColor),
              ),
              TextSpan(
                text: text.substring(input.length),
                style: _baseStyle.copyWith(color: _mint),
              ),
            ],
          )
        : TextSpan(text: text, style: _baseStyle.copyWith(color: _mint));

    return Text.rich(
      span,
      maxLines: 2,
      overflow: TextOverflow.clip,
    );
  }
}

/// Positions the popup relative to [anchor], in the parent Stack's local
/// coordinate space. Mirrors `_FloatingMenuLayout` in `selection_overlay.dart`
/// — prefer above the anchor, flip below when there's no room, clamp inside
/// the overlay bounds.
class _CompletionPopupLayout extends SingleChildLayoutDelegate {
  const _CompletionPopupLayout({required this.anchor});

  final Rect anchor;

  static const double _clearance = 4.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Prefer above the anchor (cursor is usually low on screen; below is
    // keybar/keyboard territory). Flip below only when there's no room.
    final preferredTop = anchor.top - childSize.height - _clearance;
    final top = preferredTop < 0 ? anchor.bottom + _clearance : preferredTop;

    final maxLeft =
        (size.width - childSize.width - 4.0).clamp(4.0, double.infinity);
    final maxTop =
        (size.height - childSize.height).clamp(0.0, double.infinity);

    return Offset(
      anchor.left.clamp(4.0, maxLeft),
      top.clamp(0.0, maxTop),
    );
  }

  @override
  bool shouldRelayout(_CompletionPopupLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}
