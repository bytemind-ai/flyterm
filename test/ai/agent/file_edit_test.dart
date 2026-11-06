import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/file_edit.dart';

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

/// 造一份 [buildReadForEditCommand] 会得到的 stdout。
String _payload(String content, {String? sha, int? size}) {
  final bytes = utf8.encode(content);
  return '${sha ?? _sha(content)}\n'
      '${size ?? bytes.length}\n'
      '${base64.encode(bytes)}';
}

void main() {
  group('applyEdit', () {
    test('唯一命中时替换', () {
      final r = applyEdit(
        content: 'listen 80;\nserver_name a;\n',
        oldString: 'listen 80;',
        newString: 'listen 8080;',
      );
      expect(r.error, isNull);
      expect(r.content, equals('listen 8080;\nserver_name a;\n'));
      expect(r.atLine, equals(1));
    });

    test('命中 0 次时不改，回错误', () {
      final r = applyEdit(
        content: 'listen 80;\n',
        oldString: 'listen 443;',
        newString: 'x',
      );
      expect(r.content, isNull);
      expect(r.error, contains('not found'));
    });

    test('命中多次时不改，且说明出现几次', () {
      final r = applyEdit(
        content: 'a\nfoo\nb\nfoo\n',
        oldString: 'foo',
        newString: 'bar',
      );
      expect(r.content, isNull,
          reason: '绝不能改第一处了事——那是静默改错地方');
      expect(r.error, contains('2'));
    });

    test('空 old_string 被拒（会命中无数次）', () {
      final r = applyEdit(content: 'abc', oldString: '', newString: 'x');
      expect(r.content, isNull);
      expect(r.error, isNotEmpty);
    });

    test('空 new_string 表示删除', () {
      final r = applyEdit(
        content: 'keep\ndrop me\nkeep2\n',
        oldString: 'drop me\n',
        newString: '',
      );
      expect(r.content, equals('keep\nkeep2\n'));
    });

    test('多行 old_string 的行号取起始行', () {
      final r = applyEdit(
        content: 'l1\nl2\nl3\nl4\n',
        oldString: 'l2\nl3',
        newString: 'X',
      );
      expect(r.atLine, equals(2));
      expect(r.content, equals('l1\nX\nl4\n'));
    });

    test('old_string 与 new_string 相同时视为无变化', () {
      final r = applyEdit(
        content: 'same\n',
        oldString: 'same',
        newString: 'same',
      );
      expect(r.content, isNull);
      expect(r.error, contains('identical'),
          reason: '让它白走一次审批不如直接告诉它没有变化');
    });

    test('替换结果超过大小上限时被拒', () {
      final big = 'x' * (kMaxEditFileBytes + 10);
      final r = applyEdit(content: 'seed', oldString: 'seed', newString: big);
      expect(r.content, isNull);
      expect(r.error, contains('too large'));
    });

    test('替换只发生一次，即使 new_string 里含 old_string', () {
      final r = applyEdit(
        content: 'a=1\n',
        oldString: 'a=1',
        newString: 'a=1 # patched',
      );
      expect(r.content, equals('a=1 # patched\n'),
          reason: '不能再把结果里新出现的 a=1 又替换一遍');
    });

    test('大小上限与输出上限绑定：base64 膨胀后必须装得下', () {
      const worstBase64 = 4 * ((kMaxEditFileBytes + 2) ~/ 3);
      expect(worstBase64 + 64 + 1 + 5 + 1, lessThanOrEqualTo(kMaxOutputBytes),
          reason: 'kMaxEditFileBytes 这个数字的全部理由就是这条不等式；'
              '改大它会让读取悄悄踩上截断，而截断只表现为一条误导性的 '
              'checksum 错误');
    });
  });

  group('parseEditFileRead', () {
    test('正常载荷解析并通过哈希校验', () {
      const text = 'server {\n  listen 80;\n}\n';
      final r = parseEditFileRead(_payload(text));
      expect(r.error, isNull);
      expect(r.content, equals(text));
      expect(r.sha256, equals(_sha(text)));
    });

    test('哈希不符时拒绝——这是脱敏/截断动过字节的总闸', () {
      const text = 'password: hunter2\n';
      // 模拟内容被等长替换（不触发大小校验，专门测哈希这道闸）：
      // 'hunter2' 与 'XXXXXXX' 同为 7 字节，字节总长与上报 size 一致。
      const tampered = 'password: XXXXXXX\n';
      final payload = '${_sha(text)}\n'
          '${utf8.encode(text).length}\n'
          '${base64.encode(utf8.encode(tampered))}';
      final r = parseEditFileRead(payload);
      expect(r.content, isNull);
      expect(r.error, contains('checksum'));
    });

    test('上报的 size 与解码后的字节数对不上时拒绝', () {
      // 上报 size 和实际解码长度不一致，说明中间环节动过字节数
      // （而不只是内容）——这是比对 checksum 更早的一道防线，
      // 防止后续任何基于 size 的假设（含 kMaxEditFileBytes 判断）被绕过。
      const text = 'hello';
      final payload = '${_sha(text)}\n'
          '${utf8.encode(text).length + 1}\n'
          '${base64.encode(utf8.encode(text))}';
      final r = parseEditFileRead(payload);
      expect(r.content, isNull);
      expect(r.error, isNotEmpty);
      expect(r.error, isNot(contains('checksum')),
          reason: '这是 size 对不上，不是 checksum 对不上，错误信息不该混为一谈');
    });

    test('文件超过上限时拒绝，且提示改用 bash', () {
      final r = parseEditFileRead(_payload('x', size: kMaxEditFileBytes + 1));
      expect(r.content, isNull);
      expect(r.error, contains('bash'));
    });

    test('base64 被截断时拒绝', () {
      const text = 'abcdefghijklmnop';
      final full = _payload(text);
      final cut = full.substring(0, full.length - 6);
      final r = parseEditFileRead(cut);
      expect(r.content, isNull);
      expect(r.error, isNotEmpty);
    });

    test('非 UTF-8 文件被拒（不能当文本编辑）', () {
      final bytes = [0xff, 0xfe, 0x00, 0x01];
      final payload = '${sha256.convert(bytes)}\n'
          '${bytes.length}\n'
          '${base64.encode(bytes)}';
      final r = parseEditFileRead(payload);
      expect(r.content, isNull);
      expect(r.error, contains('UTF-8'));
    });

    test('行数不足时拒绝，不下标越界', () {
      expect(parseEditFileRead('').error, isNotEmpty);
      expect(parseEditFileRead('onlysha').error, isNotEmpty);
      expect(parseEditFileRead('sha\n12').error, isNotEmpty);
    });

    test('空文件是合法的', () {
      final r = parseEditFileRead(_payload(''));
      expect(r.error, isNull);
      expect(r.content, equals(''));
    });
  });

  group('buildReadForEditCommand', () {
    test('路径被单引号包裹，不用 base64 -w0', () {
      final c = buildReadForEditCommand("/etc/n g/x'y.conf");
      expect(c, contains(r"'/etc/n g/x'\''y.conf'"));
      // BusyBox 的 base64 没有 -w，用 tr 去换行才通用
      expect(c.contains('-w0'), isFalse);
      expect(c, contains('tr -d'));
    });

    test('三段输出的顺序是 sha / size / base64', () {
      final c = buildReadForEditCommand('/f');
      expect(c.indexOf('sha256sum'), lessThan(c.indexOf('wc -c')));
      expect(c.indexOf('wc -c'), lessThan(c.indexOf('base64')));
    });
  });

  group('buildWriteFileCommand', () {
    test('无 expectedSha 时不做哈希校验（write_file 可以新建）', () {
      final c = buildWriteFileCommand('/f', utf8.encode('hi'), seq: 1);
      expect(c.contains('sha256sum'), isFalse);
      expect(c, contains('base64 -d'));
    });

    test('带 expectedSha 时在同一条命令里先验后写', () {
      final c = buildWriteFileCommand('/f', utf8.encode('hi'),
          expectedSha: 'deadbeef', seq: 1);
      expect(c, contains('deadbeef'));
      expect(c.indexOf('sha256sum'), lessThan(c.indexOf('base64 -d')),
          reason: '拆成两次往返的话中间那段时间足够别的进程改动文件');
      expect(c, contains('exit $kStaleFileExitCode'));
    });

    test('写入前先备份，且用重定向而非 mv', () {
      final c =
          buildWriteFileCommand('/etc/x.conf', utf8.encode('hi'), seq: 1);
      expect(c, contains('.flyterm.bak'));
      expect(c, contains('> '), reason: '原地截断写入才能保住 inode 的权限与属主');
      expect(c.contains('mv '), isFalse,
          reason: 'mv 一个临时文件过去会把 600 的配置变成默认权限');
    });

    test('备份路径的目录前缀在四种路径形态下都正确——尤其是根目录文件', () {
      // seq 固定为 9，验证的重点仍是 dir 前缀的四种边界；序号本身另有
      // 专门的「带序号的备份路径」分组覆盖。
      const cases = {
        '/etc/nginx/x.conf': '/etc/nginx/.x.conf.flyterm.bak.9',
        '/f': '/.f.flyterm.bak.9', // 根目录文件：dir 必须带上这个 '/'，
        // 否则会退化成相对路径 `.f.flyterm.bak`，指向远端进程的 cwd 而不是
        // 根目录——cwd 常是只读目录，cp 失败会让根目录下的文件永远编不了。
        'f': '.f.flyterm.bak.9', // 纯相对文件名：dir 为空，备份也是相对的
        'a/b.conf': 'a/.b.conf.flyterm.bak.9',
      };
      for (final entry in cases.entries) {
        final c =
            buildWriteFileCommand(entry.key, utf8.encode('x'), seq: 9);
        final m = RegExp(r"cp -p -- '[^']*' '([^']*)'").firstMatch(c);
        expect(m, isNotNull, reason: 'path=${entry.key}');
        expect(m!.group(1), equals(entry.value), reason: 'path=${entry.key}');
      }
    });

    test('base64 载荷被单引号包裹', () {
      final c = buildWriteFileCommand('/f', utf8.encode('hi'), seq: 1);
      final b64 = base64.encode(utf8.encode('hi'));
      expect(c, contains("'$b64'"));
    });

    test('内容里的引号与换行不会破坏命令', () {
      final c =
          buildWriteFileCommand('/f', utf8.encode("a'b\nc\$d`e"), seq: 1);
      // base64 字母表只有 A-Za-z0-9+/=，天然不含任何 shell 特殊字符
      final payload = RegExp(r"'([A-Za-z0-9+/=]+)'").firstMatch(c);
      expect(payload, isNotNull);
      expect(utf8.decode(base64.decode(payload!.group(1)!)),
          equals("a'b\nc\$d`e"));
    });
  });

  group('带序号的备份路径', () {
    test('普通路径', () {
      expect(
        dotBackupPathForSeq('/etc/nginx/nginx.conf', 7),
        equals('/etc/nginx/.nginx.conf.flyterm.bak.7'),
      );
    });

    test('根目录下的文件——dir 必须留住那个斜杠', () {
      // 丢掉斜杠会让备份退化成相对路径，落到 agent 的 cwd 里；
      // cp 失败 → `|| exit 1` → 根目录下的文件永远编辑不了。
      expect(dotBackupPathForSeq('/f', 3), equals('/.f.flyterm.bak.3'));
    });

    test('纯相对文件名——dir 必须是空串', () {
      expect(dotBackupPathForSeq('f', 3), equals('.f.flyterm.bak.3'));
    });

    test('不同 seq 给出不同路径——同一文件改两次都能回退', () {
      final a = dotBackupPathForSeq('/etc/app.conf', 1);
      final b = dotBackupPathForSeq('/etc/app.conf', 2);
      expect(a, isNot(equals(b)));
    });

    test('仍以点开头——nginx 的 include *.conf 不能把备份 glob 进去', () {
      final p = dotBackupPathForSeq('/etc/nginx/conf.d/site.conf', 5);
      final base = p.split('/').last;
      expect(base, startsWith('.'));
    });
  });

  group('buildWriteFileCommand 带 seq', () {
    test('命令里出现带序号的备份路径', () {
      final cmd = buildWriteFileCommand('/etc/app.conf', [104, 105], seq: 4);
      expect(cmd, contains('.app.conf.flyterm.bak.4'));
    });

    test('文件不存在时跳过备份的判断还在', () {
      final cmd = buildWriteFileCommand('/etc/app.conf', [104], seq: 1);
      expect(cmd, contains('[ -e '));
      expect(cmd, contains('|| exit 1'));
    });
  });

  group('buildUndoCommand', () {
    test('把备份拷回原路径，保留权限位', () {
      final cmd = buildUndoCommand(
          '/etc/app.conf', '/etc/.app.conf.flyterm.bak.3');
      expect(cmd, contains('cp -p'));
      expect(cmd, contains('.app.conf.flyterm.bak.3'));
      expect(cmd, contains('/etc/app.conf'));
      // mv 会换 inode、丢权限位
      expect(cmd, isNot(contains('mv ')));
    });

    test('备份不存在时用专门的退出码，不是通用失败', () {
      final cmd = buildUndoCommand('/etc/app.conf', '/etc/.bak');
      expect(cmd, contains('[ -e '));
      expect(cmd, contains('exit $kMissingBackupExitCode'));
    });

    test('整条包在大括号组里——wrapForSsh 的 cd 失败要能短路掉它', () {
      final cmd = buildUndoCommand('/etc/app.conf', '/etc/.bak');
      expect(cmd, startsWith('{ '));
      expect(cmd, endsWith('; }'));
    });

    test('路径含空格时被正确引用', () {
      final cmd = buildUndoCommand('/etc/my app.conf', '/etc/.my app.bak');
      expect(cmd, contains("'/etc/my app.conf'"));
      expect(cmd, contains("'/etc/.my app.bak'"));
    });
  });
}
