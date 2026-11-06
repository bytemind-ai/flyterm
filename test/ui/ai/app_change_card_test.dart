import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/app_control/app_change.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/app_change_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TerminalSettings settings;
  late AppControlService svc;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    settings = TerminalSettings(SecureStorageService());
    svc = AppControlService(settings: settings);
  });

  // 钉死 locale：下面有断言中文文案的用例。
  Widget wrap(String batchId) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AppChangeCard(service: svc, batchId: batchId),
        ),
      );

  /// TerminalSettings 的 fontSize/lineHeight setter 有 250ms 持久化 debounce，
  /// 那个 Timer 挂在 fake clock 上，不推进就会以 "Pending timers" 失败。
  Future<void> settle(WidgetTester t) async {
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
  }

  group('明细展示 —— 这是改成卡片的全部意义', () {
    testWidgets('字段名用界面上的词，不是内部键名', (t) async {
      await settings.setFontSize(13);
      await svc.setSetting('fontSize', 16);
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);

      expect(find.text('终端字体大小'), findsOneWidget);
      expect(find.textContaining('fontSize'), findsNothing,
          reason: '卡片上露出了内部键名');
    });

    testWidgets('double 去掉尾零 —— 13 而不是 13.0', (t) async {
      await settings.setFontSize(13);
      await svc.setSetting('fontSize', 16);
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);

      expect(find.textContaining('13 → 16'), findsOneWidget);
      expect(find.textContaining('13.0'), findsNothing);
    });

    testWidgets('bool 显示成开/关', (t) async {
      await svc.setSetting('commandCompletion', false);
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);

      expect(find.textContaining('开 → 关'), findsOneWidget);
    });

    testWidgets('enum 显示成界面上的名字', (t) async {
      await svc.setSetting('cursorStyle', 'block');
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);

      expect(find.textContaining('块状'), findsOneWidget);
      expect(find.textContaining('block'), findsNothing);
    });

    testWidgets('多项变更逐行列出', (t) async {
      await svc.setSetting('fontSize', 16);
      await svc.setSetting('commandCompletion', false);
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);

      expect(find.text('终端字体大小'), findsOneWidget);
      expect(find.text('命令补全'), findsOneWidget);
    });

    testWidgets('超过 3 项折叠，点开展开全部', (t) async {
      await svc.setSetting('fontSize', 16);
      await svc.setSetting('lineHeight', 1.5);
      await svc.setSetting('commandCompletion', false);
      await svc.setSetting('sshCompression', true);
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);

      expect(find.textContaining('还有 1 项'), findsOneWidget);
      await t.tap(find.textContaining('还有 1 项'));
      await settle(t);
      expect(find.textContaining('还有'), findsNothing);
    });
  });

  group('撤销', () {
    testWidgets('点撤销只回滚本批次', (t) async {
      await settings.setFontSize(13);
      await svc.setSetting('fontSize', 16);
      final first = svc.changeLog.currentBatch!.id;

      svc.changeLog.startBatch();
      await svc.setSetting('commandCompletion', false);

      await t.pumpWidget(wrap(first));
      await settle(t);
      await t.tap(find.byKey(Key('app-change-undo-$first')));
      await settle(t);

      expect(settings.fontSize, 13.0);
      expect(settings.commandCompletion, isFalse,
          reason: '撤第一批把第二批的改动也撤了');
    });

    testWidgets('撤销后按钮禁用并改文案', (t) async {
      await settings.setFontSize(13);
      await svc.setSetting('fontSize', 16);
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);
      await t.tap(find.byKey(Key('app-change-undo-$id')));
      await settle(t);

      final btn =
          t.widget<TextButton>(find.byKey(Key('app-change-undo-$id')));
      expect(btn.onPressed, isNull);
      expect(find.text('已撤销'), findsOneWidget);
    });

    testWidgets('含不可逆项时按钮禁用并给说明', (t) async {
      svc.changeLog.record(const AppChange(
        toolName: 'tunnel_create',
        field: 'tunnel:8080',
        oldValue: null,
        newValue: '8080 → localhost:80',
        undo: null,
      ));
      final id = svc.changeLog.currentBatch!.id;

      await t.pumpWidget(wrap(id));
      await settle(t);

      final btn =
          t.widget<TextButton>(find.byKey(Key('app-change-undo-$id')));
      expect(btn.onPressed, isNull);
      expect(find.textContaining('不可撤销'), findsOneWidget);
    });
  });

  testWidgets('批次查不到时降级成历史说明，不给撤销按钮', (t) async {
    await t.pumpWidget(wrap('no-such-batch'));
    await settle(t);

    expect(find.byKey(const Key('app-change-undo-no-such-batch')), findsNothing);
    expect(find.textContaining('无法撤销'), findsOneWidget);
  });

  testWidgets('带前缀的 field 显示成「对象 名字」', (t) async {
    svc.changeLog.record(const AppChange(
      toolName: 'server_entry_create',
      field: 'server:prod-web',
      oldValue: null,
      newValue: 'prod-web',
      undo: null,
    ));
    final id = svc.changeLog.currentBatch!.id;

    await t.pumpWidget(wrap(id));
    await settle(t);

    expect(find.text('服务器 prod-web'), findsOneWidget);
  });
}
