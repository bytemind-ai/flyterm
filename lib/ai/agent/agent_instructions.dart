// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

/// 单份指令的字节上限。
///
/// 指令进的是 **system prompt**，每一轮都要重发一次。不设上限等于给用户
/// 一把烧钱的枪：一份 50 KiB 的机器笔记在 20 轮会话里会被重发 20 次。
///
/// 4 KiB 约合 1200 token（按 chars/3.5 粗估，中文更少），够写清一台服务器
/// 的环境约定，又不至于让固定开销失控。
const int kMaxInstructionBytes = 4096;

/// 把全局指令与这台机器的笔记拼成一段能直接塞进 system prompt 的文本。
///
/// 返回 null 表示两份都是空的——调用方据此完全跳过这一段，而不是往
/// prompt 里塞一个空标题。
///
/// **两份各自独立截断**，不是拼起来再截：后者会让「全局那份太长」把机器
/// 笔记整段挤掉，而用户完全看不出发生了这件事。
///
/// [machine] 来自 `ServerNotesManager.noteFor()`，是 **app 端存储**。它曾经
/// 是从远端服务器上的一个笔记文件读来的，2026-10 改为 app 端落库 ——
/// 判准是「单一真相源优先于跟随载体」。
String? composeInstructions({String? global, String? machine}) {
  final parts = <String>[];
  final g = _clip(global);
  final m = _clip(machine);
  if (g != null) {
    parts.add('--- operator instructions for this server ---\n$g');
  }
  if (m != null) {
    parts.add('--- Notes about this server ---\n$m');
  }
  if (parts.isEmpty) return null;
  return parts.join('\n\n');
}

/// 去空白 + 按字节截断。空串一律折成 null，让调用方只需判一次 null。
String? _clip(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty) return null;
  return clipToBytes(t, kMaxInstructionBytes);
}

/// 按 UTF-8 字节数截断，超长时追加 `[truncated at N bytes]` 标记。
///
/// **不能用 substring 按字符数切** —— 那样限不住字节数（一个中文字符 3
/// 字节）。按字节切又必然可能切断一个多字节字符，所以 decode 时用
/// `allowMalformed` 让它不抛，把残缺字节变成 U+FFFD 再删掉。
///
/// skill 正文与指令共用这一份：两处都是「进 prompt 的文本，必须限字节」，
/// 抄第二份意味着这个坑要再踩一次。
String clipToBytes(String s, int maxBytes) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return s;
  final cut = utf8.decode(bytes.sublist(0, maxBytes), allowMalformed: true);
  final clean = cut.replaceAll('\u{FFFD}', '');
  return '$clean\n[truncated at $maxBytes bytes]';
}
