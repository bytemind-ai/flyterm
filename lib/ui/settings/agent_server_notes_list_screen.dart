// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/server_notes_manager.dart';
import '../../data/models/server.dart';
import '../../l10n/l10n.dart';
import 'agent_server_notes_sheet.dart';

/// 全部机器笔记的总览列表。
///
/// ## 为什么这一页必须存在
///
/// 机器笔记（"这台用 podman 不用 docker"）从远端服务器文件搬进了 app 端
/// SQLite（见 [ServerNotesManager]），这次搬迁的动机就是「单一真相源 /
/// 好管理」—— 笔记散在 N 台机器上时，用户在 app 里看不到全貌、删不掉、
/// 导不出。在服务器编辑页（`server_form_screen.dart`）里确实能看到单台
/// 机器的笔记，但那只是「进去之前先选对服务器」，不是「一眼看完所有」。
/// 这一页补的正是后者 —— 没有它，把存储搬到手机上只兑现了迁移动机的一半。
class AgentServerNotesListScreen extends StatelessWidget {
  /// id → name 的来源。**用实参传入而不是读 ServerRepository** ——
  /// `findAll()` 是异步的，在 build 里 await 不了，而这一页只需要一个映射。
  /// 与 `agent_view.dart` 的 `servers` 字段同一个理由。
  final List<Server> servers;

  const AgentServerNotesListScreen({super.key, required this.servers});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final mgr = context.watch<ServerNotesManager>();
    final notes = mgr.notes;
    final nameById = {for (final s in servers) s.id: s.name};

    return Scaffold(
      appBar: AppBar(title: Text(l.agentServerNotesOverviewEntry)),
      body: notes.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l.agentServerNotesOverviewEmpty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            )
          : ListView.builder(
              itemCount: notes.length,
              itemBuilder: (context, i) {
                final n = notes[i];
                // 机器可能已经被删掉，但笔记还留着（ServerRepository.delete
                // 只在同一次事务里顺带清笔记；传进来的 servers 快照本身就
                // 可能是删除前后不同步的那一刻）。退回显示 serverId 而不是
                // 空标题 —— 空标题会让用户完全不知道这条属于谁，也就没法
                // 删掉它，这就跟没有删除入口一样糟。
                final name = nameById[n.serverId] ?? n.serverId;
                final lineCount = n.body.split('\n').length;
                final updatedAt = _formatTime(n.updatedAt);

                return ListTile(
                  title: Text(name),
                  subtitle: Text(
                    '${l.agentServerNotesLines(lineCount)} · '
                    '${l.agentServerNotesUpdatedAt(updatedAt)}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l.agentServerNotesDelete,
                    onPressed: () => context
                        .read<ServerNotesManager>()
                        .delete(n.serverId),
                  ),
                  onTap: () =>
                      AgentServerNotesSheet.show(context, n.serverId),
                );
              },
            ),
    );
  }

  /// 简单的本地时间格式化，不依赖 `intl` 的 `DateFormat` —— 这里只是给
  /// 「最后更新」一个可读的绝对时间，不需要本地化的月份名/12小时制切换。
  static String _formatTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
