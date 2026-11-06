import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/widgets/asset_editor.dart';

/// `AssetEditor` 的行为：加/改/删、路径校验、可执行位。
Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('列出已有附件，带可执行标识', (tester) async {
    await tester.pumpWidget(_wrap(AssetEditor(
      assets: const [
        AgentSkillAsset(path: 'scripts/x.sh', content: 'z', executable: true),
        AgentSkillAsset(path: 't.conf', content: 'y'),
      ],
      onChanged: (_) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('scripts/x.sh'), findsOneWidget);
    expect(find.text('t.conf'), findsOneWidget);
    expect(find.byIcon(Icons.terminal), findsOneWidget);
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);
  });

  testWidgets('空列表给出提示', (tester) async {
    await tester.pumpWidget(_wrap(AssetEditor(
      assets: const [],
      onChanged: (_) {},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有附件'), findsOneWidget);
  });

  testWidgets('点 × 删掉一份', (tester) async {
    List<AgentSkillAsset>? out;
    await tester.pumpWidget(_wrap(AssetEditor(
      assets: const [
        AgentSkillAsset(path: 'a.sh', content: 'A'),
        AgentSkillAsset(path: 'b.sh', content: 'B'),
      ],
      onChanged: (v) => out = v,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    expect(out, hasLength(1));
    expect(out!.single.path, equals('b.sh'));
  });

  testWidgets('只读模式不显示添加与删除', (tester) async {
    await tester.pumpWidget(_wrap(AssetEditor(
      assets: const [AgentSkillAsset(path: 'a.sh', content: 'A')],
      onChanged: (_) {},
      readOnly: true,
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('加一份附件：非法路径时保存按钮禁用', (tester) async {
    List<AgentSkillAsset>? out;
    await tester.pumpWidget(_wrap(AssetEditor(
      assets: const [],
      onChanged: (v) => out = v,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加文件'));
    await tester.pumpAndSettle();

    // 填一个逃逸路径。
    // 不用 find.widgetWithText：labelText 渲染的 Text 不是 TextField 的
    // 后代，那个 finder 匹配不到。按顺序取（0 = 路径，1 = 内容）。
    await tester.enterText(find.byType(TextField).at(0), '../evil.sh');
    await tester.enterText(find.byType(TextField).at(1), 'x');
    await tester.pumpAndSettle();

    expect(find.textContaining('必须是相对路径'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull, reason: '非法路径不该能保存');
    expect(out, isNull);
  });

  testWidgets('加一份附件：合法时回写', (tester) async {
    List<AgentSkillAsset>? out;
    await tester.pumpWidget(_wrap(AssetEditor(
      assets: const [],
      onChanged: (v) => out = v,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加文件'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'scripts/run.sh');
    await tester.enterText(find.byType(TextField).at(1), 'echo hi');
    // 打开可执行位。
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(out, hasLength(1));
    expect(out!.single.path, equals('scripts/run.sh'));
    expect(out!.single.content, equals('echo hi'));
    expect(out!.single.executable, isTrue);
  });

  testWidgets('同一路径再加一份时替换而不是追加', (tester) async {
    List<AgentSkillAsset>? out;
    await tester.pumpWidget(_wrap(AssetEditor(
      assets: const [AgentSkillAsset(path: 'x.sh', content: 'OLD')],
      onChanged: (v) => out = v,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加文件'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'x.sh');
    await tester.enterText(find.byType(TextField).at(1), 'NEW');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(out, hasLength(1), reason: '与库里 UNIQUE(skill_id,path) 一致');
    expect(out!.single.content, equals('NEW'));
  });
}
