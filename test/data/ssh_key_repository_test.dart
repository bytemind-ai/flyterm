import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/ssh_key.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SSHKeyRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = SSHKeyRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('insert and fetch key', () async {
    final key = SSHKey(
      id: const Uuid().v4(),
      name: 'My Key',
      type: 'ed25519',
      publicKey: 'ssh-ed25519 AAAA... user@host',
    );
    await repo.insert(key);
    final all = await repo.findAll();
    expect(all.length, 1);
    expect(all.first.type, 'ed25519');
  });

  test('delete key', () async {
    final key = SSHKey(
      id: const Uuid().v4(),
      name: 'ToDelete',
      type: 'rsa',
      publicKey: 'ssh-rsa AAAA...',
    );
    await repo.insert(key);
    await repo.delete(key.id);
    expect(await repo.findAll(), isEmpty);
  });
}
