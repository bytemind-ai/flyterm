import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/attachment_materialize.dart';
import 'package:flyterm/ai/attachment_store.dart';

void main() {
  late Directory root;
  late AttachmentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mat_test');
    store = AttachmentStore(root);
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<Attachment> putImage(List<int> bytes) async {
    final src = File('${root.path}/src.png');
    await src.writeAsBytes(bytes);
    return store.put(
        serverId: 's', src: src, kind: AttachmentKind.image, mime: 'image/png');
  }

  test('图片被填上 b64', () async {
    final a = await putImage([0, 1, 2, 3]);
    final out = await materializeAttachments(
        [AIMessage(role: 'user', content: 'x', attachments: [a])], store);
    expect(out.single.attachments!.single.b64, isNotEmpty);
  });

  test('text 类不物化 —— 正文已在 content 里', () async {
    final src = File('${root.path}/a.log');
    await src.writeAsString('hello');
    final t = await store.put(
        serverId: 's', src: src, kind: AttachmentKind.text, mime: 'text/plain');
    final out = await materializeAttachments(
        [AIMessage(role: 'user', content: 'x', attachments: [t])], store);
    expect(out.single.attachments!.single.b64, isNull);
  });

  test('文件丢失的图片被剔除，消息本身与其余附件保留', () async {
    final ok = await putImage([1]);
    const ghost = Attachment(
        kind: AttachmentKind.image,
        relPath: 's/ghost.png',
        mime: 'image/png',
        bytes: 1);
    final out = await materializeAttachments([
      AIMessage(role: 'user', content: '正文还在', attachments: [ghost, ok])
    ], store);
    expect(out.single.content, '正文还在');
    expect(out.single.attachments, hasLength(1));
    expect(out.single.attachments!.single.relPath, ok.relPath);
  });

  test('没有附件的消息原样返回（同一个实例）', () async {
    const m = AIMessage(role: 'user', content: 'plain');
    final out = await materializeAttachments([m], store);
    expect(identical(out.single, m), isTrue,
        reason: '绝大多数消息没有附件，不该为它们造新对象');
  });
}
