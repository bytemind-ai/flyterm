// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../ssh/session_manager.dart';
import 'split_manager.dart';
import 'terminal_widget.dart';

/// Picture-in-picture style overlay hosting a live terminal session.
///
/// Visual language matches the debug overlay: hairline white-15% border,
/// translucent title bar (black 60%), low elevation. Body stays fully
/// opaque so monospace text remains readable.
///
/// Title bar interactions:
///   • drag pan      — reposition window
///   • single tap    — promote this tab to primary, close float
///   • long-press    — close float (legacy power-user shortcut)
///   • ghost button  — toggle pointer-passthrough + 55% opacity
///   • close button  — explicit ✕ to dismiss
///
/// Bottom-right corner has a 16×16 resize handle. Size is stored in
/// SplitManager so toggling close/reopen preserves it within a session.
class FloatingTerminalWindow extends StatefulWidget {
  final SessionTab tab;
  final VoidCallback onExpand;
  final VoidCallback onClose;

  const FloatingTerminalWindow({
    super.key,
    required this.tab,
    required this.onExpand,
    required this.onClose,
  });

  static OverlayEntry createEntry({
    required BuildContext context,
    required SessionTab tab,
    required VoidCallback onExpand,
    required VoidCallback onClose,
  }) {
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => FloatingTerminalWindow(
        tab: tab,
        onExpand: onExpand,
        onClose: onClose,
      ),
    );
    return entry;
  }

  @override
  State<FloatingTerminalWindow> createState() =>
      _FloatingTerminalWindowState();
}

class _FloatingTerminalWindowState extends State<FloatingTerminalWindow>
    with WidgetsBindingObserver {
  Offset? _position;
  Size? _lastScreenSize;
  bool _ghost = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final mq = MediaQuery.of(context);
      final splitMgr = context.read<SplitManager>();
      final winW = mq.size.width * splitMgr.floatRatioW;
      final winH = mq.size.height * splitMgr.floatRatioH;
      final bottomInset = mq.viewInsets.bottom;
      setState(() {
        _lastScreenSize = mq.size;
        _position = Offset(
          mq.size.width - winW - 12,
          (mq.size.height - winH - 12 - bottomInset)
              .clamp(0.0, double.infinity),
        );
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-anchor the window when screen metrics change (rotation, resize).
  /// Preserve relative position rather than the absolute pixel offset
  /// so the window stays in roughly the same place after rotation.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = View.of(context);
    final newSize = view.physicalSize / view.devicePixelRatio;
    final old = _lastScreenSize;
    final pos = _position;
    if (pos == null || old == null) return;
    if ((newSize.width - old.width).abs() < 0.5 &&
        (newSize.height - old.height).abs() < 0.5) {
      return;
    }
    final relX = pos.dx / math.max(1.0, old.width);
    final relY = pos.dy / math.max(1.0, old.height);
    setState(() {
      _position = Offset(relX * newSize.width, relY * newSize.height);
      _lastScreenSize = newSize;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_position == null) return const SizedBox.shrink();

    final mq = MediaQuery.of(context);
    final splitMgr = context.watch<SplitManager>();
    final screenW = mq.size.width;
    final screenH = mq.size.height;
    final winW = screenW * splitMgr.floatRatioW;
    final winH = screenH * splitMgr.floatRatioH;
    final bottomInset = mq.viewInsets.bottom;

    final maxY = (screenH - winH - 12 - bottomInset)
        .clamp(0.0, double.infinity);

    if (maxY == 0 && bottomInset > screenH * 0.5) {
      return const SizedBox.shrink();
    }

    final clampedX = _position!.dx.clamp(0.0, screenW - winW);
    final clampedY = _position!.dy.clamp(0.0, maxY);
    final activeShell = widget.tab.moshShell ?? widget.tab.connection.shell;
    final isConnected = activeShell != null;

    final body = isConnected
        ? TerminalWidget(
            key: ValueKey('float_${widget.tab.id}'),
            terminal: widget.tab.terminal,
            shell: activeShell,
            transport: widget.tab.transport,
            isActive: false,
          )
        : Center(
            child: Text(context.l10n.floatingNotConnected,
                style: const TextStyle(color: Colors.white54)),
          );

    final card = Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      color: Colors.black,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.white.withAlpha(38),
            width: 1,
          ),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                _TitleBar(
                  isConnected: isConnected,
                  ghost: _ghost,
                  title: widget.tab.title,
                  onPan: (delta) => setState(() {
                    final newX =
                        (_position!.dx + delta.dx).clamp(0.0, screenW - winW);
                    final newY =
                        (_position!.dy + delta.dy).clamp(0.0, maxY);
                    _position = Offset(newX, newY);
                  }),
                  onTap: widget.onExpand,
                  onLongPress: widget.onClose,
                  onClose: widget.onClose,
                  onToggleGhost: () => setState(() => _ghost = !_ghost),
                ),
                Expanded(
                  child: _ghost
                      ? IgnorePointer(
                          child: Opacity(opacity: 0.55, child: body),
                        )
                      : body,
                ),
              ],
            ),
            // Bottom-right resize handle. 16×16 hit area; the visible
            // chevron sits in the corner so it reads as a handle.
            if (!_ghost)
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) {
                    final newW =
                        ((winW + d.delta.dx) / screenW).clamp(0.30, 0.95);
                    final newH =
                        ((winH + d.delta.dy) / screenH).clamp(0.20, 0.80);
                    splitMgr.setFloatRatio(newW, newH);
                  },
                  child: Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.bottomRight,
                    padding: const EdgeInsets.only(right: 2, bottom: 2),
                    child: Icon(
                      Icons.south_east,
                      size: 12,
                      color: Colors.white.withAlpha(120),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Positioned(
      left: clampedX,
      top: clampedY,
      width: winW,
      height: winH,
      child: card,
    );
  }
}

class _TitleBar extends StatelessWidget {
  final bool isConnected;
  final bool ghost;
  final String title;
  final ValueChanged<Offset> onPan;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onClose;
  final VoidCallback onToggleGhost;

  const _TitleBar({
    required this.isConnected,
    required this.ghost,
    required this.title,
    required this.onPan,
    required this.onTap,
    required this.onLongPress,
    required this.onClose,
    required this.onToggleGhost,
  });

  @override
  Widget build(BuildContext context) {
    final disconnectedTint = Colors.red.shade900.withAlpha(160);
    final connectedTint = Colors.black.withAlpha(160); // ~ black 60%
    return Container(
      height: 28,
      color: isConnected ? connectedTint : disconnectedTint,
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => onPan(d.delta),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      isConnected
                          ? title
                          : '$title · ${context.l10n.floatingDisconnected}',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(Icons.drag_handle,
                      size: 14, color: Colors.white.withAlpha(96)),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
          _IconAction(
            icon: ghost ? Icons.visibility_off : Icons.visibility_outlined,
            tooltip: ghost
                ? context.l10n.floatingExitGhostMode
                : context.l10n.floatingGhostMode,
            onTap: onToggleGhost,
            tintActive: ghost,
          ),
          _IconAction(
            icon: Icons.close,
            tooltip: context.l10n.close,
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool tintActive;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.tintActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        tintActive ? const Color(0xFF00C896) : Colors.white.withAlpha(160);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }
}
