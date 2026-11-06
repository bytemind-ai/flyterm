// SPDX-License-Identifier: GPL-3.0-or-later
/// 一条出厂自带的技能。
///
/// **不复用 `AgentSkill`**：那个类的 `id` / `source` / `hitCount` /
/// `lastUsedAt` 全部是为了参与 25+5 索引名额竞争而存在的。内置技能不参与
/// 竞争，带上这些字段等于让读代码的人以为它们有意义，然后花十分钟去找是谁
/// 在维护 `hitCount`。
class BuiltinSkill {
  final String name;
  final String description;
  final String body;

  const BuiltinSkill({
    required this.name,
    required this.description,
    required this.body,
  });
}

/// 内置技能的 asset 路径清单。
///
/// **写死而不是用 `AssetManifest` 枚举**：枚举是 async 的（与
/// `BuiltinSkillManager.entries` 必须同步这条约束冲突），而且会把将来任何
/// 误放进这个目录的文件当技能加载。加技能时改两处（加文件 + 加一行），换来
/// 的是"目录里有什么"在代码里一眼可见。
const List<String> kBuiltinSkillAssets = [
  'assets/builtin_skills/troubleshoot.md',
  'assets/builtin_skills/plan-change.md',
  'assets/builtin_skills/skill-creator.md',
];
