// SPDX-License-Identifier: GPL-3.0-or-later
/// 内置 + 用户技能的名字合并，**内置在前、同名去重**。
///
/// 抽成纯函数而不是写在 `terminal_screen.dart` 的闭包里：合并顺序就是
/// `load_skill` 的优先级，是行为不是装配，必须能单测。
///
/// 同名时丢掉用户那条 —— `resolveSkillBody` 内置优先，留着它只会让模型在
/// 索引里看到一个名字、load 到另一份正文。
List<String> mergeSkillNames({
  required List<String> builtin,
  required List<String> user,
}) {
  final seen = builtin.map((e) => e.toLowerCase()).toSet();
  return [
    ...builtin,
    ...user.where((u) => !seen.contains(u.toLowerCase())),
  ];
}

/// 按名字取正文：**先内置（同步命中），再用户技能（异步读库）**。
///
/// 签名刻意与 `AgentLoop.skillBodyProvider` 一致，装配处可以直接把它偏应用
/// 之后传进去，`skill_executors.dart` 一行不用改。
Future<String?> resolveSkillBody({
  required String name,
  required String? Function(String) builtinBody,
  required Future<String?> Function(String, {Set<String> alsoAllow}) userBody,
  Set<String> alsoAllow = const {},
}) async {
  final hit = builtinBody(name);
  if (hit != null) return hit;
  return userBody(name, alsoAllow: alsoAllow);
}
