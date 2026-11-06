// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import 'relative_time.dart';

/// 入口区上的一条历史会话。
///
/// 与 `AgentSession` 刻意分开：那个带 `archive`（整段 JSON）和 `starred` 等
/// 本页用不到的字段，而机器名需要解析才能得到 —— 不该让展示组件去碰解析。
class LaunchpadSession {
  final int id;
  final String? title;
  final List<String> machines;
  final DateTime updatedAt;

  const LaunchpadSession({
    required this.id,
    required this.title,
    required this.machines,
    required this.updatedAt,
  });
}

class LaunchpadMachine {
  final String id;
  final String name;
  final bool connected;

  const LaunchpadMachine({
    required this.id,
    required this.name,
    required this.connected,
  });
}

/// 全局 AI 页的入口区（空态）。
///
/// **纯组件**：不读 provider、不持有状态。截断、排序、拼建议文案全在宿主
/// （`global_ai_screen.dart`）—— 「取几条」「选哪台机器举例」是产品决策，
/// 不该埋进 widget。
class AiLaunchpad extends StatelessWidget {
  final String title;
  final List<LaunchpadSession> recentSessions;
  final List<LaunchpadMachine> machines;
  final int totalMachineCount;
  final List<String> suggestions;

  final void Function(int sessionId) onOpenSession;

  /// 只传出机器 **id**，查 `Server` 与导航都是宿主的事 —— 组件不认识 `Server`。
  final void Function(String machineId) onOpenMachine;
  final void Function(String text) onSend;

  const AiLaunchpad({
    super.key,
    required this.title,
    required this.recentSessions,
    required this.machines,
    required this.totalMachineCount,
    required this.suggestions,
    required this.onOpenSession,
    required this.onOpenMachine,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final hasSessions = recentSessions.isNotEmpty;
    final hasMachines = machines.isNotEmpty;
    final overflow = totalMachineCount - machines.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 36, color: cs.primary.withValues(alpha: 0.7)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.9)),
          ),
          const SizedBox(height: 20),

          if (hasSessions) ...[
            _SectionLabel(l.aiHomeRecent),
            for (final s in recentSessions) _SessionRow(session: s, onTap: onOpenSession),
            const SizedBox(height: 16),
          ],

          if (hasMachines) ...[
            _SectionLabel(l.aiHomeMachines),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in machines)
                  _MachineChip(machine: m, onTap: onOpenMachine),
                if (overflow > 0)
                  Chip(
                    label: Text(l.aiHomeMoreMachines(overflow)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // ③ 永远渲染 —— 它是唯一的保底内容。但已有前置内容时压成一行提示。
          if (hasSessions || hasMachines) _SectionLabel(l.aiHomeOrAsk),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final s in suggestions)
                ActionChip(label: Text(s), onPressed: () => onSend(s)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}

class _SessionRow extends StatelessWidget {
  final LaunchpadSession session;
  final void Function(int) onTap;
  const _SessionRow({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final subtitle = [
      relativeTime(session.updatedAt, justNow: l.relativeTimeJustNow),
      if (session.machines.isNotEmpty) session.machines.join(', '),
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.history, size: 20),
      title: Text(
        session.title ?? l.aiHistoryUntitled,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: session.title == null
            ? theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)
            : null,
      ),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      onTap: () => onTap(session.id),
    );
  }
}

class _MachineChip extends StatelessWidget {
  final LaunchpadMachine machine;
  final void Function(String) onTap;
  const _MachineChip({required this.machine, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(
        machine.connected ? Icons.circle : Icons.circle_outlined,
        size: 10,
        color: machine.connected ? const Color(0xFF00C896) : cs.onSurfaceVariant,
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Flexible + 省略号：机器名可能很长（`Row` 给非 flex 子节点的是
          // **无界主轴约束**，普通 `Text` 会按自然宽度撑开、把 chip 顶出屏幕）。
          Flexible(
            child: Text(
              machine.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 2),
          // 尾随箭头：这个 chip 现在会**导航**（打开该机器的终端），不是只
          // 显示状态。没有这个暗示，一个看起来只显示连接状态的标签不会有人
          // 去点。
          Icon(Icons.chevron_right, size: 14, color: cs.onSurfaceVariant),
        ],
      ),
      visualDensity: VisualDensity.compact,
      onPressed: () => onTap(machine.id),
    );
  }
}
