// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'attachment.dart';

/// 一次文本读取的结果。
class AttachmentText {
  final String text;
  final bool truncated;
  const AttachmentText(this.text, {required this.truncated});
}

/// 附件文件的唯一落地点。
///
/// **构造时注入 root**，不在内部调 `getApplicationDocumentsDirectory()`：
/// 那是 `path_provider` 的平台通道，单测里拿不到。与 `agent_loop.dart:926`
/// 那处 `relayTempDirProvider` 的注入理由完全相同。
class AttachmentStore {
  final Directory root;
  AttachmentStore(this.root);

  /// 单调计数器，保证同一毫秒内多次 put 也不撞名。
  int _seq = 0;

  File fileFor(Attachment a) => File('${root.path}/${a.relPath}');

  /// 把用户选中的文件拷进库里。
  ///
  /// **拷贝而不是引用原路径**：相册的原文件随时可能被用户删除或被系统回收，
  /// 而归档里的引用要活到 resume 之后。
  Future<Attachment> put({
    required String serverId,
    required File src,
    required AttachmentKind kind,
    required String mime,
    String? name,
    Uint8List? overrideBytes,
  }) async {
    final dir = Directory('${root.path}/$serverId');
    await dir.create(recursive: true);
    final ext = _extFor(mime);
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
    final relPath = '$serverId/$id$ext';
    final dst = File('${root.path}/$relPath');
    if (overrideBytes != null) {
      await dst.writeAsBytes(overrideBytes);
    } else {
      await src.copy(dst.path);
    }
    return Attachment(
      kind: kind,
      relPath: relPath,
      mime: mime,
      bytes: await dst.length(),
      name: name,
    );
  }

  /// 读原始字节。读不到返回 null —— 文件可能已被用户清数据删掉。
  Future<Uint8List?> readBytes(Attachment a) async {
    try {
      final f = fileFor(a);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 读文本并按 [maxBytes] 截断。
  ///
  /// `allowMalformed: true`：按字节截断必然会在多字节字符中间切开，严格解码
  /// 会整段失败。与 `web_fetch.dart` 的 `decodeWebBody` 同一个取舍。
  Future<AttachmentText?> readText(Attachment a, {required int maxBytes}) async {
    final bytes = await readBytes(a);
    if (bytes == null) return null;
    final truncated = bytes.length > maxBytes;
    final slice = truncated ? bytes.sublist(0, maxBytes) : bytes;
    return AttachmentText(utf8.decode(slice, allowMalformed: true),
        truncated: truncated);
  }

  Future<void> deleteAll(List<String> relPaths) async {
    for (final p in relPaths) {
      try {
        final f = File('${root.path}/$p');
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 删不掉就留给孤儿清扫，不该让调用方（删会话）失败。
      }
    }
  }

  static String _extFor(String mime) => switch (mime) {
        'image/png' => '.png',
        'image/jpeg' => '.jpg',
        'image/gif' => '.gif',
        'image/webp' => '.webp',
        _ => '.txt',
      };

  /// 删掉没有任何归档引用的文件，返回删除条数。
  ///
  /// **只删 mtime 超过 [minAge] 的文件。** `AgentSessionManager._persistActive`
  /// 有 3 秒节流窗口，用户刚选中的附件可能还没进归档；1 小时的保护窗口让开
  /// 这段时间，代价只是孤儿多活一小时。
  ///
  /// **依赖一条外部事实**：`AgentSessionManager.takeMostRecent` 只是把归档行
  /// 「认领为当前活跃段」，**不删除它**（`takeById` 的注释明写这一点）。所以
  /// 正在 resume 的那段会话的引用仍然在库里、能被 [referenced] 收集到。
  /// 若哪天有人把它改成真的消费掉归档行，这里就会误删 resume 中的图片。
  ///
  /// 全程不抛：清扫是纯旁路，失败了下次启动再来。
  Future<int> sweepOrphans({
    required Set<String> referenced,
    Duration minAge = const Duration(hours: 1),
  }) async {
    if (!await root.exists()) return 0;
    final cutoff = DateTime.now().subtract(minAge);
    var deleted = 0;
    try {
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        final rel = entity.path.substring(root.path.length + 1);
        if (referenced.contains(rel)) continue;
        try {
          if ((await entity.lastModified()).isAfter(cutoff)) continue;
          await entity.delete();
          deleted++;
        } catch (_) {
          // 单个文件删不掉不影响其余
        }
      }
    } catch (_) {
      // 目录遍历失败（权限/并发删除）——放弃这一轮
    }
    return deleted;
  }
}
