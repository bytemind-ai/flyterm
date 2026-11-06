import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/ssh_connection.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:uuid/uuid.dart';

Server _makeServer() => Server(
      id: const Uuid().v4(),
      name: 'Test',
      host: 'host',
      port: 22,
      username: 'user',
      authType: 'password',
    );

void main() {
  test('SSHConnection initial state is disconnected', () {
    final conn = SSHConnection();
    expect(conn.isConnected, isFalse);
  });

  group('SessionManager', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('starts with no tabs', () {
      final mgr = SessionManager(prefs: prefs);
      expect(mgr.tabs, isEmpty);
      expect(mgr.activeTab, isNull);
    });

    test('addTab increases tab count', () {
      final mgr = SessionManager(prefs: prefs);
      mgr.addTab(_makeServer());
      expect(mgr.tabs.length, 1);
      expect(mgr.activeIndex, 0);
    });

    test('closeTab removes tab and adjusts activeIndex', () {
      final mgr = SessionManager(prefs: prefs);
      mgr.addTab(_makeServer());
      mgr.addTab(_makeServer());
      mgr.setActiveTab(1);
      mgr.closeTab(1);
      expect(mgr.tabs.length, 1);
      expect(mgr.activeIndex, 0);
    });

    test('setActiveTab updates activeIndex', () {
      final mgr = SessionManager(prefs: prefs);
      mgr.addTab(_makeServer());
      mgr.addTab(_makeServer());
      mgr.setActiveTab(1);
      expect(mgr.activeIndex, 1);
    });

    test('new SessionTab starts with isFirstConnection=true, inTmux=false', () {
      final mgr = SessionManager(prefs: prefs);
      final tab = mgr.addTab(_makeServer());
      expect(tab.isFirstConnection, isTrue);
      expect(tab.inTmux, isFalse);
    });

    test('tab title is server name regardless of inTmux', () {
      final mgr = SessionManager(prefs: prefs);
      final tab = mgr.addTab(_makeServer());
      // inTmux is now derived from backend.isActive (no setter).
      // Verify that title equals server name when inTmux=false (NoneBackend default).
      expect(tab.inTmux, isFalse);
      expect(tab.title, 'Test');
    });

    test('SessionTab has AIEngine with matching serverId', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = SessionManager(prefs: prefs);
      final server = Server(
        id: 'srv-x', name: 'X', host: 'h', port: 22,
        username: 'u', authType: 'password',
      );
      final tab = mgr.addTab(server);
      expect(tab.aiEngine, isNotNull);
      expect(tab.aiEngine.serverId, 'srv-x');
      mgr.dispose();
    });

    test('closeTab removes tab and disposes engine', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = SessionManager(prefs: prefs);
      final server = Server(
        id: 'srv-1', name: 'S1', host: 'h', port: 22,
        username: 'u', authType: 'password',
      );
      mgr.addTab(server);
      mgr.addTab(server);
      expect(mgr.tabs.length, 2);
      mgr.closeTab(0);
      expect(mgr.tabs.length, 1);
      mgr.dispose();
    });

    test('dispose clears all tabs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = SessionManager(prefs: prefs);
      final server = Server(
        id: 'srv-2', name: 'S2', host: 'h', port: 22,
        username: 'u', authType: 'password',
      );
      mgr.addTab(server);
      mgr.addTab(server);
      mgr.dispose(); // must not throw
    });

    group('SessionTab.contextLinesFrom', () {
      test('returns empty list when from >= current line count', () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final mgr = SessionManager(prefs: prefs);
        final tab = mgr.addTab(_makeServer());
        tab.appendOutput('line1\nline2\n');
        final count = tab.contextLineCount;
        expect(tab.contextLinesFrom(count), isEmpty);
        mgr.dispose();
      });

      test('returns only lines appended after the recorded index', () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final mgr = SessionManager(prefs: prefs);
        final tab = mgr.addTab(_makeServer());
        tab.appendOutput('before\n');
        final snap = tab.contextLineCount;
        tab.appendOutput('after1\nafter2\n');
        final captured = tab.contextLinesFrom(snap);
        expect(captured, isNotEmpty);
        expect(captured.any((l) => l.contains('after1')), isTrue);
        expect(captured.any((l) => l.contains('before')), isFalse);
        mgr.dispose();
      });

      test('contextLineCount increases after appendOutput', () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final mgr = SessionManager(prefs: prefs);
        final tab = mgr.addTab(_makeServer());
        final before = tab.contextLineCount;
        tab.appendOutput('new line\n');
        expect(tab.contextLineCount, greaterThan(before));
        mgr.dispose();
      });
    });
  });

  // 落屏调度：vsync 批处理 + 超大 burst 同步旁路。
  //
  // 这两条用例原先测的是「microtask 先落一批 + 8KB 同步旁路」，而
  // _scheduleOutputFlush 早已改成 vsync-only（它自己的注释写了原因：microtask
  // 会让 TUI 一次重绘的前 1–2 个 chunk 抢先落屏，产生水波纹 / 分块渲染），
  // 旁路阈值也提到了 32 KB。它们表面上是「binding 未初始化」报错 —— 实现改用
  // SchedulerBinding 之后纯 test() 里取不到 instance —— 但根因是断言的那条路径
  // 已经不存在了。改用 testWidgets 拿一个能 pump 的 binding，断言换成当前语义。
  group('SessionTab output flush optimizations', () {
    testWidgets('single packet waits for vsync instead of a microtask',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = SessionManager(prefs: prefs);
      mgr.addTab(_makeServer());
      final tab = mgr.tabs.first;

      tab.testWriteAndFlush('hello');
      expect(tab.testPendingOutputEmpty, isFalse);
      // 让出一次 microtask —— 旧实现在这里就落屏了，现在必须仍在缓冲里。
      await Future.value();
      expect(tab.testPendingOutputEmpty, isFalse,
          reason: '单包不该靠 microtask 抢先落屏，那正是水波纹的来源');

      await tester.pump();
      expect(tab.testPendingOutputEmpty, isTrue,
          reason: '一帧之后应当落屏');
    });

    testWidgets('oversized burst bypasses vsync and flushes synchronously',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mgr = SessionManager(prefs: prefs);
      mgr.addTab(_makeServer());
      final tab = mgr.tabs.first;

      // 32 KB 是 _scheduleOutputFlush 里的旁路阈值；9 KB（旧阈值）现在只会
      // 排一帧，所以这里必须给足。
      tab.testWriteAndFlush('x' * 40000);
      expect(tab.testPendingOutputEmpty, isTrue,
          reason: '>32KB 且尚未排帧时同步落屏，避免滚动大输出时积压');
    });
  });
}
