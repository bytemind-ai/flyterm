import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_entry.dart';
import 'package:flyterm/ui/ai/file_index.dart';

/// 造一个目录条目。`file_index` 只关心 `name` + `isDir` + `path`，
/// 其余字段走零值。
SftpEntry _dir(String path) {
  final name = path.split('/').where((s) => s.isNotEmpty).last;
  return SftpEntry(
    name: name,
    path: path,
    isDir: true,
    size: 0,
    modTime: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

SftpEntry _file(String path) {
  final name = path.split('/').where((s) => s.isNotEmpty).last;
  return SftpEntry(
    name: name,
    path: path,
    isDir: false,
    size: 1,
    modTime: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// 一个可编程的假 `listdir`：`tree` 是「目录 → 条目路径列表」。
/// 未被登记的目录返回空（模拟权限拒绝之外的空目录）。
class _FakeFs {
  final Map<String, List<SftpEntry>> tree;
  final List<String> calls = [];
  final Set<String> failOn;
  int inFlight = 0;
  int peakInFlight = 0;

  _FakeFs(this.tree, {this.failOn = const {}});

  Future<List<SftpEntry>> listDir(String dir, {String? serverId}) async {
    calls.add(dir);
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    // 让出事件循环，模拟网络往返 —— 没有它并发度恒为 1（同步返回不会重叠）。
    await Future<void>.delayed(Duration.zero);
    inFlight--;
    if (failOn.contains(dir)) throw StateError('denied: $dir');
    return tree[dir] ?? const [];
  }
}

void main() {
  group('buildFileIndex', () {
    test('递归覆盖到 maxDepth，超过的不再展开', () async {
      // /a/b/c/d/e 是一条五层链，maxDepth = 4 → 不该展开到 /a/b/c/d/e。
      final fs = _FakeFs({
        '/root': [_dir('/root/a')],
        '/root/a': [_dir('/root/a/b')],
        '/root/a/b': [_dir('/root/a/b/c')],
        '/root/a/b/c': [_dir('/root/a/b/c/d')],
        '/root/a/b/c/d': [_dir('/root/a/b/c/d/e')],
      });
      final sink = <String, List<SftpEntry>>{};

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: sink,
        isCancelled: () => false,
        onDirReady: (_) {},
      );

      expect(sink.keys, contains('/root'));
      expect(sink.keys, contains('/root/a'));
      expect(sink.keys, contains('/root/a/b'));
      expect(sink.keys, contains('/root/a/b/c'));
      expect(sink.keys, contains('/root/a/b/c/d'));
      // 第 5 层不再展开 —— 它的条目被列出（因为 /a/b/c/d 被列了），
      // 但 /a/b/c/d/e 这个目录本身没有被 listdir。
      expect(sink.keys, isNot(contains('/root/a/b/c/d/e')));
      expect(fs.calls, isNot(contains('/root/a/b/c/d/e')));
    });

    test('maxEntries 截断时留下浅层 —— BFS 而不是 DFS', () async {
      // 根下有 3 个目录：d1 里塞满 100 个文件，d2/d3 各有一个文件。
      // DFS 会一头扎进 d1 烧光预算；BFS 应该先覆盖根这一层和 d1/d2/d3。
      final fs = _FakeFs({
        '/root': [_dir('/root/d1'), _dir('/root/d2'), _dir('/root/d3')],
        '/root/d1': [for (var i = 0; i < 100; i++) _file('/root/d1/f$i')],
        '/root/d2': [_file('/root/d2/x')],
        '/root/d3': [_file('/root/d3/y')],
      });
      final sink = <String, List<SftpEntry>>{};

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: sink,
        isCancelled: () => false,
        onDirReady: (_) {},
        config: const FileIndexConfig(maxEntries: 20),
      );

      // BFS：根的三层兄弟都在，而不是只把 d1 填满。
      expect(sink.keys, contains('/root/d2'));
      expect(sink.keys, contains('/root/d3'));
    });

    test('maxEntries 记账计的是条目总数，不是目录数', () async {
      final fs = _FakeFs({
        '/root': [_dir('/root/d1'), _dir('/root/d2')],
        '/root/d1': [for (var i = 0; i < 50; i++) _file('/root/d1/f$i')],
        '/root/d2': [for (var i = 0; i < 50; i++) _file('/root/d2/f$i')],
      });
      final sink = <String, List<SftpEntry>>{};

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: sink,
        isCancelled: () => false,
        onDirReady: (_) {},
        // 并发度 1：把「按层超支」这个粒度暴露出来。并发度高时一批里可能
        // 同时装下 d1 与 d2，超支就显得更大 —— 那是并发的性质，不是记账错。
        config: const FileIndexConfig(maxEntries: 10, concurrency: 1),
      );

      // 预算 10：根占 2（d1/d2），d1 的 50 条一进来就超（一次 listdir 是
      // 原子的，没法只取一半），于是到 d2 之前就停 —— 超支的单位是「一层」。
      final total = sink.values.fold<int>(0, (a, b) => a + b.length);
      expect(total, lessThanOrEqualTo(2 + 50));
      expect(sink.keys, isNot(contains('/root/d2')));
    });

    test('并发度不超过 config.concurrency', () async {
      final fs = _FakeFs({
        '/root': [for (var i = 0; i < 20; i++) _dir('/root/d$i')],
        for (var i = 0; i < 20; i++) '/root/d$i': [_file('/root/d$i/f')],
      });

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: <String, List<SftpEntry>>{},
        isCancelled: () => false,
        onDirReady: (_) {},
        config: const FileIndexConfig(concurrency: 3),
      );

      expect(fs.peakInFlight, lessThanOrEqualTo(3));
      // 也确认真的并发了（不是退化成串行）。
      expect(fs.peakInFlight, greaterThan(1));
    });

    test('单层抛异常只丢该层，其余照常写入', () async {
      final fs = _FakeFs(
        {
          '/root': [_dir('/root/ok'), _dir('/root/bad'), _dir('/root/ok2')],
          '/root/ok': [_file('/root/ok/a')],
          '/root/bad': [_file('/root/bad/b')],
          '/root/ok2': [_file('/root/ok2/c')],
        },
        failOn: {'/root/bad'},
      );
      final sink = <String, List<SftpEntry>>{};

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: sink,
        isCancelled: () => false,
        onDirReady: (_) {},
      );

      expect(sink.keys, contains('/root/ok'));
      expect(sink.keys, contains('/root/ok2'));
      expect(sink.keys, isNot(contains('/root/bad')));
    });

    test('根目录本身失败时整体不写，但不抛异常', () async {
      final fs = _FakeFs({}, failOn: {'/root'});
      final sink = <String, List<SftpEntry>>{};

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: sink,
        isCancelled: () => false,
        onDirReady: (_) {},
      );

      expect(sink, isEmpty);
    });

    test('isCancelled 之后不再发新请求', () async {
      var cancelled = false;
      final fs = _FakeFs({
        '/root': [for (var i = 0; i < 30; i++) _dir('/root/d$i')],
        for (var i = 0; i < 30; i++) '/root/d$i': [_file('/root/d$i/f')],
      });

      await buildFileIndex(
        root: '/root',
        listDir: (dir, {serverId}) async {
          final r = await fs.listDir(dir, serverId: serverId);
          // 列完根就取消 —— 后面那 30 个目录一个都不该再发。
          if (dir == '/root') cancelled = true;
          return r;
        },
        sink: <String, List<SftpEntry>>{},
        isCancelled: () => cancelled,
        onDirReady: (_) {},
        config: const FileIndexConfig(concurrency: 1),
      );

      expect(fs.calls, ['/root']);
    });

    test('软链指向目录时不递归进去 —— 防环', () async {
      // /root/link 是软链且指向目录（isDir 为真），但不该被当成子目录展开。
      final link = SftpEntry(
        name: 'link',
        path: '/root/link',
        isDir: true,
        size: 0,
        modTime: DateTime.fromMillisecondsSinceEpoch(0),
        linkState: SftpLinkState.ok,
        linkTargetIsDir: true,
      );
      final fs = _FakeFs({
        '/root': [link, _file('/root/f')],
        '/root/link': [_file('/root/link/inner')],
      });
      final sink = <String, List<SftpEntry>>{};

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: sink,
        isCancelled: () => false,
        onDirReady: (_) {},
      );

      expect(fs.calls, ['/root']);
      expect(sink.keys, isNot(contains('/root/link')));
      // 但软链本身仍在候选里（用户点得进去）。
      expect(sink['/root']!.any((e) => e.name == 'link'), isTrue);
    });

    test('空目录写进 sink 的是空 list，不是缺失', () async {
      final fs = _FakeFs({'/root': [_dir('/root/empty')], '/root/empty': []});
      final sink = <String, List<SftpEntry>>{};

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: sink,
        isCancelled: () => false,
        onDirReady: (_) {},
      );

      expect(sink.containsKey('/root/empty'), isTrue);
      expect(sink['/root/empty'], isEmpty);
    });

    test('onDirReady 每写完一层回调一次，且带该目录', () async {
      final fs = _FakeFs({
        '/root': [_dir('/root/a')],
        '/root/a': [_file('/root/a/f')],
      });
      final ready = <String>[];

      await buildFileIndex(
        root: '/root',
        listDir: fs.listDir,
        sink: <String, List<SftpEntry>>{},
        isCancelled: () => false,
        onDirReady: ready.add,
      );

      expect(ready, containsAll(['/root', '/root/a']));
      expect(ready.length, 2);
    });

    test('serverId 原样透传给 listDir —— 跨机索引靠它分流', () async {
      final seen = <String?>[];
      await buildFileIndex(
        root: '/root',
        serverId: 'srv-9',
        listDir: (dir, {serverId}) async {
          seen.add(serverId);
          return const [];
        },
        sink: <String, List<SftpEntry>>{},
        isCancelled: () => false,
        onDirReady: (_) {},
      );
      expect(seen, ['srv-9']);
    });
  });
}
