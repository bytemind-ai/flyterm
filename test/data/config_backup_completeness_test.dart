import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/data/config_backup_service.dart';

/// 备份覆盖完整性护栏。
///
/// Dart 在 Flutter AOT 下没有 `dart:mirrors`，无法自动枚举 getter，所以这套
/// 护栏是**显式清单 + 一致性测试**的半自动方案。它的价值在于把「新增了
/// TerminalSettings 字段但忘了处理备份」从静默数据丢失变成测试红灯。
///
/// 历史：`commandCompletion` 与 `backgroundKeepAlive` 就是这么丢的 —— 两个都有
/// UI、有持久化，却不在导出列表里。
void main() {
  final source = File('lib/data/config_backup_service.dart').readAsStringSync();

  /// 从 `_applySettings` 函数体里提取 `s['xxx']` 字面量 —— 导入端的读取键。
  ///
  /// **必须限定在函数体内**：全文件扫描会误伤 `counts['ai_providers']`（第 467 行
  /// 的局部变量也叫 `s`）—— 那是预览计数，不是 TerminalSettings 的键。
  Set<String> extractAppliedKeys() {
    final start = source.indexOf('static Future<void> _applySettings');
    expect(start, greaterThan(0), reason: '找不到 _applySettings');
    // 函数体一直延伸到下一个 `\n  }`（两空格缩进的闭合花括号）
    final bodyStart = source.indexOf('{', start);
    var depth = 0;
    var end = source.length;
    for (var i = bodyStart; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    final block = source.substring(bodyStart, end);
    final re = RegExp(r"s\['([a-z_]+)'\]", multiLine: true);
    return re.allMatches(block).map((m) => m.group(1)!).toSet();
  }

  test('导出键集 == backupSettingsKeys', () {
    final start = source.indexOf('static Map<String, dynamic> _settingsToMap');
    expect(start, greaterThan(0), reason: '找不到 _settingsToMap');
    final end = source.indexOf('static Future<void> _applySettings', start);
    expect(end, greaterThan(start), reason: '找不到 _settingsToMap 的结尾');
    final block = source.substring(start, end);

    final re = RegExp(r"'([a-z_]+)':");
    final exported = re.allMatches(block).map((m) => m.group(1)!).toSet()
      ..remove('checksum');

    expect(exported, equals(ConfigBackupService.backupSettingsKeys),
        reason: '导出键与 backupSettingsKeys 不一致 —— 加了字段没同步清单？');
  });

  test('导入键集 == backupSettingsKeys', () {
    expect(extractAppliedKeys(), equals(ConfigBackupService.backupSettingsKeys),
        reason: '导入处理的键与 backupSettingsKeys 不一致 —— 加了导出忘了导入？');
  });

  test('getter 全集 == backupSettingsKeys(camel) ∪ excludedSettingsFields', () {
    // 硬编码的 getter 快照。**新增 TerminalSettings 字段时这条会失败** ——
    // 那就是提醒：去决定「补备份」还是「加豁免理由」。
    const getters = {
      'backgroundKeepAlive',
      'commandCompletion',
      'cursorBlink',
      'cursorStyle',
      'dangerousCommandGuard',
      'debugOverlay',
      'downloadsToPublicStore',
      'fetAutoFade',
      'fetEnabled',
      'fetHidden',
      'fetOnboardingShown',
      'fetOpacity',
      'fetY',
      'fontFamily',
      'fontSize',
      'keyboardTrigger',
      'lineHeight',
      'selectionColor',
      'sftpCustomDownloadPath',
      'sftpDownloadDir',
      'sshCompression',
      'terminalTheme',
    };

    String toCamel(String snake) {
      final parts = snake.split('_');
      return parts.first +
          parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
    }

    final backedUp = ConfigBackupService.backupSettingsKeys.map(toCamel).toSet();
    final excluded = ConfigBackupService.excludedSettingsFields.keys.toSet();

    expect(backedUp.intersection(excluded), isEmpty,
        reason: '同一字段不能既备份又豁免');
    expect(backedUp.union(excluded), equals(getters),
        reason: 'getter 全集与「备份 ∪ 豁免」不相等 —— '
            '新增了 TerminalSettings 字段？请决定补备份或加豁免理由。');
  });

  test('每个豁免项都必须写明理由', () {
    for (final e in ConfigBackupService.excludedSettingsFields.entries) {
      expect(e.value.trim(), isNotEmpty, reason: '${e.key} 的豁免理由为空');
    }
  });
}
