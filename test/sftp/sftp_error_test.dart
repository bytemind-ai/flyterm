import 'dart:async';
import 'dart:io';

// dartssh2 也导出一个 `SftpError`（协议基类），与本模块的 `SftpError`
// 同名。这里 hide 掉库里的那个，避免歧义导入。
import 'package:dartssh2/dartssh2.dart' hide SftpError;
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_error.dart';
import 'package:flyterm/sftp/sftp_service.dart' show SftpDisconnectedException;

void main() {
  group('SftpErrorKind 分类', () {
    SftpErrorKind kindOf(Object e) => SftpError.classify(e).kind;

    test('权限拒绝', () {
      expect(
        kindOf(SftpStatusError(3, 'Permission denied')), // SSH_FX_PERMISSION_DENIED
        SftpErrorKind.permissionDenied,
      );
    });

    test('路径不存在', () {
      expect(
        kindOf(SftpStatusError(2, 'No such file')), // SSH_FX_NO_SUCH_FILE
        SftpErrorKind.notFound,
      );
    });

    test('磁盘已满', () {
      expect(
        kindOf(SftpStatusError(4, 'Failure')), // SSH_FX_FAILURE，靠文本细化
        SftpErrorKind.unknown,
        reason: '仅凭错误码 4 无法确定是磁盘满',
      );
      expect(
        kindOf(SftpStatusError(4, 'No space left on device')),
        SftpErrorKind.diskFull,
      );
    });

    test('断线异常', () {
      expect(
        kindOf(const SftpDisconnectedException('gone')),
        SftpErrorKind.disconnected,
      );
    });

    test('超时归为断线', () {
      expect(kindOf(TimeoutException('t')), SftpErrorKind.disconnected);
    });

    test('socket 异常归为断线', () {
      expect(kindOf(const SocketException('reset')), SftpErrorKind.disconnected);
    });

    test('目标已存在', () {
      expect(
        kindOf(SftpStatusError(
            11, 'File already exists')), // SSH_FX_FILE_ALREADY_EXISTS
        SftpErrorKind.alreadyExists,
      );
    });

    test('无法识别时归为 unknown', () {
      expect(kindOf(Exception('something odd')), SftpErrorKind.unknown);
    });
  });

  group('SftpError 保留原始信息', () {
    test('raw 字段保留原始异常文本', () {
      final e = SftpError.classify(SftpStatusError(3, 'Permission denied'));
      expect(e.raw, contains('Permission denied'),
          reason: '协议原文是排查唯一线索，不能被分类吞掉');
    });

    test('分类不改变 message', () {
      final err = SftpError.classify(Exception('boom'));
      expect(err.raw, contains('boom'));
    });
  });
}
