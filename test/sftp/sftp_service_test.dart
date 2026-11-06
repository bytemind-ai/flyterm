import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_entry.dart';
import 'package:flyterm/sftp/sftp_service.dart';
import 'package:flyterm/sftp/sftp_transfer_task.dart' show TransferStalledException;

/// Stub SftpOps for tests — no real SSH needed.
class _FakeOps implements SftpOps {
  bool throwOnListdir = false;
  bool throwOnMkdir = false;
  bool throwOnDelete = false;
  bool throwOnRename = false;

  List<SftpName> listdirResult = [];

  /// 按路径返回的目录内容。命中则优先于 [listdirResult]。
  Map<String, List<SftpName>> listdirResults = {};
  final List<String> listdirCalls = [];
  final List<String> removed = [];
  final List<String> rmdirCalls = [];
  String? lastMkdirPath;
  String? lastDeletePath;
  String? lastRenameOld;
  String? lastRenameNew;

  @override
  Future<List<SftpName>> listdir(String path) async {
    listdirCalls.add(path);
    if (throwOnListdir) throw Exception('SFTP connection refused');
    return listdirResults[path] ?? listdirResult;
  }

  /// stat 返回的 size。null = 抛「文件不存在」。
  int? statSize = 0;
  String? lastStatPath;

  /// 按路径覆盖 [statSize]。命中则用它（null = 该路径不存在）。
  /// 「同名冲突探测」需要「a.txt 在、b.txt 不在」这种逐路径的精确控制。
  final Map<String, int?> statSizes = {};

  /// stat 跟随软链后，目标是否是目录。真机上目录信息在 mode 的高 4 位，
  /// 这里用 `0x4000`（目录类型位）构造一个 isDirectory 为真的 attrs。
  bool statIsDirectory = false;

  /// 软链目标。path → target。stat(followLink: false) 时用不到。
  final Map<String, String> readlinks = {};

  /// stat(followLink: false) 时返回的「链接自身」属性。null 表示走 [statSize]。
  final Map<String, SftpFileAttrs> lstatResults = {};

  /// 记录每次 stat 的 followLink，供「递归必须用 false」的断言。
  final List<bool> statFollowLinkCalls = [];

  /// 这些路径的 stat 直接抛异常（模拟悬空软链）。
  final Set<String> statThrowsForPaths = {};

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    statFollowLinkCalls.add(followLink);
    lastStatPath = path;
    if (statThrowsForPaths.contains(path)) throw Exception('No such file');
    if (!followLink) {
      final l = lstatResults[path];
      if (l != null) return l;
    }
    if (statSizes.containsKey(path)) {
      final s = statSizes[path];
      if (s == null) throw Exception('No such file');
      return SftpFileAttrs(size: s);
    }
    final size = statSize;
    if (size == null) throw Exception('No such file');
    // 只给 size + 类型位。`SftpFileMode` 的命名构造只收九个权限位，
    // **没有 isDirectory 参数** —— 文件类型在 mode 的高 4 位。
    // `0x4000` 是目录类型位（见 dartssh2 的 `_ModeFlags.isDirectory`）。
    return SftpFileAttrs(
      size: size,
      mode: statIsDirectory
          ? const SftpFileMode.value(0x4000 | 0x40 | 0x1)
          : null,
    );
  }

  @override
  Future<String> readlink(String path) async {
    final t = readlinks[path];
    if (t == null) throw Exception('Not a symlink');
    return t;
  }

  /// 每次 [mkdirRecursive] 的路径（文件夹上传递归建目录时逐步断言）。
  final List<String> mkdirRecursiveCalls = [];

  @override
  Future<void> mkdirRecursive(String path) async {
    if (throwOnMkdir) throw Exception('File exists');
    lastMkdirPath = path;
    mkdirRecursiveCalls.add(path);
  }

  @override
  Future<int> download(
    String path,
    StreamSink<List<int>> sink, {
    void Function(int bytesRead)? onProgress,
  }) async => 0;

  @override
  Future<void> downloadFromOffset(
    String path,
    StreamSink<List<int>> sink, {
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) async {}

  /// readBytes 返回的字节。默认空。
  Uint8List readBytesResult = Uint8List(0);
  bool throwOnReadBytes = false;

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async {
    if (throwOnReadBytes) throw Exception('Permission denied');
    return readBytesResult;
  }

  @override
  Future<void> writeBytes(String path, Uint8List data) async {}

  /// 非 null 时 [upload] 直接抛这个异常 —— 用来模拟传输路径的各种死法
  /// （`TransferStalledException` / 普通 `Exception`），不需要真的跑一遍
  /// 看门狗或网络往返。
  Object? uploadException;

  /// 每次 [upload] 的远端路径（文件夹上传逐个文件的顺序断言）。
  final List<String> uploadedPaths = [];

  @override
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int bytes)? onProgress,
  ) async {
    final e = uploadException;
    if (e != null) throw e;
    uploadedPaths.add(remotePath);
    onProgress?.call(totalBytes);
  }

  @override
  Future<void> remove(String path) async {
    if (throwOnDelete) throw Exception('Permission denied');
    lastDeletePath = path;
    removed.add(path);
  }

  @override
  Future<void> rmdir(String path) async {
    if (throwOnDelete) throw Exception('Permission denied');
    lastDeletePath = path;
    rmdirCalls.add(path);
  }

  @override
  Future<void> mkdir(String path) async {
    if (throwOnMkdir) throw Exception('File exists');
    lastMkdirPath = path;
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (throwOnRename) throw Exception('Rename failed');
    lastRenameOld = oldPath;
    lastRenameNew = newPath;
  }

  @override
  Future<void> createFile(String path) async {}

  @override
  Future<void> setPermissions(String path, int permissions) async {}

  @override
  Future<String> absolutePath(String path) async => '/home/test';
}

/// 所有操作都返回永不完成的 Future —— 模拟半死 channel「channel 还开着，
/// 协议请求有去无回」那种死法。配合 `fakeAsync` 用，断言超时在虚拟时钟上
/// 如期触发，不用真的等 15 秒。
class _HangingOps implements SftpOps {
  @override
  Future<List<SftpName>> listdir(String path) => Completer<List<SftpName>>().future;

  @override
  Future<int> download(
    String path,
    StreamSink<List<int>> sink, {
    void Function(int bytesRead)? onProgress,
  }) => Completer<int>().future;

  @override
  Future<void> downloadFromOffset(
    String path,
    StreamSink<List<int>> sink, {
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) => Completer<void>().future;

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) =>
      Completer<Uint8List>().future;

  @override
  Future<void> writeBytes(String path, Uint8List data) =>
      Completer<void>().future;

  @override
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int bytes)? onProgress,
  ) => Completer<void>().future;

  @override
  Future<void> remove(String path) => Completer<void>().future;

  @override
  Future<void> rmdir(String path) => Completer<void>().future;

  @override
  Future<void> mkdir(String path) => Completer<void>().future;

  @override
  Future<void> rename(String oldPath, String newPath) => Completer<void>().future;

  @override
  Future<void> createFile(String path) => Completer<void>().future;

  @override
  Future<void> setPermissions(String path, int permissions) =>
      Completer<void>().future;

  @override
  Future<String> absolutePath(String path) => Completer<String>().future;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) =>
      Completer<SftpFileAttrs>().future;

  @override
  Future<String> readlink(String path) => Completer<String>().future;

  @override
  Future<void> mkdirRecursive(String path) => Completer<void>().future;
}

SFTPService _makeService(_FakeOps ops) => SFTPService.testWith(() async => ops);

void main() {
  group('SFTPService initial state', () {
    test('currentPath is /', () {
      expect(_makeService(_FakeOps()).currentPath, '/');
    });

    test('entries is empty', () {
      expect(_makeService(_FakeOps()).entries, isEmpty);
    });

    test('isLoading is false', () {
      expect(_makeService(_FakeOps()).isLoading, isFalse);
    });

    test('error is null', () {
      expect(_makeService(_FakeOps()).error, isNull);
    });
  });

  group('SFTPService.listDirectory', () {
    test('指向目录的软链被标为可进入', () async {
      final ops = _FakeOps();
      ops.listdirResult = [
        SftpName(
          filename: 'current',
          longname: 'lrwxrwxrwx 1 user group 4 Jan 1 00:00 current -> 2026-10',
          attr: SftpFileAttrs(mode: const SftpFileMode.value(0xA000 | 0x1FF)),
        ),
      ];
      // 跟随软链的 stat 说目标是目录。
      ops.statSize = 0;
      ops.statIsDirectory = true;
      final svc = _makeService(ops);
      await svc.listDirectory('/app');

      final e = svc.entries.single;
      expect(e.isSymlink, isTrue);
      expect(e.isDir, isTrue, reason: '软链指向目录时可进入');
      expect(e.isSymlinkToDir, isTrue);
    });

    test('指向目录的软链与真目录一起排在文件前面', () async {
      // 排序必须和「可进入」用同一个判据。曾经排序跑在 SftpName 上，
      // 看 attr.isDirectory —— 它对软链恒为 false，于是可进入的链接
      // 被归到文件堆里，与 isDir 的语义自相矛盾。
      final ops = _FakeOps();
      ops.listdirResult = [
        SftpName(
          filename: 'aaa.txt',
          longname: '-rw-r--r-- 1 user group 1 Jan 1 00:00 aaa.txt',
          attr: SftpFileAttrs(
            size: 1,
            mode: const SftpFileMode.value(0x8000 | 0x1A4),
          ),
        ),
        SftpName(
          filename: 'zzz-real-dir',
          longname: 'drwxr-xr-x 1 user group 1 Jan 1 00:00 zzz-real-dir',
          attr: SftpFileAttrs(
            size: 1,
            mode: const SftpFileMode.value(0x4000 | 0x1ED),
          ),
        ),
        SftpName(
          filename: 'mmm-link-dir',
          longname: 'lrwxrwxrwx 1 user group 4 Jan 1 00:00 mmm-link-dir -> x',
          attr: SftpFileAttrs(mode: const SftpFileMode.value(0xA000 | 0x1FF)),
        ),
      ];
      // 所有软链的目标都是目录。
      ops.statIsDirectory = true;
      final svc = _makeService(ops);
      await svc.listDirectory('/app');

      final names = svc.entries.map((e) => e.name).toList();
      expect(names, ['mmm-link-dir', 'zzz-real-dir', 'aaa.txt'],
          reason: '两个可进入项（按名序）都在文件之前');
    });

    test('悬空软链不导致整个列目录失败', () async {
      final ops = _FakeOps();
      ops.listdirResult = [
        SftpName(
          filename: 'dead',
          longname: 'lrwxrwxrwx 1 user group 4 Jan 1 00:00 dead -> gone',
          attr: SftpFileAttrs(mode: const SftpFileMode.value(0xA000 | 0x1FF)),
        ),
        SftpName(
          filename: 'normal.txt',
          longname: '-rw-r--r-- 1 user group 0 Jan 1 00:00 normal.txt',
          attr: SftpFileAttrs(mode: const SftpFileMode.value(0x8000 | 0x1A4)),
        ),
      ];
      // stat 抛异常模拟「目标不存在」。
      ops.statSize = null;
      ops.statThrowsForPaths.add('/app/dead');

      final svc = _makeService(ops);
      await svc.listDirectory('/app');

      expect(svc.error, isNull, reason: '一个坏软链不该让整页失败');
      expect(svc.entries.length, 2);
      final dead = svc.entries.firstWhere((e) => e.name == 'dead');
      expect(dead.linkState, SftpLinkState.dangling);
      expect(dead.isDir, isFalse);
    });

    test('非软链不产生额外 stat 往返', () async {
      final ops = _FakeOps();
      ops.listdirResult = [
        SftpName(
          filename: 'plain.txt',
          longname: '-rw-r--r-- 1 user group 10 Jan 1 00:00 plain.txt',
          attr: SftpFileAttrs(
            size: 10,
            mode: const SftpFileMode.value(0x8000 | 0x1A4),
          ),
        ),
      ];
      final svc = _makeService(ops);
      await svc.listDirectory('/app');
      expect(ops.statFollowLinkCalls, isEmpty,
          reason: '软链才需要额外 stat，普通文件不该有');
    });

    test('sets error and clears isLoading on failure', () async {
      final ops = _FakeOps()..throwOnListdir = true;
      final svc = _makeService(ops);
      await svc.listDirectory('/home');
      expect(svc.error, contains('SFTP connection refused'));
      expect(svc.isLoading, isFalse);
    });

    test('updates currentPath on success', () async {
      final svc = _makeService(_FakeOps());
      await svc.listDirectory('/home/user');
      expect(svc.currentPath, '/home/user');
    });

    test('retries ops provider after initial provider failure', () async {
      var attempts = 0;
      final ops = _FakeOps();
      final svc = SFTPService.testWith(() async {
        attempts++;
        if (attempts == 1) throw Exception('channel open failed');
        return ops;
      });

      await expectLater(svc.ensureConnected(), throwsException);
      await svc.listDirectory('/home/user');

      expect(attempts, 2);
      expect(svc.error, isNull);
      expect(svc.currentPath, '/home/user');
    });

    test('entries is empty list when server returns empty dir', () async {
      final svc = _makeService(_FakeOps());
      await svc.listDirectory('/tmp');
      expect(svc.entries, isEmpty);
    });

    test('entries populated with real SftpName data', () async {
      final fakeName = SftpName(
        filename: 'hello.txt',
        longname: '-rw-r--r-- 1 user group 42 Jan 1 00:00 hello.txt',
        attr: SftpFileAttrs(size: 42, modifyTime: 0),
      );
      final ops = _FakeOps()..listdirResult = [fakeName];
      final svc = _makeService(ops);
      await svc.listDirectory('/tmp');
      expect(svc.entries.length, 1);
      expect(svc.entries.first.name, 'hello.txt');
      expect(svc.entries.first.size, 42);
    });

    test('刷新时不进入 loading 态（避免列表闪空白）', () async {
      final ops = _FakeOps();
      ops.listdirResult = [];
      final svc = _makeService(ops);
      await svc.listDirectory('/a');
      final seenLoading = <bool>[];
      svc.addListener(() => seenLoading.add(svc.isLoading));
      await svc.refresh();
      expect(seenLoading, isNot(contains(true)),
          reason: '刷新应保留旧列表，不显示全屏转圈');
    });

    test('刷新仍然更新 currentPath 与 entries', () async {
      final ops = _FakeOps();
      ops.listdirResults['/b'] = [
        SftpName(
          filename: 'x.txt',
          longname: '-rw-r--r-- 1 u g 1 Jan 1 00:00 x.txt',
          attr: SftpFileAttrs(size: 1, modifyTime: 0),
        ),
      ];
      final svc = _makeService(ops);
      await svc.listDirectory('/a');
      svc.currentPath = '/b';
      await svc.refresh();
      expect(svc.currentPath, '/b');
      expect(svc.entries.map((e) => e.name), contains('x.txt'));
    });

    test('silent 列出目录时同样不进入 loading 态', () async {
      final svc = _makeService(_FakeOps());
      await svc.listDirectory('/a');
      final seenLoading = <bool>[];
      svc.addListener(() => seenLoading.add(svc.isLoading));
      await svc.listDirectory('/a', silent: true);
      expect(seenLoading, isNot(contains(true)));
    });

    test('filters out . and .. entries', () async {
      final dot = SftpName(filename: '.', longname: '', attr: SftpFileAttrs());
      final dotdot = SftpName(
        filename: '..',
        longname: '',
        attr: SftpFileAttrs(),
      );
      final file = SftpName(
        filename: 'file.txt',
        longname: '',
        attr: SftpFileAttrs(size: 10),
      );
      final ops = _FakeOps()..listdirResult = [dot, dotdot, file];
      final svc = _makeService(ops);
      await svc.listDirectory('/');
      expect(svc.entries.length, 1);
      expect(svc.entries.first.name, 'file.txt');
    });
  });

  group('SFTPService.mkdir', () {
    test('returns true and calls mkdir with correct path', () async {
      final ops = _FakeOps();
      final svc = _makeService(ops);
      await svc.listDirectory('/tmp');
      final result = await svc.mkdir('/tmp/newdir');
      expect(result, isTrue);
      expect(ops.lastMkdirPath, '/tmp/newdir');
    });

    test('returns false and sets error on failure', () async {
      final ops = _FakeOps()..throwOnMkdir = true;
      final svc = _makeService(ops);
      final result = await svc.mkdir('/tmp/newdir');
      expect(result, isFalse);
      expect(svc.error, contains('File exists'));
    });
  });

  group('SFTPService.delete', () {
    test('calls remove for files', () async {
      final ops = _FakeOps();
      final svc = _makeService(ops);
      await svc.delete('/tmp/file.txt', isDir: false);
      expect(ops.lastDeletePath, '/tmp/file.txt');
    });

    test('calls rmdir for directories', () async {
      final ops = _FakeOps();
      final svc = _makeService(ops);
      await svc.delete('/tmp/mydir', isDir: true);
      expect(ops.lastDeletePath, '/tmp/mydir');
    });

    test('returns false and sets error on failure', () async {
      final ops = _FakeOps()..throwOnDelete = true;
      final svc = _makeService(ops);
      final result = await svc.delete('/tmp/file.txt', isDir: false);
      expect(result, isFalse);
      expect(svc.error, isNotNull);
    });
  });

  group('SFTPService.rename', () {
    test('calls rename with correct paths', () async {
      final ops = _FakeOps();
      final svc = _makeService(ops);
      await svc.rename('/tmp/old.txt', '/tmp/new.txt');
      expect(ops.lastRenameOld, '/tmp/old.txt');
      expect(ops.lastRenameNew, '/tmp/new.txt');
    });

    test('returns false and sets error on failure', () async {
      final ops = _FakeOps()..throwOnRename = true;
      final svc = _makeService(ops);
      final result = await svc.rename('/tmp/old.txt', '/tmp/new.txt');
      expect(result, isFalse);
      expect(svc.error, isNotNull);
    });
  });

  group('SFTPService.readlink', () {
    test('返回软链目标', () async {
      final ops = _FakeOps()..readlinks['/tmp/link'] = '/tmp/target';
      final svc = _makeService(ops);
      expect(await svc.readlink('/tmp/link'), '/tmp/target');
    });

    test('失败返回 null 且不设 error —— 一条坏链接不该让整页弹错误', () async {
      final ops = _FakeOps(); // readlinks 为空 → 抛异常
      final svc = _makeService(ops);
      expect(await svc.readlink('/tmp/link'), isNull);
      expect(svc.error, isNull);
    });
  });

  group('SFTPService.lastError（保留原始异常供分类）', () {
    test('删除失败时 lastError 持有原始异常对象', () async {
      final ops = _FakeOps()..throwOnDelete = true;
      final svc = _makeService(ops);
      await svc.delete('/tmp/file.txt', isDir: false);
      expect(svc.error, isNotNull);
      expect(svc.lastError, isNotNull);
      expect(svc.lastError, isNot(isA<String>()),
          reason: 'error 存的是 toString()，lastError 必须是原始对象');
    });

    test('下一次成功的操作清掉 lastError', () async {
      final ops = _FakeOps()..throwOnDelete = true;
      final svc = _makeService(ops);
      await svc.delete('/tmp/file.txt', isDir: false);
      expect(svc.lastError, isNotNull);
      ops.throwOnDelete = false;
      await svc.delete('/tmp/file.txt', isDir: false);
      expect(svc.lastError, isNull);
      expect(svc.error, isNull);
    });

    test('error 与 lastError 在同一次失败中一起被设置', () async {
      // 这两个字段必须同步 —— `error` 是 String（12 个既有消费方在用），
      // `lastError` 是原始对象（UI 靠它分类出可读文案）。两者分开手写的
      // 话，漏一行不会报错，只会让某条路径的错误默默退化成「未知错误」。
      //
      // 所有 catch 块现在都走 `_recordError`，所以这个不变量是结构性的；
      // 这里钉住它，以防将来有人又手写回两行。
      for (final trigger in [
        ('delete', (SFTPService s) => s.delete('/x', isDir: false)),
        ('listdir', (SFTPService s) => s.listDirectory('/x')),
        ('mkdir', (SFTPService s) => s.mkdir('/x')),
      ]) {
        final ops = _FakeOps()
          ..throwOnDelete = trigger.$1 == 'delete'
          ..throwOnListdir = trigger.$1 == 'listdir'
          ..throwOnMkdir = trigger.$1 == 'mkdir';
        final svc = _makeService(ops);
        await trigger.$2(svc);
        expect(svc.error, isNotNull, reason: '${trigger.$1}: error 应被设置');
        expect(svc.lastError, isNotNull,
            reason: '${trigger.$1}: lastError 必须与 error 同步设置');
      }
    });
  });

  test('stat 透传路径并返回 size', () async {
    final ops = _FakeOps()..statSize = 4096;
    final svc = SFTPService.testWith(() async => ops);
    final attrs = await (await svc.opsForTest()).stat('/var/log/app.log');
    expect(ops.lastStatPath, equals('/var/log/app.log'));
    expect(attrs.size, equals(4096));
  });

  group('SFTPService 半死连接守卫（isReusedClientDead / aliveProbe）', () {
    test(
      'isReusedClientDead 返回 true 时，listDirectory 抛 SftpDisconnectedException',
      () async {
        final ops = _FakeOps();
        final svc = SFTPService.testWith(
          () async => ops,
          isReusedClientDead: () => true,
        );
        await svc.listDirectory('/home');
        expect(svc.isDisconnected, isTrue);
        expect(svc.error, contains('SSH 连接已断开'));
        expect(svc.entries, isEmpty);
      },
    );

    test('列目录返回空 + 探活失败（其它异常）→ 报错而不是显示空列表', () async {
      final ops = _FakeOps()..listdirResult = [];
      final svc = SFTPService.testWith(
        () async => ops,
        aliveProbe: () async => throw Exception('探活失败：原因不明'),
      );
      await svc.listDirectory('/empty-but-dead');
      expect(svc.entries, isEmpty);
      expect(svc.error, isNotNull);
      expect(svc.isDisconnected, isTrue);
    });

    test('列目录返回空 + 探活超时（TimeoutException）→ 报错而不是显示空列表', () async {
      final ops = _FakeOps()..listdirResult = [];
      final svc = SFTPService.testWith(
        () async => ops,
        aliveProbe: () async => throw TimeoutException('探活超时'),
      );
      await svc.listDirectory('/empty-but-dead');
      expect(svc.entries, isEmpty);
      expect(svc.error, isNotNull);
      expect(svc.isDisconnected, isTrue);
    });

    test(
      '列目录返回空 + 探活被服务端明确拒绝（channel setup failure）→ 不报断线，正常显示空目录',
      () async {
        // SSHChannelOpenError / 「SSH channel setup failed」意味着服务端回了
        // 一个拒绝消息——它在响应，连接是活的（典型原因是 sshd 的 MaxSessions
        // 满了）。这和「探不通」必须区别对待，否则会把一条健康连接误判成死
        // 连接，而且探活本身占用一个 channel 名额，这个误判在 channel 紧张
        // 的会话里反而更容易触发。
        final ops = _FakeOps()..listdirResult = [];
        final svc = SFTPService.testWith(
          () async => ops,
          aliveProbe:
              () async =>
                  throw StateError('SSH channel setup failed: too many sessions'),
        );
        await svc.listDirectory('/empty-but-dead');
        expect(svc.entries, isEmpty);
        expect(svc.error, isNull);
        expect(svc.isDisconnected, isFalse);
      },
    );

    test('列目录返回空 + 探活成功 → 正常显示空目录', () async {
      final ops = _FakeOps()..listdirResult = [];
      final svc = SFTPService.testWith(
        () async => ops,
        aliveProbe: () async {},
      );
      await svc.listDirectory('/really-empty');
      expect(svc.entries, isEmpty);
      expect(svc.error, isNull);
      expect(svc.isDisconnected, isFalse);
    });

    test('非空结果不触发探活', () async {
      final fakeName = SftpName(
        filename: 'hello.txt',
        longname: '-rw-r--r-- 1 user group 42 Jan 1 00:00 hello.txt',
        attr: SftpFileAttrs(size: 42, modifyTime: 0),
      );
      final ops = _FakeOps()..listdirResult = [fakeName];
      var probeCalls = 0;
      final svc = SFTPService.testWith(
        () async => ops,
        aliveProbe: () async {
          probeCalls++;
        },
      );
      await svc.listDirectory('/tmp');
      expect(svc.entries.length, 1);
      expect(probeCalls, 0,
          reason: '结果非空时额外的探活往返是纯粹的性能浪费，不该发生');
    });
  });

  group('SFTPService.probeAlive', () {
    test('连接正常时返回 true', () async {
      final ops = _FakeOps();
      final svc = SFTPService.testWith(() async => ops);
      expect(await svc.probeAlive(), isTrue);
    });

    test('开不出 channel 时返回 false 并标记断线', () async {
      final svc = SFTPService.testWith(
        () async => throw Exception('channel setup failed'),
      );
      expect(await svc.probeAlive(), isFalse);
      expect(svc.isDisconnected, isTrue);
    });

    test('探活不污染 error（它由后台驱动，不该弹错误）', () async {
      final svc = SFTPService.testWith(
        () async => throw Exception('gone'),
      );
      await svc.probeAlive();
      expect(svc.error, isNull, reason: '探活失败不设 error，避免回前台就弹错');
    });

    test('已 dispose 时返回 false 且不抛', () async {
      final svc = SFTPService.testWith(() async => _FakeOps());
      svc.dispose();
      expect(await svc.probeAlive(), isFalse);
    });

    test('自有连接走真实往返：stat(followLink: false) 失败即判死', () async {
      // 自有连接没有 aliveProbe，探活靠一次真实的 stat 往返。
      final ops = _FakeOps()..statThrowsForPaths.add('/');
      final svc = SFTPService.testWith(() async => ops);
      svc.currentPath = '/';
      expect(await svc.probeAlive(), isFalse);
      expect(svc.isDisconnected, isTrue);
      expect(svc.error, isNull, reason: '探活失败不设 error');
    });

    test('自有连接探活用 lstat（followLink: false），不跟随软链', () async {
      final ops = _FakeOps();
      final svc = SFTPService.testWith(() async => ops);
      await svc.probeAlive();
      expect(ops.lastStatPath, '/');
      expect(ops.statFollowLinkCalls, [false]);
    });

    test('注入 aliveProbe 时成功返回 true 且不改断线态', () async {
      var probeCalls = 0;
      final svc = SFTPService.testWith(
        () async => _FakeOps(),
        aliveProbe: () async {
          probeCalls++;
        },
      );
      expect(await svc.probeAlive(), isTrue);
      expect(probeCalls, 1);
      expect(svc.isDisconnected, isFalse);
    });

    test('注入 aliveProbe 超时 → 拉黑复用连接并判死', () async {
      var markDeadCalls = 0;
      final svc = SFTPService.testWith(
        () async => _FakeOps(),
        aliveProbe: () async => throw TimeoutException('探活超时'),
        markReusedDead: () => markDeadCalls++,
      );
      expect(await svc.probeAlive(), isFalse);
      expect(markDeadCalls, 1);
      expect(svc.isDisconnected, isTrue);
      expect(svc.error, isNull);
    });

    test('注入 aliveProbe 撞上 channel setup failure → 判活，不拉黑', () async {
      // 服务端明确拒绝开新 channel 说明它在响应 —— 与 _probeAliveOnEmpty
      // 同一判据，不能把「服务端有回应」误判成死连接。
      var markDeadCalls = 0;
      final svc = SFTPService.testWith(
        () async => _FakeOps(),
        aliveProbe: () async =>
            throw StateError('SSH channel setup failed: too many sessions'),
        markReusedDead: () => markDeadCalls++,
      );
      expect(await svc.probeAlive(), isTrue);
      expect(markDeadCalls, 0);
      expect(svc.isDisconnected, isFalse);
    });

    test('isReusedClientDead 为 true 时直接判死，不尝试探活', () async {
      var probeCalls = 0;
      final svc = SFTPService.testWith(
        () async => _FakeOps(),
        isReusedClientDead: () => true,
        aliveProbe: () async {
          probeCalls++;
        },
      );
      expect(await svc.probeAlive(), isFalse);
      expect(probeCalls, 0, reason: '已拉黑就不必再浪费一次 channel');
      expect(svc.isDisconnected, isTrue);
    });
  });

  group('SFTPService 元数据操作超时守卫（channel 开着但协议请求有去无回）', () {
    // 这组测试覆盖的是和「探活」/「开不出 channel」完全不同的第三种死法：
    // channel 已经建立、`_getOps()` 的健康守卫也通过了，但实际发请求之后
    // 服务端再也不回包。没有超时的话，下面这些调用会永远挂起——用这个
    // _HangingOps 模拟，配合 fakeAsync 在虚拟时钟上验证 15 秒整后会超时
    // 报错，而不必在真实时间里等 15 秒。

    test('listDirectory 在元数据操作挂死 15 秒后超时，报错而不是永远转圈', () {
      fakeAsync((async) {
        final svc = SFTPService.testWith(() async => _HangingOps());

        Object? caught;
        bool done = false;
        svc.listDirectory('/stuck').then((_) {
          done = true;
        }).catchError((Object e) {
          caught = e;
        });

        // 14 秒还不该超时。
        async.elapse(const Duration(seconds: 14));
        expect(svc.isDisconnected, isFalse);
        expect(done, isFalse);

        // 越过 15 秒整。
        async.elapse(const Duration(seconds: 2));
        expect(done, isTrue, reason: 'listDirectory 内部 catch 住了超时异常，不会外抛');
        expect(caught, isNull);
        expect(svc.error, isNotNull);
        expect(svc.isDisconnected, isTrue);
      });
    });

    test('mkdir 在元数据操作挂死 15 秒后超时，返回 false 且标记断线', () {
      fakeAsync((async) {
        final svc = SFTPService.testWith(() async => _HangingOps());

        bool? result;
        svc.mkdir('/stuck/newdir').then((r) => result = r);

        async.elapse(const Duration(seconds: 14));
        expect(result, isNull);

        async.elapse(const Duration(seconds: 2));
        expect(result, isFalse);
        expect(svc.error, isNotNull);
        expect(svc.isDisconnected, isTrue);
      });
    });

    test('delete 在元数据操作挂死 15 秒后超时，返回 false 且标记断线', () {
      fakeAsync((async) {
        final svc = SFTPService.testWith(() async => _HangingOps());

        bool? result;
        svc
            .delete('/stuck/file.txt', isDir: false)
            .then((r) => result = r);

        async.elapse(const Duration(seconds: 14));
        expect(result, isNull);

        async.elapse(const Duration(seconds: 2));
        expect(result, isFalse);
        expect(svc.error, isNotNull);
        expect(svc.isDisconnected, isTrue);
      });
    });
  });

  group('SFTPService 传输路径的断线标记（uploadTo / downloadFile）', () {
    test(
      'uploadTo：底层连接已被判死（SftpDisconnectedException）→ 抛异常且 isDisconnected 为 true',
      () async {
        final dir = await Directory.systemTemp.createTemp('sftp_test_');
        final localFile = File('${dir.path}/hello.txt')
          ..writeAsStringSync('hi');
        addTearDown(() => dir.delete(recursive: true));

        final svc = SFTPService.testWith(
          () async => _FakeOps(),
          isReusedClientDead: () => true,
        );
        await expectLater(
          svc.uploadTo(
            localPath: localFile.path,
            remotePath: '/remote/hello.txt',
          ),
          throwsA(isA<SftpDisconnectedException>()),
        );
        expect(svc.isDisconnected, isTrue);
      },
    );

    test(
      'downloadFile：底层连接已被判死（SftpDisconnectedException）→ 返回 null 且 isDisconnected 为 true',
      () async {
        // `_getOps()` 的健康守卫在拿下载目录之前就会抛，走不到
        // `getDownloadsDirectory()`，所以这里不需要注入 downloadDirProvider。
        final svc = SFTPService.testWith(
          () async => _FakeOps(),
          isReusedClientDead: () => true,
        );
        final saved = await svc.downloadFile('/remote/hello.txt');
        expect(saved, isNull);
        expect(svc.isDisconnected, isTrue);
      },
    );

    test(
      'uploadTo：传输看门狗判定卡死（TransferStalledException）→ isDisconnected 为 true',
      () async {
        final dir = await Directory.systemTemp.createTemp('sftp_test_');
        final localFile = File('${dir.path}/hello.txt')
          ..writeAsStringSync('hi');
        addTearDown(() => dir.delete(recursive: true));

        final ops = _FakeOps()..uploadException = const TransferStalledException(0);
        final svc = _makeService(ops);
        await expectLater(
          svc.uploadTo(
            localPath: localFile.path,
            remotePath: '/remote/hello.txt',
          ),
          throwsA(isA<TransferStalledException>()),
        );
        expect(svc.isDisconnected, isTrue);
      },
    );

    test(
      'uploadTo：普通异常（非断线信号）→ isDisconnected 必须保持 false，不能见错就标断线',
      () async {
        // 护栏测试：别把所有失败都标成「断线」，那样重连按钮会到处乱弹——
        // 权限错误 / 磁盘满之类的普通失败，重连一百次也没用。
        final dir = await Directory.systemTemp.createTemp('sftp_test_');
        final localFile = File('${dir.path}/hello.txt')
          ..writeAsStringSync('hi');
        addTearDown(() => dir.delete(recursive: true));

        final ops = _FakeOps()..uploadException = Exception('Permission denied');
        final svc = _makeService(ops);
        await expectLater(
          svc.uploadTo(
            localPath: localFile.path,
            remotePath: '/remote/hello.txt',
          ),
          throwsException,
        );
        expect(svc.isDisconnected, isFalse);
      },
    );
  });

  group('递归操作不跟随软链', () {
    // 说明 —— 这组用例的保护对象要说清楚，否则后人会误解：
    //
    // **它们能抓住什么**：任何「把软链当目录递归进去」的实现。实测把判断改成
    // `attr.isDirectory || attr.isSymbolicLink`（模拟「跟随软链」）后，两个用例
    // 都变红，且环的用例不会挂死（因为断言的是 listdir 调用次数）。这是真正的
    // 回归风险 —— 例如有人为了「软链也可进入」的直觉把判据换成
    // `SftpEntry.isDir`（软链指向目录时也为 true）。
    //
    // **它们抓不住什么**：`!attr.isSymbolicLink` 这一子句本身。因为 dartssh2
    // 的 `SftpFileAttrs.type` 是同一组 mode 位上的单值 switch，软链（0xA000）
    // 的 `isDirectory` 本来就恒为 false —— 对任何真实 attr 编码，
    // `isDirectory && !isSymbolicLink` 严格等价于 `isDirectory`。所以那个子句是
    // **防御性 no-op**：它不提供额外行为，只是把「不得跟随软链」这个意图写进
    // 代码。它的价值在于**可读性与约束表达**，不在于运行时兜底。
    //
    // 不确定这一点时，下一个用例把它钉死。
    /// 构造「链接自身」的属性：类型位为 soft link（0xA000），权限 0x1FF。
    SftpFileAttrs linkAttrs() =>
        SftpFileAttrs(mode: const SftpFileMode.value(0xA000 | 0x1FF));

    test('删除指向目录的软链只删链接，不进目标', () async {
      final ops = _FakeOps();
      // /data 里有一个软链 loop → /data（自指环）
      ops.listdirResults = {
        '/data': [
          SftpName(
            filename: 'loop',
            longname: 'lrwxrwxrwx 1 u g 0 loop -> /data',
            attr: linkAttrs(),
          ),
        ],
      };
      final svc = _makeService(ops);
      await svc.delete('/data', isDir: true);

      expect(
        ops.removed.any((p) => p == '/data/loop'),
        isTrue,
        reason: '软链本身要删掉',
      );
      expect(ops.rmdirCalls.contains('/data'), isTrue);
      expect(
        ops.listdirCalls.where((p) => p == '/data').length,
        1,
        reason: '只列 /data 一次 —— 没有进入 loop 递归（否则会无限递归）',
      );
    });

    test('下载扫描不为软链指向的目录递归', () async {
      final ops = _FakeOps();
      ops.listdirResults = {
        '/src': [
          SftpName(
            filename: 'link',
            longname: 'lrwxrwxrwx 1 u g 0 link -> /src',
            attr: linkAttrs(),
          ),
        ],
      };
      final dir = await Directory.systemTemp.createTemp('sftp_scan_');
      addTearDown(() => dir.delete(recursive: true));
      final svc = SFTPService.testWith(
        () async => ops,
        downloadDirProvider: () async => dir,
      );
      await svc.downloadFolder('/src');

      expect(ops.listdirCalls.where((p) => p == '/src').length, 1);
      expect(
        ops.listdirCalls.contains('/src/link'),
        isFalse,
        reason: '不跟随软链进入目标',
      );
    });

    test('软链判定子句：attr 层 isDirectory 与 isSymbolicLink 互斥（!isSymbolicLink 是防御性 no-op）',
        () {
      // 钉住 dartssh2 的编码事实：同一个 mode 不会同时 isDirectory 且
      // isSymbolicLink。因此 `isDirectory && !isSymbolicLink` 当前等价于
      // `isDirectory`，这一子句是**面向未来**的防御（若某天把「跟随后的
      // 属性」喂进这里，或 dartssh2 改了 type 推导，它才会真正起作用）。
      final link = SftpFileAttrs(
        mode: const SftpFileMode.value(0xA000 | 0x1FF),
      );
      expect(link.isSymbolicLink, isTrue);
      expect(link.isDirectory, isFalse);
      expect(link.isDirectory && !link.isSymbolicLink, link.isDirectory);

      final dir = SftpFileAttrs(
        mode: const SftpFileMode.value(0x4000 | 0x1FF),
      );
      expect(dir.isDirectory, isTrue);
      expect(dir.isSymbolicLink, isFalse);
      expect(dir.isDirectory && !dir.isSymbolicLink, dir.isDirectory);
    });
  });

  group('readTextFile 截断结论', () {
    test('文件比上限大时 truncated 为 true，并给出真实大小', () async {
      final ops = _FakeOps()
        ..readBytesResult = Uint8List.fromList(List.filled(100, 0x61))
        ..statSize = 800000;
      final svc = _makeService(ops);
      final r = await svc.readTextFile('/big.txt');

      expect(r, isNotNull);
      expect(r!.truncated, isTrue);
      expect(r.totalSize, 800000, reason: '真实大小来自 stat，不是列表快照');
    });

    test('stat 失败时按「读满上限」保守判截断', () async {
      final ops = _FakeOps()
        ..readBytesResult = Uint8List.fromList(List.filled(512 * 1024, 0x61))
        ..statSize = null;
      final svc = _makeService(ops);
      final r = await svc.readTextFile('/unknown.txt');

      expect(r!.truncated, isTrue);
      expect(r.totalSize, isNull);
    });

    test('小文件 truncated 为 false', () async {
      final ops = _FakeOps()
        ..readBytesResult = Uint8List.fromList('hello'.codeUnits)
        ..statSize = 5;
      final svc = _makeService(ops);
      final r = await svc.readTextFile('/small.txt');
      expect(r!.truncated, isFalse);
      expect(r.content, 'hello');
    });

    test('读失败返回 null', () async {
      final ops = _FakeOps()..throwOnReadBytes = true;
      final svc = _makeService(ops);
      expect(await svc.readTextFile('/x'), isNull);
    });
  });

  group('TransferState 速率与分数', () {
    test('fraction 可空 —— 未知进度表达为 null 而不是魔数 0.5', () {
      const s = TransferState(
        filename: 'x',
        fraction: null,
        isSending: false,
      );
      expect(s.fraction, isNull);
      expect(s.progressValue, isNull);
    });

    test('rate 与 eta 可空，默认未知', () {
      const s = TransferState(
        filename: 'x',
        fraction: 0.5,
        isSending: false,
      );
      expect(s.bytesPerSecond, isNull);
      expect(s.eta, isNull);
      expect(s.progressValue, 0.5);
    });

    test('扫描阶段 fraction 为 null', () async {
      final ops = _FakeOps();
      ops.listdirResults = {'/src': []};
      final dir = await Directory.systemTemp.createTemp('sftp_state_');
      addTearDown(() => dir.delete(recursive: true));
      final svc = SFTPService.testWith(
        () async => ops,
        downloadDirProvider: () async => dir,
      );
      final states = <TransferState>[];
      svc.addListener(() {
        final st = svc.transferState;
        if (st != null) states.add(st);
      });
      await svc.downloadFolder('/src');
      expect(states.any((s) => s.isScanning && s.fraction == null), isTrue,
          reason: '扫描阶段应是「不确定进度」');
    });
  });

  group('joinRemote 路径拼接', () {
    test('根目录不产生双斜杠', () {
      expect(SFTPService.joinRemote('/', 'a.txt'), '/a.txt');
    });

    test('普通目录正常拼接', () {
      expect(SFTPService.joinRemote('/home/u', 'a.txt'), '/home/u/a.txt');
    });

    test('尾部斜杠不产生双斜杠', () {
      expect(SFTPService.joinRemote('/home/u/', 'a.txt'), '/home/u/a.txt');
    });

    test('多级相对路径', () {
      expect(SFTPService.joinRemote('/', 'a/b/c.txt'), '/a/b/c.txt');
    });

    test('根目录 + 冲突探测：//a.txt 的旧写法会让根目录冲突永远探测不到', () async {
      final ops = _FakeOps();
      // 记录 stat 收到的路径
      final svc = _makeService(ops);
      await svc.detectConflicts(remoteRoot: '/', relativePaths: ['a.txt']);
      expect(ops.lastStatPath, '/a.txt',
          reason: '拼成 //a.txt 时服务端只会说「不存在」，冲突静默漏掉');
    });
  });

  group('文件夹上传', () {
    test('本地目录不存在 → 记录错误而不是崩溃或静默成功', () async {
      final ops = _FakeOps();
      final svc = _makeService(ops);
      await svc.uploadDirectory(
        localRoot: '/tmp/nonexistent-for-test',
        remoteRoot: '/dest',
      );
      expect(svc.error, isNotNull);
      expect(svc.lastError, isNotNull,
          reason: '失败一律走 _recordError —— error/lastError 必须同步');
      expect(ops.uploadedPaths, isEmpty);
    });

    test('上传前为每个文件递归创建远端目录，并串行上传每个文件', () async {
      final root = await Directory.systemTemp.createTemp('upload_dir_');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/a/b').create(recursive: true);
      await Directory('${root.path}/empty').create(recursive: true);
      await File('${root.path}/root.txt').writeAsString('x' * 10);
      await File('${root.path}/a/one.txt').writeAsString('y' * 20);
      await File('${root.path}/a/b/two.txt').writeAsString('z' * 30);

      final ops = _FakeOps();
      final svc = _makeService(ops);
      await svc.uploadDirectory(localRoot: root.path, remoteRoot: '/dest');

      expect(svc.error, isNull);
      // 目录（含空目录）都建了。
      expect(
        ops.mkdirRecursiveCalls,
        containsAll(['/dest/a', '/dest/a/b', '/dest/empty']),
      );
      // 三个文件都传了。
      expect(
        ops.uploadedPaths.toSet(),
        {'/dest/root.txt', '/dest/a/one.txt', '/dest/a/b/two.txt'},
      );
      // 传输结束后进度清空。
      expect(svc.transferState, isNull);
    });

    test('skipRelativePaths 命中的文件被跳过', () async {
      final root = await Directory.systemTemp.createTemp('upload_dir_');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/keep.txt').writeAsString('x' * 3);
      await File('${root.path}/skip.txt').writeAsString('y' * 4);

      final ops = _FakeOps();
      final svc = _makeService(ops);
      await svc.uploadDirectory(
        localRoot: root.path,
        remoteRoot: '/dest',
        skipRelativePaths: {'skip.txt'},
      );

      expect(ops.uploadedPaths, ['/dest/keep.txt']);
      expect(svc.error, isNull);
    });

    test('冲突检测列出远端已存在的文件', () async {
      final ops = _FakeOps();
      // /dest/a.txt 已存在，/dest/b.txt 不存在。
      ops.statSizes['/dest/a.txt'] = 5;
      ops.statSizes['/dest/b.txt'] = null;
      final conflicts = await SFTPService.detectConflictsForTest(
        ops,
        remoteRoot: '/dest',
        relativePaths: ['a.txt', 'b.txt'],
      );
      expect(conflicts, contains('a.txt'));
      expect(conflicts, isNot(contains('b.txt')));
    });

    test('冲突检测用 stat(followLink: false) —— 不跟随软链', () async {
      final ops = _FakeOps();
      ops.statSizes['/dest/link'] = 1;
      await SFTPService.detectConflictsForTest(
        ops,
        remoteRoot: '/dest',
        relativePaths: ['link'],
      );
      expect(ops.statFollowLinkCalls, isNotEmpty);
      expect(ops.statFollowLinkCalls.every((f) => f == false), isTrue,
          reason: '跟随软链会把「链接存在」误判成「文件存在」');
    });
  });
}
