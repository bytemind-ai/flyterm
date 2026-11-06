import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ConfigBackupTile 的依赖接线回归测试。
///
/// **为什么需要这个文件**：2026-10-08 真机回归 —— 导出按钮点了没反应。
/// 根因是 `_export()` 新增了 `context.read<AgentSkillRepository>()` 与
/// `context.read<ServerNotesRepository>()`，但这两个 repo 在 `main.dart` 里
/// 是**内联构造**的、从未注册成 provider，运行时抛
/// `ProviderNotFoundException`。
///
/// 当时已有的测试全部只测 service 层（直接调 `ConfigBackupService`），没有
/// 一条覆盖「tile 会去读哪些 provider」，所以全绿却上线即坏。
///
/// **为什么不用 widget test 点按钮**：`_export()` 会 await sqflite，而
/// `testWidgets` 跑在 FakeAsync 区里，sqflite（后台 isolate）的 Future 永不
/// 完成 —— `pumpAndSettle` 直接超时（已实测确认，连 `timeout()` 都不触发）。
///
/// **本文件的检查方式**：对 `ConfigBackupTile` 用到的每个类型，在
/// `main.dart` 的 providers 列表里找它的注册。判据不放宽 —— 见下。
void main() {
  /// main.dart 里被注册的类型集合。
  ///
  /// 直接扫 `providers: [...]` 那一段，而不是全文 —— 全文里 `AppControlService`
  /// 等处也出现类型名，会造成假阳性。
  Set<String> registeredTypes() {
    final src = File('lib/main.dart').readAsStringSync();

    // providers 列表的边界：第一个 `providers: [` 到与其配对的 `],`
    final start = src.indexOf('providers: [');
    expect(start, greaterThan(0), reason: 'main.dart 里找不到 providers 列表');
    final end = src.indexOf('\n      ],', start);
    expect(end, greaterThan(start), reason: 'providers 列表没有结束标记');
    final block = src.substring(start, end);

    final types = <String>{};

    // 形态 A：Provider<X> / ChangeNotifierProvider<X> —— 直接拿类型参数
    for (final m in RegExp(
            r'(?:ChangeNotifier)?Provider<([A-Za-z_][A-Za-z0-9_]*)>')
        .allMatches(block)) {
      types.add(m.group(1)!);
    }

    // 形态 B：Provider(create: (_) => X(...)) —— 从构造调用取类型名
    for (final m in RegExp(r'create:\s*\([^)]*\)\s*=>\s*([A-Za-z_]\w*)\(')
        .allMatches(block)) {
      types.add(m.group(1)!);
    }

    // 形态 C：Provider.value(value: foo) —— 回到全文反查 foo 的声明。
    //
    // 按「最具体到最宽泛」的顺序试探，命中即止。顺序很要紧：先试
    // `final foo = X(...)`，再试 `final foo = await X.y()`，最后才试
    // `X foo = ...`。反过来会把 `final` 本身当成类型名（踩过）。
    final all = src;
    for (final m in RegExp(r'Provider(?:<[^>]*>)?\.value\(\s*value:\s*(\w+)')
        .allMatches(block)) {
      final v = RegExp.escape(m.group(1)!);

      // C1: final foo = X(...)
      final c1 = RegExp(
              r'\b(?:final|late\s+final|const)\s+' + v + r'\s*=\s*([A-Z]\w*)\(')
          .firstMatch(all);
      if (c1 != null) {
        types.add(c1.group(1)!);
        continue;
      }

      // C2: final foo = await X.y(...)  → 反查 X.y 的 static Future<T> 返回类型
      final c2 = RegExp(r'\b(?:final|late\s+final|const)\s+' +
              v +
              r'\s*=\s*await\s+([A-Z]\w*)\.(\w+)\(')
          .firstMatch(all);
      if (c2 != null) {
        final ownerFile = _fileForClass(c2.group(1)!);
        if (ownerFile != null) {
          final ret = RegExp(r'static\s+Future<([A-Z]\w*)>\s+' +
                  RegExp.escape(c2.group(2)!) +
                  r'\(')
              .firstMatch(ownerFile);
          if (ret != null) types.add(ret.group(1)!);
        }
        continue;
      }

      // C3: X foo = ...（显式类型声明）。类型必须以大写开头，且不能是关键字。
      final c3 = RegExp(r'\b([A-Z]\w*)\s+' + v + r'\s*[;=]').firstMatch(all);
      if (c3 != null) types.add(c3.group(1)!);
    }

    return types;
  }

  test('ConfigBackupTile 读的每个 provider 类型都在 main.dart 注册过', () {
    final tile =
        File('lib/ui/settings/config_backup_tile.dart').readAsStringSync();
    final reads = RegExp(r'\.(?:read|select)<([A-Za-z_][A-Za-z0-9_]*)>')
        .allMatches(tile)
        .map((m) => m.group(1)!)
        .toSet();

    // 正则失效的保护：tile 里确实有一批 read<X>()。
    expect(reads.length, greaterThanOrEqualTo(8),
        reason: '只扫到 ${reads.length} 个 read<X>() —— 正则可能失效了');

    final registered = registeredTypes();
    expect(registered.length, greaterThanOrEqualTo(8),
        reason: '只解析出 ${registered.length} 个已注册类型 —— 解析可能失效了');

    final missing = reads.difference(registered);
    expect(missing, isEmpty,
        reason: 'main.dart 未注册这些类型：$missing\n'
            'ConfigBackupTile 会在运行时抛 ProviderNotFoundException —— '
            '这正是 2026-10-08「导出不可用」的根因。');
  });
}

/// 在 lib/ 下找定义 [className] 的文件内容（只在 data/ 与根下扫，够用）。
String? _fileForClass(String className) {
  for (final dir in ['lib/data', 'lib', 'lib/ssh', 'lib/ai']) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: dir == 'lib')) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final c = f.readAsStringSync();
      if (RegExp(r'^class\s+' + RegExp.escape(className) + r'\b',
              multiLine: true)
          .hasMatch(c)) {
        return c;
      }
    }
  }
  return null;
}
