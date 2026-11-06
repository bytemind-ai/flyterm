import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/ssh_config_parser.dart';

void main() {
  test('解析单个 Host 块的全部常用字段', () {
    const input = '''
Host web-1
  HostName 10.0.0.5
  Port 2222
  User deploy
  ProxyJump bastion
  IdentityFile ~/.ssh/id_ed25519
''';
    final drafts = parseSshConfig(input);
    expect(drafts, hasLength(1));
    final d = drafts.single;
    expect(d.name, 'web-1');
    expect(d.host, '10.0.0.5');
    expect(d.port, 2222);
    expect(d.username, 'deploy');
    expect(d.jumpHostAlias, 'bastion');
    expect(d.identityFilePath, '~/.ssh/id_ed25519');
    expect(d.needsManualKey, isTrue);
    expect(d.provenance.keys, contains('host'));
    expect(d.provenance.keys, contains('jumpHostAlias'));
  });

  test('没有 HostName 时用 Host 别名当主机名', () {
    const input = 'Host example.com\n  User root';
    final d = parseSshConfig(input).single;
    // 这是 ssh 自己的行为：HostName 缺省时就用 Host 那个词去连。
    expect(d.host, 'example.com');
    expect(d.name, 'example.com');
  });

  test('跳过 Host * 通配块 —— 它不是一台机器', () {
    const input = '''
Host *
  ServerAliveInterval 60
  User defaultuser

Host web-1
  HostName 10.0.0.5
''';
    final drafts = parseSshConfig(input);
    expect(drafts, hasLength(1));
    expect(drafts.single.name, 'web-1');
  });

  test('跳过任何含通配符的 Host', () {
    const input = '''
Host *.internal
  User a

Host web-?
  User b

Host real
  HostName 1.2.3.4
''';
    final drafts = parseSshConfig(input);
    expect(drafts.map((d) => d.name), ['real']);
  });

  test('解析多个 Host 块', () {
    const input = '''
Host web-1
  HostName 10.0.0.5

Host db-1
  HostName 10.0.0.6
  Port 2200
''';
    final drafts = parseSshConfig(input);
    expect(drafts, hasLength(2));
    expect(drafts[0].host, '10.0.0.5');
    expect(drafts[1].host, '10.0.0.6');
    expect(drafts[1].port, 2200);
  });

  test('关键字大小写不敏感', () {
    const input = '''
host web-1
  hostname 10.0.0.5
  PORT 2222
  uSeR deploy
''';
    final d = parseSshConfig(input).single;
    expect(d.host, '10.0.0.5');
    expect(d.port, 2222);
    expect(d.username, 'deploy');
  });

  test('支持 key=value 写法', () {
    const input = 'Host web\n  HostName=10.0.0.5\n  Port=2222';
    final d = parseSshConfig(input).single;
    expect(d.host, '10.0.0.5');
    expect(d.port, 2222);
  });

  test('忽略注释与空行', () {
    const input = '''
# 这是注释
Host web-1

  # 缩进的注释
  HostName 10.0.0.5
''';
    final d = parseSshConfig(input).single;
    expect(d.host, '10.0.0.5');
  });

  test('Include 指令被记录但不跟随', () {
    const input = '''
Include ~/.ssh/config.d/*

Host web-1
  HostName 10.0.0.5
''';
    final result = parseSshConfigDetailed(input);
    expect(result.drafts, hasLength(1));
    // 必须告诉用户有东西没被读到，静默忽略会让他以为导全了。
    expect(result.sawInclude, isTrue);
  });

  test('端口非法时丢弃该字段但保留其余 —— 字段级降级', () {
    const input = 'Host web\n  HostName 10.0.0.5\n  Port 不是数字';
    final d = parseSshConfig(input).single;
    expect(d.host, '10.0.0.5');
    expect(d.port, isNull);
    expect(d.provenance.containsKey('port'), isFalse);
  });

  test('完全不是 ssh config 时返回空列表', () {
    final drafts = parseSshConfig('这是一段日志\nERROR connection refused');
    expect(drafts, isEmpty);
  });

  test('Host 行给出多个别名时只取第一个 —— 不产出带空格的名字', () {
    const input = '''
Host web-1 web-1.internal
  HostName 10.0.0.5
''';
    final drafts = parseSshConfig(input);
    expect(drafts, hasLength(1));
    expect(drafts.single.name, 'web-1');
  });

  test('多别名里后续段是通配也不影响第一段生效', () {
    const input = '''
Host web-1 *.internal
  HostName 10.0.0.5
''';
    final drafts = parseSshConfig(input);
    expect(drafts, hasLength(1));
    expect(drafts.single.name, 'web-1');
  });

  test('回归：Host * 单独一行仍整块跳过', () {
    const input = '''
Host *
  User defaultuser

Host web-1
  HostName 10.0.0.5
''';
    final drafts = parseSshConfig(input);
    expect(drafts, hasLength(1));
    expect(drafts.single.name, 'web-1');
  });

  test('回归：Host *.internal 单独一行仍跳过', () {
    const input = '''
Host *.internal
  User a

Host real
  HostName 1.2.3.4
''';
    final drafts = parseSshConfig(input);
    expect(drafts.map((d) => d.name), ['real']);
  });
}
