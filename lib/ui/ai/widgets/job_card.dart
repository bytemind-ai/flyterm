// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/agent_loop.dart';
import '../../../l10n/l10n.dart';
import 'dense_event_row.dart';
import '../../design/fly_tokens.dart';

/// [jobCheckedAgo] 的档位。
enum JobCheckedUnit { justNow, minutes, hours, days }

/// 距上次确认过了多久，分四档。
///
/// **纯函数，不碰 l10n** —— 照 `agent_skills_screen.dart` 里 `skillUsageDays`
/// 的既有模式：这里只算数值与档位，文案由 UI 层 switch 到分档 l10n 键。项目
/// 里没有通用的 timeAgo 工具，为一处需求造一个通用件不划算。
///
/// 负数（用户改过系统时间，`now < lastCheckedAtMs`）当作 0 —— 显示「刚确认
/// 过」比显示负数好，而且这种情况下我们对时间本身就没有把握。
({JobCheckedUnit unit, int value}) jobCheckedAgo(int agoMs) {
  final s = agoMs < 0 ? 0 : agoMs ~/ 1000;
  if (s < 60) return (unit: JobCheckedUnit.justNow, value: 0);
  final m = s ~/ 60;
  if (m < 60) return (unit: JobCheckedUnit.minutes, value: m);
  final h = m ~/ 60;
  if (h < 24) return (unit: JobCheckedUnit.hours, value: h);
  return (unit: JobCheckedUnit.days, value: h ~/ 24);
}

/// 把 [lastCheckedAtMs] 渲染成一句话。放在这里而不是各调用点，是因为
/// `JobCard` 与 `agent_view.dart` 的常驻条要显示完全相同的东西。
String jobCheckedLabel(BuildContext context, int lastCheckedAtMs) {
  final r = jobCheckedAgo(
    DateTime.now().millisecondsSinceEpoch - lastCheckedAtMs,
  );
  final l = context.l10n;
  return switch (r.unit) {
    JobCheckedUnit.justNow => l.agentJobCheckedJustNow,
    JobCheckedUnit.minutes => l.agentJobCheckedMinutes(r.value),
    JobCheckedUnit.hours => l.agentJobCheckedHours(r.value),
    JobCheckedUnit.days => l.agentJobCheckedDays(r.value),
  };
}

/// 距启动多久。**分钟级，不显示秒。**
///
/// 秒级跳动是在声称实时性：每秒刷新的数字让人以为系统在盯着这个任务，而我们
/// 只是在做一次减法 —— `running` 的判据是 `exitCode == null`，那个字段只有
/// 模型调 `check_job` 才会写。降到分钟级之后，这行字的变化频率与它实际承载
/// 的信息量相称。
String formatSinceStart(int seconds) {
  final m = seconds ~/ 60;
  if (m < 1) return '<1m';
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h${m % 60}m';
}

/// 卡片上显示的命令文本。
///
/// 跨机任务加 `[web-2] ` 前缀，与 `runBackground` / `bash` 的 `displayCommand`
/// 同一约定 —— 那里是「命令打到另一台」时加前缀，这里是「任务跑在另一台」
/// 时加，两者在用户眼里是同一件事。
///
/// **本机任务（serverName 为 null）原样返回**，不留下任何标记：绝大多数
/// 任务都在当前会话那台跑，给它们加个无意义的「[本机]」只会稀释前缀的信息量。
String jobCommandLabel(BackgroundJobEvent event) => event.serverName == null
    ? event.command
    : '[${event.serverName}] ${event.command}';

/// 后台任务卡。
///
/// 与 `ToolCallCard` 分开而不是加个分支：那张卡是「一次调用的结果」，终态
/// 之后不再变；这张卡在任务运行期间会被多次 `check_job` 更新，而且带一个
/// 会改变远端状态的操作（终止）。两者的生命周期和交互都不一样。
class JobCard extends StatelessWidget {
  final BackgroundJobEvent event;

  /// null = 不提供终止（任务已结束，或调用方不支持）。
  final VoidCallback? onKill;

  const JobCard({super.key, required this.event, this.onKill});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // 归属要显示在命令上：两个 pane 一边本机一边 web-2 时，两张卡都写着
    // `apt upgrade -y`，用户分不清是哪台机器在烧 CPU —— 这正是跨机任务
    // 要解决的场景。
    final command = jobCommandLabel(event);
    final theme = Theme.of(context);
    final elapsed =
        ((DateTime.now().millisecondsSinceEpoch - event.startedAtMs) ~/ 1000)
            .clamp(0, 1 << 30);

    final String statusText;
    if (!event.running) {
      statusText = l.agentJobFinished(event.exitCode ?? -1);
    } else if (event.killed) {
      statusText = l.agentJobKilling;
    } else {
      // 两处都在收回我们没有的确定性：不说「运行中」（不知道），时长降到
      // 分钟级（秒级跳动在暗示实时监控）。后半句把「多久没核实」摆出来。
      statusText =
          '${l.agentJobSinceStart(formatSinceStart(elapsed))}'
          ' · ${jobCheckedLabel(context, event.lastCheckedAtMs)}';
    }

    if (!event.running) {
      final dim = theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
      return DenseEventRow(
        leading: Icon(
          Icons.check_circle,
          size: 16,
          color: (event.exitCode ?? -1) == 0
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
        ),
        spans: [
          if (event.description.isNotEmpty) ...[
            TextSpan(text: event.description, style: theme.textTheme.bodySmall),
            TextSpan(
              text: ' · ',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ],
          TextSpan(
            text: command,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(text: ' · $statusText', style: dim),
        ],
        expanded: event.tail.isEmpty
            ? null
            : (_) => Container(
                width: double.infinity,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                ),
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    event.tail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        // 第一层·角色：中性底。
        //
        // **描边保留 running 语义** —— 它编码 `event.running`（跑完了没有），
        // 那是真状态，不能被装饰色顶掉。事件色相只在「非 running」时兜底。
        color: FlyColors.roleToolFill,
        borderRadius: FlyRadius.cardRadius,
        border: Border.all(
          color: event.running
              ? theme.colorScheme.primary.withValues(alpha: 0.4)
              : FlyColors.tintBorder(FlyColors.tintSky),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (event.running && !event.killed)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  event.running ? Icons.hourglass_bottom : Icons.check_circle,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(statusText, style: theme.textTheme.labelMedium),
              ),
              // 已结束就不摆按钮；已请求终止则摆一个不可点的，让用户知道
              // 请求已经发出去了（而不是自己没点上）。
              if (event.running)
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  onPressed: event.killed ? null : onKill,
                  tooltip: l.agentJobStop,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 命令与日志都是 shell 原始文本：等宽、不走 markdown。
          // 里面的 * 和 _ 不是 markdown 记号（同 ToolCallCard 的处理）。
          SelectableText(
            command,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          if (event.tail.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(4),
              ),
              // 只给尾巴留有限高度：几百行日志会把整个面板顶掉。
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  event.tail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
