import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/tunnel/tunnel_entry.dart';
import 'package:flyterm/ui/tunnel/tunnel_grouping.dart';
import 'package:uuid/uuid.dart';

Server _server(String name) => Server(
      id: const Uuid().v4(),
      name: name,
      host: '$name.example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    );

TunnelEntry _tunnel(
  Server server, {
  required String label,
  TunnelStatus status = TunnelStatus.active,
  TunnelDirection direction = TunnelDirection.local,
  int localPort = 8080,
  String remoteHost = 'localhost',
  int remotePort = 80,
}) {
  final e = TunnelEntry(
    server: server,
    direction: direction,
    localPort: localPort,
    remoteHost: remoteHost,
    remotePort: remotePort,
    label: label,
  );
  e.status = status;
  return e;
}

void main() {
  group('tunnelCountsByServer', () {
    test('按 server.id 计数，含全部条目', () {
      final a = _server('a');
      final b = _server('b');
      final counts = tunnelCountsByServer([
        _tunnel(a, label: 'one'),
        _tunnel(a, label: 'two'),
        _tunnel(b, label: 'three'),
      ]);
      expect(counts[a.id], 2);
      expect(counts[b.id], 1);
    });

    test('空列表返回空 Map', () {
      expect(tunnelCountsByServer(const []), isEmpty);
    });
  });

  group('groupTunnelsByServer', () {
    test('按 server.name 升序分组', () {
      final z = _server('zeta');
      final a = _server('alpha');
      final groups = groupTunnelsByServer([
        _tunnel(z, label: 'z1'),
        _tunnel(a, label: 'a1'),
      ]);
      expect(groups.map((g) => g.server.name), ['alpha', 'zeta']);
    });

    test('组内 active/connecting 排在 stopped 之前', () {
      final s = _server('alpha');
      final groups = groupTunnelsByServer([
        _tunnel(s, label: 'stopped', status: TunnelStatus.stopped),
        _tunnel(s, label: 'active', status: TunnelStatus.active),
        _tunnel(s, label: 'connecting', status: TunnelStatus.connecting),
      ]);
      expect(groups.single.tunnels.map((t) => t.label),
          ['active', 'connecting', 'stopped']);
    });

    test('query 命中 label', () {
      final s = _server('alpha');
      final groups = groupTunnelsByServer([
        _tunnel(s, label: 'MySQL'),
        _tunnel(s, label: 'Redis'),
      ], query: 'mysql');
      expect(groups.single.tunnels.map((t) => t.label), ['MySQL']);
    });

    test('query 命中 server.name', () {
      final a = _server('alpha');
      final b = _server('beta');
      final groups = groupTunnelsByServer([
        _tunnel(a, label: 'x'),
        _tunnel(b, label: 'y'),
      ], query: 'beta');
      expect(groups.single.server.name, 'beta');
    });

    test('query 无命中返回空列表', () {
      final s = _server('alpha');
      final groups =
          groupTunnelsByServer([_tunnel(s, label: 'x')], query: 'zzz');
      expect(groups, isEmpty);
    });

    test('query 命中 displayPorts（本地端口）', () {
      final s = _server('alpha');
      final groups = groupTunnelsByServer([
        _tunnel(s, label: 'Web', localPort: 9999),
      ], query: '9999');
      expect(groups.single.tunnels.map((t) => t.label), ['Web']);
    });

    test('error 排在 connecting 之后、stopped 之前', () {
      final s = _server('alpha');
      final groups = groupTunnelsByServer([
        _tunnel(s, label: 'stopped', status: TunnelStatus.stopped),
        _tunnel(s, label: 'active', status: TunnelStatus.active),
        _tunnel(s, label: 'error', status: TunnelStatus.error),
        _tunnel(s, label: 'connecting', status: TunnelStatus.connecting),
      ]);
      expect(groups.single.tunnels.map((t) => t.label),
          ['active', 'connecting', 'error', 'stopped']);
    });

    test('不修改传入列表的顺序', () {
      // "不副作用"的保证托管给本文件的单测，
      // 所以这里显式断言：传入乱序列表，输出被重排，但输入原样保留。
      final s = _server('alpha');
      final input = [
        _tunnel(s, label: 'stopped', status: TunnelStatus.stopped),
        _tunnel(s, label: 'active', status: TunnelStatus.active),
        _tunnel(s, label: 'connecting', status: TunnelStatus.connecting),
      ];
      groupTunnelsByServer(input);
      expect(input.map((t) => t.label),
          ['stopped', 'active', 'connecting']);
    });
  });
}
