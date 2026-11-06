// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../ssh/notification_service.dart';

/// 「通知权限」这一行：把系统里那个静默的开关状态**显示出来**，并在用户拒过
/// 之后给一条能走得通的路。
///
/// ## 为什么需要它
///
/// Android 13+ 拒掉 `POST_NOTIFICATIONS`、或单独关掉 `flyterm_events` 频道，
/// 系统都不会报错，通知只是不出现。用户看到的唯一现象是「通知功能没反应」，
/// app 里没有任何地方告诉他真正原因 —— 于是他会当成 bug。所以
/// 设置页开关旁需显示权限状态并能跳系统设置。
///
/// ## 为什么「去系统设置」只在被挡时出现
///
/// 已授权 / 未知时显示它，用户点进去只会发现自己什么都不用改 —— 那是纯粹
/// 的噪音。只有确实被挡（[NotificationPermissionState.denied] /
/// [channelDisabled]）时才给出口；而且此时**只**靠 app 内重新申请往往没用
/// （多数 Android 版本拒过一次后不再弹系统对话框），跳设置是唯一出路。
class NotificationPermissionTile extends StatefulWidget {
  /// 权限查询。默认走真实平台查询；测试注入假实现锁 UI 分支。
  final Future<NotificationPermissionState> Function() probe;

  /// 跳系统设置。默认走真实实现；测试注入假实现断言按钮存在。
  final Future<void> Function()? openSettings;

  const NotificationPermissionTile({
    super.key,
    NotificationPermissionTileProbe? probe,
    this.openSettings,
  }) : probe = probe ?? NotificationService.permissionState;

  @override
  State<NotificationPermissionTile> createState() =>
      _NotificationPermissionTileState();
}

/// 见 [NotificationPermissionTile.probe] —— 具名 typedef 让调用方能直接传一个
/// 顶层函数或闭包，不用写显式类型标注。
typedef NotificationPermissionTileProbe
    = Future<NotificationPermissionState> Function();

class _NotificationPermissionTileState
    extends State<NotificationPermissionTile> {
  NotificationPermissionState? _state;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await widget.probe();
    if (!mounted) return;
    setState(() => _state = s);
  }

  Future<void> _openSettings() async {
    await (widget.openSettings ?? NotificationService.openSystemSettings)();
    // 用户可能刚在设置里把开关打开 —— 回来自动复查一次，否则那一行会一直
    // 停在旧状态，用户得退出重进才看得到变化。
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = _state;
    final blocked = state == NotificationPermissionState.denied ||
        state == NotificationPermissionState.channelDisabled;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(
            blocked
                ? Icons.notifications_off_outlined
                : Icons.notifications_outlined,
            size: 20,
          ),
          title: Text(l.notificationPermissionTitle),
          subtitle: Text(
            _subtitle(l, state),
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
        if (blocked)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: Text(l.notificationPermissionOpenSettings),
              ),
            ),
          ),
      ],
    );
  }

  String _subtitle(AppLocalizations l, NotificationPermissionState? state) {
    switch (state) {
      case NotificationPermissionState.granted:
        return l.notificationPermissionGranted;
      case NotificationPermissionState.denied:
        return l.notificationPermissionDenied;
      case NotificationPermissionState.channelDisabled:
        return l.notificationPermissionChannelDisabled;
      case NotificationPermissionState.unknown:
      case null:
        // null 只是首次查询还没回来，用「未知」文案占位即可 —— 多一帧的
        // 闪烁不值得为它单开一个 loading 态文案。
        return l.notificationPermissionUnknown;
    }
  }
}
