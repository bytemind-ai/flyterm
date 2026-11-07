import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_bootstrap.dart';
import 'package:flyterm/ssh/aqt/aqt_port_spec.dart';

void main() {
  group('parseDaemonInfo', () {
    test('读出端口与活跃会话数', () {
      final info = parseDaemonInfo(
          'AQT_PORT=61005\nAQT_PUBKEY=AAAA\nAQT_PID=42\nAQT_SESSIONS=3\n');
      expect(info, isNotNull);
      expect(info!.port, 61005);
      expect(info.sessions, 3);
    });

    test('旧版服务端没有 AQT_SESSIONS 行时 sessions 为 null', () {
      final info = parseDaemonInfo('AQT_PORT=61005\nAQT_PUBKEY=AAAA\n');
      expect(info!.sessions, isNull);
    });

    test('缺端口或公钥返回 null', () {
      expect(parseDaemonInfo('AQT_PUBKEY=AAAA\n'), isNull);
      expect(parseDaemonInfo('AQT_PORT=61005\n'), isNull);
    });
  });

  group('buildDaemonSpawnCommand', () {
    final cmd = buildDaemonSpawnCommand(
      ports: const AqtPortSpec(61001, 61999),
      congestion: 'cubic',
    );

    test('把端口段传给 --listen', () {
      expect(cmd, contains('P=61001-61999'));
      expect(cmd, contains(r'--listen "$P"'));
      expect(cmd, contains('--congestion cubic'));
    });

    test('服务端不认识端口段写法时退回随机端口（升级失败的旧二进制）', () {
      expect(cmd, contains('START-END'),
          reason: '用 --help 里的写法判断服务端是否支持端口段');
      expect(cmd, contains('P=0'));
    });

    test('仍以 setsid + nohup 脱离 SSH 会话，并清理 tmux 环境', () {
      expect(cmd, contains('setsid nohup'));
      expect(cmd, contains('unset TMUX TMUX_PANE TERM_PROGRAM TERM_PROGRAM_VERSION'));
      expect(cmd, contains('& disown'));
    });
  });

  test('daemonPortMismatch：端口不在设置的范围内才算不一致', () {
    AqtBootstrapInfo at(int port) =>
        parseDaemonInfo('AQT_PORT=$port\nAQT_PUBKEY=AAAA\n')!;
    const ports = AqtPortSpec(61001, 61999);
    expect(daemonPortMismatch(at(61500), ports), isFalse);
    expect(daemonPortMismatch(at(43211), ports), isTrue);
  });

  test('installCommandPortArg：升级时把端口段带给 --install', () {
    expect(installListenArg(const AqtPortSpec(61001, 61999)),
        '--listen 61001-61999');
  });
}
