import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';

/// AI 面板的**装饰色彩**契约。
///
/// ## 背景
///
/// 这组 token 是 2026-10 按用户要求加的（原话「想加色彩」）。本文件顶部的
/// 立场是「颜色只编码状态，不做装饰」—— 两者是有张力的，而且产品历史上
/// 因为「凭空加色彩」翻过一次车（iOS 弯路，用户实测「不是 FlyTerm 了」）。
///
/// 所以这组色不追求「符合原立场」，只追求三件可验证的事：
/// 1. 每个色相**互相可辨**（不然「加色彩」没解决任何问题）
/// 2. 填充/描边有**层级差**（描边必须比填充显眼，否则边界看不出来）
/// 3. 色相**不搬用状态色**（`danger` 的红不能拿来当装饰，否则用户会把
///    「装饰」读成「出错了」）
void main() {
  const tints = {
    'blue': FlyColors.tintBlue,
    'violet': FlyColors.tintViolet,
    'cyan': FlyColors.tintCyan,
    'sky': FlyColors.tintSky,
    'amber': FlyColors.tintAmber,
  };

  group('装饰色相可辨性', () {
    test('所有装饰色都是不透明色（底色上不能靠 alpha 偷懒）', () {
      for (final entry in tints.entries) {
        expect(
          entry.value.a,
          1.0,
          reason: '${entry.key} 应当是实色，透明度交给 tintFill/tintBorder 管',
        );
      }
    });

    test('任意两个装饰色的 RGB 距离足够大 —— 否则扫读区分不出来', () {
      final entries = tints.entries.toList();
      for (var i = 0; i < entries.length; i++) {
        for (var j = i + 1; j < entries.length; j++) {
          final a = entries[i].value;
          final b = entries[j].value;
          // 用分量平方和开方。阈值 0.25（归一化）是「两个色块并排看时
          // 能立刻分辨」的经验下限；再低就会变成「好像差不多」。
          final dr = (a.r - b.r);
          final dg = (a.g - b.g);
          final db = (a.b - b.b);
          final distance = (dr * dr + dg * dg + db * db) / 3.0; // 归一化到 0..1
          expect(
            distance,
            greaterThan(0.02),
            reason:
                '${entries[i].key} 与 ${entries[j].key} 太接近，'
                '用户区分不出这两种事件类型',
          );
        }
      }
    });
  });

  group('填充与描边的层级差', () {
    test('描边比填充显眼 —— 否则卡片边界消失', () {
      for (final entry in tints.entries) {
        final fill = FlyColors.tintFill(entry.value);
        final border = FlyColors.tintBorder(entry.value);
        expect(
          border.a,
          greaterThan(fill.a),
          reason: '${entry.key} 的描边不比填充浓，边界会看不出来',
        );
      }
    });

    test('填充足够淡，不压过卡上文字', () {
      for (final entry in tints.entries) {
        final fill = FlyColors.tintFill(entry.value);
        // 10% 上下是「能看出染色但不吃掉对比度」的范围。上限放到 0.2
        // 给将来微调留空间，但不能到「实色块」那种程度。
        expect(fill.a, lessThan(0.2), reason: '${entry.key} 的填充太浓，会压过卡片上的正文');
        expect(fill.a, greaterThan(0.04), reason: '${entry.key} 的填充太淡，等于没加色彩');
      }
    });
  });

  group('不与状态色撞车', () {
    test('装饰色不得复用 danger / active / pending 的色值', () {
      // 这条是防止「为了方便直接拿状态色当装饰」：那样用户看到蓝绿色的
      // 卡片会以为「这是成功状态」，而它其实只是一类事件的底色。
      final reserved = {
        'danger': FlyColors.danger,
        'active': FlyColors.active,
        'pending': FlyColors.pending,
      };
      for (final t in tints.entries) {
        for (final r in reserved.entries) {
          expect(
            t.value.toARGB32(),
            isNot(r.value.toARGB32()),
            reason:
                '装饰色 ${t.key} 与状态色 ${r.key} 同值 —— '
                '用户会把装饰读成状态',
          );
        }
      }
    });
  });
}
