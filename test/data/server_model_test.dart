import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/transport/transport.dart';
import 'package:flyterm/ssh/multiplexer/multiplexer_backend.dart';

void main() {
  group('aqtPorts', () {
    Map<String, dynamic> base() => {
          'id': 'id1', 'name': 'test', 'host': 'localhost', 'port': 22,
          'username': 'user', 'auth_type': 'password',
        };

    test('fromMap 读取 aqt_ports；缺失或为空时为 null（用默认范围）', () {
      expect(Server.fromMap({...base(), 'aqt_ports': '60000-60010'}).aqtPorts,
          '60000-60010');
      expect(Server.fromMap(base()).aqtPorts, isNull);
    });

    test('toMap 写出 aqt_ports', () {
      final s = Server.fromMap({...base(), 'aqt_ports': '62000'});
      expect(s.toMap()['aqt_ports'], '62000');
      expect(Server.fromMap(base()).toMap()['aqt_ports'], isNull);
    });

    test('copyWith 保留与修改 aqtPorts', () {
      final s = Server.fromMap({...base(), 'aqt_ports': '62000'});
      expect(s.copyWith(name: 'x').aqtPorts, '62000');
      expect(s.copyWith(aqtPorts: '63000-63009').aqtPorts, '63000-63009');
    });
  });

  test('Server.fromMap 读取 transport=mosh 和 moshPortRange', () {
    final map = {
      'id': 'id1', 'name': 'test', 'host': 'localhost', 'port': 22,
      'username': 'user', 'auth_type': 'password',
      'key_id': null, 'last_connected_at': null, 'startup_command': null,
      'use_tmux': 0, 'jump_host_id': null,
      'connection_strategy': 'mosh',
      'mosh_port_range': '60001:60010',
    };
    final server = Server.fromMap(map);
    expect(server.transport, Transport.mosh);
    expect(server.moshPortRange, '60001:60010');
  });

  test('Server.toMap 序列化 transport 和 moshPortRange', () {
    final server = Server(
      id: 'id1', name: 'test', host: 'localhost', port: 22,
      username: 'user', authType: 'password',
      transport: Transport.mosh, moshPortRange: '60001:60010',
    );
    final map = server.toMap();
    expect(map['connection_strategy'], 'mosh');
    expect(map['mosh_port_range'], '60001:60010');
  });

  test('Server.copyWith 保留 transport 字段', () {
    final s = Server(
      id: 'id1', name: 'a', host: 'h', port: 22,
      username: 'u', authType: 'password',
      transport: Transport.mosh, moshPortRange: '60000:61000',
    );
    final s2 = s.copyWith(name: 'b');
    expect(s2.transport, Transport.mosh);
    expect(s2.moshPortRange, '60000:61000');
  });

  test('Server 默认 transport=quic, useTmux=false, useDaemon=true, moshPortRange=60000:61000',
      () {
    // useDaemon default flipped false→true so QUIC sessions survive
    // app restart (once-mode kills server on SSH close; daemon survives).
    final s = Server(
      id: 'id1', name: 'a', host: 'h', port: 22,
      username: 'u', authType: 'password',
    );
    expect(s.transport, Transport.quic);
    expect(s.useTmux, isFalse);
    expect(s.useDaemon, isTrue);
    expect(s.moshPortRange, '60000:61000');
  });

  test('Server.useDaemon 持久化和 copyWith', () {
    final s = Server(
      id: 'id1', name: 'a', host: 'h', port: 22,
      username: 'u', authType: 'password',
      useDaemon: true,
    );
    final map = s.toMap();
    expect(map['use_daemon'], 1);

    final restored = Server.fromMap(map);
    expect(restored.useDaemon, isTrue);

    final off = s.copyWith(useDaemon: false);
    expect(off.useDaemon, isFalse);
  });

  test('Server.fromMap use_daemon 缺失时默认 true', () {
    // Default flipped to match Server() constructor default.
    final map = {
      'id': 'id1', 'name': 'test', 'host': 'h', 'port': 22,
      'username': 'u', 'auth_type': 'password',
      'connection_strategy': 'quic',
    };
    final s = Server.fromMap(map);
    expect(s.useDaemon, isTrue);
  });

  test('Server.fromMap 未知 connection_strategy 回退到 quic', () {
    final map = {
      'id': 'id1', 'name': 'test', 'host': 'localhost', 'port': 22,
      'username': 'user', 'auth_type': 'password',
      'key_id': null, 'last_connected_at': null, 'startup_command': null,
      'use_tmux': 0, 'jump_host_id': null,
      'connection_strategy': 'quicFallbackSsh', // legacy
      'mosh_port_range': '60000:61000',
    };
    final server = Server.fromMap(map);
    expect(server.transport, Transport.quic);
  });

  test('Server.multiplexerType 由 useTmux 派生', () {
    final s1 = Server(
      id: 'id1', name: 'a', host: 'h', port: 22,
      username: 'u', authType: 'password',
      useTmux: true,
    );
    expect(s1.multiplexerType, MultiplexerType.tmux);

    final s2 = s1.copyWith(useTmux: false);
    expect(s2.multiplexerType, MultiplexerType.none);
  });

  test('Server 默认 serverType 为 ssh', () {
    final s = Server(
      id: 'id1', name: 'a', host: 'h', port: 22,
      username: 'u', authType: 'password',
    );
    expect(s.serverType, 'ssh');
  });

  test('Server.fromMap 读取 serverType', () {
    final map = {
      'id': 'id1', 'name': 'test', 'host': 'localhost', 'port': 22,
      'username': 'user', 'auth_type': 'password',
      'key_id': null, 'last_connected_at': null, 'startup_command': null,
      'use_tmux': 0, 'jump_host_id': null,
      'mosh_port_range': '60000:61000',
      'connection_strategy': 'ssh',
      'server_type': 'local',
    };
    final server = Server.fromMap(map);
    expect(server.serverType, 'local');
  });

  test('Server.fromMap serverType 缺失时默认 ssh', () {
    final map = {
      'id': 'id1', 'name': 'test', 'host': 'localhost', 'port': 22,
      'username': 'user', 'auth_type': 'password',
      'key_id': null, 'last_connected_at': null, 'startup_command': null,
      'use_tmux': 0, 'jump_host_id': null,
      'mosh_port_range': '60000:61000',
      'connection_strategy': 'ssh',
    };
    final server = Server.fromMap(map);
    expect(server.serverType, 'ssh');
  });

  test('Server.toMap 包含 server_type', () {
    final s = Server(
      id: 'id1', name: 'local', host: 'localhost', port: 0,
      username: '', authType: 'password', serverType: 'local',
    );
    expect(s.toMap()['server_type'], 'local');
  });

  test('Server.copyWith 保留 serverType', () {
    final s = Server(
      id: 'id1', name: 'a', host: 'localhost', port: 0,
      username: '', authType: 'password', serverType: 'local',
    );
    expect(s.copyWith(name: 'b').serverType, 'local');
  });
}
