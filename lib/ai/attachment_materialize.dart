// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'ai_message.dart';
import 'attachment.dart';
import 'attachment_store.dart';

/// 把历史里的图片附件读成 base64，返回一份可以直接交给 provider 的副本。
///
/// **为什么需要这一步**：provider 的消息拼装全是同步函数
/// （`_msgToJson` / `_buildToolMessages`），没法在里面 `await` 读文件。所以
/// 在调 provider 之前先把字节读好，塞进 `Attachment.b64`（那个字段不进
/// `toJson`，见它的 dartdoc）。
///
/// **不改原消息**：`_history` 里存的始终是不带 b64 的版本，否则归档就会把
/// base64 写进 SQLite。
///
/// 读不到文件的图片**直接从列表里剔除**：文件可能已被用户清数据删掉，而
/// `content` 里的文字是完好的 —— 少一个 image block 比整条消息发不出去好。
Future<List<AIMessage>> materializeAttachments(
  List<AIMessage> history,
  AttachmentStore store,
) async {
  final out = <AIMessage>[];
  for (final m in history) {
    final atts = m.attachments;
    if (atts == null || atts.isEmpty) {
      out.add(m); // 绝大多数消息走这条路，不造新对象
      continue;
    }
    final materialized = <Attachment>[];
    for (final a in atts) {
      if (a.kind != AttachmentKind.image) {
        materialized.add(a);
        continue;
      }
      final bytes = await store.readBytes(a);
      if (bytes == null) continue; // 丢失 → 剔除
      materialized.add(a.withB64(base64Encode(bytes)));
    }
    out.add(AIMessage(
      role: m.role,
      content: m.content,
      type: m.type,
      command: m.command,
      displayText: m.displayText,
      toolCalls: m.toolCalls,
      toolResults: m.toolResults,
      attachments: materialized,
    ));
  }
  return out;
}
