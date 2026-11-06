import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/attachment_store.dart';
import 'package:flyterm/ui/ai/attachment_picker.dart';

void main() {
  late Directory root;
  late AttachmentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('picker_test');
    store = AttachmentStore(root);
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<File> write(String name, List<int> bytes) async {
    final f = File('${root.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  const pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  test('PNG → image 附件落盘', () async {
    final f = await write('a.png', [...pngHeader, 1, 2, 3]);
    final r = await prepareAttachment(
        file: f, serverId: 's1', store: store, downscale: _noDownscale);
    expect(r.attachment, isNotNull);
    expect(r.attachment!.kind, AttachmentKind.image);
    expect(store.fileFor(r.attachment!).existsSync(), isTrue);
  });

  test('文本 → text 附件，并把正文读出来给调用方拼进 content', () async {
    final f = await write('nginx.conf', 'worker_processes 4;'.codeUnits);
    final r = await prepareAttachment(
        file: f, serverId: 's1', store: store, downscale: _noDownscale);
    expect(r.attachment!.kind, AttachmentKind.text);
    expect(r.text, contains('worker_processes'));
    expect(r.truncated, isFalse);
  });

  test('二进制 → 拒绝，不落盘', () async {
    final f = await write('a.out', [0x7F, 0x45, 0x4C, 0x46, 0x00]);
    final r = await prepareAttachment(
        file: f, serverId: 's1', store: store, downscale: _noDownscale);
    expect(r.attachment, isNull);
    expect(r.reject, AttachmentReject.binary);
    expect(root.listSync(recursive: true).whereType<File>().length, 1,
        reason: '只有源文件，没有落盘产物');
  });

  test('超大图走 downscale，落盘的是缩后的字节', () async {
    final big = await write('big.png', [...pngHeader, ...List.filled(4 * 1024 * 1024, 7)]);
    var called = false;
    final r = await prepareAttachment(
      file: big,
      serverId: 's1',
      store: store,
      downscale: (bytes, {required maxEdge}) async {
        called = true;
        return Uint8List.fromList([...pngHeader, 9]);
      },
    );
    expect(called, isTrue);
    expect(r.attachment, isNotNull);
    expect(r.attachment!.bytes, 9);
  });

  test('downscale 失败 → 拒绝并带上原始大小', () async {
    final big = await write('big.png', [...pngHeader, ...List.filled(4 * 1024 * 1024, 7)]);
    final r = await prepareAttachment(
      file: big,
      serverId: 's1',
      store: store,
      downscale: (bytes, {required maxEdge}) async => null,
    );
    expect(r.attachment, isNull);
    expect(r.tooLargeBytes, greaterThan(3500 * 1024));
  });

  test('落盘失败（磁盘满/权限）→ saveFailed，不抛', () async {
    // 用真实失败触发，不往生产代码里加测试钩子：把 store 的 root 指到一个
    // **普通文件底下**，`Directory.create(recursive: true)` 必然抛
    // FileSystemException（父路径是文件不是目录）。
    //
    // 用户该看到的是一行「附件保存失败」，而不是未捕获异常把面板打崩。
    final src = await write('a.png', [...pngHeader, 1]);
    final blocker = File('${root.path}/blocker');
    await blocker.writeAsString('x');
    final broken = AttachmentStore(Directory('${blocker.path}/sub'));

    final r = await prepareAttachment(
        file: src, serverId: 's1', store: broken, downscale: _noDownscale);
    expect(r.attachment, isNull);
    expect(r.saveFailed, isTrue);
  });

  group('classifyPick —— 取消与读不到必须分开', () {
    test('选择器返回 null = 用户取消，静默', () {
      expect(classifyPick(pickerReturned: false, path: null),
          PickOutcome.cancelled);
    });

    test('选了文件但没有本地路径 = 读不到，必须提示', () {
      // Android 上从云盘 / 在线文档选文件时就是这个形状：result 非 null，
      // 但 PlatformFile.path 是 null。真机反馈「选完界面没反应」的根因。
      expect(classifyPick(pickerReturned: true, path: null),
          PickOutcome.unreadable);
    });

    test('拿到路径 = 正常继续', () {
      expect(classifyPick(pickerReturned: true, path: '/tmp/a.png'),
          PickOutcome.ok);
    });

    test('取消与读不到不是同一种 —— 它们在屏幕上的表现必须不同', () {
      expect(classifyPick(pickerReturned: false, path: null),
          isNot(classifyPick(pickerReturned: true, path: null)));
    });
  });
}

Future<Uint8List?> _noDownscale(Uint8List b, {required int maxEdge}) async => b;
