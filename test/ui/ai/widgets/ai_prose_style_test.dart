import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/ai/widgets/code_block.dart';

/// `aiProseStyle` 的标题字号守卫。
///
/// 背景：这份样式表是 `MarkdownStyleSheet.fromTheme(...)` 加 `copyWith`，而
/// `fromTheme` 会把 h1 映射到 `headlineSmall`（24px）、h2 到 `titleLarge`
/// （22px）。正文只有 12.5px，所以**漏覆盖任何一级标题都会让它比正文大一倍
/// 以上**，在手机窄屏上一行标题就吃掉半屏。2026-09-08 真机截图就是这么暴露
/// 出来的（模型回了一段带 `##` 小标题的说明，用户指认「文字大小不合适」）。
///
/// 这条测试守的不是某个具体数字，而是「六级标题都被显式覆盖过，且与正文的
/// 比例还在手机能看的范围内」。
void main() {
  Future<MarkdownStyleSheet> styleOf(WidgetTester t) async {
    MarkdownStyleSheet? s;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            s = aiProseStyle(ctx);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return s!;
  }

  testWidgets('六级标题全部被显式覆盖，没有一级漏给 fromTheme', (t) async {
    final s = await styleOf(t);
    final levels = <String, TextStyle?>{
      'h1': s.h1,
      'h2': s.h2,
      'h3': s.h3,
      'h4': s.h4,
      'h5': s.h5,
      'h6': s.h6,
    };
    for (final e in levels.entries) {
      expect(
        e.value?.fontSize,
        isNotNull,
        reason: '${e.key} 没有显式 fontSize，会退回 fromTheme 的桌面级字号',
      );
    }
  });

  testWidgets('标题字号不超过正文的 1.3 倍 —— 层级靠字重表达，不靠字号', (t) async {
    final s = await styleOf(t);
    final p = s.p!.fontSize!;
    final levels = <String, TextStyle?>{
      'h1': s.h1,
      'h2': s.h2,
      'h3': s.h3,
      'h4': s.h4,
      'h5': s.h5,
      'h6': s.h6,
    };
    for (final e in levels.entries) {
      expect(
        e.value!.fontSize!,
        lessThanOrEqualTo(p * 1.3),
        reason:
            '${e.key} 是 ${e.value!.fontSize}，正文是 $p —— '
            '手机窄屏上比例超过 1.3 就会把正文挤出屏幕',
      );
    }
  });

  testWidgets('标题仍然比正文重，层级不至于消失', (t) async {
    final s = await styleOf(t);
    for (final h in [s.h1, s.h2, s.h3]) {
      expect(h!.fontWeight, isNotNull);
      expect(
        h.fontWeight!.index,
        greaterThan(FontWeight.w400.index),
        reason: '字号压下来之后，层级全靠字重，不能连字重也没有',
      );
    }
  });

  // ───────────────────────────────────────────────────────────────────
  // 以下是「同一个 bug 类的第三次、第四次」的守卫。
  //
  // 标题（2026-09-08）、表格（2026-09-13）都被真机截图暴露过同一件事：
  // `fromTheme` 的默认值是给**桌面 + 浅色主题**调的，比正文大一圈，
  // 漏覆盖哪一类，哪一类就会在手机上「胖」出来。
  //
  // 逐个元素地补不够 —— 要把它变成一条可检验的不变式：
  // **所有与正文并排出现的元素，字号都不得超过正文。**
  // 这样下次升级库、库新增一类默认值时，这条测试会直接拦住。
  // ───────────────────────────────────────────────────────────────────

  testWidgets('正文级元素（列表/勾选框/引用/表格）不得比正文大', (t) async {
    final s = await styleOf(t);
    final body = s.p!.fontSize!;

    final bodyLevel = <String, TextStyle?>{
      'listBullet': s.listBullet,
      'checkbox': s.checkbox,
      'blockquote': s.blockquote,
      'tableHead': s.tableHead,
      'tableBody': s.tableBody,
    };

    for (final e in bodyLevel.entries) {
      expect(
        e.value?.fontSize,
        isNotNull,
        reason:
            '${e.key} 没有显式 fontSize —— 会退回 fromTheme 的桌面级默认值'
            '（这正是标题/表格那两次真机问题的成因）',
      );
      expect(
        e.value!.fontSize!,
        lessThanOrEqualTo(body),
        reason:
            '${e.key} 是 ${e.value!.fontSize}，比正文 $body 还大 —— '
            '它和正文并排出现，大一圈会让那段内容「胖」出来',
      );
    }
  });

  testWidgets('列表缩进不得是桌面级的 24', (t) async {
    final s = await styleOf(t);
    // 24 是库默认（给桌面宽的）。手机窄屏一行只有三十来个字，
    // 24 的缩进 + 项目符号 + 项目符号间距会把正文可用宽度压掉一截。
    expect(
      s.listIndent,
      lessThan(24),
      reason: '列表缩进 ${s.listIndent} 是桌面值，手机上会挤掉正文宽度',
    );
  });

  testWidgets('表格列宽是可滚动的类型 —— 否则宽表会被压成一字一行', (t) async {
    final s = await styleOf(t);
    // 库只在 `FixedColumnWidth` / `IntrinsicColumnWidth` 下才给表格包
    // 横向滚动（见 `builder.dart` 的 `tag == 'table'` 分支）。默认的
    // `FlexColumnWidth` 不触发 —— 窄屏上等分列宽会把每列压到只剩几个字。
    expect(
      s.tableColumnWidth,
      anyOf(isA<IntrinsicColumnWidth>(), isA<FixedColumnWidth>()),
      reason:
          '列宽是 ${s.tableColumnWidth?.runtimeType} —— 库不会为它包横向'
          '滚动，模型输出三四列对比表时会挤成一团',
    );
  });

  testWidgets('表格不画滚动条 —— 滚动靠手势，不靠条', (t) async {
    final s = await styleOf(t);
    // 不设这个值时走 Flutter 默认：Android 上是 4px 粗、无圆角的直角条，
    // 且只在滚动时突然冒出来，压在 12.5px 正文旁边比正文还扎眼。
    //
    // **关掉它不影响滚动能力** —— 库仍包着 SingleChildScrollView。
    // 这两件事必须分开：能力（能不能拖）和外观（画不画条）。
    expect(
      s.tableScrollbarThumbVisibility,
      isFalse,
      reason:
          '表格又画出滚动条了 —— 移动端横向滚动靠手势，'
          '常显的直角粗条与整体圆角语汇冲突',
    );
  });

  testWidgets('滚动能力与滚动条是两个独立开关 —— 别为了去条把滚动也关了', (t) async {
    final s = await styleOf(t);
    // 这条把「可滚动」当成一个**必须保留的能力**钉住。
    //
    // 理由是可滚动严格占优：`IntrinsicColumnWidth` 下短标签表格（模型
    // 输出的主流）实际宽度小于屏宽，**根本不产生滚动** —— 与不可滚动完全
    // 一样；而长内容表格可以横拖读出。反过来不可滚动时，长内容会被压成
    // 「一个字一行」的竖条，用户会以为表格坏了。
    expect(
      s.tableColumnWidth,
      anyOf(isA<IntrinsicColumnWidth>(), isA<FixedColumnWidth>()),
      reason:
          '去滚动条的同时把可滚动的能力也去掉了 —— '
          '长内容表格会被压成一字一行的竖条',
    );
  });

  testWidgets('块间距跟着正文字号收过，不是桌面级的 8', (t) async {
    final s = await styleOf(t);
    // 8 是库默认（按 14px 正文调的）。正文降到 12.5 后，段间距显得空 ——
    // 与「信息密度优先」的立场相反。
    expect(
      s.blockSpacing,
      lessThan(8),
      reason: '块间距 ${s.blockSpacing} 偏松，一屏放不下多少内容',
    );
  });
}
