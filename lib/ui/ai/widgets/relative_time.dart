// SPDX-License-Identifier: GPL-3.0-or-later
/// 相对时间：`just now` / `5m` / `3h` / `2d` / `2026-10-06`。
///
/// **`just now` 由调用方传入而不是在这里查 l10n** —— 这样它是纯函数，
/// 测试不需要 widget 树。`m/h/d` 与绝对日期保持语言中立（三个字母在中英文
/// 里都通用），不为它们各建一个 arb 键。
String relativeTime(
  DateTime t, {
  DateTime? now,
  required String justNow,
}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return justNow;
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 30) return '${d.inDays}d';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}
