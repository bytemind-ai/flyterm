import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/attachment_downscale.dart';

void main() {
  test('解不开的字节返回 null，不抛', () async {
    // 上层据此退回「拒绝并提示大小」，而不是崩。
    final out = await downscaleImage(
        Uint8List.fromList([1, 2, 3, 4, 5]), maxEdge: 1568);
    expect(out, isNull);
  });

  testWidgets('能解码的图片被缩到长边上限内', (tester) async {
    // dart:ui 的图片编解码经由引擎原生线程回调完成 Future，
    // AutomatedTestWidgetsFlutterBinding 的 fake-async zone 接不住这类真实异步，
    // 不包 runAsync 会一直挂到测试超时（同 sqflite 在 testWidgets 里的坑）。
    await tester.runAsync(() async {
      // 造一张 2000×1000 的 PNG：用 dart:ui 画出来再编码，避免往仓库塞二进制。
      final src = await makeTestPng(2000, 1000);
      final out = await downscaleImage(src, maxEdge: 1568);
      expect(out, isNotNull);
      final size = await decodedSize(out!);
      expect(size.width, lessThanOrEqualTo(1568));
      expect(size.height, lessThanOrEqualTo(1568));
      expect(size.width / size.height, closeTo(2.0, 0.05),
          reason: '长宽比要保持');
    });
  });
}

Future<Uint8List> makeTestPng(int w, int h) async {
  final recorder = PictureRecorder();
  Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF00C896));
  final img = await recorder.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<Size> decodedSize(Uint8List bytes) async {
  final codec = await instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
}
