// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../data/models/agent_session.dart';
import '../../../l10n/l10n.dart';
import '../../design/fly_tokens.dart';
import 'relative_time.dart';
import 'session_history_search.dart';

/// 历史会话列表。
///
/// **做成面板内的视图，而不是再叠一层 modal sheet。** AI panel 本身是
/// `showModalBottomSheet` + `DraggableScrollableSheet`，再叠一层会让两层的拖拽
/// 手势打架：外层靠 `ScrollController` 判断「内部列表已经滚到顶了，接下来的
/// 下拉归我」，内层会把那个信号截断。
///
/// 同理，删除用**长按**而不是左滑：左滑在 sheet 里同样会和拖拽抢手势。
///
/// 这个 widget 是纯展示 + 回调 —— 取数据和写库都在 `ai_panel.dart` 那一层，它
/// 才是持有 `AgentSessionManager` 的地方。
///
/// **搜索框是唯一例外**：它需要一个 `TextEditingController`，所以本类是
/// `StatefulWidget`。但对外契约一模一样（数据进、回调出）—— 多出来的状态只是
/// 那一个搜索词，它不外泄、也不影响任何回调的语义。
class SessionHistoryView extends StatefulWidget {
  final List<AgentSession> sessions;
  final void Function(int id) onOpen;
  final void Function(int id, bool starred) onToggleStar;
  final void Function(int id) onDelete;

  /// 导出某一段历史。
  final void Function(int id) onExport;

  /// 这个列表背后服务器的保留段数 —— 底部配额说明要显示它。
  ///
  /// **由调用方传，而不在本 widget 里算**：本类是纯展示，只拿到 `sessions`
  /// 列表，根本不知道自己在显示哪台服务器（全局 tab 与终端页共用它）。
  /// 让它在内部 import 常量并猜一个值，只会让全局 tab 的文案撒谎。
  final int quota;

  const SessionHistoryView({
    super.key,
    required this.sessions,
    required this.onOpen,
    required this.onToggleStar,
    required this.onDelete,
    required this.onExport,
    required this.quota,
  });

  @override
  State<SessionHistoryView> createState() => _SessionHistoryViewState();
}

class _SessionHistoryViewState extends State<SessionHistoryView> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete(BuildContext context, int id) async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.aiHistoryDeleteTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.aiHistoryDelete),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(id);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);

    if (widget.sessions.isEmpty) {
      return Center(
        child: Text(
          l.aiHistoryEmpty,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // 搜索只筛已加载的列表（理由见 `session_history_search.dart`：历史本就
    // 只保留最近 N 条，能被搜到的都在这里，跨库搜索没有意义）。
    final shown = filterSessions(widget.sessions, _searchCtrl.text);

    return Column(
      children: [
        _buildSearchField(context),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    l.aiHistoryNoMatch,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _buildRow(context, shown[i]),
                ),
        ),
        _buildQuotaHint(context),
      ],
    );
  }

  /// 配额说明。
  ///
  /// 补一个此前是**静默**的行为：每台服务器只保留最近
  /// [SessionHistoryView.quota] 条非标星段，超出时最旧的被删掉，而界面上
  /// 从来没提过这件事——用户只会看到「旧会话莫名其妙不见了」。一行说明就能
  /// 把它从「bug」变成「已知的规则」。
  ///
  /// 数字来自 `widget.quota` 而不是一个全局常量：全局 AI tab（100）与普通
  /// 服务器（50）额度不同，写死会让其中一边撒谎。
  Widget _buildQuotaHint(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        context.l10n.aiHistoryQuotaHint(widget.quota),
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: TextField(
        controller: _searchCtrl,
        // 每次按键都重建，过滤是纯内存的（最多几十条），不需要 debounce。
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
        // 统一形态。改动前这里是「自己写 `border: OutlineInputBorder()`
        // 而不约束 prefixIcon」，于是图标槽默认的 48×48 触摸区把输入框
        // 撑到 48dp —— 比全局标准（40）高 8dp，比其它三个搜索框也都高。
        decoration: searchFieldDecoration(
          hintText: context.l10n.aiHistorySearchHint,
          prefixIcon: const Icon(
            Icons.search,
            size: 18,
            color: FlyColors.textTertiary,
          ),
          // 清除按钮由 searchFieldDecoration 统一构造（它知道 IconButton
          // 自带 48 的 minimumSize，得自己压住）。这里只给回调。
          onClear: _searchCtrl.text.isEmpty
              ? null
              : () => setState(_searchCtrl.clear),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, AgentSession s) {
    final l = context.l10n;
    final theme = Theme.of(context);
    // id 一定非空：列表里的每一行都是从表里读出来的。
    final id = s.id!;
        return ListTile(
          dense: true,
          title: Text(
            s.title ?? l.aiHistoryUntitled,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 无标题的那行用弱化色，让它读起来像占位而不是真的叫这个名字。
            style: s.title == null
                ? theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
          subtitle: Text(
            '${relativeTime(s.updatedAt, justNow: l.relativeTimeJustNow)} · '
            '${l.aiHistoryEvents(s.eventCount)}',
            style: theme.textTheme.bodySmall,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  s.starred ? Icons.star : Icons.star_border,
                  size: 20,
                  color: s.starred ? theme.colorScheme.primary : null,
                ),
                onPressed: () => widget.onToggleStar(id, !s.starred),
              ),
              // 用 PopupMenuButton 而不是再加一个裸 IconButton：dense ListTile
              // 的 trailing 放三个图标会挤到标题。菜单是点击触发的，不会和
              // sheet 的拖拽抢手势（长按已经归删除了，见类文档）。
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (v) {
                  if (v == 'export') widget.onExport(id);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'export',
                    child: Text(l.aiExportSession),
                  ),
                ],
              ),
            ],
          ),
      onTap: () => widget.onOpen(id),
      onLongPress: () => _confirmDelete(context, id),
    );
  }
}
