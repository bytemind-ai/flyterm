// 输入框高度的基线矩阵。
//
// 目的：`fly_tokens.dart` 的 `inputDecorationTheme` 一改，全 app 所有
// **没有自己写 contentPadding** 的输入框高度都会跟着变。没有这份矩阵就
// 无法回答「这次改动是让它们更一致了，还是更散了」。
//
// 这些数字是**实测**的，不是估的 —— 所以将来 Flutter 改了 InputDecorator
// 的默认值、或 token 被误改，这条测试会红。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ui/design/fly_tokens.dart';

  /// 全 app 输入框的**标准高度**。
///
/// 由 `fly_tokens.dart` 的 `inputDecorationTheme.contentPadding` 决定
/// （`vertical: FlySpace.sm` = 8，`isDense: true`，`filled: true`）。
///
/// 2026-10-13：从 44 → 40。当时的动机是 AI 面板底部输入框被单独压到
/// 40dp、成了全 app 最矮的一档，跨页跳转时那个差异看得出来。与其把 AI
/// 那个改回去，不如把标准整体收紧一次 —— 「底部寸土寸金」对其它页面
/// 同样成立。
const kStandardFieldHeight = 40.0;


void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildFlyTermTheme(),
        home: Scaffold(body: Center(child: child)),
      );

  Future<double> h(WidgetTester t, InputDecoration d) async {
    await t.pumpWidget(wrap(SizedBox(width: 300, child: TextField(decoration: d))));
    await t.pumpAndSettle();
    return t.getRect(find.byType(TextField)).height;
  }

  testWidgets('theme 默认（不覆盖任何 decoration）就是标准高度', (t) async {
    // 不传 contentPadding / border / isDense —— 全部由 theme 决定。
    // 这是「全 app 主流输入框」的高度，其它形态都应当**向它看齐**，
    // 而不是各自调数字。
    final themeDefault = await h(t, const InputDecoration(hintText: 'hint'));

    expect(themeDefault, equals(kStandardFieldHeight),
        reason: '全局标准。改了 token 就要同步改这个常量 —— '
            '它是「其它输入框该向谁看齐」的唯一答案');
  });

  testWidgets('AI 面板底部输入框与标准同高（a+b 两类不协调的根治）', (t) async {
    // AI 那个刻意保留胶囊形圆角（对话 UI 的设计语言），但**高度**必须与
    // 全局标准一致 —— 否则它旁边的 40dp 图标按钮会对不齐，跨页跳转时
    // 也会觉得那个输入框"矮了一截"。
    //
    // 圆角从一个显式值改成 `FlyRadius.pill`（见 panel_chrome.dart）：
    // 它不再是"某个页面自己调的 24"，而是 token 里命名的一档。
    final ai = await h(
        t,
        const InputDecoration(
          hintText: 'hint',
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: FlyRadius.pillRadius,
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: FlySpace.lg,
            vertical: FlySpace.sm,
          ),
        ));

    expect(ai, equals(kStandardFieldHeight),
        reason: 'AI 输入框必须与全局标准同高，只允许圆角不同');
  });

  testWidgets('自己写 contentPadding 会破坏一致性（那 27 处的遗留形态）',
      (t) async {
    // 复现「各自为政」：同样 isDense，只因为多写了一个 contentPadding，
    // 高度就与标准不同。这条测试**故意钉住这个不一致仍然存在** ——
    // 它是待还的技术债清单的一部分，不是期望行为。
    //
    // 还债方式：删掉那些覆盖、交给 theme，而不是把它们逐个调到 8。
    final withOwn = await h(
        t,
        const InputDecoration(
          hintText: 'hint',
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ));

    expect(withOwn, isNot(equals(kStandardFieldHeight)),
        reason: '与标准不同 —— 这正是「输入框看着不协调」的机制。'
            '这条红了说明有人把它调齐了，那是好事：把这条测试删掉');
  });
  _searchFieldGroup();
}

// ---------------------------------------------------------------------------
// 搜索框：统一形态（2026-10-13）
// ---------------------------------------------------------------------------

/// 全 app 搜索框的高度审计与回归。
///
/// ## 改动前为什么需要这件事
///
/// 4 个搜索框，4 种高度。两个各自为政的旋钮：
///
/// | 搜索框 | 改前 | 主因 |
/// |---|---|---|
/// | AI 历史会话 | 48dp | `prefixIcon` 默认 48 触摸区撑高 |
/// | 服务器/隧道 | 38dp | `contentPadding.vertical: 7` 压低 |
/// | SFTP | 36dp | AppBar 内固定高度（**刻意的例外**） |
/// | 终端 | 40dp | 恰好写对 |
///
/// 统一到 `searchFieldDecoration` 之后，页面级的三个都是 40dp。
void _searchFieldGroup() {
  Future<double> measure(WidgetTester t, InputDecoration d) async {
    await t.pumpWidget(MaterialApp(
      theme: buildFlyTermTheme(),
      home: Scaffold(
        body: Center(child: SizedBox(width: 360, child: TextField(decoration: d))),
      ),
    ));
    await t.pumpAndSettle();
    return t.getRect(find.byType(TextField)).height;
  }

  testWidgets('带图标与清除按钮的搜索框仍是标准高度', (t) async {
    // 这是改动前最坏的一格：48dp。`IconButton` 自带 48×48 的
    // minimumSize，外层给 `suffixIconConstraints` 也拦不住 ——
    // `searchFieldDecoration` 内部把 constraints / visualDensity /
    // padding 都设对了。
    //
    // **必须用 `onClear` 而不是自己传 `suffixIcon`。** 后者会拿到默认
    // 48 的 IconButton，把框撑高。这条测试构造的是**真实页面的装法**，
    // 所以页面改坏了它就会红（试过：把 session_history_view 改回自己传
    // suffixIcon，本条立刻失败）。
    final withIcons = await measure(
        t,
        searchFieldDecoration(
          hintText: 'h',
          prefixIcon: const Icon(Icons.search, size: 18),
          onClear: () {},
        ));

    expect(withIcons, equals(kStandardFieldHeight),
        reason: '图标与清除按钮不该把搜索框撑高');
  });

  testWidgets('自己传 suffixIcon 的 IconButton 会撑高 —— 钉住这个陷阱',
      (t) async {
    // 反面教材：这是「看起来等价、实际撑高 8dp」的写法。
    // 留着它，是为了让下一个人改坏了能一眼看出差别在哪。
    final wrong = await measure(
        t,
        InputDecoration(
          hintText: 'h',
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints: kSearchIconConstraints,
          suffixIcon: IconButton(
            icon: const Icon(Icons.clear, size: 18),
            onPressed: () {},
          ),
          suffixIconConstraints: kSearchIconConstraints,
        ));

    expect(wrong, isNot(equals(kStandardFieldHeight)),
        reason: 'IconButton 自带 48 minimumSize，会撑高。'
            '这条红了说明 Flutter 行为变了（那是好事，可以把这条删掉）');
  });

  test('真实页面都在用 onClear，而不是自己传 suffixIcon（源码级断言）',
      () async {
    // 上面几条测的是 `searchFieldDecoration` 这个**函数**的行为；
    // 这条测的是「页面真的在用它、且没有绕过去自己塞 IconButton」。
    //
    // 两者是不同的事：函数对而页面不用它，结果一样是错的。而 widget
    // 测试很难断言这一点（要起整个页面、还要触发搜索态才有清除按钮），
    // 所以直接读源码 —— 这个仓库没有更好的机制，而这是最后一道闸。
    final offenders = <String>[];
    for (final path in const [
      'lib/ui/ai/widgets/session_history_view.dart',
      'lib/ui/home/home_screen.dart',
    ]) {
      final src = File(path).readAsStringSync();
      if (!src.contains('searchFieldDecoration')) {
        offenders.add('$path 没用 searchFieldDecoration');
      }
      // 用了这个函数却又自己传 suffixIcon = 绕过统一点
      if (src.contains('searchFieldDecoration') &&
          RegExp(r'suffixIcon:').hasMatch(
              src.substring(src.indexOf('searchFieldDecoration')))) {
        offenders.add('$path 既用 searchFieldDecoration 又自己传 suffixIcon');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('；'));
  });

  testWidgets('不带图标的搜索框同样是标准高度', (t) async {
    final plain = await measure(t, searchFieldDecoration(hintText: 'h'));
    expect(plain, equals(kStandardFieldHeight));
  });
}
