import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/sensitive_stripper.dart';

void main() {
  test('剥掉 OpenSSH 私钥块，保留其余文本', () {
    const input = '''
Host web
  HostName 1.2.3.4
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdzc2gt
cnNhAAAAAwEAAQAAAYEAwKJ8Z3Yl5V1Q9nL0bQ9K8sT7vX2mN4pR6wE1yU3iO5aD8fG
-----END OPENSSH PRIVATE KEY-----
  User root
''';
    final out = stripSensitive(input);
    expect(out.text, contains('HostName 1.2.3.4'));
    expect(out.text, contains('User root'));
    expect(out.text, isNot(contains('BEGIN OPENSSH PRIVATE KEY')));
    expect(out.text, isNot(contains('b3BlbnNzaC1rZXktdjEA')));
    expect(out.strippedPrivateKey, isTrue);
  });

  test('剥掉 RSA / EC / PGP 等各类 PEM 私钥块', () {
    for (final label in [
      'RSA PRIVATE KEY',
      'EC PRIVATE KEY',
      'DSA PRIVATE KEY',
      'PRIVATE KEY',
      'PGP PRIVATE KEY BLOCK',
    ]) {
      final input = '-----BEGIN $label-----\nAAAA\n-----END $label-----';
      final out = stripSensitive(input);
      expect(out.text.trim(), isEmpty, reason: '$label 应当被整块剥掉');
      expect(out.strippedPrivateKey, isTrue, reason: '$label 应当被标记');
    }
  });

  test('剥掉像密码的行', () {
    const input = '''
Host web
  HostName 1.2.3.4
  password: hunter2
  密码 hunter2
''';
    final out = stripSensitive(input);
    expect(out.text, contains('HostName 1.2.3.4'));
    expect(out.text, isNot(contains('hunter2')));
    expect(out.strippedPassword, isTrue);
  });

  test('不误伤 ssh config 的正常字段', () {
    const input = '''
Host web
  HostName 1.2.3.4
  Port 2222
  User root
  ProxyJump bastion
  IdentityFile ~/.ssh/id_rsa
''';
    final out = stripSensitive(input);
    expect(out.text, contains('ProxyJump bastion'));
    // IdentityFile 是**路径**不是密钥内容，必须保留 —— 它要被解析成
    // needsManualKey 的依据。
    expect(out.text, contains('IdentityFile ~/.ssh/id_rsa'));
    expect(out.strippedPrivateKey, isFalse);
    expect(out.strippedPassword, isFalse);
  });

  test('没有敏感内容时原样返回', () {
    const input = 'ssh -p 2222 root@example.com';
    final out = stripSensitive(input);
    expect(out.text, input);
    expect(out.hasStripped, isFalse);
  });

  test('剥掉带前缀的密码变量 —— 关键词不锚定行首', () {
    // 漏洞 1：旧正则要求 password/passwd/pwd/密码 紧跟行首空白，于是
    // DB_PASSWORD / export PASSWORD / MYSQL_PWD / user_password 这类真实
    // 世界里极常见的写法全部漏网。
    const input = '''
Host web
  HostName 1.2.3.4
DB_PASSWORD=supersecret
export PASSWORD=hunter2
MYSQL_PWD=anothersecret
  user_password: thirdsecret
''';
    final out = stripSensitive(input);
    expect(out.text, contains('HostName 1.2.3.4'));
    expect(out.text, isNot(contains('supersecret')));
    expect(out.text, isNot(contains('hunter2')));
    expect(out.text, isNot(contains('anothersecret')));
    expect(out.text, isNot(contains('thirdsecret')));
    expect(out.strippedPassword, isTrue);
  });

  test('截断的 PEM 私钥块（只有 BEGIN 没有 END）也要被剥掉', () {
    // 漏洞 2（更严重）：旧正则要求 BEGIN/END 成对出现才匹配，用户只粘贴了
    // 半截私钥（复制到一半）时，私钥内容会原样放行进入 LLM 兜底层。
    const input = '''
Host web
  HostName 1.2.3.4
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA1234567890SECRETKEYMATERIALSHOULDNOTLEAK
''';
    final out = stripSensitive(input);
    expect(out.text, contains('HostName 1.2.3.4'));
    expect(out.text, isNot(contains('BEGIN RSA PRIVATE KEY')));
    expect(out.text, isNot(contains('SECRETKEYMATERIALSHOULDNOTLEAK')));
    expect(out.strippedPrivateKey, isTrue);
  });

  test('回归守卫：PasswordAuthentication 这类 ssh config 开关不被误剥', () {
    const input = '''
Host web
  HostName 1.2.3.4
  PasswordAuthentication yes
  IdentityFile ~/.ssh/id_rsa
''';
    final out = stripSensitive(input);
    expect(out.text, contains('PasswordAuthentication yes'));
    // IdentityFile 是路径不是密钥内容，必须保留。
    expect(out.text, contains('IdentityFile ~/.ssh/id_rsa'));
    expect(out.strippedPassword, isFalse);
    expect(out.strippedPrivateKey, isFalse);
  });

  test('同一行里配置开关夹带真密码时仍要剥 —— 挖空开关而非整行放行', () {
    // 漏洞 3：如果排除判据是「这一行含 passwordauthentication 子串就整行
    // 放行」，这种把开关和真实密码写在同一行的情况会完全逃过剥离。
    const input = '''
Host web
  HostName 1.2.3.4
  PasswordAuthentication yes  # 默认密码: hunter2
''';
    final out = stripSensitive(input);
    expect(out.text, contains('HostName 1.2.3.4'));
    expect(out.text, isNot(contains('hunter2')));
    expect(out.strippedPassword, isTrue);
  });

  test('回归守卫：PasswordAuthentication no 也不被误剥', () {
    const input = '''
Host web
  HostName 1.2.3.4
  PasswordAuthentication no
''';
    final out = stripSensitive(input);
    expect(out.text, contains('PasswordAuthentication no'));
    expect(out.strippedPassword, isFalse);
  });
}
