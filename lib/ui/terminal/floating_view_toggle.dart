// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// A floating circular button that toggles terminal ⇄ SFTP view modes.
///
/// Stateless — the parent (TerminalScreen) controls [opacity],
/// [isCollapsed], and vertical position via [Positioned]. This widget
/// only renders what it's told and forwards gesture callbacks.
///
/// Visual states:
///   isCollapsed=false — 36dp circle with mode icon, shadow, opacity.
///   isCollapsed=true  — 4×48dp right-edge bar (tap to expand).
class FloatingViewToggle extends StatelessWidget {
  const FloatingViewToggle({
    super.key,
    required this.isSftpMode,
    required this.onToggle,
    this.opacity = 0.6,
    this.isCollapsed = false,
    this.onCollapseTap,
    this.onPanUpdate,
    this.onPanEnd,
  });

  /// True when the active tab is showing the SFTP view.
  final bool isSftpMode;

  /// Called when the user taps the button (not the collapsed bar).
  final VoidCallback onToggle;

  /// Button opacity in expanded state. Clamped to [0.0, 1.0].
  final double opacity;

  /// When true, renders the compact 4dp edge strip instead of the circle.
  final bool isCollapsed;

  /// Called when the user taps the collapsed edge bar.
  final VoidCallback? onCollapseTap;

  /// Called on pan gesture (for drag-to-reposition).
  final ValueChanged<DragUpdateDetails>? onPanUpdate;

  /// Called on pan end (for right-fling-to-hide detection).
  final ValueChanged<DragEndDetails>? onPanEnd;

  @override
  Widget build(BuildContext context) {
    return isCollapsed ? _buildEdgeBar(context) : _buildButton(context);
  }

  // FlyTerm brand green — matches the app's seed color and reads clearly
  // on top of any terminal palette (dark or light).
  static const _kGreen = Color(0xFF00C896);

  Widget _buildButton(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: opacity.clamp(0.0, 1.0),
        child: Container(
          width: 36,
          height: 36,
          decoration: const BoxDecoration(
            color: _kGreen,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
            ],
          ),
          child: Icon(
            isSftpMode ? Icons.terminal : Icons.folder_open,
            size: 20,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildEdgeBar(BuildContext context) {
    return GestureDetector(
      onTap: onCollapseTap,
      child: Container(
        width: 6,
        height: 48,
        decoration: const BoxDecoration(
          color: Color(0x6600C896), // 40% opacity green
          borderRadius:
              BorderRadius.horizontal(left: Radius.circular(3)),
        ),
      ),
    );
  }
}
