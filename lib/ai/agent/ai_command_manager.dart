// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/models/favorite_command.dart';
import '../../data/repositories/favorite_command_repository.dart';

/// 进索引的最大条数。
///
/// 一条索引约 25–40 token（比 skill 索引的 30 略贵，因为带命令模板），
/// 20 条 ≈ 700 token 常驻。
const int kMaxIndexedCommands = 20;

/// 暴露给 agent 的收藏命令。
///
/// ## 为什么要内存缓存
///
/// `terminal_screen.dart` 的 `systemPromptProvider` 是**同步**闭包，索引每轮
/// 都要拼进去；而 `AgentLoop._resolve`（`run_saved_command` 的接入点）也是
/// **同步**的。两处都不能 await，所以命令必须常驻内存。
///
/// ## 比 AgentSkillManager 简单的地方
///
/// 命令模板只有一行，整个 `FavoriteCommand` 放内存即可 —— 没有 skills 那种
/// 「8 KiB 正文留在库里按需读」的分层，[byName] 因此可以是同步的，工具执行
/// 路径里没有第二次读库。
///
/// ## 上限按 sortOrder 取，不按时间
///
/// 收藏列表是 `ReorderableListView`，**用户自己拖出来的顺序就是优先级**。
/// 这比 skills 的「最近更新优先」好 —— 那是我们替用户猜的，这个是他自己
/// 排的，不需要任何解释。
class AiCommandManager extends ChangeNotifier {
  final FavoriteCommandRepository _repo;

  List<FavoriteCommand> _exposed = const [];

  AiCommandManager(this._repo);

  /// 勾了 `aiEnabled` 的全部，按 `sortOrder` 升序（含被挤出索引的）。
  List<FavoriteCommand> get exposed => _exposed;

  /// 真正进 system prompt、也真正可被调用的那些。**同步。**
  List<FavoriteCommand> get indexEntries =>
      _exposed.take(kMaxIndexedCommands).toList(growable: false);

  List<String> get names =>
      indexEntries.map((c) => c.name).toList(growable: false);

  /// 勾了但超出上限、没进索引的条数。列表页据此显示警告。
  int get overflowCount => _exposed.length > kMaxIndexedCommands
      ? _exposed.length - kMaxIndexedCommands
      : 0;

  /// 按名字找一条**可调用**的命令。**同步**，大小写不敏感。
  ///
  /// 只在 [indexEntries] 里找，不在 [exposed] 里找 —— 被挤出上限的那些
  /// 模型可能从更早的对话里记得名字，若能照样调用，上限就形同虚设。
  FavoriteCommand? byName(String name) {
    final key = name.trim().toLowerCase();
    for (final c in indexEntries) {
      if (c.name.toLowerCase() == key) return c;
    }
    return null;
  }

  /// 索引每轮的 token 估算，给收藏面板那行预算用。按 chars/3.5 粗估，与
  /// `kMaxInstructionBytes` 注释同一口径。不参与任何判断。
  int get indexTokenEstimate {
    final text = indexEntries
        .map((c) => '${c.name} [${c.params.join(', ')}]: ${c.command}')
        .join('\n');
    return (utf8.encode(text).length / 3.5).round();
  }

  /// 从库里重读。构造之后必须调一次；**收藏增删改之后也必须调** ——
  /// 内存缓存不会自己知道库变了，漏掉的表现是「用户勾了开关没反应，
  /// 重启 app 才生效」，而且不会有任何测试失败。
  Future<void> reload() async {
    final all = await _repo.findAll(); // 已按 sort_order ASC 排序
    _exposed = all.where((c) => c.aiEnabled).toList(growable: false);
    notifyListeners();
  }
}
