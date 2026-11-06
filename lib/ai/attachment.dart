// SPDX-License-Identifier: GPL-3.0-or-later
/// 一条附件（图片或文本文件）。
///
/// **纯 Dart，不 import flutter。** 它要被 provider、compaction、agent_loop
/// 和归档序列化四处引用，保持零 Flutter 依赖让它们都能用普通 unit test 覆盖。
library;

enum AttachmentKind { image, text }

class Attachment {
  final AttachmentKind kind;

  /// 相对 `<appDocs>/agent_attachments/` 的路径，形如 `<serverId>/<uuid>.png`。
  final String relPath;

  /// `image/png` | `image/jpeg` | `text/plain`。
  ///
  /// 文本类**统一是 `text/plain`**，不区分 `.log` / `.conf` / `.json` —— 那些
  /// 对模型侧没有意义（正文已进 `content`），存了只让判定分支变多。
  final String mime;

  final int bytes;

  /// 原始文件名，仅供 UI 显示与 drop marker 用。
  final String? name;

  /// 发送前物化出来的 base64。
  ///
  /// **不进 [toJson]。** 进了归档就等于把 base64 写进 SQLite，那正是
  /// 要避免的（一张截图 1–3MB 字符）。这个「字段存在但不持久化」的
  /// 模式项目已有先例：`AIMessage.displayText` 的注释就是
  /// `Display-only — not persisted`。
  final String? b64;

  const Attachment({
    required this.kind,
    required this.relPath,
    required this.mime,
    required this.bytes,
    this.name,
    this.b64,
  });

  Attachment withB64(String value) => Attachment(
        kind: kind,
        relPath: relPath,
        mime: mime,
        bytes: bytes,
        name: name,
        b64: value,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'relPath': relPath,
        'mime': mime,
        'bytes': bytes,
        if (name != null) 'name': name,
      };

  /// 坏数据返回 null 而不是抛。
  ///
  /// 归档是用户数据：一条记录的 relPath 丢了，不该让整段会话打不开。与
  /// `agentEventFromJson` 对未知事件类型的处理同一个口径。
  static Attachment? fromJson(Map<String, dynamic> j) {
    final relPath = j['relPath'] as String?;
    if (relPath == null || relPath.isEmpty) return null;
    return Attachment(
      kind: AttachmentKind.values.firstWhere(
        (k) => k.name == j['kind'],
        orElse: () => AttachmentKind.text,
      ),
      relPath: relPath,
      mime: j['mime'] as String? ?? 'text/plain',
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      name: j['name'] as String?,
    );
  }
}

/// 一张图片算多少 token。
///
/// 1600 是保守值：Anthropic 的算法是 `(w×h)/750`，长边压到 1568 的手机
/// 截图约 1474。
///
/// **这个数直接就是 token，不再折算成字符。** 旧实现是
/// `kImageCharEquiv = 1600 × 3.5`，走「折成字符再除」那条路——于是每次
/// 有人调整字符速率，图片的成本就跟着静默漂移一次。这里是整个估算里唯一
/// 一处本来就按真实 token 标定过的数，不该被别处的口径牵着走。
///
/// **不解码图片去拿真实尺寸**：那要额外 I/O 与内存，而估算偏保守正好符合
/// `_estimateTokens` 那条「漏算会让预算判断偏松，正好在最该停下的时候
/// 不停」。
const int kImageTokens = 1600;

/// 附件里的图片张数。text 类不计 —— 它的正文已经在 `content` 里了。
int imageCount(List<Attachment>? attachments) =>
    (attachments ?? const <Attachment>[])
        .where((a) => a.kind == AttachmentKind.image)
        .length;
