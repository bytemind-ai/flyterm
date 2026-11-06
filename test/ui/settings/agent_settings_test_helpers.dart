// AI Agent 设置页族（hub + 两个子页）的共享测试脚手架。
//
// hub 与子页都订阅 `AgentSessionManager`（技能子页那类还要
// `AgentSkillManager` / `ServerNotesManager`），构造 provider 树的代码在三个
// 测试文件里逐字重复 —— 抽到这里，各文件只关心自己的断言。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/agent_skill_manager.dart';
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/agent_skill_repository.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';

/// AI Agent 设置页族的内容比默认 800×600 测试视口长（权限档 + 说明条 +
/// 工具档位 + 导航行）。不放大视口的话，ListView 的 sliver 懒加载不会构建
/// 滚出视口之外的条目，`find` 会直接扑空 —— 这和 CLAUDE.md 里记录的 keybar
/// 编辑器测试是同一个坑。
void useBigViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 内存 db 上起一个空技能库。必须包 `tester.runAsync`：sqflite_common_ffi
/// 的 db 打开走真实 FFI/IO，直接 await 在 `testWidgets` 的 fake-async 环境
/// 里不会被正常调度，会挂死（而不是报错）。`runAsync` 让这段代码跳出 fake
/// zone、用真实事件循环跑完。
Future<AgentSkillManager> newSkillManager(WidgetTester tester) async {
  late AgentSkillManager skillMgr;
  await tester.runAsync(() async {
    final db = await AppDatabase.open(inMemory: true);
    addTearDown(db.close);
    skillMgr = AgentSkillManager(AgentSkillRepository(db));
    await skillMgr.reload();
  });
  return skillMgr;
}

/// 同上，起一个空的机器笔记库。hub 的「助手记忆」行要读它的条数。
Future<ServerNotesManager> newNotesManager(WidgetTester tester) async {
  late ServerNotesManager notesMgr;
  await tester.runAsync(() async {
    final db = await AppDatabase.open(inMemory: true);
    addTearDown(db.close);
    notesMgr = ServerNotesManager(ServerNotesRepository(db));
    await notesMgr.load();
  });
  return notesMgr;
}

Future<AgentSessionManager> newAgentManager() async =>
    AgentSessionManager(await SharedPreferences.getInstance());

/// 把 [child] 包进整套 provider + MaterialApp（zh locale）。
///
/// `sqfliteFfiInit()` / `databaseFactory` 由调用方在 `main()` 里设好 ——
/// 那是每个测试文件一次的事，不适合藏在 helper 里重复执行。
Future<void> pumpWithProviders(
  WidgetTester tester, {
  required AgentSessionManager agent,
  required Widget child,
  AgentSkillManager? skills,
  ServerNotesManager? notes,
}) async {
  final skillMgr = skills ?? await newSkillManager(tester);
  final notesMgr = notes ?? await newNotesManager(tester);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AgentSessionManager>.value(value: agent),
        ChangeNotifierProvider<AgentSkillManager>.value(value: skillMgr),
        ChangeNotifierProvider<ServerNotesManager>.value(value: notesMgr),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 开一个独立的内存 db。调用方负责 `addTearDown(db.close)` —— 每个测试必须
/// 用自己的库，共享内存实例会让状态在测试之间泄漏（CLAUDE.md 已记这条）。
///
/// 必须在 `tester.runAsync` 里调（原因同 [newSkillManager]）。
Future<Database> openMemoryDb(WidgetTester tester) async {
  late Database db;
  await tester.runAsync(() async {
    db = await AppDatabase.open(inMemory: true);
  });
  addTearDown(db.close);
  return db;
}

/// 让 sqflite_common_ffi 可用。每个测试文件的 `main()` 开头调一次。
void initFfi() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
