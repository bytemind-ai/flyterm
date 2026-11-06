import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/data/repositories/favorite_command_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late FavoriteCommandRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = FavoriteCommandRepository(db);
  });

  tearDown(() async => db.close());

  test('新建的收藏默认不对 AI 开放', () async {
    await repo.insert(
        FavoriteCommand.create(name: '重启网关', command: 'systemctl restart gw'));
    expect((await repo.findAll()).single.aiEnabled, isFalse);
  });

  test('aiEnabled 能存能读', () async {
    final cmd = FavoriteCommand.create(name: 'x', command: 'ls');
    await repo.insert(cmd.copyWith(aiEnabled: true));
    expect((await repo.findAll()).single.aiEnabled, isTrue);
  });

  test('update 能改 aiEnabled', () async {
    await repo.insert(FavoriteCommand.create(name: 'x', command: 'ls'));
    final cmd = (await repo.findAll()).single;
    await repo.update(cmd.copyWith(aiEnabled: true));
    expect((await repo.findAll()).single.aiEnabled, isTrue);
  });

  test('params 与 expand 不受影响', () {
    const cmd = FavoriteCommand(
      id: 'i',
      name: 'deploy',
      command: 'deploy-cli deploy --service {{service}} --version {{version}}',
      aiEnabled: true,
    );
    expect(cmd.params, equals(['service', 'version']));
    expect(cmd.expand({'service': 'api', 'version': 'v1'}),
        equals('deploy-cli deploy --service api --version v1'));
  });
}
