// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';
import 'dart:ui';

/// 把超限图片缩到长边 [maxEdge] 以内，输出 PNG 字节。解不开就返回 null。
///
/// **用 `dart:ui` 而不是 `flutter_image_compress`**：后者更快，但要新增依赖
/// 与平台构建面，而这条路只在「图片超过 3.5MB」时才走 —— 手机截图很少到这个
/// 量级（1080×2400 的 PNG 通常 1–3MB），主要是相机原图。为一条兜底路径引入
/// 原生依赖不划算。
///
/// 输出 PNG（`toByteData` 只支持 png）。降采样之后 PNG 通常比原图小得多，
/// 因为像素数掉了一个数量级。
///
/// 全程不抛：解码失败、格式不认、内存不够都折成 null，调用方据此提示用户。
Future<Uint8List?> downscaleImage(Uint8List bytes,
    {required int maxEdge}) async {
  try {
    // 先只解 header 拿尺寸，避免为一张超大图解两次全量像素。
    final probe = await instantiateImageCodec(bytes);
    final frame = await probe.getNextFrame();
    final w = frame.image.width;
    final h = frame.image.height;
    if (w <= maxEdge && h <= maxEdge) {
      frame.image.dispose();
      return bytes; // 尺寸本来就够小，原样返回
    }
    final scale = maxEdge / (w > h ? w : h);
    frame.image.dispose();

    final codec = await instantiateImageCodec(
      bytes,
      targetWidth: (w * scale).round(),
      targetHeight: (h * scale).round(),
    );
    final scaled = await codec.getNextFrame();
    final data = await scaled.image.toByteData(format: ImageByteFormat.png);
    scaled.image.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
