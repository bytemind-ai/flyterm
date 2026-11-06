import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_instructions.dart'
    show kMaxInstructionBytes;
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ServerNotesManager mgr;

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    mgr = ServerNotesManager(ServerNotesRepository(db));
  });

  tearDown(() async => db.close());

  test('搬迁一条旧缓存，保住它原来的同步时间', () async {
    final prefs = await prefsWith({
      'agent_remote_instructions_s1': '这台用 podman',
      'agent_remote_instructions_at_s1': 1700000000000,
    });

    // migrateFromPrefs 收尾自己会 load（F1），这里不用再补一次 —— 补了反而
    // 盖住了「不补 load 会不会读不到」这件事本身没被测到的问题。
    await mgr.migrateFromPrefs(prefs);

    expect(mgr.noteFor('s1'), '这台用 podman');
    expect(
      mgr.notes.single.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
  });

  test('搬完之后两组 key 都被删掉', () async {
    final prefs = await prefsWith({
      'agent_remote_instructions_s1': 'a',
      'agent_remote_instructions_at_s1': 1700000000000,
    });

    await mgr.migrateFromPrefs(prefs);

    expect(prefs.getString('agent_remote_instructions_s1'), isNull);
    expect(prefs.getInt('agent_remote_instructions_at_s1'), isNull);
  });

  test('时间戳 key 不会被误当成正文 key', () async {
    // 两个前缀是包含关系：agent_remote_instructions_ 是
    // agent_remote_instructions_at_ 的前缀。不排掉的话会解析出一个叫
    // at_s1 的假 serverId。
    final prefs = await prefsWith({
      'agent_remote_instructions_s1': 'a',
      'agent_remote_instructions_at_s1': 1700000000000,
    });

    await mgr.migrateFromPrefs(prefs);

    expect(mgr.notes.length, 1);
    expect(mgr.noteFor('at_s1'), isNull);
  });

  test('缺时间戳时回退到当前时间，不丢内容', () async {
    final prefs = await prefsWith({'agent_remote_instructions_s1': 'a'});

    await mgr.migrateFromPrefs(prefs);

    expect(mgr.noteFor('s1'), 'a');
  });

  test('空内容跳过，不建空行', () async {
    final prefs = await prefsWith({'agent_remote_instructions_s1': '   '});

    await mgr.migrateFromPrefs(prefs);

    expect(mgr.notes, isEmpty);
  });

  test('空内容的 key 照样被清掉', () async {
    final prefs = await prefsWith({'agent_remote_instructions_s1': '   '});

    await mgr.migrateFromPrefs(prefs);

    expect(prefs.getString('agent_remote_instructions_s1'), isNull);
  });

  test('多台机器一起搬', () async {
    final prefs = await prefsWith({
      'agent_remote_instructions_s1': 'a',
      'agent_remote_instructions_s2': 'b',
    });

    await mgr.migrateFromPrefs(prefs);

    expect(mgr.noteFor('s1'), 'a');
    expect(mgr.noteFor('s2'), 'b');
  });

  test('超过 4 KiB 的旧缓存照样搬进来，不被上限拒绝', () async {
    // 远端那份文件的上限一直只靠模型自觉，确实可能超。一次版本升级静默
    // 丢掉老用户的内容是不可接受的。
    final big = 'x' * 5000;
    final prefs = await prefsWith({'agent_remote_instructions_s1': big});

    await mgr.migrateFromPrefs(prefs);

    expect(mgr.noteFor('s1'), big);
  });

  test('不碰无关的 prefs key', () async {
    final prefs = await prefsWith({
      'agent_remote_instructions_s1': 'a',
      'agent_instructions_global': '全局指令，不该被动',
      'some_other_key': 'x',
    });

    await mgr.migrateFromPrefs(prefs);

    expect(prefs.getString('agent_instructions_global'), '全局指令，不该被动');
    expect(prefs.getString('some_other_key'), 'x');
  });

  test('第二次调用是空操作 —— 一次性闸门', () async {
    final prefs = await prefsWith({'agent_remote_instructions_s1': '原始'});

    await mgr.migrateFromPrefs(prefs);
    await mgr.replaceNote(serverId: 's1', body: '用户后来改的');

    // 再次调用不该把「用户后来改的」覆盖回「原始」。闸门已经落下，第二次
    // migrateFromPrefs 在第一行就直接 return，不会走到收尾的 load() ——
    // 这里的 load() 不是补被测代码的漏洞，是在模拟 main.dart 每次冷启动都
    // 会再调一次 load() 这件事本身。
    await mgr.migrateFromPrefs(prefs);
    await mgr.load();

    expect(mgr.noteFor('s1'), '用户后来改的');
  });

  test('没有旧 key 时也要落下闸门，不重复扫描', () async {
    final prefs = await prefsWith({});

    await mgr.migrateFromPrefs(prefs);

    expect(prefs.getBool('server_notes_migrated_v37'), isTrue);
  });

  // ───────── F1: 迁移收尾必须自己刷新内存缓存 ─────────

  test('迁移完内存缓存就是热的 —— 否则紧跟的 appendNote 会覆盖掉搬来的内容',
      () async {
    final prefs = await prefsWith({'agent_remote_instructions_s1': '老笔记'});

    await mgr.migrateFromPrefs(prefs);
    expect(mgr.noteFor('s1'), '老笔记', reason: '不额外 load 就该能读到');

    await mgr.appendNote(serverId: 's1', heading: '新', body: 'x');
    expect(mgr.noteFor('s1'), startsWith('老笔记'), reason: '读-改-写，绝不覆盖');
  });

  // ───────── F2: 存量超限（只可能来自迁移）时 appendNote 的行为 ─────────

  test('存量超限时 appendNote 直接 failed，不给模型一个它做不到的数字',
      () async {
    // 只有迁移路径能造出超限存量 —— adoptRaw 已经转私有，只能通过真实的
    // migrateFromPrefs 路径（旧缓存本来就超限）来构造这种场景。
    final big = 'x' * (kMaxInstructionBytes + 900);
    final prefs = await prefsWith({'agent_remote_instructions_s1': big});
    await mgr.migrateFromPrefs(prefs);

    final r = await mgr.appendNote(serverId: 's1', heading: '', body: '短短一段');

    expect(r.ok, isFalse);
    expect(r.error, isNotNull, reason: '要走 failed 而不是 rejected');
    expect(r.overflowBytes, 0, reason: 'failed 不该报超出量 —— 那个数字调用方做不到');
    expect(mgr.noteFor('s1')!.length, kMaxInstructionBytes + 900,
        reason: '原内容必须原样保留');
  });

  // ───────── F6: per-entry 容错 —— 一条搬不动不该让整个迁移失败 ─────────

  test('一条坏数据搬不动，不该拖垮同批其余条目，也不该拖垮闸门', () async {
    // sqflite 的 body 列是 TEXT NOT NULL，塞一个 null 进 upsert 会在写库时
    // 抛异常，用它来模拟「单条搬不动」而不用 mock —— 更贴近真实失败模式。
    final prefs = await prefsWith({
      'agent_remote_instructions_bad': 'x' * 10,
      'agent_remote_instructions_good': '好数据',
    });
    // 把 bad 那一条的时间戳塞成非法类型，制造迁移过程中的真实异常
    // （getInt 在值不是 int 时会抛 TypeError，命中循环体里的 try/catch）。
    await prefs.setString(
        'agent_remote_instructions_at_bad', 'not-a-number');

    await mgr.migrateFromPrefs(prefs);

    expect(mgr.noteFor('good'), '好数据', reason: '好的那条不该被坏的拖累');
    expect(prefs.getBool('server_notes_migrated_v37'), isTrue,
        reason: '闸门照常落下，否则每次开机都会重跑一条注定失败的记录');
  });

  // ───────── F7: 孤儿 at_ key 清理 ─────────

  test('没有对应正文 key 的孤儿 at_ key 会被一并清掉', () async {
    final prefs = await prefsWith({
      'agent_remote_instructions_at_s9': 1700000000000,
    });

    await mgr.migrateFromPrefs(prefs);

    expect(prefs.getInt('agent_remote_instructions_at_s9'), isNull);
  });

  // ───────── F8: 裸前缀 key 不该造出幽灵笔记 ─────────

  test('裸前缀 key（没有 serverId）不会造出幽灵笔记，但会被清掉', () async {
    final prefs = await prefsWith({'agent_remote_instructions_': '没头没脑'});

    await mgr.migrateFromPrefs(prefs);

    expect(mgr.notes, isEmpty, reason: '不该出现 serverId 为空字符串的幽灵笔记');
    expect(prefs.getString('agent_remote_instructions_'), isNull,
        reason: '烂 key 该清掉');
  });
}
