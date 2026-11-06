// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// Two-pane split layout with a barbell-shaped divider.
///
/// The two panes sit directly next to each other — there is no
/// allocated layout strip between them. Pane separation is provided
/// implicitly by each [_PaneFrame]'s 1px border (active pane uses
/// primary @ 40%, inactive uses white @ 10%, both drawn on top of
/// their own content via `Border.all`, so they consume 0 layout
/// space).
///
/// A 12×48 GestureDetector "bulge" is overlaid on the seam in the
/// centre, with a centred 4×32 pill as the visible drag affordance.
/// The bulge is the only place divider gestures are accepted, which
/// keeps the dead-zone for terminal gestures tiny.
///
/// [axis]               — split direction: horizontal = left/right, vertical = top/bottom.
/// [ratio]              — first-pane share, in (0, 1); SplitManager clamps to [0.25, 0.75].
/// [onRatioChanged]     — fired on bulge drag with the new (un-clamped) ratio.
/// [onRatioReset]       — fired on bulge double-tap.
/// [onSwapPanes]        — fired on bulge long-press.
/// [activeIsFirstPane]  — used to colour the active pane's border and tint
///                        the pill toward the active side.
class SplitPaneView extends StatelessWidget {
  static const double _bulgeMajor = 12.0; // perpendicular to divider
  static const double _bulgeMinor = 48.0; // along divider

  final Axis axis;
  final double ratio;
  final ValueChanged<double> onRatioChanged;
  final VoidCallback onRatioReset;
  final VoidCallback? onSwapPanes;
  final bool activeIsFirstPane;
  final Widget firstPane;
  final Widget secondPane;

  const SplitPaneView({
    super.key,
    required this.axis,
    required this.ratio,
    required this.onRatioChanged,
    required this.onRatioReset,
    required this.firstPane,
    required this.secondPane,
    this.onSwapPanes,
    this.activeIsFirstPane = true,
  }) : assert(ratio > 0 && ratio < 1,
            'ratio must be between 0 and 1 (exclusive), got $ratio');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isHorizontal = axis == Axis.horizontal;
        final totalAlong =
            isHorizontal ? constraints.maxWidth : constraints.maxHeight;
        final perpSize =
            isHorizontal ? constraints.maxHeight : constraints.maxWidth;

        final paneA = _PaneFrame(
          isActive: activeIsFirstPane,
          child: firstPane,
        );
        final paneB = _PaneFrame(
          isActive: !activeIsFirstPane,
          child: secondPane,
        );
        final flexA = (ratio * 1000).round();
        final flexB = ((1 - ratio) * 1000).round();
        final dragRow = isHorizontal
            ? Row(children: [
                Flexible(flex: flexA, child: paneA),
                Flexible(flex: flexB, child: paneB),
              ])
            : Column(children: [
                Flexible(flex: flexA, child: paneA),
                Flexible(flex: flexB, child: paneB),
              ]);

        // Bulge sits on the visible seam between the two panes. Since
        // there is no allocated divider strip, the seam is simply at
        // `totalAlong * ratio`.
        final bulgeAlongCentre = totalAlong * ratio;
        final bulgeAlongStart = bulgeAlongCentre - _bulgeMajor / 2;
        final bulgePerpStart = perpSize / 2 - _bulgeMinor / 2;

        return Stack(
          children: [
            Positioned.fill(child: dragRow),
            Positioned(
              left: isHorizontal ? bulgeAlongStart : bulgePerpStart,
              top: isHorizontal ? bulgePerpStart : bulgeAlongStart,
              width: isHorizontal ? _bulgeMajor : _bulgeMinor,
              height: isHorizontal ? _bulgeMinor : _bulgeMajor,
              child: _BulgeHandle(
                axis: axis,
                activeIsFirstPane: activeIsFirstPane,
                onPanUpdate: (details) {
                  final delta = isHorizontal
                      ? details.delta.dx
                      : details.delta.dy;
                  if (totalAlong <= 0) return;
                  onRatioChanged(ratio + delta / totalAlong);
                },
                onDoubleTap: onRatioReset,
                onLongPress: onSwapPanes,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Hairline frame highlighting the active pane. Inactive pane gets a
/// barely-visible white-10% line; active pane gets primary @ 40%, the
/// same accent the tab strip uses for the active tab's underline.
/// Border is painted on top of content (Flutter Border.all does not
/// affect layout) so it does not shrink the terminal cell grid.
class _PaneFrame extends StatelessWidget {
  final bool isActive;
  final Widget child;
  const _PaneFrame({required this.isActive, required this.child});

  @override
  Widget build(BuildContext context) {
    final color = isActive
        ? Theme.of(context).colorScheme.primary.withAlpha(102)
        : Colors.white.withAlpha(26);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1),
      ),
      child: child,
    );
  }
}

/// 12×48 (rotated for vertical split) drag region centred on the
/// divider seam. Visually transparent except for the centred 4×32
/// pill — the rest of the bulge is invisible "slack" that gives the
/// user a generous hit target without consuming layout width.
class _BulgeHandle extends StatelessWidget {
  final Axis axis;
  final bool activeIsFirstPane;
  final GestureDragUpdateCallback onPanUpdate;
  final VoidCallback onDoubleTap;
  final VoidCallback? onLongPress;

  const _BulgeHandle({
    required this.axis,
    required this.activeIsFirstPane,
    required this.onPanUpdate,
    required this.onDoubleTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isHorizontal = axis == Axis.horizontal;
    final primary = Theme.of(context).colorScheme.primary;
    final pillColor = primary.withAlpha(activeIsFirstPane ? 130 : 80);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: onPanUpdate,
      onDoubleTap: onDoubleTap,
      onLongPress: onLongPress,
      child: Center(
        child: Container(
          width: isHorizontal ? 4 : 32,
          height: isHorizontal ? 32 : 4,
          decoration: BoxDecoration(
            color: pillColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}
