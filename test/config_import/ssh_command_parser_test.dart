import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/ssh_command_parser.dart';

void main() {
  test('解析 user@host 形式', () {
    final d = parseSshCommand('ssh root@example.com')!;
    expect(d.host, 'example.com');
    expect(d.username, 'root');
    expect(d.provenance.keys, containsAll(['host', 'username']));
  });

  test('解析 -p 端口（带空格）', () {
    final d = parseSshCommand('ssh -p 2222 root@example.com')!;
    expect(d.port, 2222);
  });

  test('解析 -p 端口（不带空格）', () {
    // getopt 允许 -p2222 这种紧贴写法，真实世界里很常见。
    final d = parseSshCommand('ssh -p2222 root@example.com')!;
    expect(d.port, 2222);
  });

  test('解析 -J 跳板机', () {
    final d = parseSshCommand('ssh -J jump@bastion root@example.com')!;
    expect(d.jumpHostAlias, 'jump@bastion');
    expect(d.host, 'example.com');
  });

  test('解析 -i 密钥路径并标记需手动选密钥', () {
    final d = parseSshCommand('ssh -i ~/.ssh/id_rsa root@example.com')!;
    expect(d.identityFilePath, '~/.ssh/id_rsa');
    expect(d.needsManualKey, isTrue);
  });

  test('解析 -l 用户名', () {
    final d = parseSshCommand('ssh -l deploy example.com')!;
    expect(d.username, 'deploy');
    expect(d.host, 'example.com');
  });

  test('没有 user@ 时只给 host', () {
    final d = parseSshCommand('ssh example.com')!;
    expect(d.host, 'example.com');
    expect(d.username, isNull);
  });

  test('name 从 host 推导', () {
    final d = parseSshCommand('ssh root@web-1.example.com')!;
    expect(d.name, 'web-1.example.com');
  });

  test('开头没有 ssh 也能解析 —— 用户常常只粘参数部分', () {
    final d = parseSshCommand('-p 2222 root@example.com')!;
    expect(d.host, 'example.com');
    expect(d.port, 2222);
  });

  test('端口非法时丢弃该字段', () {
    final d = parseSshCommand('ssh -p abc root@example.com')!;
    expect(d.host, 'example.com');
    expect(d.port, isNull);
  });

  test('完全认不出时返回 null', () {
    expect(parseSshCommand('这是一段日志'), isNull);
    expect(parseSshCommand('ssh'), isNull);
    expect(parseSshCommand(''), isNull);
  });

  test('忽略只有转发参数的命令 —— 那是 SshForwardParser 的活', () {
    // -L 的值里带冒号和数字，不该被误当成 host。
    final d = parseSshCommand('ssh -L 13306:127.0.0.1:3306 root@example.com')!;
    expect(d.host, 'example.com');
  });

  test('解析方括号包裹的 IPv6 地址 —— 存储时去掉方括号', () {
    final d = parseSshCommand('ssh root@[2001:db8::1]')!;
    expect(d.host, '2001:db8::1');
  });

  test('解析裸写的 IPv6 简写 ::1', () {
    final d = parseSshCommand('ssh root@::1')!;
    expect(d.host, '::1');
  });

  test('IPv6 + -p 端口同时解析正确', () {
    final d = parseSshCommand('ssh -p 2222 root@[2001:db8::1]')!;
    expect(d.host, '2001:db8::1');
    expect(d.port, 2222);
  });

  test('回归：普通域名 host 不受 IPv6 放宽影响', () {
    final d = parseSshCommand('ssh root@example.com')!;
    expect(d.host, 'example.com');
  });

  test('回归：IPv4 host 不受 IPv6 放宽影响', () {
    final d = parseSshCommand('ssh root@10.0.0.5')!;
    expect(d.host, '10.0.0.5');
  });

  test('回归：放宽 IPv6 之后，中文日志仍然认不出', () {
    expect(parseSshCommand('这是一段日志'), isNull);
  });

  test('中文说明里夹一个合法 IP 不该被当成 ssh 命令', () {
    // 单独一个「形状像主机」的 token 不构成「认出了一条 ssh 命令」的证据，
    // 它可能只是文本里恰好出现的地址 —— 日志、运维说明里很常见。
    expect(parseSshCommand('服务器在 1.2.3.4 端口 2222'), isNull);
  });

  test('中文日志里夹一个合法 IP，同上', () {
    expect(parseSshCommand('日志里提到 10.0.0.5 这台机器'), isNull);
  });

  test('回归：裸 user@host（无 ssh 前缀无选项）仍能解析 —— @ 本身是证据', () {
    final d = parseSshCommand('root@example.com')!;
    expect(d.host, 'example.com');
  });

  test('回归：无 ssh 前缀但命中识别的选项仍能解析 —— 选项本身是证据', () {
    final d = parseSshCommand('-p 2222 root@example.com')!;
    expect(d.host, 'example.com');
    expect(d.port, 2222);
  });
}
