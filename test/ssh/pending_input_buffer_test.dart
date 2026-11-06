import 'dart:typed_data';

import 'package:flyterm/ssh/reconnect_service.dart' show ReconnectService;
import 'package:flyterm/ssh/session_manager.dart' show SessionTab;
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/ssh_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

Future<SessionTab> makeTab() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return SessionTab(
    server: Server(
        id: 'test', name: 'test', host: '127.0.0.1', port: 22, username: 'u',
        authType: 'password'),
    connection: SSHConnection(),
    terminal: Terminal(),
    sessionKey: 'test',
    aiEngine: AIEngine(prefs, serverId: 'test'),
  );
}

/// 断连期间按键的两级缓冲。
///
/// AqtTransport 自己那一级只覆盖"transport 还在、只是连不通"。走 SSH 回退链
/// 时 ReconnectService 会先把 tab.transport 置 null，之后 5-25 秒里
/// _writeToShell 既没有 transport、QUIC tab 又没有 shell，按键被静默丢弃。
/// tab 级缓冲补的就是那段空窗。
void main() {
  List<int> bytes(String s) => s.codeUnits;

  group('SessionTab 缓冲', () {
    late SessionTab tab;
    setUp(() async => tab = await makeTab());

    test('空缓冲 drain 返回 null', () {
      expect(tab.drainPendingInput(), isNull);
    });

    test('缓冲后按顺序取回', () {
      tab.bufferPendingInput(bytes('ls '));
      tab.bufferPendingInput(bytes('-la\r'));
      expect(String.fromCharCodes(tab.drainPendingInput()!), 'ls -la\r');
    });

    test('drain 之后清空，不会重复发送', () {
      tab.bufferPendingInput(bytes('x'));
      expect(tab.drainPendingInput(), isNotNull);
      expect(tab.drainPendingInput(), isNull,
          reason: '重复回灌会让同一批按键发两次');
    });

    test('空输入不建立缓冲', () {
      tab.bufferPendingInput(const []);
      expect(tab.drainPendingInput(), isNull);
    });

    test('超过上限后丢弃溢出部分而不是无限增长', () {
      final huge = List<int>.filled(SessionTab.kMaxPendingInputBytes + 5000, 0x61);
      tab.bufferPendingInput(huge);
      tab.bufferPendingInput(bytes('tail'));
      expect(tab.drainPendingInput()!.length, SessionTab.kMaxPendingInputBytes);
    });

    test('分多次写入也在上限处截断', () {
      for (var i = 0; i < 20; i++) {
        tab.bufferPendingInput(List<int>.filled(1000, 0x62));
      }
      expect(tab.drainPendingInput()!.length, SessionTab.kMaxPendingInputBytes);
    });
  });

  group('两级缓冲的拼接顺序', () {
    test('transport 级在前，tab 级在后（时序）', () {
      // 先是 transport 还在但连不通时敲的，再是 transport 被置 null 后敲的。
      final merged = ReconnectService.concatPendingInput(
        Uint8List.fromList(bytes('echo ')),
        Uint8List.fromList(bytes('hi\r')),
      );
      expect(String.fromCharCodes(merged!), 'echo hi\r',
          reason: '反过来拼会把用户敲的字打乱成 hi\\recho ');
    });

    test('任一为空时原样返回', () {
      final a = Uint8List.fromList(bytes('a'));
      expect(ReconnectService.concatPendingInput(a, null), same(a));
      expect(ReconnectService.concatPendingInput(null, a), same(a));
      expect(ReconnectService.concatPendingInput(a, Uint8List(0)), same(a));
      expect(ReconnectService.concatPendingInput(Uint8List(0), a), same(a));
    });

    test('两边都空 → null', () {
      expect(ReconnectService.concatPendingInput(null, null), isNull);
    });
  });
}
