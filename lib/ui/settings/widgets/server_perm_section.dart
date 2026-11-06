// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../ai/agent/agent_session_manager.dart';
import '../../../ai/agent/tool_registry.dart';
import '../../../l10n/l10n.dart';
import 'mode_segmented.dart';

/// 单台服务器的权限节：一个"跟随全局"开关 + 同一个三档分段选择器。
///
/// ## 为什么从底部弹窗改成内联
///
/// 原先是一个 `AgentModeSheet` 底部弹窗（4 个 RadioListTile）。改成内联是为了
/// 让用户在设置页和服务器页看到**同一套 UI、同一套词** —— 那正是本次重设计的
/// 核心。`AgentModeSheet` 整个文件随之删除。
///
/// ## 为什么抽成独立 widget 而不是内联在 builder 闭包里
///
/// 内联需要构造整个 `ServerFormScreen`（依赖 Database / ServerRepository /
/// SecureStorage 一整套装配）才能测。抽出来之后这个节可以直接构造测试。
class ServerPermSection extends StatelessWidget {
  final String serverId;

  const ServerPermSection({super.key, required this.serverId});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final mgr = context.watch<AgentSessionManager>();
    final override = mgr.modeOverrideFor(serverId);
    final following = override == null;
    // 跟随态下分段显示全局值（置灰），让用户看得到自己在跟随什么。
    final shown = override ?? mgr.defaultMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            l.agentPermServerTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        SwitchListTile(
          key: const Key('server-perm-follow-switch'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(l.agentPermFollowGlobal(
              ModeSegmented.labelOf(context, mgr.defaultMode))),
          value: following,
          onChanged: (v) {
            if (v) {
              mgr.setModeOverride(serverId, null);
            } else {
              // 关掉跟随：把**当前生效值**写成一个显式覆盖 —— 用户接下来
              // 从这一刻看到的那一档出发去调，不会见到任何跳变。
              mgr.setModeOverride(serverId, mgr.defaultMode);
            }
          },
        ),
        const SizedBox(height: 4),
        ModeSegmented(
          value: shown,
          enabled: !following,
          onChanged: (m) async {
            // 已选中档再点一次是 no-op（与设置页同一口径）。
            if (m == shown) return;
            if (m == PermissionMode.bypass) {
              if (!await confirmBypass(context)) return;
              if (!context.mounted) return;
            }
            mgr.setModeOverride(serverId, m);
          },
        ),
      ],
    );
  }
}
