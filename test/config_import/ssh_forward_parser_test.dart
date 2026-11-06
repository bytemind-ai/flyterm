import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/config_draft.dart';
import 'package:flyterm/config_import/ssh_forward_parser.dart';

void main() {
  test('解析 -L 本地转发（三段式）', () {
    final d = parseSshForward('ssh -L 13306:127.0.0.1:3306 root@db')!;
    expect(d.direction, TunnelDirection.local);
    expect(d.localPort, 13306);
    expect(d.remoteHost, '127.0.0.1');
    expect(d.remotePort, 3306);
    expect(d.serverHostHint, 'db');
    expect(d.isUsable, isTrue);
  });

  test('解析 -L 两段式（省略本地端口）', () {
    // `-L host:port` 时 ssh 用同一个端口号作为本地端口。
    final d = parseSshForward('ssh -L 127.0.0.1:3306 root@db')!;
    expect(d.remoteHost, '127.0.0.1');
    expect(d.remotePort, 3306);
    expect(d.effectiveLocalPort, 3306);
  });

  test('解析 -R 远程转发', () {
    final d = parseSshForward('ssh -R 8080:localhost:80 root@web')!;
    expect(d.direction, TunnelDirection.remote);
    expect(d.localPort, 8080);
    expect(d.remoteHost, 'localhost');
    expect(d.remotePort, 80);
  });

  test('解析 -D 动态转发', () {
    final d = parseSshForward('ssh -D 1080 root@proxy')!;
    expect(d.direction, TunnelDirection.socks5);
    expect(d.localPort, 1080);
    expect(d.remoteHost, isNull);
    expect(d.isUsable, isTrue);
  });

  test('支持 -L13306:... 紧贴写法', () {
    final d = parseSshForward('ssh -L13306:127.0.0.1:3306 root@db')!;
    expect(d.localPort, 13306);
    expect(d.remotePort, 3306);
  });

  test('带绑定地址的四段式 bind:port:host:port', () {
    final d = parseSshForward('ssh -L 0.0.0.0:13306:127.0.0.1:3306 root@db')!;
    // 绑定地址对本 app 无意义（移动端不做对外监听），丢弃但不失败。
    expect(d.localPort, 13306);
    expect(d.remoteHost, '127.0.0.1');
    expect(d.remotePort, 3306);
  });

  test('没有转发参数时返回 null', () {
    expect(parseSshForward('ssh root@example.com'), isNull);
  });

  test('端口非法时返回 null —— 转发没有端口就完全没意义', () {
    // 与 ServerDraft 的字段级降级不同：转发的端口不是可选字段。
    expect(parseSshForward('ssh -L abc:127.0.0.1:3306 root@db'), isNull);
    expect(parseSshForward('ssh -D xyz root@proxy'), isNull);
  });

  test('完全不是命令时返回 null', () {
    expect(parseSshForward('这是一段日志'), isNull);
    expect(parseSshForward(''), isNull);
  });

  test('IPv6 目标地址（三段式，带方括号）', () {
    final d = parseSshForward('ssh -L 8080:[::1]:80 root@host')!;
    expect(d.direction, TunnelDirection.local);
    expect(d.localPort, 8080);
    // 存进草稿的是裸地址，方括号只是 ssh 命令行用来消歧的记号。
    expect(d.remoteHost, '::1');
    expect(d.remotePort, 80);
  });

  test('IPv6 目标地址（两段式，省略本地端口）', () {
    final d = parseSshForward('ssh -L [2001:db8::1]:80 root@host')!;
    expect(d.remoteHost, '2001:db8::1');
    expect(d.remotePort, 80);
    expect(d.effectiveLocalPort, 80);
  });

  test('IPv6 目标地址 + -R 远程转发', () {
    final d = parseSshForward('ssh -R 8080:[::1]:80 root@host')!;
    expect(d.direction, TunnelDirection.remote);
    expect(d.localPort, 8080);
    expect(d.remoteHost, '::1');
    expect(d.remotePort, 80);
  });

  test('回归守卫：IPv4 各形态和 -D 不受切分逻辑改动影响', () {
    final a = parseSshForward('ssh -L 13306:127.0.0.1:3306 root@db')!;
    expect(a.localPort, 13306);
    expect(a.remoteHost, '127.0.0.1');
    expect(a.remotePort, 3306);

    final b = parseSshForward('ssh -L 0.0.0.0:13306:127.0.0.1:3306 root@db')!;
    expect(b.localPort, 13306);
    expect(b.remoteHost, '127.0.0.1');
    expect(b.remotePort, 3306);

    final c = parseSshForward('ssh -D 1080 root@proxy')!;
    expect(c.direction, TunnelDirection.socks5);
    expect(c.localPort, 1080);
    expect(c.remoteHost, isNull);
  });
}
