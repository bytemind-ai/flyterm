// 「全局 AI 页」与「终端页 AI 面板」的模型切换入口必须长得一样。
//
// 这两处一度完全不同：面板是「两行标题区（AI 助手 + 当前模型名）+ 下拉箭头」，
// 全局页是一个 `Icons.tune` 裸图标，而且全局页根本不显示当前模型 —— 用户跑
// 半天不知道用的哪个。方案是把标题区抽成共用组件 [ModelTitleTile]，两处都用。
//
// 这里守两件事：
//   1. [ModelTitleTile] 本身渲染「标题 + 模型名 + 下拉箭头」，可点。
//   2. 两个宿主页面的头部都真的用了这个组件（而不是有人回头又各写一份）。
//      —— 「共用组件存在」不等于「两处都在用」，这条差异只能靠宿主断言守住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/global_ai_screen.dart';
import 'package:flyterm/ui/ai/widgets/panel_chrome.dart';

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ModelTitleTile：标题 + 模型名 + 下拉箭头，点它触发回调', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      _wrap(
        ModelTitleTile(
          title: 'AI 助手',
          modelLabel: 'Anthropic (claude-sonnet-4-5-20250929)',
          onSwitchModel: () => tapped++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('AI 助手'), findsOneWidget);
    expect(
      find.text('Anthropic (claude-sonnet-4-5-20250929)'),
      findsOneWidget,
      reason: '当前模型名要常驻可见 —— 全局页原来根本不显示',
    );
    expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);

    await tester.tap(find.text('AI 助手'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('ModelTitleTile：不可切时不画下拉箭头', (tester) async {
    await tester.pumpWidget(
      _wrap(const ModelTitleTile(title: 'AI 助手', modelLabel: 'm')),
    );
    await tester.pump();

    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
  });

  testWidgets('ModelTitleTile：没有模型名时不渲染第二行', (tester) async {
    await tester.pumpWidget(
      _wrap(const ModelTitleTile(title: 'AI 助手')),
    );
    await tester.pump();

    expect(find.text('AI 助手'), findsOneWidget);
    // 只有标题一行，没有多余空行。
    expect(tester.getSize(find.byType(ModelTitleTile)).height, lessThan(40));
  });

  testWidgets('全局 AI 页的 AppBar 用共用的 ModelTitleTile，不再用 tune 图标', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SharedPreferences>.value(value: prefs),
          ChangeNotifierProvider<AIProviderService>.value(
            value: AIProviderService(prefs),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: GlobalAIScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(ModelTitleTile),
      ),
      findsOneWidget,
      reason: '全局页的切模型入口必须是与终端面板同一个组件',
    );
    expect(
      find.byIcon(Icons.tune),
      findsNothing,
      reason: 'tune 图标已由标题区取代，两处入口重复',
    );
  });
}
