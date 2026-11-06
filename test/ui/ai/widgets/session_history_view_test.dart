// 历史会话列表的渲染与三个交互（打开 / 标星 / 长按删除）。
//
// 这个 widget 是纯展示 + 回调，不碰 repository —— 数据与写库都在 ai_panel 那
// 一层。所以这里全部用构造好的 AgentSession 行来驱动，不需要 SQLite。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/data/models/agent_session.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/data/repositories/agent_session_repository.dart'
    show kSessionsPerServer, kSessionsGlobal;
import 'package:flyterm/ui/ai/widgets/session_history_view.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

AgentSession _row({
  int id = 1,
  String? title = 'why 502',
  int events = 7,
  bool starred = false,
}) =>
    AgentSession(
      id: id,
      serverId: 's1',
      title: title,
      archive: '{}',
      eventCount: events,
      starred: starred,
      createdAt: DateTime(2026, 8, 20),
      updatedAt: DateTime(2026, 8, 20),
    );

/// 只传必需回调的便捷构造 —— 每个用例只关心其中一个。
Widget _view({
  required List<AgentSession> sessions,
  void Function(int id)? onOpen,
  void Function(int id, bool starred)? onToggleStar,
  void Function(int id)? onDelete,
  void Function(int id)? onExport,
  int quota = kSessionsPerServer,
}) =>
    SessionHistoryView(
      sessions: sessions,
      onOpen: onOpen ?? (_) {},
      onToggleStar: onToggleStar ?? (_, __) {},
      onDelete: onDelete ?? (_) {},
      onExport: onExport ?? (_) {},
      quota: quota,
    );

void main() {
  final l = lookupAppLocalizations(const Locale('zh'));

  testWidgets('渲染标题与事件数', (tester) async {
    await tester.pumpWidget(
      _wrap(_view(sessions: [_row(title: '为什么 502', events: 12)])),
    );
    await tester.pump();

    expect(find.text('为什么 502'), findsOneWidget);
    // subtitle 是「相对时间 · N 条」拼成的一个 Text，只断言事件数那半截：
    // 相对时间随运行日期漂移，把它写进断言等于给测试装一颗定时炸弹。
    expect(find.textContaining(l.aiHistoryEvents(12)), findsOneWidget);
  });

  testWidgets('无标题时显示占位而不是空白', (tester) async {
    await tester.pumpWidget(_wrap(_view(sessions: [_row(title: null)])));
    await tester.pump();

    expect(find.text(l.aiHistoryUntitled), findsOneWidget);
  });

  testWidgets('空列表显示空态', (tester) async {
    await tester.pumpWidget(_wrap(_view(sessions: const [])));
    await tester.pump();

    expect(find.text(l.aiHistoryEmpty), findsOneWidget);
  });

  testWidgets('未标星显示空心星，点击回传 true', (tester) async {
    int? toggledId;
    bool? toggledTo;
    await tester.pumpWidget(_wrap(_view(
      sessions: [_row(id: 9, starred: false)],
      onToggleStar: (id, v) {
        toggledId = id;
        toggledTo = v;
      },
    )));
    await tester.pump();

    expect(find.byIcon(Icons.star_border), findsOneWidget);
    await tester.tap(find.byIcon(Icons.star_border));
    expect(toggledId, 9);
    expect(toggledTo, isTrue);
  });

  testWidgets('已标星显示实心星，点击回传 false', (tester) async {
    bool? toggledTo;
    await tester.pumpWidget(_wrap(_view(
      sessions: [_row(starred: true)],
      onToggleStar: (_, v) => toggledTo = v,
    )));
    await tester.pump();

    expect(find.byIcon(Icons.star), findsOneWidget);
    await tester.tap(find.byIcon(Icons.star));
    expect(toggledTo, isFalse, reason: '实心星再点应该是取消标星');
  });

  testWidgets('点击行触发打开', (tester) async {
    int? opened;
    await tester.pumpWidget(_wrap(_view(
      sessions: [_row(id: 5)],
      onOpen: (id) => opened = id,
    )));
    await tester.pump();

    await tester.tap(find.text('why 502'));
    expect(opened, 5);
  });

  testWidgets('长按弹删除确认，确认后触发回调', (tester) async {
    int? deleted;
    await tester.pumpWidget(_wrap(_view(
      sessions: [_row(id: 3)],
      onDelete: (id) => deleted = id,
    )));
    await tester.pump();

    await tester.longPress(find.text('why 502'));
    await tester.pumpAndSettle();
    expect(find.text(l.aiHistoryDeleteTitle), findsOneWidget);

    await tester.tap(find.text(l.aiHistoryDelete));
    await tester.pumpAndSettle();
    expect(deleted, 3);
  });

  testWidgets('长按后取消，不触发删除 —— 误触不该丢会话', (tester) async {
    var deleted = false;
    await tester.pumpWidget(_wrap(_view(
      sessions: [_row(id: 3)],
      onDelete: (_) => deleted = true,
    )));
    await tester.pump();

    await tester.longPress(find.text('why 502'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.cancel));
    await tester.pumpAndSettle();

    expect(deleted, isFalse);
  });

  group('搜索', () {
    testWidgets('输入关键词后只剩匹配的行', (tester) async {
      await tester.pumpWidget(_wrap(_view(sessions: [
        _row(id: 1, title: 'nginx 502'),
        _row(id: 2, title: '磁盘满了'),
      ])));
      await tester.pump();
      expect(find.text('nginx 502'), findsOneWidget);
      expect(find.text('磁盘满了'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'nginx');
      await tester.pump();

      expect(find.text('nginx 502'), findsOneWidget);
      expect(find.text('磁盘满了'), findsNothing);
    });

    testWidgets('匹配不到时给一句说明，而不是空白', (tester) async {
      await tester.pumpWidget(_wrap(_view(sessions: [_row(title: 'nginx')])));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'redis');
      await tester.pump();

      expect(find.text(l.aiHistoryNoMatch), findsOneWidget,
          reason: '搜不到却只剩空白，用户不知道是没结果还是坏了');
    });

    testWidgets('清空按钮把列表恢复', (tester) async {
      await tester.pumpWidget(_wrap(_view(sessions: [
        _row(id: 1, title: 'nginx'),
        _row(id: 2, title: 'redis'),
      ])));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'nginx');
      await tester.pump();
      expect(find.text('redis'), findsNothing);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump();

      expect(find.text('redis'), findsOneWidget);
    });

    testWidgets('没有输入时不显示清空按钮', (tester) async {
      await tester.pumpWidget(_wrap(_view(sessions: [_row()])));
      await tester.pump();

      expect(find.byIcon(Icons.clear), findsNothing);
    });
  });

  group('配额说明', () {
    /// 补一个此前是**静默**的行为：旧会话被自动清理而界面上从没提过。
    /// 一行说明把它从「bug」变成「已知的规则」。
    testWidgets('列表底部说明保留条数', (tester) async {
      await tester.pumpWidget(
          _wrap(_view(sessions: [_row()], quota: kSessionsPerServer)));
      await tester.pump();

      expect(find.text(l.aiHistoryQuotaHint(kSessionsPerServer)),
          findsOneWidget);
      // 文案里要真的带上那个数字，不能只说"有个上限"。
      expect(find.textContaining('$kSessionsPerServer'), findsWidgets);
    });

    testWidgets('数字来自传入的 quota，不是写死的常量', (tester) async {
      // 全局 AI tab 的额度（100）比普通服务器（50）宽。写死常量会让其中
      // 一边显示一个与实际保留数不符的数字 —— 那比不显示更糟。
      await tester.pumpWidget(
          _wrap(_view(sessions: [_row()], quota: kSessionsGlobal)));
      await tester.pump();

      expect(find.text(l.aiHistoryQuotaHint(kSessionsGlobal)), findsOneWidget);
      expect(find.textContaining('$kSessionsGlobal'), findsWidgets);
      expect(find.text(l.aiHistoryQuotaHint(kSessionsPerServer)), findsNothing,
          reason: '全局 tab 不该显示普通服务器的额度');
    });
  });

}
