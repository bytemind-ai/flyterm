import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/sftp/sftp_service.dart';
import 'package:flyterm/sftp/sftp_name_sort.dart';
import 'package:flyterm/ui/sftp/sftp_sort_prefs.dart';
import 'package:flyterm/sftp/sftp_upload_plan.dart';
import 'package:flyterm/data/models/sftp_path.dart';
import 'package:flyterm/ui/sftp/sftp_inline_view.dart';
import 'package:flyterm/ui/sftp/sftp_path_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal [SftpOps] stub.
///
/// `existingRemote` 决定哪些远端路径「已存在」—— 冲突确认那段流程靠它驱动。
class _FakeOps implements SftpOps {
  _FakeOps({this.existingRemote = const {}});

  final Set<String> existingRemote;

  /// true 时 listdir 抛异常，用于驱动错误态（重连按钮）那条分支。
  bool throwOnListdir = false;

  /// 覆盖 listdir 抛出的异常对象。null 时走默认的通用 `Exception`
  /// （分类为 unknown）。「主错误分支必须过分类器」那条回归测试需要
  /// 一个能归类到 disconnected 的异常（SftpDisconnectedException /
  /// TimeoutException），裸 `Exception` 分不出类来。
  Object? listdirError;

  /// listdir 的返回内容。默认空目录。
  List<SftpName> listdirResult = [];

  /// 按路径分发的 listdir 内容。命中则优先于 [listdirResult]。
  Map<String, List<SftpName>> listdirResults = {};

  /// 记录每次 stat 的 followLink，供「冲突探测必须用 lstat」的断言。
  final List<bool> statFollowLink = [];
  final List<String> mkdirRecursiveCalls = [];
  final List<String> uploaded = [];

  @override
  Future<List<SftpName>> listdir(String path) async {
    if (throwOnListdir) throw listdirError ?? Exception('SFTP connection refused');
    return listdirResults[path] ?? listdirResult;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    statFollowLink.add(followLink);
    if (existingRemote.contains(path)) return SftpFileAttrs(size: 1);
    throw Exception('No such file');
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

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async =>
      Uint8List(0);

  @override
  Future<void> writeBytes(String path, Uint8List data) async {}

  @override
  Future<void> upload(
    String remotePath,
    Stream<List<int>> data,
    int totalBytes,
    void Function(int)? onProgress,
  ) async {
    await data.drain<void>();
    uploaded.add(remotePath);
  }

  @override
  Future<void> remove(String path) async {}

  @override
  Future<void> rmdir(String path) async {}

  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> createFile(String path) async {}

  @override
  Future<void> setPermissions(String path, int permissions) async {}

  @override
  Future<String> absolutePath(String path) async => path;

  @override
  Future<String> readlink(String path) async => throw Exception('Not a link');

  @override
  Future<void> mkdirRecursive(String path) async {
    mkdirRecursiveCalls.add(path);
  }
}

Server _server() => const Server(
  id: 's1',
  name: 'test',
  host: '127.0.0.1',
  port: 22,
  username: 'u',
  authType: 'password',
);

/// 扫描结果直接给定，不碰真实文件系统。
///
/// ## 为什么必须注入，以及本文件测不到什么
///
/// `testWidgets` 跑在 FakeAsync 时钟下，真实的 `dart:io` 文件操作会**挂住**
/// （实测：10 秒超时；同样的操作包在 `tester.runAsync` 里就正常）。这影响两处：
/// `SftpUploadPlan.scan`（本地扫描）与 `SftpTransferTask.upload`（读本地文件）。
/// 前者用注入的 [SftpUploadPlan] 绕开；后者无法绕开 —— 所以**本文件不测
/// 「字节真的传上去了没有」**。
///
/// 覆盖面分工：
///  - 本文件：对话框出现/消失、三态结论、冲突探测用 lstat（都是纯 UI 决策）
///  - `test/sftp/sftp_service_test.dart`：skip-set 映射到实际上传调用
///  - `test/sftp/sftp_upload_plan_test.dart`：扫描语义
SftpUploadPlan _plan(List<String> rels) => SftpUploadPlan(
  files: [
    for (final r in rels)
      UploadFile(localPath: '/local/$r', relativePath: r, size: 10),
  ],
  directories: const [],
  totalBytes: rels.length * 10,
);

/// 纯内存假 store —— **绝不能接真实 sqflite**。实测（本仓库）：
/// `testWidgets` 跑在 FakeAsync 时钟下，sqflite 的异步调用永远不会完成
/// （`ok=false`），测试结束时关库还会抛 `database_closed`。
class _FakePathStore extends SftpPathStore {
  _FakePathStore({List<SftpPath> recent = const []})
      : _recent = List.of(recent),
        super(repo: null, serverId: 's1');

  final List<String> visits = [];
  List<SftpPath> _recent;
  final Set<String> pinnedPaths = {};

  @override
  Future<void> recordVisit(String path) async {
    visits.add(path);
    if (!_recent.any((e) => e.path == path)) {
      _recent = [
        SftpPath(
          serverId: 's1',
          path: path,
          lastUsedAt: DateTime(2026),
          pinned: pinnedPaths.contains(path),
        ),
        ..._recent,
      ];
    }
  }

  @override
  Future<List<SftpPath>> recent() async => _recent;

  @override
  Future<List<SftpPath>> pinned() async =>
      _recent.where((e) => pinnedPaths.contains(e.path)).toList();

  @override
  Future<void> setPinned(String path, bool pinned) async {
    if (pinned) {
      pinnedPaths.add(path);
    } else {
      pinnedPaths.remove(path);
    }
  }

  @override
  Future<void> remove(String path) async {
    _recent = _recent.where((e) => e.path != path).toList();
  }

  @override
  Future<List<String>> suggest(String prefix) async {
    final p = prefix.toLowerCase();
    return _recent
        .map((e) => e.path)
        .where((path) => path.toLowerCase().startsWith(p))
        .take(8)
        .toList();
  }
}

/// 记录 [refresh] 与 silent `listDirectory` 调用的 service，供「下拉真的
/// 触发刷新」的断言。
class _CountingService extends SFTPService {
  _CountingService(SftpOps ops) : super.testWith(() async => ops);

  int refreshCalls = 0;
  int silentListCalls = 0;

  @override
  Future<void> refresh() {
    refreshCalls++;
    return super.refresh();
  }

  @override
  Future<void> listDirectory(String path, {bool silent = false}) {
    if (silent) silentListCalls++;
    return super.listDirectory(path, silent: silent);
  }
}

Future<void> _pumpView(
  WidgetTester tester, {
  required SFTPService svc,
  required SftpUploadPlan plan,
  SftpPathStore? pathStore,
  Future<({SortKey key, bool ascending})> Function()? loadSortPrefs,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SftpInlineView(
        server: _server(),
        svc: svc,
        pathStore: pathStore,
        pickDirectory: () async => '/local',
        scanDirectory: (root, {isCancelled}) async => plan,
        loadSortPrefs: loadSortPrefs ?? SftpSortPrefs.load,
      ),
    ),
  );
  await tester.pump();
}

Future<AppLocalizations> _l10n() =>
    AppLocalizations.delegate.load(const Locale('en'));

void main() {
  // `SftpSortPrefs.load()` 在 `initState` 里读 shared_preferences —— 不 mock
  // 会抛 MissingPluginException。
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 回归：空态下点 `..` 要退出搜索并刷新 ──────────────────────────────
  //
  // 真实缺陷：空态与有内容两个分支各写了一份 `..` 的 onTap，行为悄悄分叉
  // —— 列表分支会退出搜索态，空态那份不会。用户搜出空结果后点 `..`，搜索词
  // 还在，看起来就是「点了没反应、没刷新」。

  testWidgets('空目录里点 .. 会回到上级并显示出内容', (tester) async {
    final ops = _FakeOps();
    // 按路径返回不同内容：/home/user 空，/home 有一条
    ops.listdirResults = {
      '/home/user': [],
      '/home': [
        SftpName(
          filename: 'x.txt',
          longname: 'x',
          attr: SftpFileAttrs(
            size: 1,
            mode: const SftpFileMode.value(0x8000 | 0x1A4),
          ),
        ),
      ],
    };
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();

    svc.listDirectory('/home/user');
    await tester.pumpAndSettle();
    expect(find.text('..'), findsOneWidget);

    // 进入搜索态并输入一个匹配不到任何东西的词 → 仍然是空态
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz-no-match');
    await tester.pumpAndSettle();
    expect(find.text('..'), findsOneWidget, reason: '空态里仍应给出去上级的入口');

    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();

    expect(svc.currentPath, '/home');
    // 关键：搜索态必须被退出，否则过滤词还在，新目录依然显示为空 ——
    // 用户看到的就是「点了上级没刷新」。
    expect(find.byType(TextField), findsNothing, reason: '应退出搜索态');
    expect(find.text('x.txt'), findsOneWidget, reason: '必须真的刷新出新内容');
  });

  // ── 回归：排序按钮必须能打开 sheet ────────────────────────────────────
  //
  // 真实缺陷：`_showSortSheet` 原先**先 `await SftpSortPrefs.load()` 再弹**。
  // 那个 await 期间没有任何反馈，只要它慢一点（或平台通道不可用而永不返回），
  // 用户看到的就是「点了排序没反应」。

  testWidgets('点排序按钮能打开 sheet，且四个选项齐全', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = SFTPService.testWith(() async => _FakeOps());
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    final l = await _l10n();
    expect(find.text(l.sftpSortByName), findsOneWidget);
    expect(find.text(l.sftpSortBySize), findsOneWidget);
    expect(find.text(l.sftpSortByTime), findsOneWidget);
    // 方向行写的是**动作**（当前升序 → 可切到降序），不是状态标签。
    expect(find.text(l.sftpSortToggleToDesc), findsOneWidget);
  });

  testWidgets('排序 sheet 的弹出不等偏好读取（同步开）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = SFTPService.testWith(() async => _FakeOps());
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.sort));
    // **只泵一帧**：若实现里在弹 sheet 之前先 await 偏好读取，这一帧之后
    // sheet 还没出现（也就抓得住那个回归）。
    await tester.pump();

    expect(find.byType(BottomSheet), findsOneWidget,
        reason: 'sheet 必须同步弹出，不能等偏好读取');
  });

  testWidgets('选排序维度后列表按新顺序渲染', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ops = _FakeOps();
    ops.listdirResult = [
      SftpName(filename: 'b.txt', longname: 'b',
          attr: SftpFileAttrs(size: 900, mode: const SftpFileMode.value(0x8000 | 0x1A4))),
      SftpName(filename: 'a.txt', longname: 'a',
          attr: SftpFileAttrs(size: 10, mode: const SftpFileMode.value(0x8000 | 0x1A4))),
    ];
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();

    final l = await _l10n();
    // 默认按名称：a 在 b 前
    expect(tester.getTopLeft(find.text('a.txt')).dy,
        lessThan(tester.getTopLeft(find.text('b.txt')).dy));

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.sftpSortBySize));
    await tester.pumpAndSettle();

    // 方向行默认显示「改为降序」（当前是升序）—— 点它切到降序。
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.sftpSortToggleToDesc));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('b.txt')).dy,
        lessThan(tester.getTopLeft(find.text('a.txt')).dy),
        reason: '降序后大的在前');
  });

  // ── 回归：速度拨号关闭时不得吃掉点击 ──────────────────────────────────
  //
  // 真实缺陷：`_buildMiniFabItem` 用 `Opacity(anim.value)`，关闭时 anim 为 0
  // —— **不画，但仍在命中测试树里**。4 个 mini FAB（连带标签）常驻在屏幕
  // 底部偏上，静静地吃掉落在那个区域的点击。用户看到的是「排序按钮、`..`、
  // 靠下的列表项点了没反应」，而且因为与动画值相关，表现为「有时候」。

  testWidgets('速度拨号关闭时不残留可点击的 mini FAB', (tester) async {
    final svc = SFTPService.testWith(() async => _FakeOps());
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();

    // 关闭态：mini FAB 的标签不该在树里
    expect(find.text('Upload File'), findsNothing);
    // 也不该有 Opacity(0) 的残留元素
    final zeroOpacity = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((o) => o.opacity == 0)
        .length;
    expect(zeroOpacity, 0, reason: 'Opacity(0) 仍参与命中测试');
  });

  testWidgets('速度拨号打开→关闭后，mini FAB 再次不可点', (tester) async {
    final svc = SFTPService.testWith(() async => _FakeOps());
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Upload File'), findsOneWidget, reason: '打开时应可见');

    // 再点主 FAB 收起（比点 scrim 稳 —— scrim 只覆盖 body，坐标随尺寸变）
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Upload File'), findsNothing, reason: '收起后应彻底移除');
  });

  testWidgets('速度拨号里有「上传文件夹」入口', (tester) async {
    final svc = SFTPService.testWith(() async => _FakeOps());
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.drive_folder_upload), findsOneWidget);
  });

  testWidgets('无冲突时不弹确认对话框', (tester) async {
    final ops = _FakeOps();
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(['a.txt']));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.drive_folder_upload));
    await tester.pumpAndSettle();

    final l = await _l10n();
    expect(find.text(l.sftpConflictBody), findsNothing,
        reason: '没有冲突就不该打扰用户');
  });

  testWidgets('有冲突时弹一次确认，标题含冲突数，三个动作都在', (tester) async {
    final ops = _FakeOps(existingRemote: {'/a.txt'});
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(['a.txt', 'b.txt']));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.drive_folder_upload));
    await tester.pumpAndSettle();

    final l = await _l10n();
    expect(find.text(l.sftpConflictTitle(1)), findsOneWidget);
    expect(find.text(l.sftpConflictOverwriteAll), findsOneWidget);
    expect(find.text(l.sftpConflictSkipAll), findsOneWidget);
    expect(find.text(l.cancel), findsOneWidget);
  });

  testWidgets('点「跳过已存在」后对话框关闭', (tester) async {
    final ops = _FakeOps(existingRemote: {'/a.txt'});
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(['a.txt']));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.drive_folder_upload));
    await tester.pumpAndSettle();

    final l = await _l10n();
    await tester.tap(find.text(l.sftpConflictSkipAll));
    await tester.pumpAndSettle();

    expect(find.text(l.sftpConflictBody), findsNothing);
  });

  testWidgets('点「取消」后对话框关闭', (tester) async {
    final ops = _FakeOps(existingRemote: {'/a.txt'});
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(['a.txt']));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.drive_folder_upload));
    await tester.pumpAndSettle();

    final l = await _l10n();
    await tester.tap(find.text(l.cancel));
    await tester.pumpAndSettle();

    expect(find.text(l.sftpConflictBody), findsNothing);
  });

  testWidgets('冲突探测用 lstat（不跟随软链）', (tester) async {
    final ops = _FakeOps(existingRemote: {'/a.txt'});
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(['a.txt']));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.drive_folder_upload));
    await tester.pumpAndSettle();

    expect(ops.statFollowLink, isNotEmpty);
    expect(ops.statFollowLink.every((f) => f == false), isTrue,
        reason: '跟随软链会把「链接存在」误判成「文件存在」');
  });

  testWidgets('列表外包了 RefreshIndicator，且空目录也能下拉（可滚动）', (tester) async {
    // 空目录：走的是空态分支，原实现是 Column（不可滚）会让下拉失效。
    // 断言 RefreshIndicator 下确实挂着一个垂直可滚的 ListView。
    final ops = _FakeOps();
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(const []));

    final l = await _l10n();
    expect(find.text(l.sftpEmptyDirectory), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);

    // 必须限制在 RefreshIndicator 的子树里 —— 页面别处（选择模式工具栏）
    // 也有横向 ListView，光 `find.byType(ListView)` 会误命中。
    final scrollable = find.descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byWidgetPredicate(
        (w) =>
            w is ListView &&
            w.scrollDirection == Axis.vertical,
      ),
    );
    expect(scrollable, findsOneWidget,
        reason: '空态必须是一个垂直可滚的 ListView，否则下拉刷新手势失效');
  });

  testWidgets('下拉刷新真的触发了 svc.refresh（且 silent，全程不进入 loading）',
      (tester) async {
    final ops = _FakeOps();
    final svc = _CountingService(ops);
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    expect(svc.isLoading, isFalse);
    final before = svc.refreshCalls;

    // 模拟一次下拉：fling 垂直列表向下，触发 RefreshIndicator。
    final list = find.descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(ListView),
    );
    await tester.fling(list.first, const Offset(0, 300), 1000);
    // 让 onRefresh 的 Future 完成、指示器收起。
    await tester.pumpAndSettle();

    expect(svc.refreshCalls, before + 1,
        reason: '下拉必须真的走到 svc.refresh，否则指示器只是个摆设');
    // 刷新走 silent 路径 —— 全程不该出现 loading 转圈。
    expect(svc.isLoading, isFalse);
    expect(svc.silentListCalls, greaterThan(0));
  });

  testWidgets('空目录态里的「..」仍可点（可滚动改造后不丢交互）', (tester) async {
    final ops = _FakeOps();
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    // 先进入一个非根目录，让「..」出现。
    await svc.listDirectory('/home/user');
    await tester.pumpAndSettle();

    expect(find.text('..'), findsOneWidget);
    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();

    expect(svc.currentPath, '/home',
        reason: '「..」应返回上级目录，可滚动改造后不能被破坏');
  });

  testWidgets('错误态里的重连按钮仍可点（可滚动改造后不丢交互）', (tester) async {
    final ops = _FakeOps()..throwOnListdir = true;
    final svc = SFTPService.testWith(() async => ops);
    var reconnects = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SftpInlineView(
          server: _server(),
          svc: svc,
          pickDirectory: () async => '/local',
          scanDirectory: (root, {isCancelled}) async => _plan(const []),
          onReconnectRequested: () => reconnects++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = await _l10n();
    expect(find.text(l.reconnect), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
    await tester.tap(find.text(l.reconnect));
    await tester.pumpAndSettle();
    expect(reconnects, 1);
  });

  // ── 回归：慢速偏好读取不得覆盖用户刚做出的排序选择 ────────────────────
  //
  // 真实缺陷：`initState` 里 `_loadSortPrefs()` 是**不 await** 发出去的。
  // `SharedPreferences.getInstance()` 在真机上是平台通道往返（几十到几百
  // 毫秒），而 SFTP 视图正是在切到该 tab 时挂载的（同时还并发 listDirectory）。
  // 这段窗口里用户完全可能已经点开排序面板选了一项 —— 慢读取回来时无条件
  // `_sort = prefs` 会把用户的选择覆盖回旧值，界面看起来就是「点了没反应」。
  //
  // widget 测试里 mock 的 prefs 几乎同步返回，所以必须**人为拖慢**才抓得到。

  testWidgets('慢读取回来时不覆盖用户已选的排序', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final completer = Completer<({SortKey key, bool ascending})>();
    final ops = _FakeOps();
    ops.listdirResult = [
      SftpName(
        filename: 'b.txt',
        longname: 'b',
        attr: SftpFileAttrs(
          size: 900,
          mode: const SftpFileMode.value(0x8000 | 0x1A4),
        ),
      ),
      SftpName(
        filename: 'a.txt',
        longname: 'a',
        attr: SftpFileAttrs(
          size: 10,
          mode: const SftpFileMode.value(0x8000 | 0x1A4),
        ),
      ),
    ];
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(
      tester,
      svc: svc,
      plan: _plan(const []),
      // 偏好读取挂起 —— 模拟真机上的慢平台通道
      loadSortPrefs: () => completer.future,
    );
    await tester.pump();

    // 用户在读取返回之前就选了「按大小」，再切降序 —— 与磁盘值（名称升序）
    // 产生**可观察的差异**（名称升序也会让 a 在前，看不出覆盖）。
    final l = await _l10n();
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.sftpSortBySize));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.sftpSortToggleToDesc));
    await tester.pumpAndSettle();

    // 现在慢读取才返回磁盘旧值（名称升序）
    completer.complete((key: SortKey.name, ascending: true));
    await tester.pumpAndSettle();

    // 用户选的「按大小降序」必须仍然生效：b=900 在上
    final aY = tester.getTopLeft(find.text('a.txt')).dy;
    final bY = tester.getTopLeft(find.text('b.txt')).dy;
    expect(bY, lessThan(aY),
        reason: '慢读取回来把用户的选择覆盖了（这就是「点了没反应」）');
  });

  testWidgets('用户未操作时，磁盘偏好正常应用', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final completer = Completer<({SortKey key, bool ascending})>();
    final svc = SFTPService.testWith(() async => _FakeOps());
    await _pumpView(
      tester,
      svc: svc,
      plan: _plan(const []),
      loadSortPrefs: () => completer.future,
    );
    await tester.pump();

    completer.complete((key: SortKey.time, ascending: false));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    final l = await _l10n();
    // 方向行显示「改为升序」→ 当前是降序，说明磁盘偏好被应用了
    expect(find.text(l.sftpSortToggleToAsc), findsOneWidget);
  });

  // ── 回归：主错误分支必须走分类器 ─────────────────────────────
  testWidgets('断线时显示分类后的人话文案，不是裸异常 message', (tester) async {
    final ops = _FakeOps()
      ..throwOnListdir = true
      // 只有能归类成 disconnected 的异常才走得出分类器；裸 Exception 会被
      // 归为 unknown，恰好退化成显示原文，就测不出「是否走了分类器」。
      ..listdirError = const SftpDisconnectedException(
        'SSH connection lost: channel closed unexpectedly (code 7)',
      );
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();
    await svc.listDirectory('/');
    await tester.pumpAndSettle();

    final l = await _l10n();
    // 分类器文案应出现（旧代码显示的是 SftpDisconnectedException 的裸 message）。
    expect(find.textContaining(l.sftpErrDisconnected), findsOneWidget);
    // 原文仍在详情里，不是被分类吞掉。
    expect(find.textContaining('channel closed unexpectedly'), findsOneWidget);
  });

  testWidgets('主错误分支对非断线异常也走分类器（权限被拒）', (tester) async {
    // 第二个用例打「分类器接入」的另一半：非断线失败也得给可行动的文案，
    // 而不是 dartssh2 的 SSH_FX_PERMISSION_DENIED 原文。
    final ops = _FakeOps()
      ..throwOnListdir = true
      ..listdirError = SftpStatusError(
        SftpStatusCode.permissionDenied,
        'Permission denied',
      );
    final svc = SFTPService.testWith(() async => ops);
    await _pumpView(tester, svc: svc, plan: _plan(const []));
    await tester.pumpAndSettle();
    await svc.listDirectory('/');
    await tester.pumpAndSettle();

    final l = await _l10n();
    expect(find.textContaining(l.sftpErrPermissionDenied), findsOneWidget);
  });

  // ── 排序 ────────────────────────────────────────────────────────────────

  group('排序 UI', () {
    /// 三个普通文件，名称序 = 大小序 = 时间序，**三者各不相同** —— 这样
    /// 只要列表顺序变了就能断定是哪个维度在起作用。
    ///
    /// 名称：a-small < b-medium < c-large
    /// 大小：a(small) < b(medium) < c(large)（即名称升序 = 大小升序）
    /// 时间：mtime 递增，同样与名称同序。
    /// 为了让「按时间」与「按名称」可区分，时间故意反过来：c 最旧。
    List<SftpName> threeFiles() => [
      SftpName(
        filename: 'a-small.txt',
        longname: '-rw-r--r-- 1 u g 100 Jan 1 00:00 a-small.txt',
        attr: SftpFileAttrs(
          size: 100,
          modifyTime: 3000,
          mode: const SftpFileMode.value(0x8000 | 0x1A4),
        ),
      ),
      SftpName(
        filename: 'b-medium.txt',
        longname: '-rw-r--r-- 1 u g 200 Jan 1 00:00 b-medium.txt',
        attr: SftpFileAttrs(
          size: 200,
          modifyTime: 2000,
          mode: const SftpFileMode.value(0x8000 | 0x1A4),
        ),
      ),
      SftpName(
        filename: 'c-large.txt',
        longname: '-rw-r--r-- 1 u g 300 Jan 1 00:00 c-large.txt',
        attr: SftpFileAttrs(
          size: 300,
          modifyTime: 1000,
          mode: const SftpFileMode.value(0x8000 | 0x1A4),
        ),
      ),
    ];

    /// 从列表里按垂直位置取文件名的顺序 —— 直接读 `ListTile.title` 文本。
    List<String> visibleNames(WidgetTester tester) {
      final tiles = find.descendant(
        of: find.byType(RefreshIndicator),
        matching: find.byType(ListTile),
      );
      final names = <String>[];
      for (final w in tester.widgetList<ListTile>(tiles)) {
        final t = w.title;
        if (t is Text && t.data != null) names.add(t.data!);
      }
      return names;
    }

    testWidgets('AppBar 上有排序按钮', (tester) async {
      final ops = _FakeOps()..listdirResult = threeFiles();
      final svc = SFTPService.testWith(() async => ops);
      await _pumpView(tester, svc: svc, plan: _plan(const []));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.sort), findsOneWidget);
    });

    testWidgets('点排序按钮弹出 bottom sheet，默认高亮名称 + 升序', (tester) async {
      final ops = _FakeOps()..listdirResult = threeFiles();
      final svc = SFTPService.testWith(() async => ops);
      await _pumpView(tester, svc: svc, plan: _plan(const []));
      await tester.pumpAndSettle();

      final l = await _l10n();
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();

      // 三个维度 + 方向切换都在。
      expect(find.text(l.sftpSortByName), findsOneWidget);
      expect(find.text(l.sftpSortBySize), findsOneWidget);
      expect(find.text(l.sftpSortByTime), findsOneWidget);
      expect(find.text(l.sftpSortToggleToDesc), findsOneWidget);

      // 默认名称升序 —— 两个 radio 选中态。
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('选「按大小」后列表按大小重排（方向沿用当前）', (tester) async {
      final ops = _FakeOps()..listdirResult = threeFiles();
      final svc = SFTPService.testWith(() async => ops);
      await _pumpView(tester, svc: svc, plan: _plan(const []));
      await tester.pumpAndSettle();

      expect(visibleNames(tester),
          ['a-small.txt', 'b-medium.txt', 'c-large.txt']);

      final l = await _l10n();
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.sftpSortBySize));
      await tester.pumpAndSettle();

      // 名称序与大小序在本数据下恰好一致 —— 真正断言的是「切换维度走了
      // 排序路径」，用大小降序来验证重排是真的发生了。
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.sftpSortToggleToDesc));
      await tester.pumpAndSettle();

      expect(visibleNames(tester),
          ['c-large.txt', 'b-medium.txt', 'a-small.txt'],
          reason: '按大小降序应按 size 反排');
    });

    testWidgets('切换升降序立即重排（不打开 sheet 时也生效）', (tester) async {
      final ops = _FakeOps()..listdirResult = threeFiles();
      final svc = SFTPService.testWith(() async => ops);
      await _pumpView(tester, svc: svc, plan: _plan(const []));
      await tester.pumpAndSettle();

      final l = await _l10n();
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.sftpSortToggleToDesc));
      await tester.pumpAndSettle();

      expect(visibleNames(tester),
          ['c-large.txt', 'b-medium.txt', 'a-small.txt'],
          reason: '降序后列表应反过来');
    });

    testWidgets('排序偏好被持久化（下次 initState 读回）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'sftp_sort_key': 'size',
        'sftp_sort_ascending': false,
      });
      final ops = _FakeOps()..listdirResult = threeFiles();
      final svc = SFTPService.testWith(() async => ops);
      await _pumpView(tester, svc: svc, plan: _plan(const []));
      await tester.pumpAndSettle();

      expect(visibleNames(tester), ['c-large.txt', 'b-medium.txt', 'a-small.txt'],
          reason: 'initState 读回的偏好应直接决定初始顺序');
    });

    testWidgets('搜索过滤结果也按当前排序维度排列', (tester) async {
      final ops = _FakeOps()
        ..listdirResult = [
          ...threeFiles(),
          SftpName(
            filename: 'a-huge.txt',
            longname: '-rw-r--r-- 1 u g 900 Jan 1 00:00 a-huge.txt',
            attr: SftpFileAttrs(
              size: 900,
              modifyTime: 500,
              mode: const SftpFileMode.value(0x8000 | 0x1A4),
            ),
          ),
        ];
      final svc = SFTPService.testWith(() async => ops);
      await _pumpView(tester, svc: svc, plan: _plan(const []));
      await tester.pumpAndSettle();

      // 切到按大小降序。
      final l = await _l10n();
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.sftpSortBySize));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.sftpSortToggleToDesc));
      await tester.pumpAndSettle();

      // 进入搜索态，过滤出含有 “a-” 的文件（a-huge 与 a-small）。
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'a-');
      await tester.pumpAndSettle();

      expect(visibleNames(tester), ['a-huge.txt', 'a-small.txt'],
          reason: '搜索态不能退回默认顺序 —— 用户刚设的排序应当继续生效');
    });
  });

  // ── 路径历史 / 书签 ────────────────────────────────────────────────────

  group('路径历史 / 书签', () {
    testWidgets('进入目录成功后记一次访问，同一路径不重复记', (tester) async {
      final ops = _FakeOps();
      final svc = SFTPService.testWith(() async => ops);
      final store = _FakePathStore();
      await _pumpView(tester, svc: svc, plan: _plan(const []), pathStore: store);
      await tester.pumpAndSettle();

      // initState 的首次 listDirectory('/') 成功 → 记一条。
      expect(store.visits, contains('/'));
      final before = store.visits.length;

      await svc.listDirectory('/home/user');
      await tester.pumpAndSettle();
      expect(store.visits.last, '/home/user');

      // 同一路径再列一次（refresh）—— 不应新增记录。
      await svc.listDirectory('/home/user');
      await tester.pumpAndSettle();
      expect(store.visits.length, before + 1,
          reason: '路径没变不该重复写库');
    });

    testWidgets('listDirectory 失败不记访问', (tester) async {
      final ops = _FakeOps()..throwOnListdir = true;
      final svc = SFTPService.testWith(() async => ops);
      final store = _FakePathStore();
      await _pumpView(tester, svc: svc, plan: _plan(const []), pathStore: store);
      await tester.pumpAndSettle();

      expect(store.visits, isEmpty, reason: '列目录失败没有可记的路径');
    });

    testWidgets('跳转对话框列出最近路径，点击即跳过去', (tester) async {
      final ops = _FakeOps();
      final svc = SFTPService.testWith(() async => ops);
      final store = _FakePathStore(
        recent: [
          SftpPath(
            serverId: 's1',
            path: '/etc/nginx',
            lastUsedAt: DateTime(2026),
            pinned: false,
          ),
        ],
      );
      await _pumpView(tester, svc: svc, plan: _plan(const []), pathStore: store);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      // 标题 + 历史条目都在；输入框预填当前路径。
      final l = await _l10n();
      expect(find.text(l.sftpJumpToPath), findsOneWidget);
      expect(find.text('/etc/nginx'), findsOneWidget);

      await tester.tap(find.text('/etc/nginx'));
      await tester.pumpAndSettle();

      expect(svc.currentPath, '/etc/nginx');
      expect(find.text(l.sftpJumpToPath), findsNothing, reason: '选中后应关闭');
    });

    testWidgets('输入前缀时出现补全建议区', (tester) async {
      final ops = _FakeOps();
      final svc = SFTPService.testWith(() async => ops);
      final store = _FakePathStore(
        recent: [
          SftpPath(
            serverId: 's1',
            path: '/var/log',
            lastUsedAt: DateTime(2026),
            pinned: false,
          ),
          SftpPath(
            serverId: 's1',
            path: '/etc/nginx',
            lastUsedAt: DateTime(2026),
            pinned: false,
          ),
        ],
      );
      await _pumpView(tester, svc: svc, plan: _plan(const []), pathStore: store);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      // 未输入时不显示建议区（下面「最近」列表已是同一批内容）。
      final l = await _l10n();
      expect(find.text(l.sftpPathSuggestions), findsNothing);

      await tester.enterText(find.byType(TextField), '/var');
      await tester.pumpAndSettle();

      // 输入后出现建议区，且建议只含匹配前缀的条目。
      expect(find.text(l.sftpPathSuggestions), findsOneWidget);
      final suggestionList = find.byIcon(Icons.history);
      expect(suggestionList, findsOneWidget,
          reason: '只有 /var/log 匹配 /var，/etc/nginx 不是建议');
    });
  });

  // ── 网络/前台事件驱动的 SFTP 恢复 ──────────────────────────────────────
  //
  // 两条路径的分工是刻意的：
  //  - 切网 → TCP 已失效，直接重建，不必浪费一次探活往返；
  //  - 回前台 → 只探活，探通就不动。无差别重建会让「切出去看一眼通知
  //    再回来」也触发一次重连，列表闪一下。
  // 两者都走既有的 onAutoReconnectRequested，因此仍受 TerminalScreen 的
  // 30 秒限流保护。
  // ── 回归：浏览中断线必须能自愈 ──────────────────────────────────────
  //
  // 真实缺陷：`_maybeAutoReconnect` 的守卫写的是
  //   `if (!_svc.isDisconnected || _svc.entries.isNotEmpty) return;`
  // 第二个条件把**最常见的那个场景**排除掉了 —— 用户正浏览着一个目录
  // （entries 非空）时连接断掉，`listDirectory` 的 catch 只记错误、不清空
  // entries，于是 entries 一直非空，自动重连**永远不触发**。真机表现就是
  // 「断了之后不会自己恢复，必须手动点重连」。
  //
  // 它只在「列表为空 + 断线」时才工作，而那恰恰是最罕见的情形。
  testWidgets('浏览中断线也要自动重连 —— 列表非空不该挡住自愈', (tester) async {
    var reconnects = 0;
    final ops = _FakeOps();
    ops.listdirResult = [
      SftpName(
        filename: 'a.txt',
        longname: 'a',
        attr: SftpFileAttrs(
          size: 10,
          mode: const SftpFileMode.value(0x8000 | 0x1A4),
        ),
      ),
    ];
    final svc = SFTPService.testWith(() async => ops);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SftpInlineView(
        server: _server(),
        svc: svc,
        onAutoReconnectRequested: () => reconnects++,
      ),
    ));
    await tester.pumpAndSettle();
    // 前提：列表确实有内容 —— 否则测的就是旧守卫也放行的那条路径了。
    expect(find.text('a.txt'), findsOneWidget);

    // 连接断开：下一次操作以 disconnected 失败。entries 保持旧值不变。
    ops.throwOnListdir = true;
    ops.listdirError = const SftpDisconnectedException('SSH 连接已断开');
    await svc.refresh();
    await tester.pumpAndSettle();

    expect(svc.entries, isNotEmpty, reason: '断线不清空列表，这正是守卫踩的坑');
    expect(reconnects, 1,
        reason: '列表非空时断线，自动重连被 entries.isNotEmpty 挡掉了 '
            '—— 真机上表现为「断了不会自己恢复」');
  });

  group('网络/前台事件驱动的 SFTP 恢复', () {
    testWidgets('回前台时连接还活着 → 不触发重连', (tester) async {
      var reconnects = 0;
      // stat('/') 成功 = 探活通过（自有连接路径用一次真实往返判活）。
      final ops = _FakeOps(existingRemote: {'/'});
      final svc = SFTPService.testWith(() async => ops);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SftpInlineView(
          server: _server(),
          svc: svc,
          onAutoReconnectRequested: () => reconnects++,
        ),
      ));
      await tester.pumpAndSettle();
      final st = tester.state(find.byType(SftpInlineView)) as dynamic;
      await st.onForegroundResumed();
      await tester.pumpAndSettle();
      expect(reconnects, 0, reason: '活着的连接不该被无谓重建');
    });

    testWidgets('回前台时连接已死 → 触发一次重连', (tester) async {
      var reconnects = 0;
      var fail = false;
      // 用 aliveProbe（复用连接路径）来模拟「探活失败」：自有连接会复用已有
      // ops，拿旧 ops 做往返永远成功，模拟不出一条死连接。真实 QUIC 场景
      // 下这条辅助 SSH 正是复用连接，所以这才是该测的路径。
      final svc = SFTPService.testWith(
        () async => _FakeOps(existingRemote: {'/'}),
        aliveProbe: () async {
          if (fail) throw Exception('channel setup failed');
        },
      );
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SftpInlineView(
          server: _server(),
          svc: svc,
          onAutoReconnectRequested: () => reconnects++,
        ),
      ));
      await tester.pumpAndSettle();
      fail = true;
      final st = tester.state(find.byType(SftpInlineView)) as dynamic;
      await st.onForegroundResumed();
      await tester.pumpAndSettle();
      expect(reconnects, 1);
    });

    testWidgets('网络类型变化 → 直接重连（不先探活）', (tester) async {
      var reconnects = 0;
      // 这个 ops 的 stat 会抛（探活必然失败）—— 若 onNetworkChanged 真的去
      // 探活，就会因为失败而重连；若它直接重连，也会重连一次。两者结果相同，
      // 因此另用「探活计数」判据在下面的用例里区分。
      final svc = SFTPService.testWith(() async => _FakeOps(existingRemote: {'/'}));
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SftpInlineView(
          server: _server(),
          svc: svc,
          onAutoReconnectRequested: () => reconnects++,
        ),
      ));
      await tester.pumpAndSettle();
      final st = tester.state(find.byType(SftpInlineView)) as dynamic;
      st.onNetworkChanged();
      await tester.pumpAndSettle();
      expect(reconnects, 1, reason: '切网时 TCP 已失效，不必探活');
    });

    testWidgets('网络类型变化不探活（切网直接重建）', (tester) async {
      var reconnectCalls = 0;
      // 探活会被记录：用 aliveProbe 记一次。若 onNetworkChanged 走了探活，
      // 这里就能看到 >0。
      var probes = 0;
      final svc = SFTPService.testWith(
        () async => _FakeOps(existingRemote: {'/'}),
        aliveProbe: () async {
          probes++;
        },
      );
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SftpInlineView(
          server: _server(),
          svc: svc,
          onAutoReconnectRequested: () => reconnectCalls++,
        ),
      ));
      await tester.pumpAndSettle();
      // 首屏 listDirectory 返回空目录会触发 _probeAliveOnEmpty 自愈探活，
      // 那不是本用例要测的驱动路径 —— 从此刻起重新计数。
      probes = 0;
      final st = tester.state(find.byType(SftpInlineView)) as dynamic;
      st.onNetworkChanged();
      await tester.pumpAndSettle();
      expect(reconnectCalls, 1);
      expect(probes, 0, reason: '切网直接重建，不做探活往返');
    });
  });
}
