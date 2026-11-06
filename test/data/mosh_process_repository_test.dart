import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/mosh_process_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late MoshProcessRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = MoshProcessRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('database creates mosh_processes table', () async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    expect(names, contains('mosh_processes'));
  });

  test(
    'tracks multiple mosh processes for same server independently',
    () async {
      await repo.upsertActive(
        id: 'tab1-1001',
        serverId: 'server-a',
        tabId: 'tab1',
        tmuxKey: 'server-a',
        pid: 1001,
        udpPort: 60001,
        host: 'example.com',
        sshPort: 22,
        username: 'root',
        portRange: '60000:61000',
      );
      await repo.upsertActive(
        id: 'tab2-1002',
        serverId: 'server-a',
        tabId: 'tab2',
        tmuxKey: 'server-a-tab2',
        pid: 1002,
        udpPort: 60002,
        host: 'example.com',
        sshPort: 22,
        username: 'root',
        portRange: '60000:61000',
      );

      expect(await repo.findAllActiveOrPending(), hasLength(2));
      await repo.markKilledByTabId('tab1');

      final remaining = await repo.findAllActiveOrPending();
      expect(remaining, hasLength(1));
      expect(remaining.single.pid, 1002);
    },
  );
}
