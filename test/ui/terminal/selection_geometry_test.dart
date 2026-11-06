import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/selection_geometry.dart';

void main() {
  group('cellColumnAt —— 吸附到最近的格边界', () {
    test('格中线之前吸附到左边界', () {
      expect(cellColumnAt(x: 4.0, cellWidth: 10.0), 0);
    });

    test('格中线之后吸附到右边界', () {
      expect(cellColumnAt(x: 6.0, cellWidth: 10.0), 1);
    });

    test('正好在中线上吸附到右边界', () {
      expect(cellColumnAt(x: 5.0, cellWidth: 10.0), 1);
    });

    test('负坐标夹到 0', () {
      expect(cellColumnAt(x: -30.0, cellWidth: 10.0), 0);
    });

    test('cellWidth 为 0 时返回 0 而不是抛除零', () {
      expect(cellColumnAt(x: 42.0, cellWidth: 0.0), 0);
    });
  });

  group('liftedTouchPoint —— 指尖上方偏移', () {
    test('正常情况作用点在指尖上方一行', () {
      final p = liftedTouchPoint(
        finger: const Offset(100, 200),
        grabOffset: Offset.zero,
        cellHeight: 20,
        wasFlipped: false,
      );
      expect(p.point.dy, 180);
      expect(p.flipped, isFalse);
    });

    test('抓取偏移被叠加', () {
      final p = liftedTouchPoint(
        finger: const Offset(100, 200),
        grabOffset: const Offset(5, -3),
        cellHeight: 20,
        wasFlipped: false,
      );
      expect(p.point.dx, 105);
      expect(p.point.dy, 177);
    });

    test('作用点越过顶部时翻到指尖下方', () {
      final p = liftedTouchPoint(
        finger: const Offset(100, 10),
        grabOffset: Offset.zero,
        cellHeight: 20,
        wasFlipped: false,
      );
      expect(p.flipped, isTrue);
      expect(p.point.dy, 30);
    });

    test('已翻转且落在迟滞带内时保持翻转', () {
      // base.dy=25 → up.dy=5，越过了下翻边界（cellHeight=20）但不足 8px
      // 余量，正好落在迟滞带 [20, 28) 内 → 保持翻转
      final p = liftedTouchPoint(
        finger: const Offset(100, 25),
        grabOffset: Offset.zero,
        cellHeight: 20,
        wasFlipped: true,
      );
      expect(p.flipped, isTrue);
    });

    test('恰好在迟滞带上沿时翻回上方', () {
      // base.dy=28 → up.dy=8，8 >= kFlipHysteresis → 翻回
      final p = liftedTouchPoint(
        finger: const Offset(100, 28),
        grabOffset: Offset.zero,
        cellHeight: 20,
        wasFlipped: true,
      );
      expect(p.flipped, isFalse);
      expect(p.point.dy, 8);
    });

    test('迟滞带宽度与 cellHeight 无关，恒为 8px', () {
      // cellHeight 翻倍到 40，迟滞带仍是 [40, 48)。base.dy=45 → up.dy=5
      // → 保持翻转；若阈值错写成 cellHeight+8，这里会要求 base.dy>=88。
      final inBand = liftedTouchPoint(
        finger: const Offset(100, 45),
        grabOffset: Offset.zero,
        cellHeight: 40,
        wasFlipped: true,
      );
      expect(inBand.flipped, isTrue);

      final aboveBand = liftedTouchPoint(
        finger: const Offset(100, 48),
        grabOffset: Offset.zero,
        cellHeight: 40,
        wasFlipped: true,
      );
      expect(aboveBand.flipped, isFalse);
    });

    test('已翻转且余量足够时翻回上方', () {
      final p = liftedTouchPoint(
        finger: const Offset(100, 200),
        grabOffset: Offset.zero,
        cellHeight: 20,
        wasFlipped: true,
      );
      expect(p.flipped, isFalse);
      expect(p.point.dy, 180);
    });
  });

  /// 命中判定以**圆点中心**为圆心，不是锚点。
  ///
  /// 锚点是文本边缘，圆点画在锚点之外 kHandleDotCenterOffset(26dp)。以锚点
  /// 为圆心时，圆点中心本身就在 26dp 外，32dp 半径只剩 6dp 容错 —— 手指比
  /// 圆点中心高一点就脱靶，返回 null，这一按被判成普通 tap，而 tap 会退出
  /// 选区。真机症状是"手柄一碰就没"。
  group('nearestHandle', () {
    // 一个横跨两行的选区：start 锚点在 (100,100)，end 锚点在 (300,140)。
    const start = Offset(100, 100);
    const end = Offset(300, 140);

    // start 圆点在锚点上方 26，end 圆点在锚点下方 26。
    const startDot = Offset(100, 100 - kHandleDotCenterOffset);
    const endDot = Offset(300, 140 + kHandleDotCenterOffset);

    test('按在 start 圆点中心 → 命中 start', () {
      expect(
        nearestHandle(touch: startDot, start: start, end: end),
        HandleHit.start,
      );
    });

    test('按在 end 圆点中心 → 命中 end', () {
      expect(
        nearestHandle(touch: endDot, start: start, end: end),
        HandleHit.end,
      );
    });

    // 这条是"一碰就没"的回归护栏。指尖很难正落在圆点中心，通常偏上或偏下
    // 几 dp；以锚点为圆心的旧实现里，偏上 6dp 就正好落在 32dp 边界外。
    test('按在 start 圆点上沿偏外 10dp 仍命中 —— 旧实现在这里脱靶', () {
      // 偏移量取 10 是有讲究的：以锚点为圆心的旧实现里，触点距锚点
      // 26+10=36 > 32，恰好脱靶。取 6 抓不住 —— 那时距锚点正好 32，
      // `ds > radius` 是 32 > 32 = false，仍算命中。旧实现的容错就只有
      // 这 6dp，多 1dp 就没了。
      expect(
        nearestHandle(
          touch: startDot - const Offset(0, 10),
          start: start,
          end: end,
        ),
        HandleHit.start,
      );
    });

    test('按在 end 圆点下沿（比中心低 6dp）仍命中', () {
      expect(
        nearestHandle(
          touch: endDot + const Offset(0, 6),
          start: start,
          end: end,
        ),
        HandleHit.end,
      );
    });

    test('按在锚点（文本边缘）也算命中 —— 26dp 在半径内', () {
      expect(
        nearestHandle(touch: start, start: start, end: end),
        HandleHit.start,
      );
    });

    test('按在选区中间的空白处 → 两端都够不着，返回 null', () {
      expect(
        nearestHandle(touch: const Offset(200, 120), start: start, end: end),
        isNull,
      );
    });

    test('两端都在半径外时返回 null', () {
      expect(
        nearestHandle(touch: const Offset(800, 800), start: start, end: end),
        isNull,
      );
    });

    test('恰好落在半径上算命中', () {
      expect(
        nearestHandle(
          touch: startDot + const Offset(kHandleGrabRadius, 0),
          start: start,
          end: end,
        ),
        HandleHit.start,
      );
    });

    test('离两端一样近时优先 start', () {
      final mid = Offset(
        (startDot.dx + endDot.dx) / 2,
        (startDot.dy + endDot.dy) / 2,
      );
      // 把半径放大到足以同时够到两端，验证并列时的取舍。
      expect(
        nearestHandle(touch: mid, start: start, end: end, radius: 1000),
        HandleHit.start,
      );
    });
  });
}
