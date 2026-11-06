import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ssh/notification_permission.dart';
import 'package:flyterm/ui/settings/widgets/notification_permission_tile.dart';

/// 通知权限 tile 的**渲染契约**。
///
/// 这条 tile 存在的全部理由是「把静默失败变成可看见的事实」—— 所以这里守的
/// 不是「有没有这个 widget」，而是**每种状态都要给出能让用户行动的文案**：
/// 被拒/频道被关时必须显示「去系统设置」按钮，正常时不能显示（否则用户会点
/// 进去发现自己什么都不用改），未知时也不能冒充「已授权」。
///
/// 权限查询本身（`areNotificationsEnabled` 等）只能在真机跑，这里注入一个
/// 假的查询函数锁住 UI 分支。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      );

  group('通知权限 tile', () {
    testWidgets('已授权 → 显示「已允许」，不显示去设置按钮', (tester) async {
      await tester.pumpWidget(wrap(NotificationPermissionTile(
        probe: () async => NotificationPermissionState.granted,
      )));
      await tester.pumpAndSettle();

      expect(find.text('通知已允许'), findsOneWidget);
      expect(find.text('打开系统设置'), findsNothing);
    });

    testWidgets('被拒 → 显示原因 + 去设置按钮', (tester) async {
      await tester.pumpWidget(wrap(NotificationPermissionTile(
        probe: () async => NotificationPermissionState.denied,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('被系统挡住'), findsOneWidget);
      expect(find.text('打开系统设置'), findsOneWidget);
    });

    testWidgets('频道被单独关闭 → 也要给去设置按钮（这是最容易被当成 bug 的一种）',
        (tester) async {
      await tester.pumpWidget(wrap(NotificationPermissionTile(
        probe: () async => NotificationPermissionState.channelDisabled,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('频道被关闭'), findsOneWidget);
      expect(find.text('打开系统设置'), findsOneWidget);
    });

    testWidgets('未知 → 如实说「无法判断」，既不说已授权也不给去设置按钮',
        (tester) async {
      await tester.pumpWidget(wrap(NotificationPermissionTile(
        probe: () async => NotificationPermissionState.unknown,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('无法判断'), findsOneWidget);
      expect(find.text('打开系统设置'), findsNothing);
    });
  });
}
