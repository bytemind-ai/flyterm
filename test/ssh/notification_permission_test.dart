import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/notification_permission.dart';

/// 通知权限状态的**纯判定**。
///
/// 拆成纯枚举 + 判定函数是为了 device-free 锁死三态语义：真实权限查询
/// （`areNotificationsEnabled` / `getNotificationChannels`）只能在设备上跑，
/// 但它返回什么、以及「什么算被挡」是纯逻辑，这部分必须能在宿主机上回归。
///
/// ## 为什么要有这个状态
///
/// Android 13+ 用户拒掉 `POST_NOTIFICATIONS` 之后，`notify()` 不抛异常，
/// 只是静默不显示。用户看到的现象是「通知功能没反应」，没有 UI 会告诉他是
/// 权限被拒了 —— 于是他会当成 bug。这条状态就是把那个静默失败变成可看见的
/// 事实。
void main() {
  group('NotificationPermissionState', () {
    test('app 级开关关闭 → 权限被拒', () {
      expect(
        resolveNotificationPermission(
          appLevelEnabled: false,
          channelImportanceNone: false,
        ),
        NotificationPermissionState.denied,
      );
    });

    test('app 级开着但频道被关 → 频道被禁', () {
      expect(
        resolveNotificationPermission(
          appLevelEnabled: true,
          channelImportanceNone: true,
        ),
        NotificationPermissionState.channelDisabled,
      );
    });

    test('app 级开着、频道也开着 → 正常', () {
      expect(
        resolveNotificationPermission(
          appLevelEnabled: true,
          channelImportanceNone: false,
        ),
        NotificationPermissionState.granted,
      );
    });

    test('app 级被拒优先于频道状态 —— 频道关着但 app 也关着时，用户看到的是'
        '「权限被拒」（那是更外层、更该先处理的开关）', () {
      expect(
        resolveNotificationPermission(
          appLevelEnabled: false,
          channelImportanceNone: true,
        ),
        NotificationPermissionState.denied,
      );
    });

    test('拿不到明确信号（非 Android / 查询失败）→ 未知，不当成被拒', () {
      // 误报「被拒」比漏报贵得多：它会引导用户去翻一个根本不需要动的
      // 系统设置，而且旧 Android / iOS 上根本没有这个 API。
      expect(
        resolveNotificationPermission(
          appLevelEnabled: null,
          channelImportanceNone: null,
        ),
        NotificationPermissionState.unknown,
      );
    });

    test('app 级未知但频道明确被关 → 仍报频道被禁', () {
      expect(
        resolveNotificationPermission(
          appLevelEnabled: null,
          channelImportanceNone: true,
        ),
        NotificationPermissionState.channelDisabled,
      );
    });

    test('app 级未知、频道未知 → 未知', () {
      expect(
        resolveNotificationPermission(
          appLevelEnabled: null,
          channelImportanceNone: null,
        ),
        NotificationPermissionState.unknown,
      );
    });

    test('app 级开着、频道未知 → 正常（频道信息拿不到就不当作被挡）', () {
      expect(
        resolveNotificationPermission(
          appLevelEnabled: true,
          channelImportanceNone: null,
        ),
        NotificationPermissionState.granted,
      );
    });
  });
}

// 平台未注册时的健壮性（在 notification_service 上验证）由
// `test/ui/settings/connection_advanced_screen_test.dart` 覆盖 —— 它会在真实
// 插件平台缺失的测试宿主上挂载 UI，若 `permissionState()` 抛异常整页都会挂。
