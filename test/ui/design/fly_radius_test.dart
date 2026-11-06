import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';

/// `FlyRadius` 必须覆盖**现场真实存在的所有圆角语义**。
///
/// ## 这条测试拦的是什么
///
/// 改造前全站 6 档圆角（8/6/4/2/10/12），token 化时只定义了 3 档
/// （chip 2 / control 4 / panel 6）。结果是：**缺档的语义无处可去，只能继续
/// 手写数值** —— 实测 `circular(8)` 有 32 处、`circular(10)` 9 处、
/// `circular(12)` 5 处，`8` 用得比任何一个合法档位都多。
///
/// 那些 8/10/12 不是「违规」，而是**token 系统不完备的证据**：它们承载了
/// 小控件之外的语义（卡片、气泡）。所以修法是**补档**，不是把它们压到 6 ——
/// 强行压平会让对话气泡与卡片变得棱角分明，是视觉倒退而非优化。
///
/// 这条测试钉住「补档后的档位语义」，防止将来又有人把非控件圆角手写回去。
void main() {
  group('FlyRadius 档位完备性', () {
    test('三个原始档位保持不变（控件语汇不许动）', () {
      // 这三个是「专业仪表盘」立场的落点，改动等于换设计语言。
      expect(FlyRadius.chip, 2);
      expect(FlyRadius.control, 4);
      expect(FlyRadius.panel, 6);
    });

    test('补齐容器与气泡档位 —— 缺了它们手写值就会回流', () {
      // 卡片：设置页分组、审批卡、工具调用卡等。
      expect(FlyRadius.card, 8);
      // 对话气泡：用户/助手消息、附件预览。比卡片更圆是有意的 ——
      // 气泡是「说出来的话」，卡片是「装东西的盒子」，两者形态本就不同。
      expect(FlyRadius.bubble, 10);
    });

    test('档位严格递增，不允许出现重复值', () {
      // 重复值意味着两档其实是一档，那就不该有两个名字。
      final values = [
        FlyRadius.chip,
        FlyRadius.control,
        FlyRadius.panel,
        FlyRadius.card,
        FlyRadius.bubble,
      ];
      expect(values, orderedEquals([...values]..sort()));
      expect(values.toSet().length, values.length);
    });
  });

  group('预置 BorderRadius 常量与档位一致', () {
    // 调用点写 `FlyRadius.cardRadius` 而不是
    // `BorderRadius.circular(FlyRadius.card)` —— 少一层手写就少一次抄错。
    test('每个 double 档位都有对应的 BorderRadius', () {
      expect(FlyRadius.chipRadius.topLeft.x, FlyRadius.chip);
      expect(FlyRadius.controlRadius.topLeft.x, FlyRadius.control);
      expect(FlyRadius.panelRadius.topLeft.x, FlyRadius.panel);
      expect(FlyRadius.cardRadius.topLeft.x, FlyRadius.card);
      expect(FlyRadius.bubbleRadius.topLeft.x, FlyRadius.bubble);
    });
  });
}
