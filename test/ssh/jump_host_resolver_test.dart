import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/ssh/jump_host_resolver.dart';

// Minimal stub — only methods called by resolveJumpParams.
class _FakeStorage implements SecureStorageService {
  final Map<String, String> _passwords;
  _FakeStorage(this._passwords);

  @override
  Future<String?> loadPassword(String serverId) async =>
      _passwords[serverId];

  @override
  Future<String?> loadPrivateKey(String keyId) async => null;

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ServerRepository repo;
  const uuid = Uuid();

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = ServerRepository(db);
  });

  tearDown(() async => db.close());

  test('returns null when jumpHostId is null', () async {
    final server = Server(
      id: uuid.v4(), name: 'T', host: 'h', port: 22,
      username: 'u', authType: 'password',
    );
    final storage = _FakeStorage({});
    final result = await resolveJumpParams(server, repo, storage);
    expect(result, isNull);
  });

  test('returns null when referenced jump server does not exist', () async {
    final server = Server(
      id: uuid.v4(), name: 'T', host: 'h', port: 22,
      username: 'u', authType: 'password',
      jumpHostId: 'nonexistent-id',
    );
    final storage = _FakeStorage({});
    final result = await resolveJumpParams(server, repo, storage);
    expect(result, isNull);
  });

  test('returns JumpHostParams with password when jump uses password auth', () async {
    final jumpId = uuid.v4();
    final jump = Server(
      id: jumpId, name: 'Bastion', host: 'bastion.example.com',
      port: 2222, username: 'ops', authType: 'password',
    );
    await repo.insert(jump);

    final server = Server(
      id: uuid.v4(), name: 'Target', host: '10.0.0.1', port: 22,
      username: 'dev', authType: 'password', jumpHostId: jumpId,
    );
    final storage = _FakeStorage({jumpId: 's3cr3t'});
    final result = await resolveJumpParams(server, repo, storage);

    expect(result, isNotNull);
    expect(result!.host, 'bastion.example.com');
    expect(result.port, 2222);
    expect(result.username, 'ops');
    expect(result.password, 's3cr3t');
    expect(result.privateKeyPem, isNull);
  });
}
