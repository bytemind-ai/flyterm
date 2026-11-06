// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/repositories/agent_skill_repository.dart';
import 'skill.dart';

/// 从启用的技能里挑出进索引的那些，**两段名额**。
///
/// 1. 前 [kIndexMeritSlots] 格按使用分数：用过的优先 → 最近用的优先 →
///    命中多的优先 → 内容新的优先
/// 2. 后 [kIndexFreshSlots] 格从剩下的里按 `updatedAt` 取最新，保证刚存入
///    的一定看得见
///
/// 纯函数、无 IO：冷启动饥饿与名额边界都能直接单测，不必装配数据库。
///
/// 入参应当只含 `enabled == true` 的条目，过滤由调用方做。
List<AgentSkill> selectIndexed(List<AgentSkill> enabled) {
  if (enabled.length <= kMaxIndexedSkills) return List.of(enabled);

  final byMerit = List.of(enabled)
    ..sort((a, b) {
      // 用过的整体压过没用过的。两者都没用过时这一项打平，落到最后的
      // updatedAt 比较，于是退化成改造前的行为。
      final au = a.lastUsedAt, bu = b.lastUsedAt;
      if ((au == null) != (bu == null)) return au == null ? 1 : -1;
      if (au != null && bu != null) {
        final c = bu.compareTo(au);
        if (c != 0) return c;
      }
      final h = b.hitCount.compareTo(a.hitCount);
      if (h != 0) return h;
      return b.updatedAt.compareTo(a.updatedAt);
    });

  final picked = byMerit.take(kIndexMeritSlots).toList();
  final pickedIds = picked.map((s) => s.id).toSet();

  final fresh = byMerit.where((s) => !pickedIds.contains(s.id)).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  return [...picked, ...fresh.take(kIndexFreshSlots)];
}

/// 技能库。**索引在内存里，正文在库里。**
///
/// ## 为什么必须有内存缓存
///
/// `terminal_screen.dart` 的 `systemPromptProvider` 是个**同步**闭包
/// （`() => buildAgentSystemPrompt(...)`），里面的 `mgr.instructions` 是
/// 同步的 prefs 读。技能索引每一轮都要拼进那份 prompt，所以 [indexEntries]
/// 必须是同步 getter —— 这是整个存储设计被劈成两半的根本原因，不是性能
/// 优化。
///
/// 正文没有这个约束：`load_skill` 本来就在 async 的 `_executeOne` 里。
///
/// 不并进 `AgentSessionManager`：那个类已经 633 行、管着规则 / 模式 / 指令 /
/// 会话归档 / loop 生命周期五件事，而且它全是 SharedPreferences，技能是
/// SQLite。
class AgentSkillManager extends ChangeNotifier {
  final AgentSkillRepository _repo;

  List<AgentSkill> _skills = const [];

  AgentSkillManager(this._repo);

  /// 全部技能，按 `updatedAt` 倒序。列表页用它（含被禁用、被挤出索引的）。
  List<AgentSkill> get skills => _skills;

  /// 进 system prompt 的那些。**同步**，见类文档。
  List<SkillIndexEntry> get indexEntries =>
      selectIndexed(_skills.where((s) => s.enabled).toList())
          .map((s) => SkillIndexEntry(name: s.name, description: s.description))
          .toList(growable: false);

  /// 索引里的 name，`load_skill` 的匹配与错误提示都用它。
  List<String> get names =>
      indexEntries.map((e) => e.name).toList(growable: false);

  /// 启用但因为超出上限而没进索引的条数。列表页据此显示警告。
  int get overflowCount {
    final enabled = _skills.where((s) => s.enabled).length;
    return enabled > kMaxIndexedSkills ? enabled - kMaxIndexedSkills : 0;
  }

  /// 索引每轮的 token 估算，给设置页那行预算用。
  ///
  /// 按 chars/3.5 粗估，与 `kMaxInstructionBytes` 注释里的口径一致。它是
  /// 给用户看的量级，不参与任何判断，所以不必精确。
  int get indexTokenEstimate {
    final text = indexEntries
        .map((e) => '${e.name}: ${e.description}')
        .join('\n');
    return (utf8.encode(text).length / 3.5).round();
  }

  /// 从库里重读全量。构造之后必须调一次。
  Future<void> reload() async {
    _skills = await _repo.all();
    notifyListeners();
  }

  /// 读正文。**只认「进了索引」或「本会话搜到过」的那些** —— 二者都不占的
  /// 一律返回 null。
  ///
  /// ## [alsoAllow]：检索加进来的第二条放行路径
  ///
  /// [alsoAllow] 是**本会话** `search_skills` 确认存在过的名字（小写）。
  ///
  /// 原先只放行进了索引的条目，理由是「模型可能从更早的对话里记得那个 name」
  /// ——拦的是凭记忆猜名字，不是安全边界。加了检索之后，模型会合法地知道索引
  /// 外的名字，所以白名单成为第二个放行来源：本会话真搜到过的可以 load，凭
  /// 记忆猜的照旧被拦。上限的语义从「能 load 的总数」变成「不搜索就能看见的
  /// 数量」，依然成立。
  ///
  /// ## 命中时记账，但**不刷新内存**
  ///
  /// `markUsed` 只写库，不 `reload()`、不 `notifyListeners()`。索引段每轮
  /// 随 system prompt 重发，是 prompt cache 公共前缀的一部分；会话中途重排
  /// 等于每次 `load_skill` 都击穿一次 cache，为了排序精确去烧 token 完全
  /// 划不来。新排序在下一次 [reload] 时生效（app 启动、增删改、开面板）。
  Future<String?> bodyOf(
    String name, {
    Set<String> alsoAllow = const {},
  }) async {
    final key = name.trim().toLowerCase();
    final inIndex = names.any((n) => n.toLowerCase() == key);
    if (!inIndex && !alsoAllow.contains(key)) return null;
    final body = await _repo.bodyOf(name);
    if (body != null) await _repo.markUsed(name);
    return body;
  }

  /// 按 name 读附件。
  ///
  /// **白名单判定与 [bodyOf] 完全一致** —— 两边各自实现一套的话，
  /// `install_skill_assets` 就会成为绕过索引上限的后门（load 不到但装得到）。
  /// 这里不记账（`markUsed` 只由 `load_skill` 记）：附件安装不是「这条知识
  /// 被用上了」的信号，它只是 load 的一个后续动作。
  Future<List<AgentSkillAsset>> assetsOf(
    String name, {
    Set<String> alsoAllow = const {},
  }) async {
    final key = name.trim().toLowerCase();
    final inIndex = names.any((n) => n.toLowerCase() == key);
    if (!inIndex && !alsoAllow.contains(key)) return const [];
    return _repo.assetsOf(name);
  }

  Future<void> save({
    required String name,
    required String description,
    required String body,
    required SkillSource source,
    List<AgentSkillAsset>? assets,
  }) async {
    await _repo.upsert(
        name: name,
        description: description,
        body: body,
        source: source,
        assets: assets);
    await reload();
  }

  Future<void> updateFields(int id,
      {String? description,
      String? body,
      List<AgentSkillAsset>? assets}) async {
    await _repo.updateFields(id,
        description: description, body: body, assets: assets);
    await reload();
  }

  Future<void> setEnabled(int id, bool enabled) async {
    await _repo.setEnabled(id, enabled);
    await reload();
  }

  Future<void> delete(int id) async {
    await _repo.delete(id);
    await reload();
  }
}
