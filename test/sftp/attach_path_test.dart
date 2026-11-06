// test/sftp/attach_path_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/attach_path.dart';

void main() {
  group('sanitizeAttachName', () {
    test('空格换成下划线', () {
      expect(sanitizeAttachName('Screenshot 2026-09-02 10.30.15.png'),
          'Screenshot_2026-09-02_10.30.15.png');
    });

    test('shell 特殊字符换成下划线', () {
      expect(sanitizeAttachName('a\$b`c"d\'e.png'), 'a_b_c_d_e.png');
      expect(sanitizeAttachName('report(1).pdf'), 'report_1_.pdf');
      expect(sanitizeAttachName('a&b;c|d.txt'), 'a_b_c_d.txt');
    });

    test('中文 / 日文原样保留 —— 它们在 shell 里本来就安全', () {
      expect(sanitizeAttachName('报错截图.png'), '报错截图.png');
      expect(sanitizeAttachName('スクショ.png'), 'スクショ.png');
    });

    test('中文带空格：只动空格', () {
      expect(sanitizeAttachName('报错截图 (1).png'), '报错截图_1_.png');
    });

    test('连续特殊字符折叠成一个下划线', () {
      expect(sanitizeAttachName('a   b.png'), 'a_b.png');
      expect(sanitizeAttachName('a \$ b.png'), 'a_b.png');
    });

    test('首尾的下划线去掉', () {
      expect(sanitizeAttachName(' foo.png '), 'foo.png');
      expect(sanitizeAttachName('  .bashrc'), '.bashrc');
    });

    test('多重扩展名保留', () {
      expect(sanitizeAttachName('my archive.tar.gz'), 'my_archive.tar.gz');
    });

    test('安全的名字原样返回 —— 调用方据此决定要不要提示改名', () {
      expect(sanitizeAttachName('report.png'), 'report.png');
      expect(sanitizeAttachName('a-b_c.2026.log'), 'a-b_c.2026.log');
    });

    test('全是特殊字符时不返回空串', () {
      expect(sanitizeAttachName('***'), 'file');
      expect(sanitizeAttachName('   '), 'file');
    });

    test('控制字符也要清掉', () {
      expect(sanitizeAttachName('a\nb\tc.png'), 'a_b_c.png');
    });
  });

  group('nextAttachName（重名后缀）', () {
    test('有扩展名时插在扩展名之前', () {
      expect(nextAttachName('foo.png', 2), 'foo-2.png');
      expect(nextAttachName('foo.png', 3), 'foo-3.png');
    });

    test('多重扩展名只认最后一个点', () {
      expect(nextAttachName('a.tar.gz', 2), 'a.tar-2.gz');
    });

    test('无扩展名直接追加', () {
      expect(nextAttachName('README', 2), 'README-2');
    });

    test('点开头的隐藏文件不当成扩展名', () {
      expect(nextAttachName('.bashrc', 2), '.bashrc-2');
    });
  });

  group('buildAttachPath（远端绝对路径）', () {
    test('cwd 正常', () {
      expect(buildAttachPath(cwd: '/home/dk/proj', name: 'a.png'),
          '/home/dk/proj/a.png');
    });

    test('cwd 是根目录时不出现双斜杠', () {
      expect(buildAttachPath(cwd: '/', name: 'a.png'), '/a.png');
    });

    test('cwd 末尾多一个斜杠也不出现双斜杠', () {
      expect(buildAttachPath(cwd: '/home/dk/', name: 'a.png'),
          '/home/dk/a.png');
    });
  });

  group('buildInsertText（插进命令行的那串）', () {
    // 一律绝对路径。曾经 cwd 已知时插相对路径 `./name` —— 那对**终端 shell**
    // 成立（shell 的 cwd 就是上传目录），但对 **AI agent** 不成立：agent 执行
    // 工具时的 cwd 未必等于终端 cwd，`./name` 会解析到别处，于是「上传成功、
    // 路径却读不到」。绝对路径在任何 cwd 下都对，shell 里同样是合法参数。
    test('cwd 已知 → 绝对路径（不插相对路径 ./name）', () {
      expect(buildInsertText(cwd: '/home/dk/proj', name: 'a.png'),
          '/home/dk/proj/a.png');
    });

    test('cwd 未知 → 退回 home 的绝对路径', () {
      expect(buildInsertText(cwd: null, name: 'a.png', home: '/home/dk'),
          '/home/dk/a.png');
    });

    test('cwd 是根目录 → 绝对路径，不出现双斜杠', () {
      expect(buildInsertText(cwd: '/', name: 'a.png'), '/a.png');
    });

    test('cwd 末尾带斜杠也不出现双斜杠', () {
      expect(buildInsertText(cwd: '/home/dk/', name: 'a.png'),
          '/home/dk/a.png');
    });
  });
}
