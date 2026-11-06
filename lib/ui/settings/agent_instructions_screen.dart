// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_instructions.dart';
import '../../ai/agent/agent_session_manager.dart';
import '../../l10n/l10n.dart';

/// **全局**说明的编辑页，所有服务器共用：放跟机器无关的偏好，
/// 「回答简洁点」「用中文」「先说结论」。
///
/// ## 为什么是全局的
///
/// 原本按服务器存，后来又搬到过远端的一个笔记文件、2026-10 又搬回 app
/// 端——不要再搬回远端。那套「远端更好」的论证（换手机还在、多设备共享、
/// agent 自己也能维护）本身没错，但它优化的是持久性，而真正的痛点是
/// 可管理性：知识散在 N 台机器上，用户在 app 里看不到全貌、删不掉、导
/// 不出。判准是单一真相源优先于跟随载体。
/// 剩下真正需要本地存的只有用户偏好。
///
/// ## 单台机器的笔记不在这里
///
/// 曾经这个页面还有下半截，展示那台服务器的远端笔记（只读）。拆走了：
/// 从「这台机器的说明」进来的人要看的就是那份，主次不该颠倒成「一个大的
/// 全局编辑框在上面、这台机器的内容在下面」。现在它归 `AgentServerNotesSheet`
/// （数据存 app 端 SQLite，可编辑），入口在服务器编辑页。
/// ## 机器笔记总览不在这里
///
/// 它一度挂在本页页脚，2026-10-14 迁去「助手记忆」子页
/// （`agent_memory_screen.dart`）。理由正是本类文档上面那句「两者都是 agent
/// 记忆的一部分，合群」——既然合群，就不该一个是兄弟、一个是侄子。搬走之后
/// 这一页回归纯粹：只编辑那一段全局说明。
class AgentInstructionsScreen extends StatefulWidget {
  const AgentInstructionsScreen({super.key});

  @override
  State<AgentInstructionsScreen> createState() =>
      _AgentInstructionsScreenState();
}

class _AgentInstructionsScreenState extends State<AgentInstructionsScreen> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    final mgr = context.read<AgentSessionManager>();
    _ctrl = TextEditingController(text: mgr.instructions ?? '');
    // 字节数提示要跟着输入走。
    _ctrl.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  /// 把一个示例追加进输入框。
  ///
  /// 追加而不是替换——用户可能已经写了两条，点第三个例子是想加上去，不是
  /// 想覆盖。已经包含这句就不再重复加（连点两次不该出现两遍）。
  void _insertExample(String example) {
    final current = _ctrl.text.trimRight();
    if (current.contains(example)) return;
    _ctrl.text = current.isEmpty ? example : '$current\n$example';
    // 光标移到末尾，接着打字就是续写
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
  }

  void _save() {
    context.read<AgentSessionManager>().instructions = _ctrl.text;
    final l = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l.agentInstructionsSaved)),
    );
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final used = utf8.encode(_ctrl.text).length;
    final over = used > kMaxInstructionBytes;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.agentInstructionsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: l.agentInstructionsSaved,
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.agentInstructionsHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          Text(
            l.agentInstructionsLocalLabel,
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _ctrl,
            maxLines: 10,
            minLines: 5,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 6),
          // 「告诉 AI 你希望它怎么回答」是个很抽象的要求，面对空白输入框
          // 多数人不知道写什么。给几个点一下就插入的例子，比再写一段说明
          // 有用得多 —— 它把抽象要求变成了可以直接用的东西，用户也能从
          // 例子的形状里看出「原来是写这种句子」。
          Text(
            l.agentInstructionsExamplesLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final example in [
                l.agentInstructionsExample1,
                l.agentInstructionsExample2,
                l.agentInstructionsExample3,
              ])
                ActionChip(
                  label: Text(example),
                  onPressed: () => _insertExample(example),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            over
                ? l.agentInstructionsTooLong(kMaxInstructionBytes)
                : l.agentInstructionsRemaining(kMaxInstructionBytes - used),
            style: theme.textTheme.labelSmall?.copyWith(
              color: over
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
