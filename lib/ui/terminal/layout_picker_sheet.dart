// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Possible layout choices the user can pick from the bottom sheet.
/// Mirrors `SplitMode` plus an explicit `single` (no split, no float)
/// and `float` (overlay PiP).
enum LayoutChoice { single, leftRight, topBottom, floating }

/// Visual 2×2 chooser. Each cell paints a tiny diagram of the layout
/// instead of a text label so the user picks "by shape." Selected
/// state highlights the active layout and disables the same choice
/// (re-selecting it is a no-op).
class LayoutPickerSheet extends StatelessWidget {
  final LayoutChoice current;
  final bool floatAvailable;
  final ValueChanged<LayoutChoice> onPicked;

  const LayoutPickerSheet({
    super.key,
    required this.current,
    required this.floatAvailable,
    required this.onPicked,
  });

  static Future<void> show({
    required BuildContext context,
    required LayoutChoice current,
    required bool floatAvailable,
    required ValueChanged<LayoutChoice> onPicked,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => LayoutPickerSheet(
        current: current,
        floatAvailable: floatAvailable,
        onPicked: (c) {
          Navigator.pop(ctx);
          onPicked(c);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                l.layoutPickerTitle,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.35,
              children: [
                _LayoutCell(
                  selected: current == LayoutChoice.single,
                  enabled: true,
                  label: l.layoutSingle,
                  thumb: const _SingleThumb(),
                  onTap: () => onPicked(LayoutChoice.single),
                ),
                _LayoutCell(
                  selected: current == LayoutChoice.leftRight,
                  enabled: true,
                  label: l.splitHorizontal,
                  thumb: const _LeftRightThumb(),
                  onTap: () => onPicked(LayoutChoice.leftRight),
                ),
                _LayoutCell(
                  selected: current == LayoutChoice.topBottom,
                  enabled: true,
                  label: l.splitVertical,
                  thumb: const _TopBottomThumb(),
                  onTap: () => onPicked(LayoutChoice.topBottom),
                ),
                _LayoutCell(
                  selected: current == LayoutChoice.floating,
                  enabled: floatAvailable,
                  label: l.floatTerminal,
                  thumb: const _FloatThumb(),
                  onTap: () => onPicked(LayoutChoice.floating),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LayoutCell extends StatelessWidget {
  final bool selected;
  final bool enabled;
  final String label;
  final Widget thumb;
  final VoidCallback onTap;

  const _LayoutCell({
    required this.selected,
    required this.enabled,
    required this.label,
    required this.thumb,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final borderColor = selected
        ? cs.primary
        : (enabled ? cs.onSurface.withAlpha(40) : cs.onSurface.withAlpha(15));
    final tint = selected ? cs.primary.withAlpha(20) : null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: tint ?? cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: borderColor,
                width: selected ? 2 : 1,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Center(child: thumb)),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Layout thumbnails ────────────────────────────────────────────────────

/// Shared hairline + fill style across all four thumbs so the cells read
/// as a coherent set.
BoxDecoration _thumbDeco(BuildContext context) => BoxDecoration(
      color: Theme.of(context).colorScheme.onSurface.withAlpha(20),
      borderRadius: BorderRadius.circular(3),
      border: Border.all(
        color: Theme.of(context).colorScheme.onSurface.withAlpha(80),
        width: 0.8,
      ),
    );

class _SingleThumb extends StatelessWidget {
  const _SingleThumb();
  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.6,
      child: Container(decoration: _thumbDeco(context)),
    );
  }
}

class _LeftRightThumb extends StatelessWidget {
  const _LeftRightThumb();
  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.6,
      child: Row(
        children: [
          Expanded(child: Container(decoration: _thumbDeco(context))),
          const SizedBox(width: 3),
          Expanded(child: Container(decoration: _thumbDeco(context))),
        ],
      ),
    );
  }
}

class _TopBottomThumb extends StatelessWidget {
  const _TopBottomThumb();
  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.6,
      child: Column(
        children: [
          Expanded(child: Container(decoration: _thumbDeco(context))),
          const SizedBox(height: 3),
          Expanded(child: Container(decoration: _thumbDeco(context))),
        ],
      ),
    );
  }
}

class _FloatThumb extends StatelessWidget {
  const _FloatThumb();
  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.6,
      child: Stack(
        children: [
          Positioned.fill(child: Container(decoration: _thumbDeco(context))),
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              width: 22,
              height: 14,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(120),
                borderRadius: BorderRadius.circular(2),
                border: Border.all(
                  color:
                      Theme.of(context).colorScheme.primary.withAlpha(200),
                  width: 0.8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
