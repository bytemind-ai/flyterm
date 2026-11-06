// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui';

/// 命中了哪个 handle。
enum HandleHit { start, end }

/// 指尖偏移的计算结果。
class LiftedPoint {
  const LiftedPoint({required this.point, required this.flipped});

  /// handle 的实际作用点。
  final Offset point;

  /// 是否翻到了指尖下方。调用方要把它存起来下次传回 `wasFlipped`。
  final bool flipped;
}

/// handle 的抓取半径（dp）。真机上可调。
const double kHandleGrabRadius = 32.0;

/// 圆点中心相对 handle 锚点的垂直距离：圆点半径 6 + 竖线 20 = 26dp。
///
/// start handle 的圆点在锚点**上方**（点在上、线在下，线的下端贴着文本上沿），
/// end handle 的圆点在锚点**下方**。命中判定必须用这个偏移把锚点换算成圆点
/// 中心 —— 见 [nearestHandle]。
///
/// 必须与 `selection_overlay.dart` 里 `_SelectionHandle` 的绘制保持一致：
/// `_dotRadius(6) + _lineHeight(20)`，也等于
/// `kSelectionHandleVisualHeight(32) - _dotRadius(6)`。
const double kHandleDotCenterOffset = 26.0;

/// 翻转迟滞（px）。防止作用点在视口顶部附近反复横跳。
const double kFlipHysteresis = 8.0;

/// 把像素横坐标 [x] 吸附到最近的格边界，返回列号。
///
/// ## 为什么是 round 而不是 floor / ceil
///
/// 旧实现两端用了不同的公式：start 端走 `RenderTerminal.getCellOffset`
/// （`render.dart:657`，`x ~/ cellWidth`，floor），end 端走
/// `getSelectionEndOffset`（`:673`，`(x / cellWidth).ceil()`）。
///
/// 后果是两端手感差整整一格，而且 end 端只要手指越过格左边界 1px 就跳整格 ——
/// 这就是"差一格 / 跳格"的直接来源。
///
/// round 让两端用同一个公式，且自带 ±0.5 格死区，不需要另加 hysteresis。
/// begin 取它作起始格索引、end 取它作结束边界索引（exclusive），语义各自
/// 成立而公式相同。
int cellColumnAt({required double x, required double cellWidth}) {
  if (cellWidth <= 0) return 0;
  final col = (x / cellWidth).round();
  return col < 0 ? 0 : col;
}

/// 算出 handle 的实际作用点：指尖上方一行，必要时翻到下方。
///
/// [grabOffset] 是按下瞬间 handle 锚点与指尖的差值。没有它，按下的一刻
/// handle 会瞬移到指尖，选区当场跳一下 —— 那是"差一格"的另一半成因。
///
/// [wasFlipped] 是上一帧的翻转状态，用来实现 [kFlipHysteresis] 迟滞。
///
/// ## 两条边界，中间夹 8px —— 标准的施密特触发器
///
/// 以 `base.dy`（指尖叠加抓取偏移后的位置）为准：
///
/// ```
///   base.dy:  0 ────────── cellHeight ── +8 ──────────────► 大
///                              │          │
///             ← 保持翻转 ──────┤          ├────── 保持不翻 →
///                              │          │
///                        下翻边界      上翻边界
/// ```
///
/// - 未翻转时，`up.dy < 0`（即 `base.dy < cellHeight`）就翻到下方 —— 作用点
///   跑出视口顶部了。
/// - 已翻转时，要翻回上方得满足 `up.dy >= kFlipHysteresis`（即
///   `base.dy >= cellHeight + 8`），比下翻边界高出 8px。
///
/// 迟滞带**恒为 8px**，与 `cellHeight` 无关。一度写成
/// `up.dy >= cellHeight + kFlipHysteresis`，那会让迟滞带变成
/// `cellHeight + 8`（真机上 28~48px），手感是"翻转粘住了"：用户从顶部往下
/// 拖将近两行，作用点才肯翻回上方。
///
/// 注意 `up.dy` 是作用点的**绝对位置**，不是这一帧的移动量 —— 拿它当位移
/// 读会把阈值推导带偏。
LiftedPoint liftedTouchPoint({
  required Offset finger,
  required Offset grabOffset,
  required double cellHeight,
  required bool wasFlipped,
}) {
  final base = finger + grabOffset;
  final up = Offset(base.dx, base.dy - cellHeight);
  final down = Offset(base.dx, base.dy + cellHeight);

  if (wasFlipped) {
    // 已经翻在下方：要回到上方，得有足够余量，否则在边界上反复横跳。
    if (up.dy >= kFlipHysteresis) {
      return LiftedPoint(point: up, flipped: false);
    }
    return LiftedPoint(point: down, flipped: true);
  }
  if (up.dy < 0) {
    return LiftedPoint(point: down, flipped: true);
  }
  return LiftedPoint(point: up, flipped: false);
}

/// 找出离 [touch] 最近且在 [radius] 内的 handle，都不在则返回 null。
///
/// 命中判定放在这里、由外层 Listener 调用，而不是让 handle widget 自己收
/// 事件：Flutter 不跨父边界 hit-test，而 handle 在视口边缘时它的命中框会被
/// clamp 出去，于是"画得出来但点不中"（旧 `selection_overlay.dart:140-157`
/// 那段自称 deliberate trade-off 的妥协）。
HandleHit? nearestHandle({
  required Offset touch,
  required Offset start,
  required Offset end,
  double radius = kHandleGrabRadius,
}) {
  // 以**圆点中心**为圆心，不是锚点。
  //
  // 锚点是文本边缘（start = 首个选中格的左上角，end = 末格的右下角），而用户
  // 真正伸手去按的圆点画在锚点之外 [kHandleDotCenterOffset]。以锚点为圆心时，
  // 圆点中心本身就已经在 26dp 外，32dp 的半径只剩 6dp 容错 —— 手指比圆点中心
  // 高 7dp 就脱靶，返回 null，于是这一按被 _onPointerUp 判成普通 tap，而 tap
  // 会退出选区。真机上的表现是"手柄一碰就没"。
  final startDot = Offset(start.dx, start.dy - kHandleDotCenterOffset);
  final endDot = Offset(end.dx, end.dy + kHandleDotCenterOffset);
  final ds = (touch - startDot).distance;
  final de = (touch - endDot).distance;
  if (ds > radius && de > radius) return null;
  return ds <= de ? HandleHit.start : HandleHit.end;
}
