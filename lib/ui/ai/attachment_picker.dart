// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import '../../ai/attachment.dart';
import '../../ai/attachment_sniff.dart';
import '../../ai/attachment_store.dart';

export '../../ai/attachment_sniff.dart' show AttachmentReject;

/// 降采样函数的注入形状。测试传假的，生产传 `downscaleImage`。
typedef Downscaler = Future<Uint8List?> Function(Uint8List bytes,
    {required int maxEdge});

/// 文件选择器返回之后的三种终态。
enum PickOutcome {
  /// 用户按了返回/取消。**静默是对的**，不该弹任何提示。
  cancelled,

  /// 选了文件，但拿不到本地路径。
  ///
  /// Android 上从云盘、在线文档、以及某些 content provider 选文件时，
  /// `PlatformFile.path` 会是 null（内容不在本机，file_picker 没有可 copy
  /// 的源）。
  unreadable,

  ok,
}

/// 判定一次文件选择的终态。
///
/// **`cancelled` 与 `unreadable` 必须分开。** 它们在代码里长得一样（都是
/// 「没有可用路径」），但对用户是两件完全不同的事：前者是他自己按的返回，
/// 后者是他选了文件却什么都没发生。
///
/// 真机反馈（2026-09-13）「点了附件、能选、选完界面没反应」就是后者被当成
/// 前者静默掉了 —— 一次失败的选择与一次主动取消在屏幕上无法区分。
///
/// 做成纯函数是为了能直接单测：`_pickAttachment` 本身要 mock
/// `FilePicker.platform` 才跑得起来，而这里的判定逻辑才是出过错的那部分。
PickOutcome classifyPick({required bool pickerReturned, required String? path}) {
  if (!pickerReturned) return PickOutcome.cancelled;
  return path == null ? PickOutcome.unreadable : PickOutcome.ok;
}

/// 一次「选中文件 → 可用附件」的结果。四种互斥情形靠字段区分。
class PreparedAttachment {
  final Attachment? attachment;

  /// text 类读出来的正文，调用方负责拼进 `content`。
  final String? text;
  final bool truncated;

  final AttachmentReject? reject;

  /// 图片超限且降采样失败时的原始字节数。
  final int? tooLargeBytes;

  /// 落盘失败（磁盘满、权限、路径异常）。
  final bool saveFailed;

  const PreparedAttachment({
    this.attachment,
    this.text,
    this.truncated = false,
    this.reject,
    this.tooLargeBytes,
    this.saveFailed = false,
  });
}

/// 校验选中的文件并落盘。**不碰 UI，不弹任何提示** —— 调用方拿结果去决定
/// 显示哪条文案，这样这一整段能用普通 unit test 覆盖（无需 widget 环境）。
Future<PreparedAttachment> prepareAttachment({
  required File file,
  required String serverId,
  required AttachmentStore store,
  required Downscaler downscale,
}) async {
  // 读源文件本身也可能失败（用户在选完之后把它删了、权限被撤）。整段包起来，
  // 任何 IO 异常都折成 saveFailed —— 这个函数**绝不抛**，调用方只需看字段。
  try {
    final total = await file.length();
    final raf = await file.open();
    Uint8List head;
    try {
      head = await raf.read(512);
    } finally {
      await raf.close();
    }

    final sniff = sniffAttachment(
        head: head, totalBytes: total, fileName: file.uri.pathSegments.last);
    if (sniff.rejectReason != null) {
      return PreparedAttachment(reject: sniff.rejectReason);
    }

    final name = file.uri.pathSegments.last;

    if (sniff.kind == AttachmentKind.image) {
      Uint8List? override;
      if (sniff.needsDownscale) {
        final scaled = await downscale(await file.readAsBytes(), maxEdge: 1568);
        if (scaled == null || scaled.length > kMaxImageBytes) {
          return PreparedAttachment(tooLargeBytes: total);
        }
        override = scaled;
      }
      final a = await store.put(
        serverId: serverId,
        src: file,
        kind: AttachmentKind.image,
        mime: sniff.mime,
        name: name,
        overrideBytes: override,
      );
      return PreparedAttachment(attachment: a);
    }

    final a = await store.put(
      serverId: serverId,
      src: file,
      kind: AttachmentKind.text,
      mime: 'text/plain',
      name: name,
    );
    final read = await store.readText(a, maxBytes: kMaxTextBytes);
    return PreparedAttachment(
      attachment: a,
      text: read?.text,
      truncated: read?.truncated ?? false,
    );
  } catch (_) {
    return const PreparedAttachment(saveFailed: true);
  }
}
