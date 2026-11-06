import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/ai_provider_config.dart';
import 'package:flyterm/data/repositories/ai_provider_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late AIProviderRepository repo;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = AIProviderRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('ai_providers table exists', () async {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'");
    final names = tables.map((r) => r['name'] as String).toSet();
    expect(names, contains('ai_providers'));
  });

  test('insert and findAll', () async {
    final config = AIProviderConfig(
      id: const Uuid().v4(),
      name: 'My GPT-4',
      type: 'openai',
      model: 'gpt-4o',
    );
    await repo.insert(config);
    final all = await repo.findAll();
    expect(all.length, 1);
    expect(all.first.model, 'gpt-4o');
    expect(all.first.isDefault, isFalse);
  });

  test('findDefault returns the default provider', () async {
    await repo.insert(AIProviderConfig(
      id: const Uuid().v4(),
      name: 'A',
      type: 'openai',
      model: 'gpt-4o',
    ));
    final defaultId = const Uuid().v4();
    await repo.insert(AIProviderConfig(
      id: defaultId,
      name: 'B',
      type: 'anthropic',
      model: 'claude-3-5-sonnet-20241022',
      isDefault: true,
    ));
    final def = await repo.findDefault();
    expect(def?.id, defaultId);
  });

  test('insert with isDefault=true clears old default', () async {
    final id1 = const Uuid().v4();
    await repo.insert(AIProviderConfig(
      id: id1,
      name: 'A',
      type: 'openai',
      model: 'gpt-4o',
      isDefault: true,
    ));
    final id2 = const Uuid().v4();
    await repo.insert(AIProviderConfig(
      id: id2,
      name: 'B',
      type: 'anthropic',
      model: 'claude-3-5-sonnet-20241022',
      isDefault: true,
    ));
    final all = await repo.findAll();
    final defaults = all.where((c) => c.isDefault).toList();
    expect(defaults.length, 1);
    expect(defaults.first.id, id2);
  });

  test('update and delete', () async {
    final config = AIProviderConfig(
      id: const Uuid().v4(),
      name: 'Old',
      type: 'ollama',
      model: 'llama3',
      baseUrl: 'http://localhost:11434',
    );
    await repo.insert(config);
    await repo.update(config.copyWith(name: 'New'));
    final updated = await repo.findAll();
    expect(updated.first.name, 'New');
    await repo.delete(config.id);
    expect(await repo.findAll(), isEmpty);
  });
}
