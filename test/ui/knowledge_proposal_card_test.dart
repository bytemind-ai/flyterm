import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/knowledge.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/dense_event_row.dart';
import 'package:flyterm/ui/ai/widgets/knowledge_proposal_card.dart';

KnowledgeCandidate skill({String? updates}) => KnowledgeCandidate(
      target: KnowledgeTarget.skill,
      name: 'nginx-502',
      description: '排查 502 的标准顺序',
      body: '1. 看 upstream\n2. 看 error.log',
      updatesExisting: updates,
    );

KnowledgeCandidate note() => const KnowledgeCandidate(
      target: KnowledgeTarget.serverNote,
      name: '配置位置',
      description: '',
      body: '这台的 nginx 配置在 /data/etc',
    );

Widget host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('渲染候选的标题', (t) async {
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill()],
      resolved: const {},
      onSave: (_, __) {},
      onDismiss: () {},
    )));
    expect(find.text('nginx-502'), findsOneWidget);
  });

  testWidgets('一张卡装两条候选', (t) async {
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill(), note()],
      resolved: const {},
      onSave: (_, __) {},
      onDismiss: () {},
    )));
    expect(find.text('nginx-502'), findsOneWidget);
    expect(find.text('配置位置'), findsOneWidget);
  });

  // 正文全文是凭据泄漏的最后一道人工闸门 —— redactSecrets 拦不住
  // `-phunter2` 这类形状，用户得能看见才拦得住。
  testWidgets('可以展开看正文全文', (t) async {
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill()],
      resolved: const {},
      onSave: (_, __) {},
      onDismiss: () {},
    )));
    expect(find.textContaining('看 upstream'), findsNothing);

    await t.tap(find.byIcon(Icons.expand_more).first);
    await t.pumpAndSettle();
    expect(find.textContaining('看 upstream'), findsOneWidget);
  });

  testWidgets('点存入回调带上下标与候选', (t) async {
    int? gotIndex;
    KnowledgeCandidate? gotCand;
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill()],
      resolved: const {},
      onSave: (i, c) {
        gotIndex = i;
        gotCand = c;
      },
      onDismiss: () {},
    )));
    await t.tap(find.text('存入'));
    await t.pumpAndSettle();
    expect(gotIndex, equals(0));
    expect(gotCand?.name, equals('nginx-502'));
  });

  testWidgets('命中已有 skill 时按钮显示「更新 xxx」', (t) async {
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill(updates: 'nginx-502')],
      resolved: const {},
      onSave: (_, __) {},
      onDismiss: () {},
    )));
    expect(find.text('更新 nginx-502'), findsOneWidget);
    expect(find.text('存入'), findsNothing);
  });

  // 用两条候选、只 resolve 一条：若全部 resolve 整张卡会退成流水行（见
  // 下方「全部处理完之后退成流水行」用例），这里要测的是完整卡内单个
  // 已处理条目的样子，得留一条未处理的撑住完整卡。
  testWidgets('已处理的条目显示「已存入」且按钮不可点', (t) async {
    var saves = 0;
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill(), note()],
      resolved: const {0},
      onSave: (_, __) => saves++,
      onDismiss: () {},
    )));
    expect(find.text('已存入'), findsOneWidget);
    expect(find.text('存入'), findsOneWidget);
    expect(saves, equals(0));
  });

  // 补上「分类错了不可纠」——模型判归属会出错，用户当场能改
  testWidgets('点归属标识可以切换去向', (t) async {
    KnowledgeCandidate? saved;
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill()],
      resolved: const {},
      onSave: (_, c) => saved = c,
      onDismiss: () {},
    )));
    await t.tap(find.text('技能'));
    await t.pumpAndSettle();
    expect(find.text('本机笔记'), findsOneWidget);

    await t.tap(find.text('存入'));
    await t.pumpAndSettle();
    expect(saved?.target, equals(KnowledgeTarget.serverNote));
  });

  testWidgets('点忽略触发回调', (t) async {
    var dismissed = 0;
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill()],
      resolved: const {},
      onSave: (_, __) {},
      onDismiss: () => dismissed++,
    )));
    await t.tap(find.text('忽略'));
    await t.pumpAndSettle();
    expect(dismissed, equals(1));
  });

  testWidgets('候选为空时不渲染任何东西', (t) async {
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: const [],
      resolved: const {},
      onSave: (_, __) {},
      onDismiss: () {},
    )));
    expect(find.byType(Card), findsNothing);
    expect(find.text('存入'), findsNothing);
  });

  testWidgets('全部处理完之后退成流水行', (t) async {
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill(), note()],
      resolved: const {0, 1},
      onSave: (_, __) {},
      onDismiss: () {},
    )));
    expect(find.byType(DenseEventRow), findsOneWidget);
    expect(find.text('nginx-502'), findsNothing);
  });

  testWidgets('退成流水行后仍能展开看到提议过哪几条', (t) async {
    // 收起的那一行说不出提议过什么、去向是哪、存了还是忽略了。没有展开区
    // 的话，「如实反映用户的选择」这句话就不成立。
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill(), note()],
      resolved: {0, 1},
      onSave: (_, __) {},
      onDismiss: () {},
    )));

    await t.tap(find.byIcon(Icons.expand_more));
    await t.pumpAndSettle();

    expect(find.text('nginx-502'), findsOneWidget);
    expect(find.text('配置位置'), findsOneWidget);
  });

  testWidgets('还有未处理的仍是完整卡', (t) async {
    await t.pumpWidget(host(KnowledgeProposalCard(
      candidates: [skill(), note()],
      resolved: const {0},
      onSave: (_, __) {},
      onDismiss: () {},
    )));
    expect(find.byType(DenseEventRow), findsNothing);
    expect(find.text('nginx-502'), findsOneWidget);
  });
}
