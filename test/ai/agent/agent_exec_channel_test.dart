import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/secure_storage.dart';

/// 数「凭据读了几次」的 storage。读取挂在闸门上，好让两个并发 `obtain()`
/// 必然同时在飞 —— 不靠任何时间常量。
class _CountingStorage extends SecureStorageService {
  int passwordReads = 0;
  final Completer<void> gate = Completer<void>();

  @override
  Future<String?> loadPassword(String serverId) async {
    passwordReads++;
    await gate.future;
    // 返回 null（凭据不可用）让 obtain 在真正建连之前就抛 —— 这条测试
    // 只关心「建连流程被发起了几次」，不需要真的握手。
    return null;
  }

  @override
  Future<String?> loadPrivateKey(String keyId) async => null;
}

const _server = Server(
  id: 'srv-1',
  name: 'web-1',
  host: '10.0.0.1',
  port: 22,
  username: 'ops',
  authType: 'password',
);

void main() {
  group('AgentCredentials.isUsable', () {
    test('有密码即可用', () {
      const c = AgentCredentials(password: 'pw', privateKeyPem: null);
      expect(c.isUsable, isTrue);
    });

    test('有私钥即可用', () {
      const c = AgentCredentials(password: null, privateKeyPem: '-----BEGIN');
      expect(c.isUsable, isTrue);
    });

    test('两者皆无不可用', () {
      const c = AgentCredentials(password: null, privateKeyPem: null);
      expect(c.isUsable, isFalse);
    });

    test('空字符串不算有效凭据', () {
      const c = AgentCredentials(password: '', privateKeyPem: '');
      expect(c.isUsable, isFalse);
    });
  });

  test('AgentCredentialsUnavailable 带可读消息', () {
    expect(
      AgentCredentialsUnavailable().toString(),
      contains('凭据'),
    );
  });

  group('obtain 的在飞去重', () {
    test('两次并发 obtain 只发起一次建连', () async {
      final storage = _CountingStorage();
      final ch = AgentExecChannel(server: _server, storage: storage);

      // 两个调用者，都不 await —— 第二个到达时第一个还卡在读凭据上。
      final a = ch.obtain();
      final b = ch.obtain();
      // 让第一个调用者跑到 `await loadPassword` 那一步。
      await Future<void>.delayed(Duration.zero);

      expect(storage.passwordReads, 1,
          reason: '第二个调用者必须汇入第一条在飞的建连，而不是自己再建一条。'
              '没有去重时这里是 2，两条 SSH 连接各跑一遍 TCP+KEX+auth，'
              '后完成的覆盖 _owned，先完成的永久泄漏');

      storage.gate.complete();
      await expectLater(a, throwsA(isA<AgentCredentialsUnavailable>()));
      await expectLater(b, throwsA(isA<AgentCredentialsUnavailable>()));
    });

    test('失败之后去重状态被清掉，下一次还能重新建连', () async {
      final storage = _CountingStorage();
      final ch = AgentExecChannel(server: _server, storage: storage);

      final first = ch.obtain();
      await Future<void>.delayed(Duration.zero);
      storage.gate.complete();
      await expectLater(first, throwsA(isA<AgentCredentialsUnavailable>()));

      // 不清 `_connecting` 的话，这一次会拿到同一个已经 reject 的 Future，
      // 读凭据的次数停在 1 —— 连接此后再也建不起来。
      final second = ch.obtain();
      await expectLater(second, throwsA(isA<AgentCredentialsUnavailable>()));
      expect(storage.passwordReads, 2,
          reason: '前一次失败不该把这条 channel 永久钉死');
    });
  });

  group('hasLiveConnection', () {
    test('没有连接时为 false，且一次凭据都不读', () {
      // 最要紧的断言是 passwordReads == 0：这个 getter 存在的全部理由就是
      // 「看一眼而不建连」。它要是走了 obtain 的建连路径，看板打开时会给
      // 每台机器都握一次手 —— 正是渐进式加载要避免的。
      final storage = _CountingStorage();
      final ch = AgentExecChannel(server: _server, storage: storage);
      expect(ch.hasLiveConnection, isFalse);
      expect(storage.passwordReads, 0);
    });

    test('reuseProvider 返回 null 时为 false，且被读了一次', () {
      final storage = _CountingStorage();
      var probes = 0;
      final ch = AgentExecChannel(
        server: _server,
        storage: storage,
        reuseProvider: () {
          probes++;
          return null;
        },
      );
      expect(ch.hasLiveConnection, isFalse);
      expect(probes, 1, reason: 'reuseProvider 是同步查询，读它是对的');
      expect(storage.passwordReads, 0);
    });
  });
}
