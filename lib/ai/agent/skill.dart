// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'agent_instructions.dart' show clipToBytes;

/// 单条 description 的字节上限。
///
/// 它是**索引的计价单位** —— 每条约 30 token，且每一轮都随 system prompt
/// 重发。正文可以很长（用完就能被 compaction 回收），这一行不行。
const int kMaxSkillDescriptionBytes = 200;

/// 单份正文的字节上限。
///
/// 与 `bash` 的输出截断阈值同一个数，理由相同：两者最终都落在对话历史里，
/// 对上下文预算的压力是一回事。
const int kMaxSkillBodyBytes = 8192;

/// 一份技能的附件数上限。
///
/// 附件要逐个投送到远端，每多一个是多一次写入。8 个足够覆盖「一两个脚本 +
/// 一两个模板 + 一份参考文档」这个常见形状，同时让批量投送的命令规模和审批
/// 卡的展示长度都在可控范围。
const int kMaxSkillAssets = 8;

/// 单个附件的字节上限。
///
/// 比 `kMaxEditFileBytes`（6000，`write_file` 的上限）更小：一个技能可能带
/// 多个附件，投送时它们**合并成一条命令**，单条命令的体积要留出余量。
const int kMaxSkillAssetBytes = 4096;

/// 一份技能全部附件的合计上限。
///
/// 8 × 4096 = 32768，但合计再卡一道 16384：全是 4 KiB 附件的技能在手机上是
/// 异常形状，真到那个量级应该拆成两份技能，而不是让一次投送把审批卡撑到读
/// 不完。
const int kMaxSkillAssetsTotalBytes = 16384;

/// 投送附件的远端目录前缀。
///
/// 与 `~/.flyterm/skills/`（导入源，扁平）是**两个不同的目录**：那个是「服务
/// 器上有什么可以导进来」，这个是「手机上这份技能的附件往哪落」。
const String kSkillAssetsDirName = '.flyterm/skill-assets';

/// 一份技能的附件。
///
/// [path] 是**相对路径**（POSIX 分隔符），投送时拼成
/// `~/<kSkillAssetsDirName>/<技能名>/<path>`。存绝对路径会让技能不可移植
/// —— 换台机器、换个用户目录就废了。
///
/// [executable] 为 true 的附件在投送后会 `chmod +x`。它是**显式**的，不从
/// 扩展名猜：`chmod +x` 一个数据文件不致命，但让「哪些文件会成为可执行文件」
/// 在审批卡上可见，是用户能做出知情决定的前提。
class AgentSkillAsset {
  final String path;
  final String content;
  final bool executable;

  const AgentSkillAsset({
    required this.path,
    required this.content,
    this.executable = false,
  });

  int get byteLength => utf8.encode(content).length;
}

/// 附件路径是否安全。是 [parseAssetPath] 的谓词形式。
bool isSafeAssetPath(String raw) => parseAssetPath(raw) != null;

/// 校验并规范化一条附件路径。不安全时返回 null。
///
/// ## 为什么这是一个必须存在的纯函数
///
/// `path` 是**模型提供的字符串**，会被拼进远端绝对路径。不校验的话
/// `../../.ssh/authorized_keys` 就是一次任意文件写入。校验放在这里（而不是
/// 只在写入时做）是因为**三处调用点都要用**：`save_skill`、`skill_update`、
/// `install_skill_assets`。库里存着一条坏路径，迟早有别的代码去用它。
///
/// 拒绝的形状：
///
/// - 绝对路径（`/` 开头）—— 落点必须是技能目录内部
/// - 任何 `..` 段 —— 目录逃逸
/// - 反斜杠 —— POSIX 里它是合法文件名字符，但在跨平台的语境里会造成
///   「这是路径分隔符还是文件名」的歧义，不如禁掉
/// - 空段（连续 `/`）、尾随 `/`、`.` 段 —— 规范化问题，不是路径
/// - 首尾空白、控制字符、换行 —— 会破坏投送命令的拼接
///
/// **不做进一步规范化**（比如把 `a//b` 折成 `a/b`）：静默改写模型给的路径
/// 会让它在错误提示里看到的东西和它发出去的不一样。拒绝，然后让它重发。
String? parseAssetPath(String raw) {
  if (raw.isEmpty) return null;
  // 首尾空白一律拒，不 trim 后接受：尾随空格是个合法的（虽然讨厌的）
  // 文件名，而这里要的是「所见即所得」—— 它发什么，落下去的就得是什么。
  if (raw != raw.trim()) return null;
  if (raw.startsWith('/')) return null;
  if (raw.contains('\\')) return null;
  if (raw.endsWith('/')) return null;

  for (final unit in raw.codeUnits) {
    // 拒绝所有 C0 控制字符（含 NUL、换行、制表符）。
    if (unit < 0x20 || unit == 0x7f) return null;
  }

  final segments = raw.split('/');
  for (final seg in segments) {
    if (seg.isEmpty) return null; // 连续斜杠 / 前导斜杠
    if (seg == '.' || seg == '..') return null;
  }

  return raw;
}

/// 按使用分数竞争的名额。
const int kIndexMeritSlots = 25;

/// 留给最新存入的保留位。
///
/// 没有这几格就会**冷启动饥饿**：一条刚存的 skill 排在所有用过的老 skill
/// 之后 → 进不了索引 → 模型看不见 → 永远不会被 load → 永远进不去。自动
/// 沉淀上线第一天就把自己锁死。
///
/// 否决过的替代方案是「新存入 N 天内视同已用过」的宽限期：逻辑藏在排序
/// 表达式里，用户看不见也解释不清。分段是一句话能说明白的。
const int kIndexFreshSlots = 5;

/// 进索引的最大条数。
///
/// 30 × 30 ≈ 900 token 常驻，与现有 instructions 的 ~2300 token 同量级。
/// 超出的不删，只是不进索引 —— 见 `selectIndexed`。
const int kMaxIndexedSkills = kIndexMeritSlots + kIndexFreshSlots;

/// skill 的来源，只用于 UI 上的来源徽标。
///
/// 新值一律加在**末尾**。持久化存的是 [Enum.name] 而不是 index
/// （`agent_skill_repository.dart` 的 `upsert` / `_fromRow`），所以顺序本身
/// 不影响已经落库的数据；加在末尾只是避免有人日后改用 index。
///
/// 降级安装是安全的：`_fromRow` 读到不认识的 name 会 `orElse` 回落到
/// [file]，不会让整个技能列表打不开。
enum SkillSource { ai, remote, file, manual }

/// 一条完整的技能。正文只在 `load_skill` 命中时才从库里读出来。
class AgentSkill {
  final int id;
  final String name;
  final String description;
  final String body;
  final bool enabled;
  final SkillSource source;
  final DateTime updatedAt;

  /// 这条技能的附件（脚本 / 模板 / 参考文档）。
  ///
  /// **默认空列表** —— `AgentSkillRepository.all()` 不填它（那会变成 N+1 次
  /// 查询），只有详情页和 `load_skill` 按需调 `assetsOf` 取。列表页要看
  /// “有没有附件”时用 [assetCount]，不要依赖这个字段。
  final List<AgentSkillAsset> assets;

  /// 附件**数量**。由 `all()` 的子查询填好（不读正文），列表页的徒标用它。
  ///
  /// 与 [assets].length 分两件事：这个是“有几份”，那个是“是什么”。列表
  /// 只需要前者，而把后者拉进列表就是每行读一遍全部脚本正文。
  final int assetCount;

  /// 最后一次被 `load_skill` 成功取出正文的时刻。null = 从未用过。
  ///
  /// 与 [updatedAt] **必须分列**：那个是「内容改动时间」，新人名额靠它判定。
  /// 合成一列的话，一条老 skill 被 load 一次就变「新」，真正的新条目永远
  /// 挤不进那 5 格保留位。
  final DateTime? lastUsedAt;

  /// 被成功 load 的累计次数。同名 upsert 覆盖内容时**不清零** —— 那是同一
  /// 条知识的新版本，它过去被用过多少次仍然是有效信号。
  final int hitCount;

  const AgentSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.body,
    required this.enabled,
    required this.source,
    required this.updatedAt,
    this.lastUsedAt,
    this.hitCount = 0,
    this.assets = const [],
    this.assetCount = 0,
  });

  AgentSkill copyWith({
    String? name,
    String? description,
    String? body,
    bool? enabled,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
    int? hitCount,
    List<AgentSkillAsset>? assets,
    int? assetCount,
  }) =>
      AgentSkill(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        body: body ?? this.body,
        enabled: enabled ?? this.enabled,
        source: source,
        updatedAt: updatedAt ?? this.updatedAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        hitCount: hitCount ?? this.hitCount,
        assets: assets ?? this.assets,
        assetCount: assetCount ?? this.assetCount,
      );
}

/// 索引里的一条。**刻意不含 body** —— 索引要能同步、廉价地遍历，
/// 带上正文就等于每轮把整个技能库读一遍。
class SkillIndexEntry {
  final String name;
  final String description;

  const SkillIndexEntry({required this.name, required this.description});
}

/// 一次 markdown 解析的结果。
///
/// [error] 非 null 时其余字段无意义。**缺 description 不算 error** ——
/// 那是「待用户补全」，由导入预览页处理；自动编一句会永久占着索引的
/// token 预算。
class SkillParseResult {
  final String name;
  final String description;
  final String body;
  final String? error;

  const SkillParseResult({
    required this.name,
    required this.description,
    required this.body,
    this.error,
  });

  const SkillParseResult.failure(this.error)
      : name = '',
        description = '',
        body = '';
}

/// 解析一份 skill markdown。
///
/// ## 为什么手写而不是用 `yaml` 包
///
/// 我们只认 `name` 和 `description` 两个键。`yaml` 包会欣然接受嵌套、
/// 锚点、多行标量、类型推断 —— 每一种多支持的语法都是一种将来要在
/// 导入路径上处理的畸形输入，而它们一个都不是我们需要的。
SkillParseResult parseSkillMarkdown(String raw, {required String fallbackName}) {
  final text = raw.replaceAll('\r\n', '\n').trim();
  if (!text.startsWith('---')) {
    return const SkillParseResult.failure(
        'Missing frontmatter: the file must start with a `---` block '
        'containing `name:` and `description:`.');
  }
  final end = text.indexOf('\n---', 3);
  if (end < 0) {
    return const SkillParseResult.failure(
        'Unterminated frontmatter: no closing `---` line was found.');
  }

  var name = '';
  var description = '';
  for (final line in text.substring(3, end).split('\n')) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    if (key == 'name') name = value;
    if (key == 'description') description = value;
  }

  final afterMarker = text.indexOf('\n', end + 1);
  final body = afterMarker < 0 ? '' : text.substring(afterMarker + 1).trim();
  if (body.isEmpty) {
    return const SkillParseResult.failure('The skill body is empty.');
  }

  return SkillParseResult(
    name: name.isEmpty ? fallbackName : name,
    // description 走裸截断而不是 clipToBytes：它是**一行**，末尾挂一个
    // `[truncated at 200 bytes]` 标记会把这一行撑得更长，正好和限制它的
    // 目的相反。
    description: _clipLine(description, kMaxSkillDescriptionBytes),
    body: clipToBytes(body, kMaxSkillBodyBytes),
  );
}

/// 单行截断：按字节切，不加标记。
String _clipLine(String s, int maxBytes) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return s;
  return utf8
      .decode(bytes.sublist(0, maxBytes), allowMalformed: true)
      .replaceAll('\u{FFFD}', '');
}
