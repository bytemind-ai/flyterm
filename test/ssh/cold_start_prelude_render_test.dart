// Device-free reproduction/falsification harness for the "冷启动空白" bug.
//
// Prior investigation (see task history) ruled out: server not sending
// replay bytes, preludeSwallowRemaining eating live bytes, late listener
// attachment, wrong clear-screen ordering, and infinite RESUME hang. The
// one remaining unknown is whether the post-clear prelude bytes actually
// reach `tab.terminal` through `SessionTab.startStreaming()` →
// `_pendingRawBytes` → `_flushOutput()` → xterm.
//
// `tab.transport` is statically typed `RemoteTransport?` (confirmed by
// reading session_manager.dart — see `RemoteTransport? transport;`), so a
// fake `RemoteTransport` can be substituted without touching AqtTransport
// internals (which are intentionally NOT mocked here — this test manually
// arms the tab fields that the cold-RESUME branch would have set, then lets
// the real `startStreaming()` pipeline run unmodified).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ssh/transport/remote_transport.dart';

const _marker = 'ALT-SCREEN-MARKER';

Server _makeServer() => Server(
      id: const Uuid().v4(),
      name: 'Test',
      host: 'host',
      port: 22,
      username: 'user',
      authType: 'password',
    );

Future<SessionManager> _newManager() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return SessionManager(prefs: prefs);
}

/// Byte-for-byte copy of `TerminalScreen._readTerminalText` (private, so it
/// can't be imported directly) — reads exactly what xterm has rendered into
/// cells, the same view the user sees on screen.
String readTerminalText(Terminal terminal, {int maxLines = 200}) {
  final buffer = terminal.buffer;
  final totalLines = buffer.lines.length;
  if (totalLines == 0) return '';
  final startLine = (totalLines - maxLines).clamp(0, totalLines);
  final range = BufferRangeLine(
    CellOffset(0, startLine),
    CellOffset(
      terminal.viewWidth > 0 ? terminal.viewWidth - 1 : 79,
      totalLines - 1,
    ),
  );
  return buffer.getText(range).trimRight();
}

/// Builds a byte string shaped like the real cold+alt RESUME prelude
/// (211 bytes observed against a real daemon+PTY): pre-alt history +
/// eviction line + `\x1b[?1049h` (enter alt, clears screen) + SGR reset +
/// a "live snapshot" line carrying [_marker], optionally terminated by the
/// server's trailing CAN (0x18) byte (connection.rs:174).
List<int> _buildPrelude({bool withCan = true}) {
  final s = StringBuffer()
    ..write('pre-alt-history-line-1\r\n')
    ..write('pre-alt-history-line-2\r\n')
    ..write('[evicted 128 lines]\r\n')
    ..write('\x1b[?1049h') // enter alt screen buffer
    ..write('\x1b[2J\x1b[H') // clear + home
    ..write('\x1b[0m') // SGR reset
    ..write(_marker)
    ..write('\r\n');
  final bytes = utf8.encode(s.toString()).toList();
  if (withCan) bytes.add(0x18); // trailing CAN, as the real server appends
  return bytes;
}

List<List<int>> _splitIntoChunks(List<int> bytes, {int chunkSize = 7}) {
  final chunks = <List<int>>[];
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
    chunks.add(bytes.sublist(i, end));
  }
  return chunks;
}

/// Minimal fake `RemoteTransport` — only `output`/`stderr` are exercised by
/// `SessionTab.startStreaming()`; everything else is inert. Deliberately NOT
/// an `AqtTransport` subclass/mock: the task under test is the
/// listener → buffering → xterm pipeline, not AqtTransport's own bookkeeping.
class _FakeTransport implements RemoteTransport {
  final StreamController<Uint8List> _outputCtrl = StreamController<Uint8List>();
  final StreamController<Uint8List> _stderrCtrl = StreamController<Uint8List>();

  void emit(List<int> bytes) {
    if (bytes.isEmpty) return;
    _outputCtrl.add(Uint8List.fromList(bytes));
  }

  @override
  TransportKind get kind => TransportKind.aqt;
  @override
  Set<TransportCapability> get capabilities => const {};
  @override
  TransportState get currentState => TransportState.connected;
  @override
  Stream<TransportState> get stateStream => Stream<TransportState>.empty();
  @override
  TransportMetrics get metrics => TransportMetrics.empty;
  @override
  Stream<Uint8List> get output => _outputCtrl.stream;
  @override
  Stream<Uint8List> get stderr => _stderrCtrl.stream;
  @override
  Future<void> get done => Future<void>.value();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  Future<void> close() async {
    await _outputCtrl.close();
    await _stderrCtrl.close();
  }
  @override
  void setForeground(bool active) {}
  @override
  void heartbeat() {}
  @override
  void roam() {}
  @override
  Future<bool> softReconnect() async => false;
  @override
  void suppressLocalEcho() {}
  @override
  void suppressNextLocalEcho() {}
  @override
  Future<FileTransferHandle> upload(File local, String remotePath) =>
      throw UnimplementedError('not exercised by this test');
  @override
  Future<FileTransferHandle> download(String remotePath, File local) =>
      throw UnimplementedError('not exercised by this test');
  @override
  Future<void> requestScrollbackReplay(int fromOffset) async {}
}

void main() {
  group('cold-start prelude render pipeline', () {
    testWidgets(
        '1. baseline — no clear, direct prelude feed renders the marker',
        (tester) async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final fake = _FakeTransport();
      tab.transport = fake;
      tab.startStreaming();

      fake.emit(_buildPrelude(withCan: true));
      await tester.pump();
      await tester.pump();

      final text = readTerminalText(tab.terminal);
      expect(text.contains(_marker), isTrue,
          reason:
              'sanity check: the listener → _flushOutput → xterm pipeline '
              'must work at all when nothing precedes it');
      mgr.dispose();
    });

    // 2. （已删除）"cold start simulation — clear + armed prelude counters
    // still render the marker"。
    //
    // 这条测的是：手工把 tab 摆进"冷 RESUME 分支清屏 + 装好 replay/capture
    // 计数器"之后的状态，验证 startStreaming() 仍能把 prelude 字节送进
    // xterm。它依赖的 `tab.serverRingOff` 字段已删除，但这不是简单的改名——
    // 它测的那条时序本身不再存在：新模型下 RESUME 拿到的历史（`AqtRestored
    // .screen`）不经过 `next.output` 流、不经过 `startStreaming()` 的监听器、
    // 也不被任何 replay/capture 计数器过滤，而是服务端通过
    // `takeResumeDisposition()`（同步 FFI take）整段给出，由
    // `_applyResumeDisposition` 一次 `terminal.write()` 直接写完
    // （reconnect_service.dart `_applyResumeDisposition`）。
    //
    // 换句话说，"清屏 + 装计数器 + 等 startStreaming 把 prelude 冲进来"这条
    // 路径在生产代码里已经无法触达：全仓库没有任何调用点会把
    // `preludeReplayRemaining` / `preludeCaptureRemaining` 置为非零
    // （已核实），本测试原本模拟的正是那个从未真正发生的赋值。
    // `test/ssh/aqt_transport_install_test.dart` 的 AqtRestored 分组已经在
    // 新模型下验证了同一批意图（单次 write、marker 正确出现）。

    testWidgets(
        '3. CAN byte at prelude tail does not suppress marker rendering',
        (tester) async {
      for (final withCan in [true, false]) {
        final mgr = await _newManager();
        final tab = mgr.addTab(_makeServer());
        final fake = _FakeTransport();
        tab.transport = fake;
        tab.startStreaming();

        fake.emit(_buildPrelude(withCan: withCan));
        await tester.pump();
        await tester.pump();

        final text = readTerminalText(tab.terminal);
        expect(text.contains(_marker), isTrue,
            reason: 'withCan=$withCan must not affect marker visibility');
        // _flushOutput explicitly strips 0x18 (CAN) before terminal.write;
        // the literal control char must never land in the rendered buffer.
        expect(text.contains('\x18'), isFalse,
            reason: 'CAN must be stripped, never rendered as tofu (□)');
        mgr.dispose();
      }
    });

    testWidgets(
        '3b. live output after a CAN-terminated prelude still renders '
        '(parser/unwrapper must not get stuck on CAN)',
        (tester) async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final fake = _FakeTransport();
      tab.transport = fake;
      tab.startStreaming();

      fake.emit(_buildPrelude(withCan: true));
      await tester.pump();
      await tester.pump();
      fake.emit(utf8.encode('POST-CAN-LIVE-OUTPUT\r\n'));
      await tester.pump();
      await tester.pump();

      final text = readTerminalText(tab.terminal);
      expect(text.contains(_marker), isTrue);
      expect(text.contains('POST-CAN-LIVE-OUTPUT'), isTrue,
          reason:
              'a CAN byte in one flush batch must not leave the tmux '
              'unwrapper (or decoder residue) in a state that swallows a '
              'later, independent flush batch');
      mgr.dispose();
    });

    testWidgets(
        '4. fragmented delivery (multi-chunk) yields the same rendered text as a single chunk',
        (tester) async {
      final prelude = _buildPrelude(withCan: true);

      final mgrA = await _newManager();
      final tabA = mgrA.addTab(_makeServer());
      final fakeA = _FakeTransport();
      tabA.transport = fakeA;
      tabA.startStreaming();
      fakeA.emit(prelude);
      await tester.pump();
      await tester.pump();
      final textA = readTerminalText(tabA.terminal);
      mgrA.dispose();

      final mgrB = await _newManager();
      final tabB = mgrB.addTab(_makeServer());
      final fakeB = _FakeTransport();
      tabB.transport = fakeB;
      tabB.startStreaming();
      for (final chunk in _splitIntoChunks(prelude, chunkSize: 7)) {
        fakeB.emit(chunk);
        await tester.pump(); // force each fragment through its own vsync flush
      }
      await tester.pump();
      final textB = readTerminalText(tabB.terminal);
      mgrB.dispose();

      expect(textB.contains(_marker), isTrue,
          reason: 'fragmented delivery must still render the marker');
      expect(textB, equals(textA),
          reason:
              'chunking must be transparent to the rendered result — a '
              'mismatch would point at the UTF-8 residue / chunk-boundary '
              'splicing logic in _flushOutput');
    });
  });

  // ── Coordinator hypothesis: double startStreaming() before the scheduled
  // frame flush lands ────────────────────────────────────────────────────
  //
  // startStreaming() (session_manager.dart:599) unconditionally does, at
  // the top:
  //   _pendingRawBytes.clear();
  //   _hasPendingRaw = false;
  // before re-subscribing. If it is called a SECOND time on the same tab
  // while bytes from the FIRST subscription are still sitting in
  // _pendingRawBytes (frame callback not yet fired), those bytes are
  // discarded with no trace — they were never handed to terminal.write().
  //
  // IMPORTANT SIDE FINDING (see report): whether the second call also
  // *throws* depends on whether tab.transport is the SAME instance across
  // both calls. AqtTransport's `output` is a single-subscription
  // `StreamController<Uint8List>().stream` (aqt_transport.dart:149/771).
  // Calling `.listen()` a second time on that exact Stream object — even
  // after the first subscription was cancelled — throws synchronously:
  // "Bad state: Stream has already been listened to." Real call sites
  // (_installAqtTransport at reconnect_service.dart:1801/1814 always does
  // `tab.transport = next;` BEFORE `tab.startStreaming()`) only avoid this
  // if the second startStreaming() targets a *different* transport
  // instance. Both configurations are tested below.
  //
  // 2026-08-26 更新（a2.jpg 全黑屏定案）：5a 原来断言"必须抛"，理由写的是
  // 「这个形状在生产里不会静默发生，它会以崩溃暴露」。**那个理由不成立**：
  // `_installAqtTransport` 的 4 个调用点全是 fire-and-forget，抛出后只变成
  // unhandled Future error（只进 logcat），并且吃掉它后面的 registerAqtTab
  // —— 于是 tab 既收不到输出、又没接上 onSessionDead，屏幕永久停住且不自愈。
  // 恢复内容改走 PTY 流（eaf65d1）之后，"收不到输出"就等于"永久黑屏"，因为
  // 服务端只在 RESUME 那一刻发一次快照。
  //
  // 修复：startStreaming() 现在按**输出源对象**幂等 —— 同源二次调用直接返回，
  // 既不 cancel（不丢在途字节）也不 listen（不抛）。5a 因此翻转成"第二次调用
  // 是 no-op，prelude 照样落地"。
  group('double startStreaming() before flush — race hazard', () {
    testWidgets(
        '5a. same transport instance, second call is a no-op: '
        'no throw AND the in-flight prelude still lands',
        (tester) async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final prelude = _buildPrelude(withCan: true);

      tab.terminal.write('\x1b[3J\x1b[2J\x1b[H\x1b[0m');
      tab.renderedOutputBytes = 0;
      tab.preludeReplayRemaining = prelude.length;
      // `tab.serverRingOff = 900000 - prelude.length;` 原来在这里——该字段
      // 已删除（服务端不再靠客户端报的 offset 判断续传/重建）。这条测试本身
      // 测的是 startStreaming() 自己的重复订阅竞态，与 RESUME offset 无关，
      // 删掉这一行不影响测试意图。
      tab.preludeCaptureRemaining = 16;

      final fake = _FakeTransport();
      tab.transport = fake;
      tab.startStreaming(); // first subscription attaches to fake.output

      fake.emit(prelude); // buffered into _pendingRawBytes, frame scheduled
      // Deliberately do NOT pump here — the frame callback has not fired yet.

      Object? thrown;
      try {
        tab.startStreaming(); // second call, same tab.transport instance
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNull,
          reason:
              '同源二次调用必须是 no-op。抛出会停在"旧订阅已取消、新订阅没装上"'
              '的状态：此后没有任何输出能进终端，onDone 也永远不来 → 重连链'
              '不会被唤醒，屏幕永久黑着（a2.jpg）');
      expect(tab.streamAttachFailures, 0,
          reason: '幂等返回不该走到兜底分支 —— 那条路是给"还没想到的触发路径"留的');

      await tester.pump();
      await tester.pump();
      final text = readTerminalText(tab.terminal);
      expect(text.contains(_marker), isTrue,
          reason:
              '第二次调用既没 cancel 订阅也没清 _pendingRawBytes，所以第一个'
              '订阅缓冲的 prelude 照常 flush 进终端');
      mgr.dispose();
    });

    testWidgets(
        '5b. different transport instance, second call before delivery: '
        'in-flight prelude is LOST (known bug, cancel drops queued events)',
        (tester) async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final prelude = _buildPrelude(withCan: true);

      tab.terminal.write('\x1b[3J\x1b[2J\x1b[H\x1b[0m');
      tab.renderedOutputBytes = 0;
      tab.preludeReplayRemaining = prelude.length;
      // `tab.serverRingOff = 900000 - prelude.length;` 原来在这里——该字段
      // 已删除（服务端不再靠客户端报的 offset 判断续传/重建）。这条测试本身
      // 测的是 startStreaming() 自己的重复订阅竞态，与 RESUME offset 无关，
      // 删掉这一行不影响测试意图。
      tab.preludeCaptureRemaining = 16;

      final fakeA = _FakeTransport();
      tab.transport = fakeA;
      tab.startStreaming();
      fakeA.emit(prelude);
      // No pump: bytes are sitting in _pendingRawBytes, frame not yet fired.

      // Simulate a second, independent transport install landing before the
      // first frame callback fires (e.g. terminal_screen.dart:1009 racing
      // _installAqtTransport's own startStreaming() call).
      final fakeB = _FakeTransport();
      tab.transport = fakeB;
      tab.startStreaming(); // flushes _pendingRawBytes before re-arming
      fakeB.emit(utf8.encode('LIVE-AFTER-SECOND-CALL\r\n'));

      await tester.pump();
      await tester.pump();

      final text = readTerminalText(tab.terminal);
      // 仍然是 isFalse —— 这条 bug **没有**被修掉，测试如实记录现状。
      //
      // 曾经试过在 startStreaming() 清缓冲前先 _flushOutput()，无效。原因：
      // StreamController.add() 投递给监听器是**异步**的，所以第二次
      // startStreaming() 执行时字节还没进 _pendingRawBytes，flush 无从可救。
      // 真正的丢失点是本函数第一行的 `_stdoutSub?.cancel()` —— 取消订阅会
      // 丢弃流里还没投递的事件。
      //
      // 这个窗口比"帧回调没落地"更容易命中：它只需要 controller.add() 到监听器
      // 执行之间那个 microtask 间隙，而那个间隙每次 emit 都存在。
      //
      // 为什么失败模式这么恶劣：丢掉的是服务端已经 ack 过、不会重发的字节，
      // 而连接是健康的——没有任何一层能发现（watchdog 查的是 QUIC 连接存活，
      // 不是"屏幕上该有内容"）。所以表现为永久静默空白 + 不自愈。
      expect(text.contains(_marker), isFalse,
          reason:
              'KNOWN BUG (not fixed): the second startStreaming() cancels the '
              'first subscription before its in-flight stream events are '
              'delivered, discarding them. Bytes are server-acked and will '
              'never be resent, and no layer can detect the loss because the '
              'connection itself stays healthy.');
      expect(text.contains('LIVE-AFTER-SECOND-CALL'), isTrue,
          reason:
              'the second transport\'s own bytes still render fine — only '
              'the first transport\'s pre-flush bytes are lost, matching '
              '"connection healthy, screen blank"');
      mgr.dispose();
    });

    testWidgets(
        '6. control — second startStreaming() AFTER the first flush lands: marker survives',
        (tester) async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final prelude = _buildPrelude(withCan: true);

      tab.terminal.write('\x1b[3J\x1b[2J\x1b[H\x1b[0m');
      tab.renderedOutputBytes = 0;
      tab.preludeReplayRemaining = prelude.length;
      // `tab.serverRingOff = 900000 - prelude.length;` 原来在这里——该字段
      // 已删除（服务端不再靠客户端报的 offset 判断续传/重建）。这条测试本身
      // 测的是 startStreaming() 自己的重复订阅竞态，与 RESUME offset 无关，
      // 删掉这一行不影响测试意图。
      tab.preludeCaptureRemaining = 16;

      final fakeA = _FakeTransport();
      tab.transport = fakeA;
      tab.startStreaming();
      fakeA.emit(prelude);
      await tester.pump();
      await tester.pump(); // flush lands — marker committed to terminal.write()

      final fakeB = _FakeTransport();
      tab.transport = fakeB;
      tab.startStreaming(); // safe now — nothing pending to clear
      fakeB.emit(utf8.encode('LIVE-AFTER-SECOND-CALL\r\n'));
      await tester.pump();
      await tester.pump();

      final text = readTerminalText(tab.terminal);
      expect(text.contains(_marker), isTrue,
          reason:
              'once the flush has already committed bytes via '
              'terminal.write(), a later startStreaming() clearing the '
              '(now-empty) _pendingRawBytes buffer cannot retroactively '
              'un-render them — pins down "before flush" as the exact '
              'necessary condition for the loss in 5b');
      expect(text.contains('LIVE-AFTER-SECOND-CALL'), isTrue);
      mgr.dispose();
    });

    testWidgets(
        '5c. 兜底 — 订阅装不上时上报会话已死，而不是静默失聪',
        (tester) async {
      // 幂等闸门只挡"同一个 tab 对同一来源二次调用"。装订阅还有别的失败形状
      // （这里用两个 tab 抢同一条单订阅流模拟），它们的共同后果是一样的：这个
      // tab 从此收不到任何字节，而 onDone 也永远不来 —— 没有任何一层能发现。
      // 所以 startStreaming 必须自己把它翻译成"会话死了"，让重连链换一条新
      // transport（新 controller 才能重新订阅）。
      final mgr = await _newManager();
      final tabA = mgr.addTab(_makeServer());
      final tabB = mgr.addTab(_makeServer());
      final shared = _FakeTransport();

      tabA.transport = shared;
      tabA.startStreaming();

      var deadCalls = 0;
      tabB.onSessionDead = () => deadCalls++;
      tabB.transport = shared;

      Object? thrown;
      try {
        tabB.startStreaming(); // 同一条流，第二个订阅者
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNull, reason: '异常不能逃出去 —— 调用点全是 fire-and-forget，'
          '逃出去就等于被吞掉，还会连带吃掉 registerAqtTab');
      expect(tabB.streamAttachFailures, 1);
      expect(tabB.lastStreamAttachError, contains('already been listened to'));

      // 上报是异步的：真实调用点在本方法返回后才跑 registerAqtTab（也就是
      // onSessionDead 的接线点），同步 call 会打在 null 上。
      expect(deadCalls, 0, reason: '同步上报会打在还没接线的 onSessionDead 上');
      await tester.pump();
      expect(deadCalls, 1, reason: '一个微任务之后必须上报，否则这个 tab 永久黑屏');
      mgr.dispose();
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // （已删除）"alt-buffer swallow discards the server cold-RESUME snapshot"
  // 整组。
  //
  // 这组测的是客户端 `preludeSwallowRemaining` 机制（终端处于 alt 屏时把整段
  // RESUME prelude 吞掉不写 xterm）与服务端 `assemble_cold_resume_prelude_alt`
  // （同一场景下特意组装一份"可以直接安全写进 xterm 的完整快照"）之间的矛盾——
  // 服务端发了，客户端却因为自己也在 alt 屏而把它整段丢掉。
  //
  // 这个矛盾在新模型下不成立了，不是因为哪一侧"修好了"，而是因为
  // `preludeSwallowRemaining` 赖以触发的整条路径已经不存在：
  //   - 全仓库核实过，没有任何生产代码调用点会把 `tab.preludeSwallowRemaining`
  //     / `tab.preludeReplayRemaining` 置为非零——只有本测试文件自己在模拟
  //     "假如它被置位会怎样"。
  //   - RESUME 恢复的内容不再经过 `next.output` 流、不再经过
  //     `SessionTab.startStreaming()` 的监听器，因而根本不会被这套
  //     swallow/capture 计数器过滤。它是服务端通过 `takeResumeDisposition()`
  //     （同步 FFI take）整段给出的 `AqtRestored.screen`，由
  //     `_applyResumeDisposition` 一次 `terminal.write()` 直写
  //     （reconnect_service.dart `_applyResumeDisposition`）——这条路径不问
  //     "客户端此刻在不在 alt 屏"，自然也没有"因为在 alt 屏而吞掉"这个分支。
  //   - 依赖的 `tab.serverRingOff` 字段本身也已删除（服务端不再靠客户端报
  //     的 offset 反推续传/重建）。
  //
  // 也就是说这不是"改个字段名就能修好"的测试，它验证的整套矛盾场景在结构上
  // 已经消失。`test/ssh/aqt_transport_install_test.dart` 的 AqtNewSession /
  // AqtRestored 分组已经在新模型下覆盖了"进 alt 屏的场景该怎么处理"这批意图
  // （NewSession 才复位、Restored 只管单次写入不看 alt 状态）。

  // ── ⑤ 段：快照渲染完成回调 —— 恰好一次 + 一次性清空 ─────────────────
  //
  // preludeReplayRemaining 归零后，_flushOutput 在写完 terminal 的下一帧
  // 触发 onResumeRenderComplete。这里验证：回调用计数器（不是"触发了没有"）
  // 断言恰好一次；触发后字段本身被清空（一次性语义，防止把 span
  // 闭包进来后被陈旧的积压 postFrame 重复闭合）。
  group('onResumeRenderComplete — ⑤ 段一次性回调', () {
    testWidgets(
        '7. 快照末字节落地后的首帧恰好触发一次回调，随后自动清空',
        (tester) async {
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final fake = _FakeTransport();
      tab.transport = fake;
      tab.startStreaming();

      final prelude = _buildPrelude(withCan: true);
      tab.preludeReplayRemaining = prelude.length;

      var callCount = 0;
      int? capturedMs;
      tab.onResumeRenderComplete = (nowMs) {
        callCount++;
        capturedMs = nowMs;
      };

      fake.emit(prelude);
      await tester.pump();
      await tester.pump();
      // 多泵一帧兜底：即便 postFrame 因某种调度顺序被推迟到下一帧，也不该
      // 再多触发一次。
      await tester.pump();

      expect(callCount, 1,
          reason:
              '快照末字节落地后的首帧必须且只能触发一次回调 —— 用计数器断言，'
              '不是"触发了"，否则测不出重复触发（双重计数）这个真实故障模式');
      expect(capturedMs, isNotNull);
      expect(capturedMs! > 0, isTrue,
          reason: '回调收到的必须是墙钟毫秒时间戳');
      expect(tab.onResumeRenderComplete, isNull,
          reason:
              '一次性语义：触发后必须自动清空字段本身，否则下一轮恢复复用同一个'
              'tab 时，陈旧回调会被新一轮恢复的 span 误判成"还没装好"而'
              '重复触发');
      mgr.dispose();
    });

    testWidgets(
        '8. 连续两次独立完成（期间未重新赋值回调）—— 回调至多触发一次',
        (tester) async {
      // 复现审查者指出的竞态：两次独立的 _flushOutput 触发，若消费（置 null）
      // 被推迟到 postFrame 内部完成，第二次触发会在第一次的 postFrame 跑完
      // 之前就捕获到同一个尚未清空的回调，导致同一个回调被调用两次。
      //
      // 用两个 >32KB 的大块触发 _flushOutput 的"同步快路径"
      // （_pendingOutputBytes > 32768 && !_framePending，见
      // session_manager.dart _scheduleOutputFlush），这条路径不经过
      // SchedulerBinding 的帧回调，两次触发可以在同一次 microtask flush
      // 里背靠背同步跑完，中间不需要、也没有任何一帧被绘制 —— 这正是复现
      // "捕获时刻早于清空时刻"所需要的时序：若消费不是与捕获同步完成，
      // 第二次触发发生时字段必然还没被清空。
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final fake = _FakeTransport();
      tab.transport = fake;
      tab.startStreaming();

      var callCount = 0;
      tab.onResumeRenderComplete = (_) => callCount++;

      final bytes1 = List<int>.filled(40000, 0x41); // 'A' * 40000
      final bytes2 = List<int>.filled(40000, 0x42); // 'B' * 40000

      tab.preludeReplayRemaining = bytes1.length;
      fake.emit(bytes1);
      // 让第一条 emit 的 stream 投递 microtask 跑完（从而同步跑完第一次
      // _flushOutput 的快路径），但刻意不推进任何一帧 —— 帧才会真正触发
      // postFrame，这里要确保它还没触发。
      await Future<void>.value();

      // 不重新赋值回调，直接再次武装 preludeReplayRemaining，模拟第二次
      // 独立的"快照末字节落地"（比如同一个 tab 在短时间内经历了两轮
      // RESUME）。
      tab.preludeReplayRemaining = bytes2.length;
      fake.emit(bytes2);
      await Future<void>.value();

      // 两次快路径 flush 全走完之后，这条测试从没让任何 widget 建树、也没
      // 触发过任何一次真实绘制 —— TestWidgetsFlutterBinding.pump() 只有在
      // 有一帧被"排上日程"时才会真的跑 handleDrawFrame（进而触发排队的
      // postFrame 回调），否则是 no-op。生产环境里帧一直在跑，不需要这行；
      // 这里手动请求一帧，只是为了让已经排队的 postFrame 有机会执行。
      SchedulerBinding.instance.scheduleFrame();
      await tester.pump();
      await tester.pump();

      expect(callCount, 1,
          reason:
              '两次独立完成、期间未重新赋值回调，回调至多触发一次 —— 消费'
              '（置 null）必须与捕获在同一个同步块内完成；若推迟到 postFrame'
              '内部才清空，两次快路径 flush 会各自捕获到同一个尚未清空的'
              '回调，各自调度一次，回调被调用两次');
      mgr.dispose();
    });

    testWidgets(
        '9. 捕获发生在 flag 置位的同一个同步块——帧回调落地前重新武装 '
        'onResumeRenderComplete 也不会连累已经捕获走的回调',
        (tester) async {
      // 复现三审指出的更深一层竞态：_flushOutput 不一定同步跑——小于 32KB
      // 的批次会被 _scheduleOutputFlush 推迟到下一个 vsync 帧
      // （scheduleFrameCallback），而 preludeReplayRemaining 归零是在 stdout
      // 监听器里同步发生的。如果"捕获"这一步推迟到 _flushOutput 才做（回读
      // onResumeRenderComplete 字段），中间这段窗口里 ReconnectService 完全
      // 可能为下一轮恢复重新赋值该字段——上一轮的回调就会被换成下一轮的。
      //
      // 用 _buildPrelude()（211 字节，远小于 32768）走"延迟路径"：emit 之后
      // 只让 microtask 跑完（StreamController.add 投递监听器），不 pump —— 此
      // 时监听器已经同步执行、preludeReplayRemaining 已归零，但帧还没画。
      // 这正是"捕获必须与 flag 置位同一个同步块完成"最需要验证的时刻。
      final mgr = await _newManager();
      final tab = mgr.addTab(_makeServer());
      final fake = _FakeTransport();
      tab.transport = fake;
      tab.startStreaming();

      var callsA = 0;
      var callsB = 0;
      tab.onResumeRenderComplete = (_) => callsA++;

      final prelude = _buildPrelude(withCan: true);
      tab.preludeReplayRemaining = prelude.length;
      fake.emit(prelude);

      // 只放行 microtask（stream 投递 + 监听器同步执行），刻意不 pump —— 帧
      // 还没画，_flushOutput 还没跑。若捕获逻辑不对，此刻
      // tab.onResumeRenderComplete 应该仍是非 null（还没被消费）。
      await Future<void>.value();
      await Future<void>.value();

      // 模拟 ReconnectService 在帧落地前，为下一轮恢复重新武装回调。
      tab.onResumeRenderComplete = (_) => callsB++;

      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(callsA, 1,
          reason:
              '捕获必须发生在 preludeReplayRemaining 归零的同一个同步块里——'
              '此时上一轮回调已经被搬进 _capturedRenderCompleteCb，帧落地前'
              '重新赋值 onResumeRenderComplete 不应该影响已经捕获走的那一份');
      expect(callsB, 0,
          reason:
              '重新武装的回调属于"下一轮"，这一次快照的渲染完成事件不该误闭合'
              '它——否则就是三审指出的"用错误的时刻归因下一轮恢复"');
      mgr.dispose();
    });
  });
}
