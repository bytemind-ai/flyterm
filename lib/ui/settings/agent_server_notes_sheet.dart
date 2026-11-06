// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_instructions.dart' show kMaxInstructionBytes;
import '../../ai/agent/server_notes_manager.dart';
import '../../l10n/l10n.dart';

/// 编辑某台服务器的机器笔记（"这台用 podman 不用 docker" 这类事实）。
///
/// ## 为什么现在可编辑了
///
/// 这份笔记以前存在服务器上的一个笔记文件里，手机上只缓存一份
/// 只读副本——只读是因为那份文件属于服务器，在手机上编辑一份缓存副本只会
/// 制造两个真相：用户改了手机上这份，服务器上那份没变，下次同步又被覆盖
/// 回去。
///
/// 现在笔记整个搬进了 app 端 SQLite（[ServerNotesManager]），手机上这份
/// 就是唯一的真相源，没有第二份可以分叉。只读的理由随载体搬迁自动失效，
/// 于是它改成了普通的编辑框。
///
/// ## 为什么是独立的 sheet 而不是塞进全局说明那一页
///
/// 从「这台机器的说明」进来的人要看的就是这份，主次不该颠倒成「一个大的
/// 全局编辑框在上面、这台机器的内容在下面」。
class AgentServerNotesSheet extends StatefulWidget {
  final String serverId;

  const AgentServerNotesSheet({super.key, required this.serverId});

  static Future<void> show(BuildContext context, String serverId) =>
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => AgentServerNotesSheet(serverId: serverId),
      );

  @override
  State<AgentServerNotesSheet> createState() => _AgentServerNotesSheetState();
}

class _AgentServerNotesSheetState extends State<AgentServerNotesSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    // 只读一次初始值，不 watch/listen ServerNotesManager：模型可能在后台
    // 通过 save_note 工具改这台机器的笔记，如果这里 watch，用户正在打的字
    // 会被那次后台写入刷新出来的新值冲掉。编辑期间这个 sheet 就是唯一
    // 真相源，保存时才整份写回去。
    final initial =
        context.read<ServerNotesManager>().noteFor(widget.serverId) ?? '';
    _ctrl = TextEditingController(text: initial);
    _ctrl.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // BuildContext 要跨 await 用，提前存成局部变量。
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final l = context.l10n;

    final result = await context.read<ServerNotesManager>().replaceNote(
          serverId: widget.serverId,
          body: _ctrl.text,
        );

    if (!mounted) return;
    if (!result.ok) {
      // 实践中这个分支到不了：下面 `build()` 里的 `over` 按**未 trim** 的字节
      // 算，`replaceNote` 按 **trim 后**算，trim 只会让字节数变少或不变，
      // 所以 untrimmed ≤ limit 时 trimmed 必然也 ≤ limit —— 而保存按钮在
      // `over` 为真时已经被禁用，调不到这里。
      //
      // 留着不删：`replaceNote` 是上限判定唯一的收口，万一以后这里的 `over`
      // 判断和 Manager 里的判断再次分叉（比如改了字节算法却只改了一处），
      // 这段兜底能接住，不至于用户点了保存却悄无声息地丢了内容。
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.agentServerNotesTooLong(result.overflowBytes)),
        ),
      );
      return;
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    // 按 UTF-8 字节算，不是字符数——中文一个字 3 字节。真正的上限检查在
    // ServerNotesManager.replaceNote 里，这里只是提前算出来给用户看，不能
    // 用 _ctrl.text.length 糊弄。
    final used = utf8.encode(_ctrl.text).length;
    final over = used > kMaxInstructionBytes;

    return SafeArea(
      child: Padding(
        // 键盘弹出时要把内容顶上去，不然输入框会被键盘盖住。
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.agentServerNotesTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              l.agentServerNotesHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              maxLines: 8,
              minLines: 4,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: l.agentServerNotesEmpty,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  l.agentServerNotesBytes(used, kMaxInstructionBytes),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: over
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: over ? null : _save,
                  child: Text(l.agentServerNotesSave),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
