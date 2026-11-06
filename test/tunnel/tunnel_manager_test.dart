import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/tunnel/tunnel_entry.dart';
import 'package:flyterm/tunnel/tunnel_manager.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/tunnel_config.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/tunnel_repository.dart';

Server _makeServer() => Server(
      id: const Uuid().v4(),
      name: 'Test Server',
      host: '192.168.1.1',
      port: 22,
      username: 'user',
      authType: 'key',
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('TunnelEntry', () {
    test('has unique id on construction', () {
      final s = _makeServer();
      final a = TunnelEntry(
        server: s, direction: TunnelDirection.local,
        localPort: 3306, remoteHost: 'localhost', remotePort: 3306,
        label: 'MySQL',
      );
      final b = TunnelEntry(
        server: s, direction: TunnelDirection.local,
        localPort: 3306, remoteHost: 'localhost', remotePort: 3306,
        label: 'MySQL',
      );
      expect(a.id, isNot(b.id));
    });

    test('initial status is connecting', () {
      final entry = TunnelEntry(
        server: _makeServer(), direction: TunnelDirection.local,
        localPort: 8080, remoteHost: 'localhost', remotePort: 80,
        label: 'HTTP',
      );
      expect(entry.status, TunnelStatus.connecting);
    });

    test('displayPorts for local shows correct direction', () {
      final entry = TunnelEntry(
        server: _makeServer(), direction: TunnelDirection.local,
        localPort: 3306, remoteHost: 'db.internal', remotePort: 3306,
        label: 'DB',
      );
      expect(entry.displayPorts, 'localhost:3306 → db.internal:3306');
    });

    test('displayPorts for remote shows correct direction', () {
      final entry = TunnelEntry(
        server: _makeServer(), direction: TunnelDirection.remote,
        localPort: 8080, remoteHost: 'localhost', remotePort: 9090,
        label: 'Dev',
      );
      expect(entry.displayPorts, 'localhost:9090 → localhost:8080');
    });

    test('displayPorts for socks5 shows local port only', () {
      final entry = TunnelEntry(
        server: _makeServer(),
        direction: TunnelDirection.socks5,
        localPort: 1080,
        remoteHost: '',
        remotePort: 0,
        label: 'SOCKS5',
      );
      expect(entry.displayPorts, 'SOCKS5 :1080');
    });
  });

  group('TunnelManager', () {
    test('starts with empty tunnel list', () {
      expect(TunnelManager().tunnels, isEmpty);
    });

    test('stopAll on empty list does not throw', () async {
      await expectLater(TunnelManager().stopAll(), completes);
    });
  });

  group('TunnelManager with repository', () {
    late Database db;
    late TunnelRepository repo;

    setUp(() async {
      db = await AppDatabase.open(inMemory: true);
      repo = TunnelRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('saveAndAdd inserts config into DB', () async {
      final mgr = TunnelManager(repository: repo);
      final server = _makeServer();
      await mgr.saveAndAdd(
        existingClient: null,
        server: server,
        storage: null,
        direction: TunnelDirection.local,
        localPort: 3306,
        remoteHost: 'db.internal',
        remotePort: 3306,
        label: 'MySQL',
        autoStart: false,
      );
      final configs = await repo.findAll();
      expect(configs.length, 1);
      expect(configs.first.serverId, server.id);
      expect(configs.first.label, 'MySQL');
      expect(mgr.tunnels.length, 1);
      expect(mgr.tunnels.first.saved, true);
    });

    test('removeSaved deletes from DB and list', () async {
      final mgr = TunnelManager(repository: repo);
      final server = _makeServer();
      await mgr.saveAndAdd(
        existingClient: null,
        server: server,
        storage: null,
        direction: TunnelDirection.local,
        localPort: 3306,
        remoteHost: 'db.internal',
        remotePort: 3306,
        label: 'MySQL',
        autoStart: false,
      );
      final id = mgr.tunnels.first.id;
      await mgr.removeSaved(id);
      expect(mgr.tunnels, isEmpty);
      expect(await repo.findAll(), isEmpty);
    });

    test('setAutoStart updates DB', () async {
      final mgr = TunnelManager(repository: repo);
      final server = _makeServer();
      await mgr.saveAndAdd(
        existingClient: null,
        server: server,
        storage: null,
        direction: TunnelDirection.local,
        localPort: 3306,
        remoteHost: 'db.internal',
        remotePort: 3306,
        label: 'MySQL',
        autoStart: false,
      );
      final id = mgr.tunnels.first.id;
      await mgr.setAutoStart(id, true);
      expect(mgr.tunnels.first.autoStart, true);
      final configs = await repo.findAll();
      expect(configs.first.autoStart, true);
    });

    test('stopTunnel on saved entry keeps it as stopped', () async {
      final mgr = TunnelManager(repository: repo);
      final server = _makeServer();
      await mgr.saveAndAdd(
        existingClient: null,
        server: server,
        storage: null,
        direction: TunnelDirection.local,
        localPort: 3306,
        remoteHost: 'db.internal',
        remotePort: 3306,
        label: 'MySQL',
        autoStart: false,
      );
      final id = mgr.tunnels.first.id;
      await mgr.stopTunnel(id);
      expect(mgr.tunnels.length, 1);
      expect(mgr.tunnels.first.status, TunnelStatus.stopped);
    });

    test('restoreFromDb adds stopped entries from DB', () async {
      final server = _makeServer();
      // Insert the server into DB for ServerRepository to find
      await db.insert('servers', server.toMap());
      // Insert tunnel config directly
      await repo.insert(TunnelConfig(
        id: const Uuid().v4(),
        serverId: server.id,
        direction: TunnelDirection.local,
        localPort: 5432,
        remoteHost: 'pg.internal',
        remotePort: 5432,
        label: 'Postgres',
        autoStart: false,
      ));

      final mgr = TunnelManager(repository: repo);
      final serverRepo = ServerRepository(db);
      await mgr.restoreFromDb(serverRepo, null);

      expect(mgr.tunnels.length, 1);
      expect(mgr.tunnels.first.label, 'Postgres');
      expect(mgr.tunnels.first.status, TunnelStatus.stopped);
      expect(mgr.tunnels.first.saved, true);
    });
  });
}
