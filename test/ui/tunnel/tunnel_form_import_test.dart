import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/config_draft.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ui/tunnel/tunnel_form_screen.dart';

Server _server(String id, String name, String host) => Server(
      id: id,
      name: name,
      host: host,
      port: 22,
      username: 'root',
      authType: 'password',
    );

void main() {
  final servers = [
    _server('id-1', 'db-prod', '10.0.0.6'),
    _server('id-2', 'web-1', '10.0.0.5'),
  ];

  test('本地转发映射成控制器文本', () {
    const draft = TunnelDraft(
      direction: TunnelDirection.local,
      localPort: 13306,
      remoteHost: '127.0.0.1',
      remotePort: 3306,
      provenance: {'remoteHost': 'ssh 命令的转发参数'},
    );
    final a = TunnelDraftApplication.from(draft, servers);

    expect(a.direction, TunnelDirection.local);
    expect(a.localPort, '13306');
    expect(a.remoteHost, '127.0.0.1');
    expect(a.remotePort, '3306');
    expect(a.highlightedFields, contains('remoteHost'));
  });

  test('localPort 缺省时回落到 remotePort', () {
    const draft = TunnelDraft(
      direction: TunnelDirection.local,
      remoteHost: '127.0.0.1',
      remotePort: 3306,
    );
    final a = TunnelDraftApplication.from(draft, servers);
    expect(a.localPort, '3306');
  });

  test('serverHostHint 按 host 匹配到已存服务器', () {
    const draft = TunnelDraft(
      direction: TunnelDirection.local,
      remoteHost: '127.0.0.1',
      remotePort: 3306,
      serverHostHint: '10.0.0.6',
    );
    final a = TunnelDraftApplication.from(draft, servers);
    expect(a.matchedServer?.id, 'id-1');
  });

  test('serverHostHint 按名字匹配', () {
    const draft = TunnelDraft(
      direction: TunnelDirection.local,
      remoteHost: '127.0.0.1',
      remotePort: 3306,
      serverHostHint: 'web-1',
    );
    final a = TunnelDraftApplication.from(draft, servers);
    expect(a.matchedServer?.id, 'id-2');
  });

  test('匹配不上时 matchedServer 为 null —— 让用户自己选，不报错', () {
    const draft = TunnelDraft(
      direction: TunnelDirection.local,
      remoteHost: '127.0.0.1',
      remotePort: 3306,
      serverHostHint: '还没加过的机器',
    );
    final a = TunnelDraftApplication.from(draft, servers);
    // 先拿到转发命令、还没加那台机器是很常见的顺序。
    expect(a.matchedServer, isNull);
    expect(a.localPort, '3306');
  });

  test('socks5 没有远端字段，控制器留空', () {
    const draft = TunnelDraft(
      direction: TunnelDirection.socks5,
      localPort: 1080,
    );
    final a = TunnelDraftApplication.from(draft, servers);
    expect(a.direction, TunnelDirection.socks5);
    expect(a.localPort, '1080');
    expect(a.remoteHost, '');
    expect(a.remotePort, '');
  });
}
