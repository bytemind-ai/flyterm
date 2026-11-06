import 'package:dartssh2/dartssh2.dart' show SftpName;
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_service.dart';

/// 最小 fake：只需 `listdir` 可控抛出，其余方法一律不调用。
class _FakeOps implements SftpOps {
  Object? throwOnListdir;
  int listdirCalls = 0;

  @override
  Future<List<SftpName>> listdir(String path) async {
    listdirCalls++;
    final e = throwOnListdir;
    if (e != null) throw e;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('EvictOnChannelFailureOps', () {
    test('普通异常不触发 evict，原样抛出', () async {
      final inner = _FakeOps()..throwOnListdir = Exception('permission denied');
      var evicted = 0;
      final ops = EvictOnChannelFailureOps(inner, onFailure: () => evicted++);

      await expectLater(ops.listdir('/etc'), throwsA(isA<Exception>()));
      expect(evicted, 0, reason: '权限错误不是通道故障，不该踢缓存');
    });

    test('channel 开不出来触发 evict，异常仍向上传播', () async {
      // StateError('SSH channel setup failed') 是 dartssh2 在半死连接下抛的
      // 形态，`isSshChannelSetupFailure` 认得它。
      final inner = _FakeOps()
        ..throwOnListdir = StateError('SSH channel setup failed');
      var evicted = 0;
      final ops = EvictOnChannelFailureOps(inner, onFailure: () => evicted++);

      await expectLater(
        ops.listdir('/etc'),
        throwsA(isA<StateError>()),
        reason: '异常必须继续传下去 —— 调用方要靠它显示错误',
      );
      expect(evicted, 1, reason: '通道故障必须踢掉缓存条目，否则永不自愈');
    });

    test('成功时既不 evict 也不改结果', () async {
      final inner = _FakeOps();
      var evicted = 0;
      final ops = EvictOnChannelFailureOps(inner, onFailure: () => evicted++);

      expect(await ops.listdir('/etc'), isEmpty);
      expect(inner.listdirCalls, 1);
      expect(evicted, 0);
    });
  });
}
