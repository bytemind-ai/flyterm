import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/transfer_guard.dart';

void main() {
  group('checkTransferPath', () {
    test('绝对路径放行', () {
      final r = checkTransferPath('/var/log/app.log');
      expect(r.ok, isTrue);
      expect(r.credentialDeny, isFalse);
    });

    test('相对路径拒绝', () {
      final r = checkTransferPath('var/log/app.log');
      expect(r.ok, isFalse);
      expect(r.error, contains('absolute'));
    });

    test('空路径拒绝', () {
      expect(checkTransferPath('   ').ok, isFalse);
    });

    test('~ 开头拒绝 —— SFTP 不做 shell 展开，传上去会真的建一个叫 ~ 的目录',
        () {
      final r = checkTransferPath('~/.bashrc');
      expect(r.ok, isFalse);
      expect(r.error, contains('absolute'));
    });

    test('凭据路径：放行但标记 credentialDeny', () {
      for (final p in [
        '/home/u/.ssh/id_rsa',
        '/srv/app/.env.production',
        '/etc/shadow',
        '/home/u/.aws/credentials',
      ]) {
        final r = checkTransferPath(p);
        expect(r.ok, isTrue, reason: '$p 不该被硬拒 —— 落盘是用户自己的选择');
        expect(r.credentialDeny, isTrue, reason: '$p 应命中凭据清单');
      }
    });

    test('公钥不命中', () {
      final r = checkTransferPath('/home/u/.ssh/id_rsa.pub');
      expect(r.credentialDeny, isFalse);
    });
  });

  group('transferBackupPath', () {
    test('备份名带 seq，与 file_edit 同一套编号', () {
      expect(transferBackupPath('/www/img/logo.png', 7),
          equals('/www/img/logo.png.flyterm.bak.7'));
    });

    test('根目录下的文件', () {
      expect(transferBackupPath('/f.txt', 0), equals('/f.txt.flyterm.bak.0'));
    });
  });

  group('joinRemote', () {
    test('普通目录', () {
      expect(joinRemote('/www/img', 'a.png'), equals('/www/img/a.png'));
    });

    test('带尾斜杠的目录不产生双斜杠', () {
      expect(joinRemote('/www/img/', 'a.png'), equals('/www/img/a.png'));
    });

    test('根目录', () {
      expect(joinRemote('/', 'a.png'), equals('/a.png'));
    });
  });
}
