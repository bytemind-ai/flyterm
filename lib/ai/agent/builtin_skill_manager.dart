// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ai/agent/builtin_skill_manager.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'builtin_skill.dart';
import 'skill.dart';

/// 出厂自带技能。**索引与正文都在内存里**。
///
/// ## 为什么必须是同步 getter
///
/// `terminal_screen.dart` 的 `systemPromptProvider` 是个**同步**闭包，技能
/// 索引每轮都要拼进那份 prompt。这与 `AgentSkillManager` 受同一条约束（见
/// 那个类的文档）—— 区别只在于内置技能的正文也一起常驻：两条加起来约 6 KB，
/// 没有像用户技能那样把正文留在数据库里的必要。
///
/// 注意「常驻内存」与「进 context」是两回事：正文只有在 `load_skill` 命中时
/// 才作为 tool result 进入对话历史，用完能被 compaction 回收。
class BuiltinSkillManager extends ChangeNotifier {
  /// 被禁用的技能名（小写）。
  ///
  /// **存"被禁用的"而不是"被启用的"**：默认全开，将来新增的内置技能会自动
  /// 生效。反过来存启用列表的话，新增一条会因为不在老列表里而静默失效 ——
  /// 而且是升级后才出现、本地永远复现不了的那种失效。
  static const String kDisabledPrefsKey = 'builtin_skills_disabled';

  final SharedPreferences _prefs;

  List<BuiltinSkill> _all = const [];

  BuiltinSkillManager(this._prefs);

  /// 全部内置技能（含被禁用的）。设置页列表用它。
  List<BuiltinSkill> get all => _all;

  Set<String> get _disabled =>
      (_prefs.getStringList(kDisabledPrefsKey) ?? const [])
          .map((e) => e.toLowerCase())
          .toSet();

  bool isEnabled(String name) => !_disabled.contains(name.toLowerCase());

  /// 进 system prompt 的那些。**同步**，见类文档。
  List<SkillIndexEntry> get entries => _all
      .where((s) => isEnabled(s.name))
      .map((s) => SkillIndexEntry(name: s.name, description: s.description))
      .toList(growable: false);

  List<String> get names =>
      entries.map((e) => e.name).toList(growable: false);

  /// 全部内置技能的名字，**含被禁用的**。撞名判定用这个，不要用 [names]。
  ///
  /// 内置技能的名字是**保留**的，禁用并不把它释放出来。否则会出现这条路径：
  /// 用户禁用 `plan-change` → 存一条同名的自己的技能（此时能读到，因为
  /// 内置被禁、`bodyOf` 返回 null）→ 过几天重新启用内置 → 自己那条被永久
  /// 遮住，而设置页里它还显示着「已启用」。
  ///
  /// 三处撞名判定必须都用它：`save_skill`（AI 存）、手动新建页、导入预览页。
  List<String> get allNames =>
      _all.map((s) => s.name).toList(growable: false);

  /// 索引每轮的 token 估算。口径与 `AgentSkillManager.indexTokenEstimate`
  /// 一致（chars/3.5），因为设置页把两者相加显示成一个数。
  int get indexTokenEstimate {
    if (entries.isEmpty) return 0;
    final text =
        entries.map((e) => '${e.name}: ${e.description}').join('\n');
    return (utf8.encode(text).length / 3.5).round();
  }

  /// 读正文。**同步**，不碰数据库。被禁用的返回 null —— 与
  /// `AgentSkillRepository.bodyOf` 同一个语义：禁用了却还能 load，那个开关
  /// 就没有意义。
  String? bodyOf(String name) {
    final key = name.trim().toLowerCase();
    if (!isEnabled(key)) return null;
    for (final s in _all) {
      if (s.name.toLowerCase() == key) return s.body;
    }
    return null;
  }

  /// 从 assets 读全部内置技能。`main.dart` 里 await 一次。
  ///
  /// [bundle] 只为测试注入，生产走 `rootBundle`。
  ///
  /// **解析失败/文件缺失时跳过并记日志，不抛**：一条内置技能的 frontmatter
  /// 写坏了不该让整个 App 起不来 —— 与 `AgentSkillRepository._fromRow` 对
  /// 未知 `source` 的处理同一个理由。
  Future<void> load({AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    final out = <BuiltinSkill>[];
    for (final path in kBuiltinSkillAssets) {
      try {
        final raw = await b.loadString(path);
        final parsed = parseSkillMarkdown(raw, fallbackName: '');
        if (parsed.error != null ||
            parsed.name.isEmpty ||
            parsed.description.trim().isEmpty) {
          debugPrint('[builtin-skill] skipped $path: '
              '${parsed.error ?? "missing name/description"}');
          continue;
        }
        out.add(BuiltinSkill(
          name: parsed.name,
          description: parsed.description,
          body: parsed.body,
        ));
      } catch (e) {
        debugPrint('[builtin-skill] failed to load $path: $e');
      }
    }
    _all = List.unmodifiable(out);
    notifyListeners();
  }

  Future<void> setEnabled(String name, bool enabled) async {
    final key = name.trim().toLowerCase();
    final next = _disabled;
    if (enabled) {
      next.remove(key);
    } else {
      next.add(key);
    }
    await _prefs.setStringList(kDisabledPrefsKey, next.toList()..sort());
    notifyListeners();
  }
}
