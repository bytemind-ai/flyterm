import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/panel_chrome.dart';

/// 附件按钮**灰着的时候仍然点得动**。
///
/// ## 为什么这条必须有测试
///
/// 原先禁用时把原因写在 `tooltip` 里就算完了 —— 但 tooltip 在手机上要长按
/// 才显示。用户点一下灰按钮，屏幕上什么都不会发生，与「App 坏了」无法区分。
/// 真机反馈（2026-09-13）「附件上传有问题」有一半是这个。
///
/// 这类回归不会让任何既有测试变红（按钮还在、布局没变、也不崩），只能靠
/// 一条专门盯住「禁用态可点」的用例守着。
void main() {
  Widget host({
    required bool attachEnabled,
    VoidCallback? onAttachTap,
    VoidCallback? onAttachBlockedTap,
  }) =>
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PanelInputRow(
            ctrl: TextEditingController(),
            onSubmit: () {},
            onAttachTap: onAttachTap ?? () {},
            attachEnabled: attachEnabled,
            onAttachBlockedTap: onAttachBlockedTap,
          ),
        ),
      );

  testWidgets('灰着时点击走 onAttachBlockedTap，而不是什么都不发生', (tester) async {
    var blocked = 0;
    var picked = 0;
    await tester.pumpWidget(host(
      attachEnabled: false,
      onAttachTap: () => picked++,
      onAttachBlockedTap: () => blocked++,
    ));

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();

    expect(blocked, 1, reason: '点灰按钮必须给出反馈，否则与「坏了」无法区分');
    expect(picked, 0, reason: '灰着的时候不该真的去弹文件选择器');
  });

  testWidgets('可用时点击走 onAttachTap', (tester) async {
    var blocked = 0;
    var picked = 0;
    await tester.pumpWidget(host(
      attachEnabled: true,
      onAttachTap: () => picked++,
      onAttachBlockedTap: () => blocked++,
    ));

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();

    expect(picked, 1);
    expect(blocked, 0);
  });

  testWidgets('灰着的按钮视觉上要能看出不可用', (tester) async {
    await tester.pumpWidget(host(attachEnabled: false, onAttachBlockedTap: () {}));
    final icon = tester.widget<Icon>(find.byIcon(Icons.attach_file));
    expect(icon.color, isNotNull,
        reason: '禁用态必须显式上灰色 —— 现在 onPressed 非 null，'
            'IconButton 不会再自动帮我们置灰');
  });

  testWidgets('没传 onAttachBlockedTap 时退回真正的禁用', (tester) async {
    // 兜底语义：调用方没提供「点了之后说什么」，那就老老实实点不动，
    // 而不是点了一下毫无反应。
    await tester.pumpWidget(host(attachEnabled: false));
    final btn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.attach_file));
    expect(btn.onPressed, isNull);
  });
}
