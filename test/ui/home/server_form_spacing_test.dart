import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';
import 'package:flyterm/ui/home/server_form_screen.dart';

/// 「新增服务器」页面的**行间距**必须存在，不能靠 InputDecoration 自带的
/// 边距硬撑。
///
/// ## 这条测试拦的是什么
///
/// 用户反馈「不同行之间没有间隔，内容有重叠」。根因是字段以一个扁平
/// `ListView` 排布，相邻 `TextFormField` **之间没有任何显式间距** —— 全靠
/// `InputDecoration` 自带的 `helperText` / 错误文案预留空间撑着。一旦某个
/// 字段带上 `helperText`（如 host 的 `labelHostHelper`），它的占位高度会和
/// 下一个字段的边框挤在一起，视觉上就是「重叠」。
///
/// 所以这里断言的是**几何关系**而不是某个具体 dp 值：相邻两个输入框的
/// 包围盒之间必须有真实空隙。把间距写成 `SizedBox` 还是别的形式都行，
/// 只要切得出空间。
///
/// 用「最坏情况」选字段：`host` 带 helperText，是现场最容易挤的那个。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpForm(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: ServerRepository(db)),
          Provider.value(value: SSHKeyRepository(db)),
          Provider.value(value: SecureStorageService()),
          ChangeNotifierProvider.value(value: AIProviderService(prefs)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildFlyTermTheme(),
          home: const ServerFormScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('相邻输入框之间有可见空隙（不许贴在一起）', (tester) async {
    // 加高视口，避免 ListView 的懒加载把靠下的字段裁掉。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpForm(tester);

    final fields = find.byType(TextFormField);
    expect(fields, findsWidgets, reason: '至少要有若干输入框');

    // 按 y 坐标排序，逐对检查相邻两个字段的包围盒。
    final rects = <Rect>[];
    for (var i = 0; i < fields.evaluate().length; i++) {
      rects.add(tester.getRect(fields.at(i)));
    }
    rects.sort((a, b) => a.top.compareTo(b.top));

    var checked = 0;
    for (var i = 0; i < rects.length - 1; i++) {
      final gap = rects[i + 1].top - rects[i].bottom;
      // 只检查「真的相邻」的一对：同一条竖列上，且下一个字段在下方。
      // 跨列/跨分组的会有大间距，不构成风险。
      if (gap < 0) {
        fail(
          '第 $i 与第 ${i + 1} 个输入框重叠了（gap=$gap），'
          '上={${rects[i]}} 下={${rects[i + 1]}}',
        );
      }
      if (gap < 200) checked++;
      expect(
        gap,
        greaterThanOrEqualTo(kFormFieldGap),
        reason:
            '第 $i 与第 ${i + 1} 个输入框间距 ${gap}px，'
            '小于最小间距 ${kFormFieldGap}px —— '
            '这正是用户报的「行之间没有间隔」',
      );
    }
    expect(checked, greaterThan(0), reason: '没有检查到任何相邻对，测试没生效');
  });
}
