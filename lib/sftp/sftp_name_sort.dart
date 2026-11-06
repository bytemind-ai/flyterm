// SPDX-License-Identifier: GPL-3.0-or-later
import 'sftp_entry.dart';

enum SortKey { name, size, time }

/// 自然序比较：数字段按**数值**比，其余按大小写不敏感的字符比。
///
/// 为什么需要它：带数字的文件名极常见（`log1`…`log10`、`part2`、`v1.9` vs
/// `v1.10`），纯字典序会给出 `log10` 在 `log2` 前这种明显错误的结果。
///
/// 大小写不敏感是另一半：历史实现用 `String.compareTo`（ASCII 序），于是
/// `Zoo.txt` 排在 `apple.txt` 前、`README` 排在 `build` 前 —— 不符合任何人
/// 的直觉。这是修 bug，不是加一种排序偏好。
int naturalCompare(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  var i = 0, j = 0;
  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    final aDigit = _isDigit(ca);
    final bDigit = _isDigit(cb);
    if (aDigit && bDigit) {
      // 抓出两边的完整数字段，按数值比（去掉前导零后先比长度，再比字典序 ——
      // 避免大数字溢出 int）。
      var ei = i;
      while (ei < la.length && _isDigit(la.codeUnitAt(ei))) {
        ei++;
      }
      var ej = j;
      while (ej < lb.length && _isDigit(lb.codeUnitAt(ej))) {
        ej++;
      }
      final na = _stripLeadingZeros(la.substring(i, ei));
      final nb = _stripLeadingZeros(lb.substring(j, ej));
      if (na.length != nb.length) return na.length - nb.length;
      final cmp = na.compareTo(nb);
      if (cmp != 0) return cmp;
      i = ei;
      j = ej;
      continue;
    }
    if (ca != cb) return ca - cb;
    i++;
    j++;
  }
  return (la.length - i) - (lb.length - j);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

String _stripLeadingZeros(String s) {
  var k = 0;
  while (k < s.length - 1 && s.codeUnitAt(k) == 0x30) {
    k++;
  }
  return s.substring(k);
}

/// 按 [key]/[ascending] 比较两个条目。目录区与文件区共用。
int _compareBy(SftpEntry a, SftpEntry b, SortKey key, bool ascending) {
  int cmp;
  switch (key) {
    case SortKey.name:
      cmp = naturalCompare(a.name, b.name);
    case SortKey.size:
      cmp = a.size.compareTo(b.size);
    case SortKey.time:
      // modTime 缺失（epoch 0）的**恒排最后**，与升降序无关。
      //
      // 「不知道时间」既不是最新也不是最旧：用户按时间找最近的文件时，
      // 它不该插在结果中间。
      //
      // **注意这个 `return` 不能改成设 cmp。** 下面统一有
      // `ascending ? cmp : -cmp`，走那条路的话升序时缺失项（epoch 0，
      // 最小）会被翻到最前面 —— 就变成「冒充最旧」了。提前 return 绕过
      // 那次翻转，正是这里的目的。
      final aMissing = a.modTime.millisecondsSinceEpoch == 0;
      final bMissing = b.modTime.millisecondsSinceEpoch == 0;
      if (aMissing != bMissing) return aMissing ? 1 : -1;
      cmp = a.modTime.compareTo(b.modTime);
  }
  return ascending ? cmp : -cmp;
}

/// 按 [key]/[ascending] 排序，**目录恒优先**。
///
/// 目录优先是独立于排序维度的一条规则，不是第四个维度：目录永远排在文件
/// 前面，但**目录之间的顺序照样跟随 [key] 和 [ascending]**。
///
/// 这两件事曾经被混为一谈 —— 目录分支硬编码成名称升序，`key` 和 `ascending`
/// 一个都没参与。代价不是「目录区顺序更稳定」，而是在**目录占满首屏**的路径
/// （home、项目根、`/`、按日期分的备份目录）下，用户点任何排序项屏幕上都是
/// 零变化，整个功能看起来就是坏的。按日期找最新的备份目录恰恰是最常见的
/// 需求之一，而那正是被吞掉的那条路径。
///
/// 唯一的例外是「按大小」：目录的 `attr.size` 往往是块大小（4096）而不是
/// 内容真实大小，拿它比较没有意义，所以目录区退回名称序 —— 但**方向仍然
/// 跟随 [ascending]**，否则切升降序时目录区又会纹丝不动，回到同一个坑里。
List<SftpEntry> sortEntries(
  List<SftpEntry> entries, {
  required SortKey key,
  required bool ascending,
}) {
  final dirKey = key == SortKey.size ? SortKey.name : key;
  final dirs = entries.where((e) => e.isDir).toList()
    ..sort((a, b) => _compareBy(a, b, dirKey, ascending));
  final files = entries.where((e) => !e.isDir).toList()
    ..sort((a, b) => _compareBy(a, b, key, ascending));
  return [...dirs, ...files];
}
