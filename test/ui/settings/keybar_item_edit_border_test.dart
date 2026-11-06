// 序列编辑器内嵌输入框不得自带边框/填充。
//
// 背景：外层那个 AnimatedContainer 自己画边框（聚焦时 accent 1.5px），
// 内嵌的 TextField 只是它里面的一段光标。但 TextField 会执行
// `decoration.applyDefaults(theme.inputDecorationTheme)`，把全局的
// enabled/focusedBorder（都是 OutlineInputBorder）填进来，而
// InputDecorator 取边框时**状态专属的优先于 `border`** —— 只写
// `border: InputBorder.none` 关不掉，聚焦时会出现第二圈绿框。
//
// 所以这条测试必须跑在**真实 app theme** 下，用默认 theme 测不出来。
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';
import 'package:flyterm/ui/settings/keybar_item_edit_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<InputDecoration> pumpAndFindSequenceDecoration(
      WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final keybar = KeybarSettings();
    await keybar.seedIfEmpty();

    await tester.pumpWidget(
      ChangeNotifierProvider<KeybarSettings>.value(
        value: keybar,
        child: MaterialApp(
          theme: buildFlyTermTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const KeybarItemEditScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 序列那个是唯一带 hintText 的输入框（标签输入框没有 hint）。
    final decorators = tester
        .widgetList<InputDecorator>(find.byType(InputDecorator))
        .where((d) => d.decoration.hintText != null)
        .toList();
    expect(decorators, hasLength(1),
        reason: '序列输入框应当是页面上唯一带 hint 的输入框');
    return decorators.single.decoration;
  }

  testWidgets('内嵌序列输入框的三种边框都是 none（不会出现第二个框）',
      (tester) async {
    final d = await pumpAndFindSequenceDecoration(tester);

    expect(d.border, InputBorder.none);
    expect(d.enabledBorder, InputBorder.none,
        reason: '否则未聚焦时会从 theme 继承一圈 divider 色的框');
    expect(d.focusedBorder, InputBorder.none,
        reason: '否则聚焦时会从 theme 继承一圈 accent 绿框，与外层边框重影');
  });

  testWidgets('内嵌序列输入框不填充背景', (tester) async {
    final d = await pumpAndFindSequenceDecoration(tester);
    expect(d.filled, isFalse,
        reason: 'theme 的 filled:true 会让内嵌框在外框里显出一块底色');
  });
}
