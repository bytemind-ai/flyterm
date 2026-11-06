// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:uuid/uuid.dart';

class FavoriteCommand {
  final String id;
  final String name;
  final String command; // may contain {{param}} placeholders
  final int sortOrder;

  /// 是否允许 agent 通过 `run_saved_command` 调用这一条。
  ///
  /// **默认 false，且 migration 里的 DEFAULT 也必须是 0。** 「我收藏它是为了
  /// 自己一键点」和「我允许 AI 替我跑」是两件事 —— 收藏里很可能有
  /// `rm -rf /tmp/cache/*` 这种自己用没问题、但不想让 AI 自主决定何时跑的。
  /// 把默认改成开，等于让一次版本升级把用户所有收藏都交给模型。
  final bool aiEnabled;

  const FavoriteCommand({
    required this.id,
    required this.name,
    required this.command,
    this.sortOrder = 0,
    this.aiEnabled = false,
  });

  factory FavoriteCommand.create(
          {required String name, required String command}) =>
      FavoriteCommand(id: const Uuid().v4(), name: name, command: command);

  FavoriteCommand copyWith({
    String? name,
    String? command,
    int? sortOrder,
    bool? aiEnabled,
  }) =>
      FavoriteCommand(
        id: id,
        name: name ?? this.name,
        command: command ?? this.command,
        sortOrder: sortOrder ?? this.sortOrder,
        aiEnabled: aiEnabled ?? this.aiEnabled,
      );

  /// Parameter names found in {{...}} placeholders, deduped in order.
  List<String> get params {
    final seen = <String>{};
    return RegExp(r'\{\{(\w+)\}\}')
        .allMatches(command)
        .map((m) => m.group(1)!)
        .where(seen.add)
        .toList();
  }

  bool get hasParams => params.isNotEmpty;

  /// **缺键会静默替换成空串。** 调用方必须先确认 [values] 覆盖了 [params]
  /// 里的每一项 —— 见 `saved_command_guard.dart` 的 `validateCommandParams`
  /// （另一个 agent 正在写那个文件）。现有的填参对话框按 [params] 逐个渲染
  /// 输入框，撞不上这个；模型可以只传一半，展开出的命令语法完整、语义错误，
  /// 而且会真的执行。
  String expand(Map<String, String> values) =>
      command.replaceAllMapped(
          RegExp(r'\{\{(\w+)\}\}'), (m) => values[m.group(1)!] ?? '');

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'command': command,
        'sort_order': sortOrder,
        'ai_enabled': aiEnabled ? 1 : 0,
      };

  factory FavoriteCommand.fromMap(Map<String, dynamic> m) => FavoriteCommand(
        id: m['id'] as String,
        name: m['name'] as String,
        command: m['command'] as String,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        aiEnabled: ((m['ai_enabled'] as int?) ?? 0) == 1,
      );
}
