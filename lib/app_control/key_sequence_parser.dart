// SPDX-License-Identifier: GPL-3.0-or-later
import '../data/keybar_config.dart';

/// 解析失败。[message] 直接回给模型，所以必须自带可用名清单。
class KeySequenceParseError implements Exception {
  final String message;
  KeySequenceParseError(this.message);
  @override
  String toString() => message;
}

/// 把 `"cd [tab]"` 这样的字符串解析成 [KeyToken] 列表。
///
/// ## 为什么是字符串而不是嵌套 JSON
///
/// [KeyToken] 是 sealed 层级（[TextToken] / [SpecialToken]），让模型构造
/// `[{"type":"text","text":"cd "},{"type":"special","key":"tab"}]` 这种嵌套
/// 结构既费 token 又容易出错 —— 它每多一层括号就多一次写坏的机会。
/// 占位符语法对模型来说是纯文本，写错了也只是字符串内容错，不会把整个
/// 工具调用的 JSON 结构带坏。
///
/// ```
/// "git status\n"  → [TextToken('git status'), SpecialToken(enter)]
/// "[ctrl-c]"      → [SpecialToken(ctrlC)]
/// "cd [tab]"      → [TextToken('cd '), SpecialToken(tab)]
/// ```
///
/// 占位符名是 [SpecialKey] 的 kebab-case 形式（`ctrlC` → `ctrl-c`，
/// `pageUp` → `page-up`）。匹配大小写无关，但**不做模糊匹配** —— 猜错一个
/// 键名的代价是用户按下去发出错误的字节，比报错严重得多。
List<KeyToken> parseKeySequence(String input) {
  if (input.isEmpty) {
    throw KeySequenceParseError('Key sequence must not be empty.');
  }

  final tokens = <KeyToken>[];
  final buf = StringBuffer();

  void flush() {
    if (buf.isNotEmpty) {
      tokens.add(TextToken(buf.toString()));
      buf.clear();
    }
  }

  var i = 0;
  while (i < input.length) {
    final ch = input[i];

    if (ch == '[') {
      // `[[` → 字面量 `[`。**必须在找 `]` 之前判**：`a[[b` 里压根没有 `]`，
      // 先找闭括号会让它误报 Unclosed。没有这条转义，键序列里就永远打不出
      // 一个左方括号。
      if (i + 1 < input.length && input[i + 1] == '[') {
        buf.write('[');
        i += 2;
        continue;
      }
      final close = input.indexOf(']', i + 1);
      if (close == -1) {
        throw KeySequenceParseError(
          'Unclosed `[` at position $i. Use `[name]` for special keys, '
          'or escape a literal bracket as `[[`.',
        );
      }
      // **先 flush**：缓冲里攒着的文本在这个特殊键之前，不先吐出来顺序就反了
      // （`cd [tab]` 会解析成 [tab, "cd "]）。
      flush();
      tokens.add(SpecialToken(_lookup(input.substring(i + 1, close))));
      i = close + 1;
      continue;
    }

    // 换行写法：`\n` 已经被 JSON 解码成真实换行，直接当 enter。
    if (ch == '\n') {
      flush();
      tokens.add(const SpecialToken(SpecialKey.enter));
      i++;
      continue;
    }
    if (ch == '\t') {
      flush();
      tokens.add(const SpecialToken(SpecialKey.tab));
      i++;
      continue;
    }

    buf.write(ch);
    i++;
  }
  flush();

  if (tokens.isEmpty) {
    throw KeySequenceParseError('Key sequence must not be empty.');
  }
  return tokens;
}

/// `ctrlC` → `ctrl-c`，`pageUp` → `page-up`，`f1` → `f1`。
String kebab(SpecialKey k) =>
    k.name.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) {
      return '${m[1]}-${m[2]!.toLowerCase()}';
    });

SpecialKey _lookup(String raw) {
  final want = raw.trim().toLowerCase();
  for (final k in SpecialKey.values) {
    // 同时接受 kebab (`ctrl-c`) 和原始 enum 名 (`ctrlC`) —— 模型两种都可能写。
    if (kebab(k) == want || k.name.toLowerCase() == want) return k;
  }
  throw KeySequenceParseError(
    'Unknown special key `$raw`. Available: '
    '${SpecialKey.values.map(kebab).join(', ')}.',
  );
}
