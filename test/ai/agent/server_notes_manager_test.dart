import 'package:flutter_test/flutter_test.dart';
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

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    mgr = ServerNotesManager(ServerNotesRepository(db));
    await mgr.load();
  });

  tearDown(() async => db.close());

  test('noteFor 是同步的，load 之后直接命中内存', () async {
    await mgr.replaceNote(serverId: 's1', body: '这台用 podman');
    // 不 await、不碰数据库 —— systemPromptProvider 是同步闭包，这是硬约束。
    expect(mgr.noteFor('s1'), '这台用 podman');
  });

  test('noteFor 未命中返回 null', () {
    expect(mgr.noteFor('nope'), isNull);
  });

  test('appendNote 在现有内容后追加带标题的小节', () async {
    await mgr.replaceNote(serverId: 's1', body: '已有内容');
    await mgr.appendNote(serverId: 's1', heading: '容器', body: '用 podman');

    expect(mgr.noteFor('s1'), '已有内容\n\n## 容器\n\n用 podman');
  });

  test('appendNote 对空笔记不留前导空行', () async {
    await mgr.appendNote(serverId: 's1', heading: '容器', body: '用 podman');
    expect(mgr.noteFor('s1'), '## 容器\n\n用 podman');
  });

  test('heading 为空时只追加正文', () async {
    await mgr.appendNote(serverId: 's1', heading: '  ', body: '裸正文');
    expect(mgr.noteFor('s1'), '裸正文');
  });

  test('写入会 notifyListeners', () async {
    var fired = 0;
    mgr.addListener(() => fired++);
    await mgr.replaceNote(serverId: 's1', body: 'a');
    expect(fired, greaterThan(0));
  });

  test('delete 同时清掉库和内存', () async {
    await mgr.replaceNote(serverId: 's1', body: 'a');
    await mgr.delete('s1');

    expect(mgr.noteFor('s1'), isNull);
    expect(await ServerNotesRepository(db).bodyOf('s1'), isNull);
  });

  test('空白正文等于删除', () async {
    await mgr.replaceNote(serverId: 's1', body: 'a');
    await mgr.replaceNote(serverId: 's1', body: '   ');

    expect(mgr.noteFor('s1'), isNull);
  });

  test('notes 按 updatedAt 倒序，总览列表用它', () async {
    await mgr.replaceNote(serverId: 'old', body: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await mgr.replaceNote(serverId: 'new', body: 'b');

    expect(mgr.notes.map((n) => n.serverId).toList(), ['new', 'old']);
  });

  // adoptRaw 已经转为私有（F3），「不查上限」这条行为已经被
  // server_notes_migration_test.dart 里「超过 4 KiB 的旧缓存照样搬进来」
  // 那条测完整覆盖，且那条更贴近真实路径，这里不再重复。

  test('notes 的 tie-break 要和 repository 的 ORDER BY 一致', () async {
    // Dart 的 List.sort 在元素数 > 32 时切到不稳定的 dual-pivot quicksort。
    // 同时间戳是常态（migrateFromPrefs 对缺时间戳的条目一律用
    // DateTime.now()），所以这里故意用 40 条同一时间戳的数据踩中那条分支。
    final same = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    for (var i = 0; i < 40; i++) {
      final id = 's${i.toString().padLeft(2, '0')}';
      await mgr.replaceNote(serverId: id, body: 'note-$id');
    }
    await mgr.load();
    // replaceNote 各自带着自己的写入时间，这里改用底层 repo 把它们统一成
    // 同一毫秒，才能真的踩中「同时间戳」这个分支。
    for (var i = 0; i < 40; i++) {
      final id = 's${i.toString().padLeft(2, '0')}';
      await ServerNotesRepository(db)
          .upsert(serverId: id, body: 'note-$id', updatedAt: same);
    }
    await mgr.load();

    final ids = mgr.notes.map((n) => n.serverId).toList();
    final expected = List.generate(
        40, (i) => 's${i.toString().padLeft(2, '0')}')
      ..sort();
    expect(ids, expected, reason: '同时间戳时必须按 server_id 升序排列');
  });

  test('body 全空白时不写出光杆标题，heading 是否非空都一样', () {
    expect(
      composeAppendedNote(current: '已有内容', heading: '标题', body: '   '),
      '已有内容',
      reason: '正文是空白就什么都不该追加，哪怕标题非空',
    );
    expect(
      composeAppendedNote(current: null, heading: '标题', body: ''),
      '',
      reason: '原来就没内容，追加空正文应该维持原样（空）',
    );
    expect(
      composeAppendedNote(current: '已有内容', heading: '', body: '  '),
      '已有内容',
    );
  });

  test('appendNote 对空白正文返回 failed，不伪装成功', () async {
    await mgr.replaceNote(serverId: 's1', body: '已有内容');
    final r = await mgr.appendNote(serverId: 's1', heading: '标题', body: '   ');

    expect(r.ok, isFalse);
    expect(r.error, 'Nothing to append.');
    expect(mgr.noteFor('s1'), '已有内容', reason: '不该改动原内容');
  });

  test('delete 对不存在的笔记直接返回，不触发无意义的重建', () async {
    var fired = 0;
    mgr.addListener(() => fired++);

    await mgr.delete('ghost');

    expect(fired, 0);
    expect(mgr.noteFor('ghost'), isNull);
  });

  test('存量在限内时 overflowBytes 一定砍得掉', () async {
    await mgr.replaceNote(
        serverId: 's1', body: 'x' * (kMaxInstructionBytes - 6));
    final added = 'y' * 20;

    final r = await mgr.appendNote(serverId: 's1', heading: '', body: added);

    expect(r.ok, isFalse);
    // 契约：rejected 报的数字一定 <= 调用方自己加的那段长度，否则它无解。
    expect(r.overflowBytes, lessThanOrEqualTo(added.length));
  });

  // ───────── 字节上限：三条写入路径逐一验证 ─────────
  //
  // 这一组是整个改造最容易漏的地方。笔记每轮随 system prompt 重发，漏掉
  // 任何一条路径就等于上限形同虚设。技能库那次就是只拦了 save_skill、
  // 漏掉了设置页手动新建与两条导入路径。

  String oversized() => 'x' * (kMaxInstructionBytes + 1);

  test('上限路径 1 —— replaceNote（手工编辑）超限被拒', () async {
    final r = await mgr.replaceNote(serverId: 's1', body: oversized());

    expect(r.ok, isFalse);
    expect(r.overflowBytes, 1);
    expect(mgr.noteFor('s1'), isNull, reason: '被拒的写入不该落盘');
  });

  test('上限路径 2 —— appendNote（沉淀卡片 / save_note）超限被拒', () async {
    await mgr.replaceNote(serverId: 's1', body: '已有内容');
    final r = await mgr.appendNote(
      serverId: 's1',
      heading: '',
      body: oversized(),
    );

    expect(r.ok, isFalse);
    expect(r.overflowBytes, greaterThan(0));
    expect(mgr.noteFor('s1'), '已有内容', reason: '被拒时原内容必须原样保留');
  });

  test('上限按 UTF-8 字节算，不是字符数', () async {
    // 中文一个字 3 字节。1400 字 = 4200 字节 > 4096，但只有 1400 个字符。
    final r = await mgr.replaceNote(serverId: 's1', body: '中' * 1400);

    expect(r.ok, isFalse);
    expect(r.overflowBytes, 1400 * 3 - kMaxInstructionBytes);
  });

  test('正好等于上限是放行的', () async {
    final r = await mgr.replaceNote(
      serverId: 's1',
      body: 'x' * kMaxInstructionBytes,
    );

    expect(r.ok, isTrue);
    expect(mgr.noteFor('s1')!.length, kMaxInstructionBytes);
  });

  test('overflowBytes 报的是超出量，供 UI 告诉用户该精简多少', () async {
    final r = await mgr.replaceNote(
      serverId: 's1',
      body: 'x' * (kMaxInstructionBytes + 500),
    );

    expect(r.overflowBytes, 500);
  });

  test('failed 与 rejected 是两种失败，不能混为一谈', () {
    const rejected = ServerNoteSaveResult.rejected(42);
    const failed = ServerNoteSaveResult.failed('没指定是哪台机器');

    expect(rejected.ok, isFalse);
    expect(rejected.overflowBytes, 42);
    expect(rejected.error, isNull);

    expect(failed.ok, isFalse);
    expect(failed.overflowBytes, 0);
    expect(failed.error, '没指定是哪台机器');
  });

  test('composeAppendedNote 是纯函数，可以脱离 Manager 单测', () {
    expect(
      composeAppendedNote(current: 'a', heading: 'h', body: 'b'),
      'a\n\n## h\n\nb',
    );
    expect(composeAppendedNote(current: null, heading: '', body: 'b'), 'b');
  });
}
