import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/ai/widgets/code_block.dart';

/// 表格**列宽分配**的分层守卫。
///
/// ## 背景：为什么这条测试测的是「列宽」而不是「滚动」
///
/// 一开始的假设是「宽表会溢出屏宽，所以要能滚动」。用真实布局引擎量下来
/// 发现这个假设不成立：`MarkdownBody` 给表格的可用宽度是有约束的，
/// **没有任何一种 `TableColumnWidth` 会让表格真的溢出屏宽** —— 实在放不下
/// 时 Flutter 压缩单元格。所以 326dp 可用宽下四种方案的总宽都是 326。
///
/// 于是真正的取舍变成「**列宽怎么分配**」，实测一张「短标签 + 一句话」的
/// 两列表：
///
/// | 方案                    | 短列  | 长列  |
/// |-------------------------|-------|-------|
/// | FlexColumnWidth（等分） | 147dp | 147dp |
/// | IntrinsicColumnWidth    |  39dp | 255dp |
/// | Intrinsic(flex: 1)      |  84dp | 211dp |
///
/// 裸 Intrinsic 让短列只剩 39dp（约 3 个中文字，字段名显示不全）——
/// 这就是用户说的「不好看」。等分虽然平衡，但长内容要多换一行（26 字：
/// 等分 3 行 vs 按内容 2 行）。
///
/// 选定 `IntrinsicColumnWidth(flex: 1)`：先按内容分宽（短列窄、长列宽），
/// 再把余量按 flex 均分（短列不至于被压垮）。
void main() {
  const avail = 336.0; // 360dp 屏 - 面板 padding 24（助手回答已无左侧色条）

  /// 量一张两列表下，短列与长列各自拿到的宽度。
  Future<(double, double)> columnWidths(
    WidgetTester t,
    TableColumnWidth cw,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: avail,
            child: Table(
              defaultColumnWidth: cw,
              children: [
                TableRow(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('原因', style: TextStyle(fontSize: 12.5)),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '防火墙拦截了 8080 端口的入站流量',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final a = t.getRect(find.text('原因'));
    final b = t.getRect(find.text('防火墙拦截了 8080 端口的入站流量'));
    return (a.width, b.width);
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('短列不得被压垮 —— 这是裸 Intrinsic 的老毛病', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final (short, _) = await columnWidths(
      t,
      const IntrinsicColumnWidth(flex: 1),
    );

    // 12.5px 一个字。40dp 只够放 3 个字，「原因」这类两字标签都悬，
    // 更别说「磁盘使用率」这种。裸 Intrinsic 实测就是 39dp。
    expect(
      short,
      greaterThan(60),
      reason:
          '短列只有 ${short.toStringAsFixed(1)}dp —— '
          '裸 IntrinsicColumnWidth 会这样（实测 39dp），flex 均分就是为了救它',
    );
  });

  testWidgets('长列比等分拿到更多宽度 —— 少换一行', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final (equShort, _) = await columnWidths(t, const FlexColumnWidth());
    final (_, long) = await columnWidths(
      t,
      const IntrinsicColumnWidth(flex: 1),
    );

    // 等分给长列 147dp（实测），按内容能给到 200dp 以上。
    // 多出来的宽度直接换成更少的换行 —— 26 字从 3 行降到 2 行。
    expect(
      long,
      greaterThan(equShort),
      reason:
          '长列 ${long.toStringAsFixed(1)}dp 不比等分 ${equShort.toStringAsFixed(1)}dp 宽，'
          '说明没按内容分配，长内容会白多换一行',
    );
  });

  testWidgets('选定的列宽类型必须能触发库的横向滚动兜底', (t) async {
    // 极端情况（列数很多且每列都长）仍要能横拖读出。库只在
    // `FixedColumnWidth` / `IntrinsicColumnWidth` 下包滚动包裹层 ——
    // 所以选型不能退化成 `FlexColumnWidth`，否则兜底能力一并丢失。
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
    expect(
      s!.tableColumnWidth,
      anyOf(isA<IntrinsicColumnWidth>(), isA<FixedColumnWidth>()),
      reason:
          '列宽类型是 ${s!.tableColumnWidth.runtimeType} —— '
          '库不会为它包横向滚动，极端宽的表读不出来了',
    );
  });

  testWidgets('列宽用 flex 均分 —— 不是裸 Intrinsic（flex 为 null）', (t) async {
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
    final cw = s!.tableColumnWidth! as IntrinsicColumnWidth;
    // flex 为 null 时余量不分给任何列 —— 实测短列会被压到 39dp。
    expect(
      cw.flex(const <RenderBox>[]),
      isNotNull,
      reason: 'flex 是 null，余量不分配 —— 短列会被长内容挤到只剩几个字宽',
    );
    expect(cw.flex(const <RenderBox>[]), greaterThan(0));
  });
}
