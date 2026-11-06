import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_instructions.dart'
    show kMaxInstructionBytes;
import 'package:flyterm/ai/agent/server_notes_manager.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_notes_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/agent_server_notes_sheet.dart';

const _serverId = 'srv-notes';

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

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

  /// 把 sheet 直接当页面 pump —— 它是个普通 widget，不必真的走
  /// showModalBottomSheet 才能测内容。
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ServerNotesManager>.value(
        value: mgr,
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AgentServerNotesSheet(serverId: _serverId)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('显示已有内容', (tester) async {
    // 直接 await sqflite 操作会在 testWidgets 的 zone 里挂死十分钟而不是
    // 报错，必须包进 runAsync。
    await tester.runAsync(() async {
      await mgr.replaceNote(serverId: _serverId, body: '这台用 podman 不用 docker');
    });
    await pump(tester);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '这台用 podman 不用 docker',
    );
  });

  testWidgets('原本没有笔记时输入框是空的', (tester) async {
    await pump(tester);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('编辑后点保存会落库', (tester) async {
    await tester.runAsync(() async {
      await mgr.replaceNote(serverId: _serverId, body: '旧内容');
    });
    await pump(tester);

    await tester.enterText(find.byType(TextField), '新内容');
    await tester.pump();

    // FilledButton.onPressed 是同步回调，_save() 在里面是 fire-and-forget——
    // tap 本身不会等那次写入完成。必须连同 tap 一起放进 runAsync，再用
    // until 轮询等写入真正落地，而不是指望一次 pump 就够：固定 sleep 在
    // 并发跑全量测试时会被负载推翻，导致保存在 tearDown 关库之后才完成，
    // 报 database_closed（而且只在全量跑时偶发，单独跑永远绿）。
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, l.agentServerNotesSave));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (mgr.noteFor(_serverId) != '新内容' &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(mgr.noteFor(_serverId), '新内容');
  });

  testWidgets('超限时保存按钮禁用、不落库', (tester) async {
    // 注意：这里没有、也不该断言超限提示的 SnackBar ——`_save()` 里那个
    // `!result.ok` 分支在实践中到不了（UI 的 `over` 按未 trim 字节判，
    // `replaceNote` 按 trim 后字节判，后者必然更小或相等；保存按钮已经在
    // `over` 为真时被禁用，点不到 `_save`）。那段 SnackBar 代码是防御性
    // 兜底，不是这条交互路径真正的反馈渠道，所以测试只断言按钮状态和
    // 落库结果。详见 `agent_server_notes_sheet.dart` 里对应的注释。
    await pump(tester);

    final oversized = 'x' * (kMaxInstructionBytes + 10);
    await tester.enterText(find.byType(TextField), oversized);
    await tester.pump();

    // 保存按钮应该已经被禁用。
    final button =
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);

    expect(mgr.noteFor(_serverId), isNull, reason: '不该落库');
  });
}
