import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_service.dart';
import 'package:flyterm/sftp/sftp_transfer_task.dart';

/// 只实现传输用到的方法，其余抛 UnimplementedError —— 谁不小心用了会立刻炸，
/// 而不是拿到一个静默的空值。
class FakeTransferOps implements SftpOps {
  /// 每次 downloadFromOffset 吐出的分片。
  List<List<int>> chunks = [];
  int? lastOffset;
  int downloadCalls = 0;

  /// 上传收到的字节。
  final List<int> uploaded = [];
  String? lastUploadPath;

  /// null = stat 抛「文件不存在」。
  int? statSize = 0;

  /// upload 时抛错，用来测上传段失败。
  bool throwOnUpload = false;

  /// rename 是否发生在第一次 upload 之前 —— 覆盖备份的顺序守卫。
  bool renamedBeforeUpload = false;
  bool _uploadStarted = false;

  @override
  Future<void> downloadFromOffset(
    String path,
    StreamSink<List<int>> sink, {
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) async {
    downloadCalls++;
    lastOffset = offset;
    var total = offset;
    for (final c in chunks) {
      sink.add(c);
      total += c.length;
      onProgress?.call(total);
      // 让出事件循环，让取消/看门狗有插入点。
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int bytes)? onProgress,
  ) async {
    _uploadStarted = true;
    if (throwOnUpload) throw Exception('upload failed');
    lastUploadPath = remotePath;
    var n = 0;
    await for (final chunk in data) {
      uploaded.addAll(chunk);
      n += chunk.length;
      onProgress?.call(n);
    }
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final s = statSize;
    if (s == null) throw Exception('No such file');
    return SftpFileAttrs(size: s);
  }

  @override
  Future<String> readlink(String path) => throw UnimplementedError();
  @override
  Future<void> mkdirRecursive(String path) => throw UnimplementedError();

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (!_uploadStarted) renamedBeforeUpload = true;
  }

  @override
  Future<List<SftpName>> listdir(String path) => throw UnimplementedError();
  @override
  Future<int> download(String path, StreamSink<List<int>> sink,
          {void Function(int)? onProgress}) =>
      throw UnimplementedError();
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) =>
      throw UnimplementedError();
  @override
  Future<void> writeBytes(String path, Uint8List data) =>
      throw UnimplementedError();
  @override
  Future<void> remove(String path) => throw UnimplementedError();
  @override
  Future<void> rmdir(String path) => throw UnimplementedError();
  @override
  Future<void> mkdir(String path) => throw UnimplementedError();
  @override
  Future<void> createFile(String path) => throw UnimplementedError();
  @override
  Future<void> setPermissions(String path, int permissions) =>
      throw UnimplementedError();
  @override
  Future<String> absolutePath(String path) => throw UnimplementedError();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flyterm_transfer_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('全新下载：落盘到 destDir，.part 被改名掉', () async {
    final ops = FakeTransferOps()
      ..chunks = [
        [1, 2, 3],
        [4, 5],
      ];
    final task = SftpTransferTask(ops: ops);

    final saved = await task.download(
      remotePath: '/var/log/app.log',
      destDir: tmp,
      totalBytes: 5,
    );

    expect(saved, equals('${tmp.path}/app.log'));
    expect(await File(saved).readAsBytes(), equals([1, 2, 3, 4, 5]));
    expect(await File('$saved.flyterm.part').exists(), isFalse);
    expect(ops.lastOffset, equals(0));
  });

  test('续传：offset 从已有 .part 长度算出，只下剩余部分', () async {
    // 先造一个「已经下了 3 字节」的 .part
    await File('${tmp.path}/app.log.flyterm.part').writeAsBytes([1, 2, 3]);

    final ops = FakeTransferOps()..chunks = [[4, 5]];
    final task = SftpTransferTask(ops: ops);

    final saved = await task.download(
      remotePath: '/var/log/app.log',
      destDir: tmp,
      totalBytes: 5,
    );

    expect(ops.lastOffset, equals(3), reason: '必须从 3 续，不能从头下');
    expect(await File(saved).readAsBytes(), equals([1, 2, 3, 4, 5]));
  });

  test('.part 已经完整时直接改名，一次远端调用都不发', () async {
    await File('${tmp.path}/app.log.flyterm.part').writeAsBytes([1, 2, 3, 4, 5]);

    final ops = FakeTransferOps();
    final task = SftpTransferTask(ops: ops);

    final saved = await task.download(
      remotePath: '/var/log/app.log',
      destDir: tmp,
      totalBytes: 5,
    );

    expect(ops.downloadCalls, equals(0));
    expect(await File(saved).readAsBytes(), equals([1, 2, 3, 4, 5]));
  });

  test('进度回调单调递增，终值等于 totalBytes', () async {
    final ops = FakeTransferOps()
      ..chunks = [
        [1, 2],
        [3, 4],
        [5],
      ];
    final seen = <int>[];
    final task = SftpTransferTask(
      ops: ops,
      onProgress: (p) => seen.add(p.bytesDone),
    );

    await task.download(
      remotePath: '/f',
      destDir: tmp,
      totalBytes: 5,
    );

    // 首项 0 是发起时那次初始 emit（见 `download()` 里的说明）—— 它让进度条
    // 在第一个分片到达之前就出现。这个测试要守的是「单调递增、终值等于
    // totalBytes」，0 开头完全符合；写死成 [2,4,5] 会把一个有用的 UI 行为
    // 判成 bug。
    expect(seen, equals([0, 2, 4, 5]));
    expect(seen.last, equals(5));
  });

  test('取消后抛 TransferCancelledException，.part 保留以便续传', () async {
    final token = TransferCancelToken();
    final ops = FakeTransferOps()
      ..chunks = [
        [1, 2],
        [3, 4],
        [5, 6],
      ];
    final task = SftpTransferTask(
      ops: ops,
      cancelToken: token,
      // 拨快看门狗，让取消能在几毫秒内被观察到。
      stallCheckInterval: const Duration(milliseconds: 1),
      stallTimeout: const Duration(seconds: 30),
      onProgress: (p) {
        // 传到 2 字节就取消。
        if (p.bytesDone >= 2) token.cancel();
      },
    );

    await expectLater(
      task.download(remotePath: '/f', destDir: tmp, totalBytes: 6),
      throwsA(isA<TransferCancelledException>()),
    );

    // .part 必须留着 —— 删了下次没法续。
    expect(await File('${tmp.path}/f.flyterm.part').exists(), isTrue);
    expect(await File('${tmp.path}/f').exists(), isFalse);
  });

  test('连续 30 秒没有字节推进 → TransferStalledException', () {
    fakeAsync((async) {
      final ops = FakeTransferOps();
      // 永不完成、永不吐字节的下载 —— 模拟远端卡死。
      ops.chunks = [];
      final stuck = Completer<void>();
      final task = _StuckTask(ops: ops, block: stuck.future);

      Object? caught;
      task
          .download(remotePath: '/f', destDir: tmp, totalBytes: 100)
          .catchError((Object e) {
        caught = e;
        return '';
      });

      // 29 秒还不该判死。
      async.elapse(const Duration(seconds: 29));
      expect(caught, isNull);

      // 越过 30 秒。
      async.elapse(const Duration(seconds: 6));
      expect(caught, isA<TransferStalledException>());
    });
  });

  test('上传：字节送达远端指定路径，进度回调到位', () async {
    final local = File('${tmp.path}/pic.jpg');
    await local.writeAsBytes([9, 8, 7, 6]);

    final ops = FakeTransferOps();
    final seen = <int>[];
    final task = SftpTransferTask(
      ops: ops,
      onProgress: (p) => seen.add(p.bytesDone),
    );

    await task.upload(localPath: local.path, remotePath: '/www/img/pic.jpg');

    expect(ops.lastUploadPath, equals('/www/img/pic.jpg'));
    expect(ops.uploaded, equals([9, 8, 7, 6]));
    expect(seen.last, equals(4));
  });

  test('上传中取消 → TransferCancelledException', () async {
    final local = File('${tmp.path}/big.bin');
    await local.writeAsBytes(List.filled(4096, 7));

    final token = TransferCancelToken()..cancel(); // 传之前就取消
    final ops = FakeTransferOps();
    final task = SftpTransferTask(
      ops: ops,
      cancelToken: token,
      stallCheckInterval: const Duration(milliseconds: 1),
    );

    await expectLater(
      task.upload(localPath: local.path, remotePath: '/www/big.bin'),
      throwsA(isA<TransferCancelledException>()),
    );
  });
}

/// 一个永远卡住的 task —— 用来测看门狗。
///
/// 不能靠 FakeTransferOps 的空 chunks 模拟：那样 downloadFromOffset 会立刻
/// 正常返回，看门狗根本没机会跑。
class _StuckTask extends SftpTransferTask {
  final Future<void> block;
  _StuckTask({required super.ops, required this.block})
      : super(
          stallTimeout: const Duration(seconds: 30),
          stallCheckInterval: const Duration(seconds: 5),
        );

  @override
  Future<String> download({
    required String remotePath,
    required Directory destDir,
    required int totalBytes,
    bool publishToPublicStore = false,
  }) async {
    await guardedForTest(startBytes: 0, body: () => block);
    return '${destDir.path}/stuck';
  }
}
