import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_server_installer.dart';

void main() {
  group('AqtInstallResult', () {
    test('success constructor', () {
      const r = AqtInstallResult.success();
      expect(r.status, AqtInstallStatus.success);
      expect(r.errorReason, isNull);
    });

    test('declined constructor', () {
      const r = AqtInstallResult.declined();
      expect(r.status, AqtInstallStatus.declined);
      expect(r.errorReason, isNull);
    });

    test('error constructor with reason', () {
      const r = AqtInstallResult.error('unsupported arch riscv64');
      expect(r.status, AqtInstallStatus.error);
      expect(r.errorReason, 'unsupported arch riscv64');
    });
  });

  group('arch detection parsing', () {
    test('parseArch maps uname -m output', () {
      expect(AqtServerInstaller.parseArch('x86_64\n'), 'x86_64');
      expect(AqtServerInstaller.parseArch('aarch64\n'), 'aarch64');
      expect(AqtServerInstaller.parseArch('arm64\n'), 'aarch64'); // macOS naming
      expect(AqtServerInstaller.parseArch('amd64\n'), 'x86_64');  // BSD naming
      expect(AqtServerInstaller.parseArch('riscv64\n'), isNull);
      expect(AqtServerInstaller.parseArch('i686\n'), isNull);
      expect(AqtServerInstaller.parseArch(''), isNull);
    });
  });

  group('asset path resolution', () {
    test('assetPathFor returns correct .gz path per arch', () {
      // Assets are gzipped (saves install bandwidth).
      // Remote gunzip decompresses after SFTP upload, before mv → final.
      expect(
        AqtServerInstaller.assetPathFor('x86_64'),
        'assets/flyterm-server/flyterm-server-linux-x86_64.gz',
      );
      expect(
        AqtServerInstaller.assetPathFor('aarch64'),
        'assets/flyterm-server/flyterm-server-linux-aarch64.gz',
      );
    });
  });

  group('SelfInstallOutcome.parse', () {
    test('parses INSTALL_OK with port/pid/version', () {
      final r = SelfInstallOutcome.parse(
        stdout: 'INSTALL_OK port=12345 pid=99 version=0.2.0-abc123\n',
        stderr: '',
        exitCode: 0,
      );
      expect(r.success, true);
      expect(r.port, 12345);
      expect(r.pid, 99);
      expect(r.version, '0.2.0-abc123');
      expect(r.errorReason, null);
    });

    test('parses INSTALL_ERR with reason', () {
      final r = SelfInstallOutcome.parse(
        stdout: 'INSTALL_ERR reason=daemon_info_timeout log_tail=foo bar\n',
        stderr: '',
        exitCode: 1,
      );
      expect(r.success, false);
      expect(r.errorReason, contains('daemon_info_timeout'));
      expect(r.port, null);
    });

    test('falls back to stderr when no INSTALL_* line', () {
      final r = SelfInstallOutcome.parse(
        stdout: '',
        stderr: 'flyterm-server: --install: command not found\n',
        exitCode: 127,
      );
      expect(r.success, false);
      expect(r.errorReason, contains('command not found'));
    });

    test('falls back to stdout when neither stderr nor INSTALL_* present', () {
      final r = SelfInstallOutcome.parse(
        stdout: 'garbage output\n',
        stderr: '',
        exitCode: 42,
      );
      expect(r.success, false);
      expect(r.errorReason, contains('garbage output'));
    });
  });
}
