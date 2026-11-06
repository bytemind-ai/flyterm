// SPDX-License-Identifier: GPL-3.0-or-later
/// 一次文本读取的结果，**包含「是否被截断」的结论**。
///
/// ## 为什么需要这个类型
///
/// 旧代码 `readTextFile` 返回 `String?`，读到 512 KB 上限就静默截断，而两个
/// 调用方各自拿 `entry.size`（**列表快照里的大小**）去猜是否截断：
///
///   `sftp_text_editor_screen.dart` / `sftp_markdown_preview_screen.dart`
///   → `entry.size > _maxBytes`
///
/// 只要快照过期（用户没刷新，或文件在别处被追加），`entry.size` 就与真实大小
/// 不符。文件实际 800 KB、快照说 300 KB 时：读取截到 512 KB、判据不触发、
/// 用户看不到任何警告、编辑器可写 —— **保存后远端文件被截断覆盖**。
///
/// 修法是把判据从「猜」变成「知」：谁读的谁最清楚读了多少。
class ReadResult {
  final String content;

  /// 内容是否被截断（真实文件还有更多没读到）。
  final bool truncated;

  /// `stat` 得到的真实大小。拿不到（stat 失败）时为 null。
  final int? totalSize;

  const ReadResult({
    required this.content,
    required this.truncated,
    this.totalSize,
  });

  /// 由「读到的字节数」和「上限」推断截断。
  ///
  /// [totalSize] 已知时直接比大小 —— 这是准确判据，也是修复的核心。
  /// [totalSize] 未知时退化为「是否读满上限」：读满就无法排除还有更多，于是
  /// **保守地判为截断**（宁可让用户看到一个多余的提示，也不要让他把截断的
  /// 内容存回去）。
  factory ReadResult.fromBytes(
    String content, {
    required int maxBytes,
    required int? totalSize,
  }) {
    final bool truncated;
    if (totalSize != null) {
      truncated = content.length < totalSize;
    } else {
      truncated = content.length >= maxBytes;
    }
    return ReadResult(
      content: content,
      truncated: truncated,
      totalSize: totalSize,
    );
  }
}