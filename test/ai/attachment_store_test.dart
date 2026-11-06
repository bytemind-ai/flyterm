import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/attachment_store.dart';

void main() {
  late Directory root;
  late AttachmentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('attach_test');
    store = AttachmentStore(root);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<File> srcFile(String name, List<int> bytes) async {
    final f = File('${root.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  test('put 把文件拷进 <serverId>/ 并返回相对路径', () async {
    final src = await srcFile('shot.png', [1, 2, 3, 4]);
    final a = await store.put(
      serverId: 'srv-1',
      src: src,
      kind: AttachmentKind.image,
      mime: 'image/png',
      name: 'shot.png',
    );

    expect(a.relPath, startsWith('srv-1/'));
    expect(a.relPath, endsWith('.png'));
    expect(a.bytes, 4);
    expect(a.name, 'shot.png');
    expect(store.fileFor(a).existsSync(), isTrue);
    // 拷贝而不是移动：原文件还在（相册的原文件不该被我们动）
    expect(src.existsSync(), isTrue);
  });

  test('同一个源文件 put 两次得到两条不同的记录', () async {
    final src = await srcFile('a.png', [1]);
    final a1 = await store.put(
        serverId: 's', src: src, kind: AttachmentKind.image, mime: 'image/png');
    final a2 = await store.put(
        serverId: 's', src: src, kind: AttachmentKind.image, mime: 'image/png');
    expect(a1.relPath, isNot(a2.relPath));
  });

  test('deleteAll 删掉给定的相对路径，不存在的忽略', () async {
    final src = await srcFile('a.png', [1]);
    final a = await store.put(
        serverId: 's', src: src, kind: AttachmentKind.image, mime: 'image/png');
    await store.deleteAll([a.relPath, 's/does-not-exist.png']);
    expect(store.fileFor(a).existsSync(), isFalse);
  });

  test('readBytes 读不到文件时返回 null 而不是抛', () async {
    const ghost = Attachment(
        kind: AttachmentKind.image,
        relPath: 's/ghost.png',
        mime: 'image/png',
        bytes: 1);
    expect(await store.readBytes(ghost), isNull);
  });

  test('readText 截断到上限并返回是否被截断', () async {
    final src = await srcFile('big.log', List.filled(100, 0x41)); // 100 个 'A'
    final a = await store.put(
        serverId: 's', src: src, kind: AttachmentKind.text, mime: 'text/plain');
    final r = await store.readText(a, maxBytes: 10);
    expect(r!.text.length, 10);
    expect(r.truncated, isTrue);
  });

  group('sweepOrphans', () {
    test('删掉没有引用的旧文件，保留被引用的', () async {
      final src = await srcFile('a.png', [1]);
      final kept = await store.put(
          serverId: 's', src: src, kind: AttachmentKind.image, mime: 'image/png');
      final orphan = await store.put(
          serverId: 's', src: src, kind: AttachmentKind.image, mime: 'image/png');

      // 把两个文件的 mtime 推到 2 小时前，越过保护窗口
      final old = DateTime.now().subtract(const Duration(hours: 2));
      await store.fileFor(kept).setLastModified(old);
      await store.fileFor(orphan).setLastModified(old);

      final n = await store.sweepOrphans(referenced: {kept.relPath});
      expect(n, 1);
      expect(store.fileFor(kept).existsSync(), isTrue);
      expect(store.fileFor(orphan).existsSync(), isFalse);
    });

    test('不删 mtime 在保护窗口内的文件 —— 那可能是刚选中还没落进归档的', () async {
      // AgentSessionManager 有 3 秒节流落盘，选中到归档有个窗口；清扫必须
      // 让开它，否则会删掉用户正要发的那张图。
      final src = await srcFile('a.png', [1]);
      final fresh = await store.put(
          serverId: 's', src: src, kind: AttachmentKind.image, mime: 'image/png');

      final n = await store.sweepOrphans(referenced: const {});
      expect(n, 0);
      expect(store.fileFor(fresh).existsSync(), isTrue);
    });

    test('root 不存在时返回 0，不抛', () async {
      await root.delete(recursive: true);
      expect(await store.sweepOrphans(referenced: const {}), 0);
    });
  });
}
