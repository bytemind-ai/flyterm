import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/remote_skills.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/skill_import_preview_screen.dart';

void main() {
  PendingSkill p(String name, {String desc = 'd'}) => PendingSkill(
        name: name,
        description: desc,
        body: 'body',
        source: SkillSource.remote,
      );

  Future<void> pump(
    WidgetTester tester,
    List<PendingSkill> items, {
    List<String> existing = const [],
    void Function(List<PendingSkill>)? onConfirm,
    int skipped = 0,
  }) async {
    // 撞名三选控件（SegmentedButton）让卡片变高，默认 800×600 的测试视口
    // 会把它挤到折叠区之外，跟 keybar 编辑器测试用的是同一套约定。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SkillImportPreviewScreen(
        candidates: items,
        existingNames: existing,
        skippedCount: skipped,
        onConfirm: onConfirm ?? (_) {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('列出每一条候选', (tester) async {
    await pump(tester, [p('nginx'), p('deploy')]);
    expect(find.text('nginx'), findsOneWidget);
    expect(find.text('deploy'), findsOneWidget);
  });

  testWidgets('确认时只回传勾选的那些', (tester) async {
    List<PendingSkill>? got;
    await pump(tester, [p('a'), p('b')], onConfirm: (v) => got = v);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(got!.map((s) => s.name), equals(['b']));
  });

  testWidgets('缺 description 的条目默认不勾选，并提示补一行', (tester) async {
    await pump(tester, [p('a', desc: '')]);
    final cb = tester.widget<Checkbox>(find.byType(Checkbox).first);
    expect(cb.value, isFalse);
    expect(find.textContaining('描述'), findsWidgets);
  });

  testWidgets('缺 description 时勾选框是禁用的 —— 勾不上比悄悄失效诚实', (tester) async {
    await pump(tester, [p('a', desc: '')]);
    final cb = tester.widget<Checkbox>(find.byType(Checkbox).first);
    expect(cb.onChanged, isNull);
  });

  testWidgets('撞名的条目显示冲突提示', (tester) async {
    await pump(tester, [p('nginx')], existing: ['nginx']);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('编辑 description 之后可以勾选并回传新值', (tester) async {
    List<PendingSkill>? got;
    await pump(tester, [p('a', desc: '')], onConfirm: (v) => got = v);

    await tester.enterText(find.byType(TextField).first, '补的描述');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(got!.single.description, equals('补的描述'));
  });

  testWidgets('候选为空时显示「没找到」说明', (tester) async {
    await pump(tester, const []);
    expect(find.textContaining('没有技能'), findsOneWidget);
  });

  testWidgets('有解析失败的份数时显示一行说明', (tester) async {
    await pump(tester, [p('a')], skipped: 3);
    expect(find.textContaining('3'), findsWidgets);
  });

  // ── 撞名三选：覆盖 / 两份都留 / 跳过 ───────────────────────────────
  //
  // 空 description 的代价是「索引里多一行废话，每次请求持续小额扣费」；
  // 误覆盖是一次性丢数据，且没有任何撤销手段——用户可能已经在详情页手动
  // 编辑过那条技能的正文。两者不是一个量级，所以撞名默认必须是「跳过」，
  // 不能像空 description 那样还能"仍可勾选"。

  testWidgets('撞名条目默认选择是"跳过"，确认后不出现在结果里', (tester) async {
    List<PendingSkill>? got;
    await pump(tester, [p('nginx')],
        existing: ['nginx'], onConfirm: (v) => got = v);

    await tester.tap(find.byKey(const Key('skillImportConfirmButton')));
    await tester.pumpAndSettle();

    expect(got, isEmpty);
  });

  testWidgets('选择"覆盖"后确认，结果里那条保持原 name', (tester) async {
    List<PendingSkill>? got;
    await pump(tester, [p('nginx')],
        existing: ['nginx'], onConfirm: (v) => got = v);

    await tester.tap(find.text('覆盖'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skillImportConfirmButton')));
    await tester.pumpAndSettle();

    expect(got!.single.name, equals('nginx'));
  });

  testWidgets('选择"两份都留"后确认，结果里那条 name 不等于原 name 且不在 existingNames 里',
      (tester) async {
    List<PendingSkill>? got;
    await pump(tester, [p('nginx')],
        existing: ['nginx'], onConfirm: (v) => got = v);

    await tester.tap(find.text('两份都留'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skillImportConfirmButton')));
    await tester.pumpAndSettle();

    expect(got!.single.name, isNot(equals('nginx')));
    expect(got!.single.name.toLowerCase(), isNot(equals('nginx')));
  });

  testWidgets('不撞名的条目不显示三选控件', (tester) async {
    await pump(tester, [p('nginx')]); // existing 默认空，没有撞名

    expect(find.text('跳过'), findsNothing);
    expect(find.text('覆盖'), findsNothing);
    expect(find.text('两份都留'), findsNothing);
  });

  testWidgets('"两份都留"生成的新 name 是确定性的——同样输入同样结果', (tester) async {
    List<PendingSkill>? got1;
    await pump(tester, [p('nginx')],
        existing: ['nginx'], onConfirm: (v) => got1 = v);
    await tester.tap(find.text('两份都留'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skillImportConfirmButton')));
    await tester.pumpAndSettle();

    List<PendingSkill>? got2;
    await pump(tester, [p('nginx')],
        existing: ['nginx'], onConfirm: (v) => got2 = v);
    await tester.tap(find.text('两份都留'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skillImportConfirmButton')));
    await tester.pumpAndSettle();

    expect(got1!.single.name, equals(got2!.single.name));
  });

  testWidgets('同批次两条都撞名且都选"两份都留"时，两个新 name 互不相同', (tester) async {
    List<PendingSkill>? got;
    await pump(tester, [p('nginx'), p('nginx')],
        existing: ['nginx'], onConfirm: (v) => got = v);

    final keepBoth = find.text('两份都留');
    expect(keepBoth, findsNWidgets(2));
    await tester.tap(keepBoth.at(0));
    await tester.pumpAndSettle();
    // 第一次点击之后第二条的按钮位置不变，重新取一次 finder 避免陈旧引用。
    await tester.tap(find.text('两份都留').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skillImportConfirmButton')));
    await tester.pumpAndSettle();

    expect(got!.length, equals(2));
    expect(got![0].name, isNot(equals(got![1].name)));
  });
}
