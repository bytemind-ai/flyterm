// 测试用：把若干文件打成远端 `tar -czf - . | base64` 会产生的形状。
//
// 手写 512 字节 USTAR 头而不是引 tar 包：造数据的一侧如果跟被测代码共用
// 同一个库，库的 bug 会同时体现在两边、测试照绿。USTAR 头格式稳定且看得见。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 造一个 tar 条目（512 字节头 + 数据 + 512 对齐填充）。
Uint8List tarEntry(String name, List<int> content) {
  final header = Uint8List(512);
  void put(int offset, String s) {
    final b = ascii.encode(s);
    header.setRange(offset, offset + b.length, b);
  }

  put(0, name);
  put(100, '0000644\u0000'); // mode
  put(108, '0000000\u0000'); // uid
  put(116, '0000000\u0000'); // gid
  put(124, content.length.toRadixString(8).padLeft(11, '0') + '\u0000');
  put(136, '00000000000\u0000'); // mtime
  header[156] = 0x30; // '0' = regular file
  put(257, 'ustar\u0000');
  put(263, '00');

  for (var i = 148; i < 156; i++) {
    header[i] = 0x20;
  }
  var sum = 0;
  for (final b in header) {
    sum += b;
  }
  put(148, sum.toRadixString(8).padLeft(6, '0') + '\u0000 ');

  final padded = ((content.length + 511) ~/ 512) * 512;
  final out = BytesBuilder();
  out.add(header);
  out.add(content);
  out.add(Uint8List(padded - content.length));
  return out.toBytes();
}

/// 把若干文件打成 tar.gz 再 base64（模拟远端 `tar -czf - . | base64`）。
String tarGzBase64(Map<String, String> files) {
  final tar = BytesBuilder();
  for (final e in files.entries) {
    tar.add(tarEntry(e.key, utf8.encode(e.value)));
  }
  tar.add(Uint8List(1024)); // 两个全零块 = 结束标记
  return base64.encode(gzip.encode(tar.toBytes()));
}

String skillMd(String name, String desc, String body) =>
    '---\nname: $name\ndescription: $desc\n---\n\n$body\n';

/// 手写一个 zip。与 `_tar_bundle.dart` 同一个理由：造数据的一侧不能跟被测
/// 代码共用同一个库。
///
/// 支持 stored（method 0）与 deflate（method 8），正好覆盖 [unzip] 支持的两
/// 种。CRC 写 0 —— [unzip] 不校验 CRC（那是**写**方该保证的）。
Uint8List buildZip(
  Map<String, String> files, {
  bool deflate = true,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();

  for (final e in files.entries) {
    final nameBytes = utf8.encode(e.key);
    final raw = utf8.encode(e.value);
    final List<int> data;
    final int method;
    if (deflate && raw.isNotEmpty) {
      data = ZLibEncoder(raw: false, level: 6).convert(raw);
      method = 8;
    } else {
      data = raw;
      method = 0;
    }

    final localOffset = out.length;

    // 本地文件头。
    final lh = BytesBuilder();
    _u32(lh, 0x04034b50);
    _u16(lh, 20); // version needed
    _u16(lh, 0); // flags
    _u16(lh, method);
    _u16(lh, 0); // time
    _u16(lh, 0); // date
    _u32(lh, 0); // crc
    _u32(lh, data.length);
    _u32(lh, raw.length);
    _u16(lh, nameBytes.length);
    _u16(lh, 0); // extra len
    lh.add(nameBytes);
    lh.add(data);
    out.add(lh.toBytes());

    // 中央目录条目。
    _u32(central, 0x02014b50);
    _u16(central, 20); // version made by
    _u16(central, 20); // version needed
    _u16(central, 0); // flags
    _u16(central, method);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0); // crc
    _u32(central, data.length);
    _u32(central, raw.length);
    _u16(central, nameBytes.length);
    _u16(central, 0); // extra
    _u16(central, 0); // comment
    _u16(central, 0); // disk
    _u16(central, 0); // internal attrs
    _u32(central, 0); // external attrs
    _u32(central, localOffset);
    central.add(nameBytes);
  }

  final cdStart = out.length;
  final cd = central.toBytes();
  out.add(cd);

  // 中央目录结束记录。
  final eocd = BytesBuilder();
  _u32(eocd, 0x06054b50);
  _u16(eocd, 0);
  _u16(eocd, 0);
  _u16(eocd, files.length);
  _u16(eocd, files.length);
  _u32(eocd, cd.length);
  _u32(eocd, cdStart);
  _u16(eocd, 0); // comment
  out.add(eocd.toBytes());

  return out.toBytes();
}

void _u16(BytesBuilder b, int v) {
  b.addByte(v & 0xff);
  b.addByte((v >> 8) & 0xff);
}

void _u32(BytesBuilder b, int v) {
  b.addByte(v & 0xff);
  b.addByte((v >> 8) & 0xff);
  b.addByte((v >> 16) & 0xff);
  b.addByte((v >> 24) & 0xff);
}

