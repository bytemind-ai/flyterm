import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/shell_guard.dart';

void main() {
  group('hasShellMetachar', () {
    test('简单命令不含元字符', () {
      expect(hasShellMetachar('systemctl status nginx'), isFalse);
      expect(hasShellMetachar('ls -la /var/log'), isFalse);
      expect(hasShellMetachar('journalctl -u nginx --no-pager -n 50'), isFalse);
    });

    test('每个元字符都被检出', () {
      expect(hasShellMetachar('ls; rm -rf /'), isTrue);
      expect(hasShellMetachar('ls && rm -rf /'), isTrue);
      expect(hasShellMetachar('ls || true'), isTrue);
      expect(hasShellMetachar('ps aux | grep nginx'), isTrue);
      expect(hasShellMetachar('echo `whoami`'), isTrue);
      expect(hasShellMetachar(r'echo $(whoami)'), isTrue);
      expect(hasShellMetachar('cat a > b'), isTrue);
      expect(hasShellMetachar('cat a >> b'), isTrue);
      expect(hasShellMetachar('cat < a'), isTrue);
      expect(hasShellMetachar('sleep 5 &'), isTrue);
      expect(hasShellMetachar('ls\nrm -rf /'), isTrue);
      expect(hasShellMetachar('ls\r\nrm'), isTrue);
    });

    test('引号内的元字符也算命中 —— 我们不做 shell 解析，宁可多问', () {
      expect(hasShellMetachar('echo "a;b"'), isTrue);
      expect(hasShellMetachar("grep 'foo|bar' /var/log/x"), isTrue);
    });

    test('变量展开不算元字符', () {
      expect(hasShellMetachar(r'ls $HOME'), isFalse);
      expect(hasShellMetachar(r'echo ${PATH}'), isFalse);
    });
  });

  group('shellQuote', () {
    test('普通字符串包单引号', () {
      expect(shellQuote('/var/log'), equals(r"'/var/log'"));
    });

    test('内含单引号按 POSIX 转义', () {
      expect(shellQuote("it's"), equals(r"'it'\''s'"));
    });

    test('空字符串产生一对空引号', () {
      expect(shellQuote(''), equals("''"));
    });
  });

  group('wrapForSsh', () {
    test('无 cwd 时直接 base64 命令本身', () {
      final wrapped = wrapForSsh('uptime', cwd: null);
      expect(wrapped, startsWith('echo '));
      expect(wrapped, endsWith('|base64 -d|bash'));
      final b64 = wrapped.substring(5, wrapped.indexOf('|'));
      expect(utf8.decode(base64.decode(b64)), equals('uptime'));
    });

    test('有 cwd 时前置 cd', () {
      final wrapped = wrapForSsh('uptime', cwd: '/var/log');
      final b64 = wrapped.substring(5, wrapped.indexOf('|'));
      expect(utf8.decode(base64.decode(b64)), equals(r"cd '/var/log' && uptime"));
    });

    test('cwd 含单引号被正确转义', () {
      final wrapped = wrapForSsh('ls', cwd: "/tmp/it's");
      final b64 = wrapped.substring(5, wrapped.indexOf('|'));
      expect(utf8.decode(base64.decode(b64)), equals(r"cd '/tmp/it'\''s' && ls"));
    });
  });
}
