import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/config_draft.dart';

void main() {
  group('ServerDraft', () {
    test('只有 host 就算 usable —— host 是唯一无法推断的字段', () {
      const d = ServerDraft(host: 'example.com');
      expect(d.isUsable, isTrue);
    });

    test('没有 host 就不 usable，哪怕别的字段齐全', () {
      const d = ServerDraft(username: 'root', port: 2222, name: 'web');
      expect(d.isUsable, isFalse);
    });

    test('provenance 只记解析到的字段，默认值不进去', () {
      const d = ServerDraft(
        host: 'example.com',
        port: 2222,
        provenance: {'host': 'ssh config 的 HostName', 'port': 'ssh config 的 Port'},
      );
      expect(d.provenance.keys, containsAll(['host', 'port']));
      expect(d.provenance.containsKey('username'), isFalse);
    });

    test('identityFile 记下来但标记为不可自动使用', () {
      const d = ServerDraft(
        host: 'example.com',
        identityFilePath: '~/.ssh/id_rsa',
      );
      // 桌面路径在手机上没有意义：记录是为了告诉用户「这台机器用的是密钥，
      // 你得手动选一个」，而不是假装已经配好了。
      expect(d.identityFilePath, '~/.ssh/id_rsa');
      expect(d.needsManualKey, isTrue);
    });

    test('没有 identityFile 时 needsManualKey 为 false', () {
      const d = ServerDraft(host: 'example.com');
      expect(d.needsManualKey, isFalse);
    });
  });

  group('TunnelDraft', () {
    test('远程主机 + 远程端口齐了才 usable', () {
      const d = TunnelDraft(
        direction: TunnelDirection.local,
        remoteHost: '127.0.0.1',
        remotePort: 3306,
        localPort: 13306,
      );
      expect(d.isUsable, isTrue);
    });

    test('缺远程端口就不 usable', () {
      const d = TunnelDraft(
        direction: TunnelDirection.local,
        remoteHost: '127.0.0.1',
        localPort: 13306,
      );
      expect(d.isUsable, isFalse);
    });

    test('localPort 缺省时回落到 remotePort', () {
      const d = TunnelDraft(
        direction: TunnelDirection.local,
        remoteHost: '127.0.0.1',
        remotePort: 3306,
      );
      expect(d.effectiveLocalPort, 3306);
    });

    test('socks5 不需要 remoteHost/remotePort', () {
      const d = TunnelDraft(
        direction: TunnelDirection.socks5,
        localPort: 1080,
      );
      expect(d.isUsable, isTrue);
    });
  });
}
