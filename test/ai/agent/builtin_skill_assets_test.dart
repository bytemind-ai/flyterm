import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';

/// 直接用 dart:io 读仓库文件，不走 rootBundle：
/// 这条测试要钉住的是**磁盘上那份文件**的字节数，而 rootBundle 在测试环境
/// 里读到的是构建产物，中间多一层就多一种"测试过了但发布的不是这份"的可能。
///
/// 提取原始正文（clipToBytes 截断之前）的逻辑，与 `parseSkillMarkdown`
/// 内部一致（见 lib/ai/agent/skill.dart）：
///
/// ```dart
/// final text = raw.replaceAll('\r\n', '\n').trim();
/// final end = text.indexOf('\n---', 3);
/// final afterMarker = text.indexOf('\n', end + 1);
/// final body = afterMarker < 0 ? '' : text.substring(afterMarker + 1).trim();
/// ```
///
/// 只是不对 body 调用 `clipToBytes` —— 量的是截断前的正文，否则量到的就是
/// 截断器本身的输出，而不是我们要护栏的东西。
String _rawBody(String raw) {
  final text = raw.replaceAll('\r\n', '\n').trim();
  final end = text.indexOf('\n---', 3);
  final afterMarker = text.indexOf('\n', end + 1);
  return afterMarker < 0 ? '' : text.substring(afterMarker + 1).trim();
}

void main() {
  const paths = [
    'assets/builtin_skills/troubleshoot.md',
    'assets/builtin_skills/plan-change.md',
    'assets/builtin_skills/skill-creator.md',
  ];

  for (final p in paths) {
    test('$p 存在且能解析出 name / description', () async {
      final raw = await File(p).readAsString();
      final parsed = parseSkillMarkdown(raw, fallbackName: 'FALLBACK');
      expect(parsed.error, isNull, reason: 'frontmatter 解析失败');
      expect(parsed.name, isNot('FALLBACK'), reason: 'name 必须写在 frontmatter 里');
      expect(parsed.description.trim(), isNotEmpty);
      expect(parsed.body.trim(), isNotEmpty);
    });

    test('$p 的 description 不超过 $kMaxSkillDescriptionBytes 字节', () async {
      final raw = await File(p).readAsString();
      final parsed = parseSkillMarkdown(raw, fallbackName: 'x');
      // parseSkillMarkdown 会裸截断 description，所以这里比对的是"截断后 ==
      // 截断前"，否则测试自己把证据抹掉了。
      final descLine = RegExp(r'^description:\s*(.*)$', multiLine: true)
          .firstMatch(raw)!
          .group(1)!
          .trim();
      expect(utf8.encode(descLine).length,
          lessThanOrEqualTo(kMaxSkillDescriptionBytes));
      expect(parsed.description, equals(descLine));
    });

    test('$p 的正文严格小于 $kMaxSkillBodyBytes 字节 —— 超了会被静默截断', () async {
      final raw = await File(p).readAsString();
      // 不能用 parsed.body：它已经被 clipToBytes 截过了，量它等于量截断器。
      // 必须量原始正文（截断前）。
      final body = _rawBody(raw);
      expect(utf8.encode(body).length, lessThan(kMaxSkillBodyBytes),
          reason: '超出后 clipToBytes 会砍掉文件尾部 —— 正是 Verify 阶段和红旗表');
    });
  }
}
