// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../../data/models/favorite_command.dart';

/// 索引里单条命令模板的字节上限。超出的截断显示。
const int kMaxIndexedTemplateBytes = 200;

/// 把用户勾了「AI 可用」的收藏命令拼成 system prompt 里的一段。
///
/// 返回 null 表示一条都没有 —— 调用方据此完全跳过这一段，而不是塞一个空
/// 标题（与 `composeInstructions` / `composeSkillIndex` 同一约定）。
///
/// 每条三段：**用户起的名字** + **参数名列表** + **命令模板**。模板本身就是
/// 最好的描述，用户不需要再写一句说明。
///
/// ## 模板截断为什么是安全的
///
/// 这里有一个和 skills 的关键区别：skill 的正文是**给模型读的**（它要照着
/// 拼命令），而这里的模板**只是给模型判断相关性用的** —— 真正拼命令的是
/// 我们，用 `FavoriteCommand.expand()`。
///
/// 所以超长模板截断显示不会导致执行错误：模型只需要认出「这条命令是干什么
/// 的、要哪几个参数」，一条几百字符的 awk 管道截断后照样能认出来。
///
/// ## 条数与顺序由调用方负责
///
/// 这个函数原样输出传进来的顺序、不做条数截断。取前 N 条是
/// `AiCommandManager.indexEntries` 的事（另一个 agent 正在写）—— 那里才
/// 知道 `sortOrder`。
String? composeSavedCommandIndex(List<FavoriteCommand> commands) {
  if (commands.isEmpty) return null;
  final buf = StringBuffer();
  buf.writeln('--- saved commands (call `run_saved_command` by name) ---');
  for (final c in commands) {
    buf.writeln(
        '${c.name} [${c.params.join(', ')}]: ${_clipTemplate(c.command)}');
  }
  return buf.toString().trimRight();
}

/// 按字节截断模板并加省略号。
///
/// 不加 `[truncated at N bytes]` 那种标记 —— 这是**一行**，末尾挂一段说明
/// 会把行撑得更长，与限制它的目的相反。
///
/// 按字节切必然可能切断一个多字节字符，`allowMalformed` 让 decode 不抛，
/// 把残缺字节变成 U+FFFD 再删掉。直接 substring 按字符数切是错的 ——
/// 那样限不住字节数（一个中文字符 3 字节）。
String _clipTemplate(String s) {
  final bytes = utf8.encode(s);
  if (bytes.length <= kMaxIndexedTemplateBytes) return s;
  final cut = utf8.decode(bytes.sublist(0, kMaxIndexedTemplateBytes),
      allowMalformed: true);
  return '${cut.replaceAll('\u{FFFD}', '')}…';
}
