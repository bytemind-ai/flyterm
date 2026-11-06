import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_channel_pool.dart';

/// 一个可编程的「开 channel」函数，记录被调了几次。
class _Opener {
  int calls = 0;
  final List<Completer<Object>> pending = [];
  bool throwOnOpen = false;
  Object error = Exception('boom');

  Future<Object> open() {
    calls++;
    if (throwOnOpen) return Future.error(error);
    final c = Completer<Object>();
    pending.add(c);
    return c.future;
  }

  void completeLast(Object value) => pending.last.complete(value);
  void failLast(Object err) => pending.last.completeError(err);
}

void main() {
  group('SftpChannelPool', () {
    test('同一 key 只开一次通道，后续调用拿到同一个实例', () async {
      final pool = SftpChannelPool();
      final opener = _Opener();
      final key = Object();

      final f1 = pool.obtain(key, opener.open);
      final f2 = pool.obtain(key, opener.open);

      // 两次并发调用都还在飞，开通道只该发生一次。
      expect(opener.calls, 1);

      opener.completeLast('ops');
      expect(await f1, 'ops');
      expect(await f2, 'ops');
      expect(opener.calls, 1);
    });

    test('缓存命中后不再开新通道', () async {
      final pool = SftpChannelPool();
      final opener = _Opener();
      final key = Object();

      final f = pool.obtain(key, opener.open);
      opener.completeLast('ops');
      await f;

      expect(await pool.obtain(key, opener.open), 'ops');
      expect(opener.calls, 1);
    });

    test('不同 key 各开一条通道', () async {
      final pool = SftpChannelPool();
      final opener = _Opener();
      final a = Object();
      final b = Object();

      final fa = pool.obtain(a, opener.open);
      final fb = pool.obtain(b, opener.open);
      expect(opener.calls, 2);

      opener.pending[0].complete('ops-a');
      opener.pending[1].complete('ops-b');
      expect(await fa, 'ops-a');
      expect(await fb, 'ops-b');
    });

    test('开通道失败：缓存不留 reject 的 Future，下次会重试', () async {
      final pool = SftpChannelPool();
      final opener = _Opener()..throwOnOpen = true;
      final key = Object();

      await expectLater(pool.obtain(key, opener.open), throwsA(isA<Exception>()));
      expect(opener.calls, 1);

      // 关键：失败的那次必须从缓存里清掉，否则此后每次 obtain 都拿到
      // 同一个已 reject 的 Future，通道再也建不起来。
      opener.throwOnOpen = false;
      final f = pool.obtain(key, opener.open);
      expect(opener.calls, 2);
      opener.completeLast('ops');
      expect(await f, 'ops');
    });

    test('evict：清掉后下次重开', () async {
      final pool = SftpChannelPool();
      final opener = _Opener();
      final key = Object();

      final f = pool.obtain(key, opener.open);
      opener.completeLast('ops');
      await f;

      pool.evict(key);
      final f2 = pool.obtain(key, opener.open);
      expect(opener.calls, 2);
      opener.completeLast('ops2');
      expect(await f2, 'ops2');
    });

    test('evict 后若旧通道的 open 仍失败，不会污染新条目', () async {
      final pool = SftpChannelPool();
      final opener = _Opener();
      final key = Object();

      final f = pool.obtain(key, opener.open);
      pool.evict(key); // 旧的那条还在飞
      final f2 = pool.obtain(key, opener.open);
      expect(opener.calls, 2);

      // 旧的那条失败，不该把新条目也带走。
      opener.pending[0].completeError(Exception('stale'));
      opener.pending[1].complete('fresh');

      await expectLater(f, throwsA(isA<Exception>()));
      expect(await f2, 'fresh');
    });

    test('并发 8 个 listdir（@file 索引的批次）只开一条通道', () async {
      // 这是本池存在的**唯一理由**的回归锁：dartssh2 的 client.sftp() 每次
      // 都开新 session channel，@file 的并发 8 会让一批就是 8 条，撞上
      // sshd 的 MaxSessions（默认 10）后用户看到「SSH 连接错误」。
      //
      // 这里用同一把 key 模拟「同一个 SSHClient」：无论叠多少个并发调用，
      // open 只该发生一次。
      final pool = SftpChannelPool();
      final opener = _Opener();
      final client = Object(); // 生产侧就是 SSHClient 实例

      final futures = [
        for (var i = 0; i < 8; i++) pool.obtain(client, opener.open),
      ];

      expect(opener.calls, 1, reason: '一批 8 个 listdir 必须共享同一条通道');
      opener.completeLast('ops');
      for (final f in futures) {
        expect(await f, 'ops');
      }
    });
  });
}
