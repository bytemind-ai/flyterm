// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'selection_geometry.dart' show HandleHit;

/// Positions of the two selection handles, in TerminalWidget Stack-local
/// coordinates.
///
/// [start] is the top-left corner of the first selected cell; [end] is the
/// bottom-right edge of the last selected cell.
/// A handle's visual height: 12dp dot + 20dp line.
///
/// The floating menu needs this to clear the handles. The menu only avoids the
/// selection *anchor* — the text edge — but a handle is drawn on the far side
/// of that anchor, occupying this much space beyond it. Without the extra
/// clearance the menu lands right on top of the start handle's dot, and since
/// the menu is a later Stack child it wins the hit test: the finger meant for
/// the handle presses Copy instead, and the handle cannot be dragged at all.
const double kSelectionHandleVisualHeight = 32.0;

/// Positions of the two selection handles, in TerminalWidget Stack-local
/// coordinates.
///
/// [start] is the top-left corner of the first selected cell; [end] is the
/// bottom-right edge of the last selected cell.
class HandlePositions {
  const HandlePositions(this.start, this.end, {this.dragging = false});

  final Offset start;
  final Offset end;

  /// True while a handle is being dragged. The menu hides itself then: it
  /// would otherwise chase the moving handle around the screen, and it is
  /// useless mid-drag anyway.
  final bool dragging;

  static const zero = HandlePositions(Offset.zero, Offset.zero);

  /// `==` is load-bearing, not boilerplate: [ValueNotifier] only notifies when
  /// the new value differs, so without it every per-frame assignment during a
  /// handle drag would rebuild the overlay even when nothing moved.
  @override
  bool operator ==(Object other) =>
      other is HandlePositions &&
      other.start == start &&
      other.end == end &&
      other.dragging == dragging;

  @override
  int get hashCode => Object.hash(start, end, dragging);

  @override
  String toString() => 'HandlePositions($start, $end, dragging: $dragging)';
}

class TerminalSelectionOverlay extends StatelessWidget {
  const TerminalSelectionOverlay({
    super.key,
    required this.handles,
    required this.onCopy,
    required this.onHandleGrab,
    required this.onHandleMove,
    required this.onHandleRelease,
  });

  /// Handle positions. A [ValueListenable] rather than a plain [Offset] pair:
  /// during a drag these change every frame, and passing values would rebuild
  /// the whole TerminalWidget (TerminalView subtree included) each time — the
  /// main cause of drag jank. Subscribing keeps the repaint to this layer.
  final ValueListenable<HandlePositions> handles;

  final VoidCallback onCopy;

  /// 手指按住了某个 handle（全局坐标）。handle 自己收事件是第一道命中，
  /// 外层 Listener 的 `nearestHandle` 是边缘情况的兜底 —— 见 [_SelectionHandle]。
  final void Function(HandleHit which, Offset globalPosition) onHandleGrab;

  /// 拖拽中（全局坐标）。
  final void Function(Offset globalPosition) onHandleMove;

  /// 抬手或取消。
  final VoidCallback onHandleRelease;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HandlePositions>(
      valueListenable: handles,
      builder: (context, pos, _) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Floating toolbar — same component the long-press menu uses.
            // Hidden mid-drag; see HandlePositions.dragging.
            if (!pos.dragging)
              TerminalFloatingMenu(
                anchor: Rect.fromPoints(pos.start, pos.end),
                // Clear the handle itself, not just the text edge — see
                // kSelectionHandleVisualHeight. The long-press menu keeps the
                // default because it has no handles to avoid.
                clearance: kSelectionHandleVisualHeight + 8.0,
                actions: [
                  TerminalMenuAction(
                    icon: Icons.copy,
                    label: context.l10n.selectionCopy,
                    onTap: onCopy,
                  ),
                ],
              ),
            // Start handle (circle on top, line downward)
            _SelectionHandle(
              key: const ValueKey('start_handle'),
              position: pos.start,
              isStart: true,
              onGrab: (g) => onHandleGrab(HandleHit.start, g),
              onMove: onHandleMove,
              onRelease: onHandleRelease,
            ),
            // End handle (line upward, circle on bottom)
            _SelectionHandle(
              key: const ValueKey('end_handle'),
              position: pos.end,
              isStart: false,
              onGrab: (g) => onHandleGrab(HandleHit.end, g),
              onMove: onHandleMove,
              onRelease: onHandleRelease,
            ),
          ],
        );
      },
    );
  }
}

class _SelectionHandle extends StatelessWidget {
  const _SelectionHandle({
    super.key,
    required this.position,
    required this.isStart,
    required this.onGrab,
    required this.onMove,
    required this.onRelease,
  });

  final Offset position;
  final bool isStart;

  /// 手指按在 handle 上（全局坐标）。
  final void Function(Offset globalPosition) onGrab;

  /// 拖拽中（全局坐标）。
  final void Function(Offset globalPosition) onMove;

  /// 抬手或取消。
  final VoidCallback onRelease;

  // 圆点中心距锚点 = _dotRadius + _lineHeight = 26dp。命中判定依赖这个值
  // （selection_geometry.dart 的 kHandleDotCenterOffset），改这里必须同步改
  // 那里，否则会回到"画得出来但按不中、一碰就退出选区"的老问题。
  static const double _dotRadius = 6.0; // 12dp diameter
  static const double _lineWidth = 2.0;
  static const double _lineHeight = 20.0;
  static const double _hitSize = 44.0; // Material touch target

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    // The visual widget: dot + line
    // isStart: dot above, line below. isEnd: line above, dot below.
    final visual = Column(
      mainAxisSize: MainAxisSize.min,
      children:
          isStart
              ? [
                _Dot(radius: _dotRadius, color: color),
                _Line(width: _lineWidth, height: _lineHeight, color: color),
              ]
              : [
                _Line(width: _lineWidth, height: _lineHeight, color: color),
                _Dot(radius: _dotRadius, color: color),
              ],
    );

    // Visual height = dot diameter + line height = 12 + 20 = 32dp.
    // For start handle: position is top-left of first selected cell.
    //   → place visual so line bottom aligns with position.dy (text top edge).
    //   → top = position.dy - visualHeight, centered horizontally on position.dx.
    // For end handle: position is bottom-right edge of last selected cell.
    //   → place visual so line top aligns with position.dy (text bottom edge).
    //   → top = position.dy, centered horizontally on position.dx.
    const visualHeight = _dotRadius * 2 + _lineHeight; // 32dp
    final top = isStart ? position.dy - visualHeight : position.dy;

    // 不再 clamp 命中框。旧代码把 44x44 的框硬塞进 overlay 边界，代价是靠近
    // 视口边缘时 handle 会漂离真实锚点将近 38px。
    //
    // ## 两道命中，缺一不可
    //
    // 这层自己收指针事件（opaque），**同时**外层 Listener 还有一道按距离算的
    // 兜底（`selection_geometry.dart` 的 `nearestHandle`）。两者不冲突：Stack
    // 的 hit test 是 topmost-first，命中这里就不会再往下传给外层。
    //
    // 为什么两道都要：
    //   • 只靠这一道 —— Flutter 不跨父边界 hit-test，handle 画在视口边缘外时
    //     这个框收不到事件，于是"画得出来但点不中"。
    //   • 只靠外层那道 —— 判定纯靠距离算，一旦算歪（圆心取错、半径不够）就
    //     返回 null，那一按被当成普通 tap，而 tap 会退出选区。真机症状是
    //     "手柄一碰就没"。master 上从来没这个毛病，正因为它的 handle 自己吃
    //     事件，外层压根收不到，物理上不可能误判。
    //
    // 所以：正常情况走这一道（物理隔离，最稳），边缘情况由外层兜底。
    return Positioned(
      left: position.dx - _hitSize / 2,
      top: top - (_hitSize - visualHeight) / 2,
      width: _hitSize,
      height: _hitSize,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => onGrab(e.position),
        onPointerMove: (e) => onMove(e.position),
        onPointerUp: (_) => onRelease(),
        onPointerCancel: (_) => onRelease(),
        child: Center(child: visual),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.radius, required this.color});
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.width, required this.height, required this.color});
  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: width, height: height, color: color);
  }
}

/// One action in a [TerminalFloatingMenu].
class TerminalMenuAction {
  const TerminalMenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// A floating menu bar anchored to [anchor]: centred horizontally on it,
/// placed above it when there is room and flipped below it otherwise, and
/// clamped inside the overlay it fills.
///
/// Positioning uses the framework's measure-then-position pattern
/// (`CustomSingleChildLayout`, as used by `Tooltip` and the text-selection
/// toolbar) so the clamp is computed from the menu's REAL rendered size —
/// not an estimate — which matters once labels are arbitrary l10n strings
/// of varying width.
///
/// Used for BOTH the long-press menu (anchor = a zero-size rect at the
/// finger) and the selection toolbar (anchor = the box spanning the two
/// selection handles), so the two share one positioning implementation and
/// one visual style rather than drifting apart.
class TerminalFloatingMenu extends StatelessWidget {
  TerminalFloatingMenu({
    super.key,
    required this.anchor,
    required this.actions,
    this.clearance = 8.0,
  }) : assert(actions.isNotEmpty, 'TerminalFloatingMenu needs >=1 action');

  /// Rectangle the menu must avoid, in overlay-local coordinates.
  final Rect anchor;

  /// Gap between [anchor] and the menu, on whichever side the menu lands.
  ///
  /// The selection toolbar passes a much larger value than the default: its
  /// anchor is the pair of handle *anchor points*, but each handle is drawn
  /// [kSelectionHandleVisualHeight] beyond that point, so a small gap puts the
  /// menu straight on top of the handle and steals its taps.
  final double clearance;

  final List<TerminalMenuAction> actions;

  static final ButtonStyle _buttonStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _FloatingMenuLayout(anchor: anchor, clearance: clearance),
        child: Material(
          key: const ValueKey('floating_menu_body'),
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in actions)
                TextButton.icon(
                  onPressed: action.onTap,
                  icon: Icon(action.icon, size: 16),
                  label: Text(action.label,
                      style: const TextStyle(fontSize: 13)),
                  style: _buttonStyle,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingMenuLayout extends SingleChildLayoutDelegate {
  const _FloatingMenuLayout({required this.anchor, this.clearance = 8.0});

  final Rect anchor;
  final double clearance;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Prefer above the anchor; flip below when there is no room.
    final preferredTop = anchor.top - childSize.height - clearance;
    final top = preferredTop < 0 ? anchor.bottom + clearance : preferredTop;
    final maxLeft =
        (size.width - childSize.width - 4.0).clamp(4.0, double.infinity);
    final maxTop =
        (size.height - childSize.height).clamp(0.0, double.infinity);
    return Offset(
      (anchor.center.dx - childSize.width / 2).clamp(4.0, maxLeft),
      top.clamp(0.0, maxTop),
    );
  }

  @override
  bool shouldRelayout(_FloatingMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.clearance != clearance;
}
