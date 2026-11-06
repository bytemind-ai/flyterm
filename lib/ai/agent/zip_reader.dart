// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io' show gzip, ZLibDecoder;
import 'dart:typed_data';

/// 一个极小的 ZIP 读取器。
///
/// ## 为什么手写而不引 `archive` 包
///
/// 我们只需要一件事：把用户从手机文件管理器选来的 zip 里的**普通文件**解出
/// 来。`archive` 能做的其余全部（写、加密、分卷、zip64、符号链接……）这里
/// 一件都用不上，而代价是一个新依赖：apk 变大、多一条供应链、多一份升级
/// 负担。同目录的 `remote_skills.dart` 为 tar 做了同样的取舍。
///
/// ## 支持范围
///
/// - **stored**（method 0）与 **deflate**（method 8）—— 这两种覆盖了所有
///   正常工具产出的 zip
/// - 不支持加密、zip64、分卷。遇到就跳过该条目（或整体返回 null）
///
/// ## 目录条目的处理
///
/// zip 里的目录通常以 `/` 结尾、长度为 0。**直接跳过**：我们要的是“相对
/// 路径 → 字节”，目录只是路径的前缀关系，创建它们没有意义（tar 那条路同理）。
///
/// 返回 null = 这不是一个能读的 zip（签名不对、中央目录坏了）。空 map =
/// 读通了但里面没有普通文件。

/// ZIP 中央目录条目签名 `PK\x01\x02`。
const int _kCentralHeaderSig = 0x02014b50;

/// ZIP 本地文件头签名 `PK\x03\x04`。
const int _kLocalHeaderSig = 0x04034b50;

/// 解一个 zip 字节流，返回「相对路径 → 内容」。失败返回 null。
Map<String, List<int>>? unzip(Uint8List bytes) {
  // 先找**结束记录**，从它里面读中央目录的起始偏移。
  //
  // 不能“从尾部往前扫中央目录签名”：中央目录里每个条目的签名都是同一个
  // `PK\x01\x02`，倒着找会命中**最后一个**条目，于是只能读出一份文件。
  // （这个 bug 真发生过：三个文件的 zip 只解出 `c.txt`。）
  final cdStart = _findCentralDirectoryStart(bytes);
  if (cdStart < 0) return null;

  final files = <String, List<int>>{};
  var p = cdStart;
  final reader = _ByteReader(bytes);

  while (p + 46 <= bytes.length) {
    reader.pos = p;
    if (reader.uint32() != _kCentralHeaderSig) break;

    reader.pos = p + 10;
    final method = reader.uint16();
    reader.pos = p + 20;
    final compressedSize = reader.uint32();
    // 未压缩大小（p+24）不参与切数据（deflate 自己知道何时结束），
    // 跳过它去读名字长度。
    reader.pos = p + 28;
    final nameLen = reader.uint16();
    final extraLen = reader.uint16();
    final commentLen = reader.uint16();
    reader.pos = p + 42;
    final localHeaderOffset = reader.uint32();

    reader.pos = p + 46;
    final name = _decodeName(reader.bytes(nameLen));

    // 目录条目 / 空条目：跳过。
    final isDir = name.endsWith('/') || name.endsWith('\\');
    if (isDir || name.isEmpty) {
      p += 46 + nameLen + extraLen + commentLen;
      continue;
    }

    final content = _readLocalEntry(
      bytes,
      localHeaderOffset,
      method,
      compressedSize,
    );
    // 解不出来（加密 / zip64 / 损坏）就跳过这一条，不让整包失败 ——
    // 一个奇怪的条目不该毁掉整个导入。
    if (content != null) files[name] = content;

    p += 46 + nameLen + extraLen + commentLen;
  }

  return files;
}

/// 从结束记录里读出中央目录的起始偏移。找不到返回 -1。
///
/// 从尾部往前扫 `PK\x05\x06`（最多扫 64 KiB，zip 注释长度上限）：结束记录
/// 一定在文件最末尾，而它的签名在普通数据里几乎不会出现。
int _findCentralDirectoryStart(Uint8List b) {
  final minStart = b.length - 22 - 65535;
  for (var i = b.length - 22; i >= (minStart < 0 ? 0 : minStart); i--) {
    if (b[i] == 0x50 &&
        b[i + 1] == 0x4b &&
        b[i + 2] == 0x05 &&
        b[i + 3] == 0x06) {
      // 偏移在结束记录的第 16 字节处（4 小端）。
      return b[i + 16] |
          (b[i + 17] << 8) |
          (b[i + 18] << 16) |
          (b[i + 19] << 24);
    }
  }
  return -1;
}

/// 读一个本地文件头并解出内容。失败返回 null。
List<int>? _readLocalEntry(
  Uint8List bytes,
  int offset,
  int method,
  int compressedSize,
) {
  if (offset < 0 || offset + 30 > bytes.length) return null;
  final r = _ByteReader(bytes)..pos = offset;
  if (r.uint32() != _kLocalHeaderSig) return null;

  r.pos = offset + 26;
  final nameLen = r.uint16();
  final extraLen = r.uint16();
  final dataStart = offset + 30 + nameLen + extraLen;
  // 中央目录记的 compressedSize 为 0 时（某些流式写出的 zip）退回到
  // “从 dataStart 到中央目录起点”。这里不追求那个形状，直接按记的值切。
  if (compressedSize <= 0 || dataStart + compressedSize > bytes.length) {
    return null;
  }
  final raw = bytes.sublist(dataStart, dataStart + compressedSize);

  switch (method) {
    case 0: // stored
      return raw;
    case 8: // deflate
      try {
        return Uint8List.fromList(ZLibDecoder(raw: false).convert(raw));
      } catch (_) {
        return null;
      }
    default:
      return null; // bzip2 / lzma / 加密等一律不支持
  }
}

/// 文件名编码。
///
/// zip 的 general purpose bit 11 表示“名字是 UTF-8”。不判那个标志位、
/// 一律按 UTF-8 解是在赌——而中文技能名在手机上是常态。这里先试 UTF-8，
/// 解码失败再退回到 latin1（老工具产出的纯 ASCII 名两种都对）。
String _decodeName(Uint8List nameBytes) {
  try {
    return utf8.decode(nameBytes);
  } on FormatException {
    return latin1.decode(nameBytes);
  }
}

/// 小端读字节的小工具。
class _ByteReader {
  final Uint8List _b;
  int pos = 0;
  _ByteReader(this._b);

  int uint16() {
    final v = _b[pos] | (_b[pos + 1] << 8);
    pos += 2;
    return v;
  }

  int uint32() {
    final v = _b[pos] |
        (_b[pos + 1] << 8) |
        (_b[pos + 2] << 16) |
        (_b[pos + 3] << 24);
    pos += 4;
    return v;
  }

  Uint8List bytes(int n) {
    final v = Uint8List.fromList(_b.sublist(pos, pos + n));
    pos += n;
    return v;
  }
}

/// 读一个 zip 文件并解析成技能。与 `importSkillsFromDirectory` 同约定：
/// **绝不抛**，失败折成 error。
///
/// 放在这里（而不是 `skill_file_import.dart`）是为了让“字节怎么解”
/// 与“解出来怎么变成技能”分开：前者是格式细节，后者是产品语义。
Map<String, List<int>>? unzipOrNull(Uint8List bytes) => unzip(bytes);

/// gzip 也在别处用过，这里顺手导出给同目录的调用方，避免它们各自 import
/// `dart:io`（那是移动端专属的，集中一处便于将来换实现）。
List<int> gunzip(List<int> bytes) => gzip.decode(bytes);
