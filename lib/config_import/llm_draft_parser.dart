// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'config_draft.dart';

/// 从模型回复里抠出第一个**完整的** JSON 对象。
///
/// 不用 `RegExp(r'\{[\s\S]*\}')`：贪婪匹配会从第一个 `{` 一路吃到最后一个
/// `}`。模型爱在 JSON 之后补一段解释，而解释里举例子时很容易又带花括号 ——
/// 两个对象之间的说明文字会被一起吞进来，`jsonDecode` 必然失败。更糟的是
/// 这通常是某个模型的**稳定习惯**而非偶发抖动，于是重试那一次会以完全相同
/// 的方式再失败一遍。
///
/// 括号配对扫描：从第一个 `{` 开始数深度，归零处就是这个对象的结尾。
/// 字符串字面量内部的花括号要跳过，否则 `{"a":"}"}` 会在错误的位置截断；
/// 转义符也要处理，否则 `{"a":"\""}` 会把转义的引号误判成字符串结束。
String? _firstJsonObject(String text) {
  final start = text.indexOf('{');
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final c = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == r'\') {
      escaped = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
    }
  }
  return null; // 花括号没闭合
}

/// 让模型把一段自由文本解析成服务器配置。失败返回 null。
///
/// ## 为什么收一个函数而不是 `AIProvider`
///
/// 这一层不该知道 provider 怎么来的、要不要流式、算不算钱。收
/// `Future<String> Function(String)` 让测试可以零成本注入假实现，也让
/// 「没配 provider」在调用方自然表达成「不调用本函数」，不需要本文件里有
/// 任何 null 判断。
///
/// ## 为什么只重试一次
///
/// 格式错误通常是模型的稳定倾向（这个模型就是爱加解释文字），重试三次大概率
/// 三次都错，白烧三份钱。重试一次覆盖的是偶发抖动。
Future<ServerDraft?> llmParseServerDraft(
  String text, {
  required Future<String> Function(String prompt) complete,
}) async {
  final prompt = _buildPrompt(text);
  for (var attempt = 0; attempt < 2; attempt++) {
    final String reply;
    try {
      reply = await complete(prompt);
    } catch (_) {
      // 网络/额度问题。不把异常抛给 UI —— 对用户来说「AI 没认出来」和
      // 「AI 调用失败」是同一件事：他得自己填。
      continue;
    }
    final draft = _parseReply(reply);
    if (draft != null) return draft;
  }
  return null;
}

String _buildPrompt(String text) => '''
Extract SSH server connection settings from the text below.

Reply with ONLY a JSON object, no explanation, no code fences. Use these keys:
  "name"     — a short label for this server (optional)
  "host"     — hostname or IP (REQUIRED)
  "port"     — SSH port number (optional, omit if unknown)
  "username" — login user (optional)

If the text does not describe a server, reply with {}.

Text:
$text
''';

ServerDraft? _parseReply(String reply) {
  final json0 = _firstJsonObject(reply);
  if (json0 == null) return null;
  final Map<String, dynamic> json;
  try {
    final decoded = jsonDecode(json0);
    if (decoded is! Map) return null;
    json = decoded.cast<String, dynamic>();
  } catch (_) {
    return null;
  }

  final host = json['host'];
  if (host is! String || host.trim().isEmpty) return null;

  // port 可能是数字也可能是字符串 —— 两种模型都见过。非法就丢字段，
  // 与确定性解析器的字段级降级保持一致。
  final rawPort = json['port'];
  final port = switch (rawPort) {
    int p => p,
    String s => int.tryParse(s),
    _ => null,
  };

  String? str(String key) {
    final v = json[key];
    return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
  }

  final prov = <String, String>{'host': 'AI 从文本中识别'};
  if (port != null) prov['port'] = 'AI 从文本中识别';
  if (str('username') != null) prov['username'] = 'AI 从文本中识别';

  return ServerDraft(
    name: str('name') ?? host.trim(),
    host: host.trim(),
    port: port,
    username: str('username'),
    provenance: Map.unmodifiable(prov),
  );
}
