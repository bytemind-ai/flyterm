// AgentSettingsScreen（hub）的行为测试。
//
// 背景：旧版用两行 RadioListTile 表达 ask/bypass。用户报"点『全部放行，
// 不要问』没反应"——根因是 Flutter 的 RadioListTile（未传 toggleable）在
// "该行已选中"时整行 onTap 直接短路、不调用 onChanged；而用户点它的时候
// mode 其实已经是 bypass，页面上表达"已经开着"的信号只有一个不起眼的圆点。
//
// 第一版修法是加常驻状态横幅 + 两张自绘卡片。2026-10-13 换成三档**分段
// 选择器**（ModeSegmented）后那个横幅不再需要：段位高亮本身就是状态展示。
//
// 2026-10-14 拆分：
// 这一页从"8 个区块一页塞"精简成 hub —— 只留权限档、工具档位、两个导航行。
// 放行清单与记忆类入口各自拆成子页，关于它们的断言搬到
// `agent_allowlist_screen_test.dart` / `agent_memory_screen_test.dart`。
// 本文件只测 hub 自己：三档模式、bypass 确认、工具档位、导航行、firstReview。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/agent_allowlist_screen.dart';
import 'package:flyterm/ui/settings/agent_instructions_screen.dart';
import 'package:flyterm/ui/settings/agent_rules_data.dart';
import 'package:flyterm/ui/settings/agent_settings_screen.dart';

import 'agent_settings_test_helpers.dart';

void main() {
  initFfi();

  final l = lookupAppLocalizations(const Locale('zh'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpHub(
    WidgetTester tester, {
    required bool firstReview,
    dynamic agent,
  }) async {
    useBigViewport(tester);
    final m = agent ?? await newAgentManager();
    await pumpWithProviders(
      tester,
      agent: m,
      child: AgentSettingsScreen(firstReview: firstReview),
    );
  }

  // 空 prefs + 未 markRulesReviewed = 新用户，默认档是 plan（见
  // `AgentSessionManager.modeFor` 的迁移说明）。这一组测的是「从任何非
  // bypass 档切到 bypass 都要弹确认框」，与起始档具体是 plan 还是 ask
  // 无关——所以断言跟着新默认走，不必强行 setMode 成 ask。
  group('基础路径：非 bypass 状态下点「全放行」', () {
    testWidgets('弹确认框，确认后 defaultMode 变 bypass', (tester) async {
      final m = await newAgentManager();
      expect(m.defaultMode, PermissionMode.ask);

      await pumpHub(tester, firstReview: false, agent: m);
      await tester.tap(find.byKey(const Key('mode-seg-bypass')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget,
          reason: '非 bypass 状态下点「全放行」应该弹确认框');

      await tester.tap(find.text(MaterialLocalizations.of(
              tester.element(find.byType(AlertDialog)))
          .okButtonLabel));
      await tester.pumpAndSettle();

      expect(m.defaultMode, PermissionMode.bypass);
    });

    testWidgets('确认框点取消，defaultMode 保持原档不变', (tester) async {
      final m = await newAgentManager();
      await pumpHub(tester, firstReview: false, agent: m);

      await tester.tap(find.byKey(const Key('mode-seg-bypass')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text(
          MaterialLocalizations.of(tester.element(find.byType(AlertDialog)))
              .cancelButtonLabel));
      await tester.pumpAndSettle();

      expect(m.defaultMode, PermissionMode.ask);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('状态可见性（原 bug 的核心）', () {
    testWidgets('bypass 档下说明文字是"全放行"那一版', (tester) async {
      final m = await newAgentManager();
      m.defaultMode = PermissionMode.bypass;

      await pumpHub(tester, firstReview: false, agent: m);

      expect(find.text(l.agentPermBypassDesc), findsOneWidget);
      expect(find.text(l.agentPermAskDesc), findsNothing,
          reason: '不能同时把 ask 那版说明也渲染出来');
    });

    testWidgets('点「先问我」段：直接切回 ask，不弹确认框', (tester) async {
      final m = await newAgentManager();
      m.defaultMode = PermissionMode.bypass;

      await pumpHub(tester, firstReview: false, agent: m);
      await tester.tap(find.byKey(const Key('mode-seg-ask')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing,
          reason: '从危险切回安全不该有摩擦');
      expect(m.defaultMode, PermissionMode.ask);
    });

    testWidgets('点已选中的段（bypass 已是 bypass）：no-op', (tester) async {
      final m = await newAgentManager();
      m.defaultMode = PermissionMode.bypass;

      await pumpHub(tester, firstReview: false, agent: m);
      await tester.tap(find.byKey(const Key('mode-seg-bypass')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(m.defaultMode, PermissionMode.bypass);
      // 状态可见性由段位高亮 + 说明文字保证。
      expect(find.text(l.agentPermBypassDesc), findsOneWidget);
    });
  });

  group('三档模式', () {
    testWidgets('三段都在，新用户默认选中 ask', (tester) async {
      final m = await newAgentManager();
      await pumpHub(tester, firstReview: false, agent: m);

      for (final key in ['mode-seg-readOnly', 'mode-seg-ask', 'mode-seg-bypass']) {
        expect(find.byKey(Key(key)), findsOneWidget);
      }
      expect(m.defaultMode, PermissionMode.ask);
      expect(find.text(l.agentPermAskDesc), findsOneWidget);
    });

    testWidgets('从 ask 点 readOnly 段直接切换，不弹确认框', (tester) async {
      final m = await newAgentManager();
      m.defaultMode = PermissionMode.ask;

      await pumpHub(tester, firstReview: false, agent: m);
      await tester.tap(find.byKey(const Key('mode-seg-readOnly')));
      await tester.pumpAndSettle();

      expect(m.defaultMode, PermissionMode.readOnly);
      expect(find.byType(AlertDialog), findsNothing,
          reason: '从 ask 收紧到 readOnly 不该有确认摩擦');
    });

    testWidgets('从 bypass 点 readOnly 段也直接切换', (tester) async {
      final m = await newAgentManager();
      m.defaultMode = PermissionMode.bypass;

      await pumpHub(tester, firstReview: false, agent: m);
      await tester.tap(find.byKey(const Key('mode-seg-readOnly')));
      await tester.pumpAndSettle();

      expect(m.defaultMode, PermissionMode.readOnly);
      expect(find.byType(AlertDialog), findsNothing,
          reason: '从 bypass 收紧到 readOnly 不该有确认摩擦');
    });

    testWidgets('readOnly 档下说明不显示 bypass 那套文案', (tester) async {
      final m = await newAgentManager();
      m.defaultMode = PermissionMode.readOnly;

      await pumpHub(tester, firstReview: false, agent: m);

      expect(find.text(l.agentPermReadOnlyDesc), findsOneWidget);
      expect(find.text(l.agentPermBypassDesc), findsNothing);
    });
  });

  group('hub 保留下来的全局设置项', () {
    testWidgets('工具档位在这一页上', (tester) async {
      final m = await newAgentManager();
      await pumpHub(tester, firstReview: false, agent: m);

      expect(find.text(l.agentToolTierGroup), findsOneWidget);
      expect(find.byType(DropdownButton<AgentToolTier?>), findsOneWidget);
    });

    testWidgets('工具档位下拉能改 mgr.toolTierOverride', (tester) async {
      final m = await newAgentManager();
      await pumpHub(tester, firstReview: false, agent: m);

      await tester.tap(find.byType(DropdownButton<AgentToolTier?>));
      await tester.pumpAndSettle();
      // 下拉菜单里 lean 那个 item（注意 ListTile 上也有一个同名文案，
      // 所以点菜单里最后出现的那一个）。
      await tester.tap(find.text(l.agentToolTierLean).last);
      await tester.pumpAndSettle();

      expect(m.toolTierOverride, AgentToolTier.lean);
    });
  });

  // 拆分之后放行清单与记忆类入口都成了导航行 —— 这里只断言「点得进去」，
  // 两页自己的内容由各自的测试文件覆盖。
  group('两个导航行', () {
    testWidgets('放行清单导航行显示「N / M 类已放行」，点进去是清单页',
        (tester) async {
      final m = await newAgentManager();
      final builtin = m.rules.rules.where((r) => r.builtin).toList();
      await pumpHub(tester, firstReview: false, agent: m);

      expect(find.text(l.agentAllowlistEntry), findsOneWidget);
      // 不硬编码数字：默认清单里除了分组表 6 组，还有一组未被覆盖的
      // builtin 规则（git 那几条）落在兜底组 —— 用 helper 现算期望值，
      // 未来 defaultAllowRules 增删时这条断言自动跟着走。
      expect(
        find.text(l.agentAllowlistSubtitleEnabled(
            enabledGroupCount(builtin), totalGroupCount(builtin))),
        findsOneWidget,
      );

      await tester.tap(find.text(l.agentAllowlistEntry));
      await tester.pumpAndSettle();

      expect(find.byType(AgentAllowlistScreen), findsOneWidget);
    });

    testWidgets('关掉一整组后 subtitle 计数下降', (tester) async {
      final m = await newAgentManager();
      // 「文件内容」组整组关掉。计数口径是 `any(enabled)`，要整组变 0 才能
      // 看到数字降 1 —— 只关一条不算（同 `_RuleGroupSection` 的开关状态）。
      for (final p in ['ls *', 'cat *', 'head *', 'tail *', 'grep *', 'stat *']) {
        m.setRuleEnabled(p, false);
      }
      final builtin = m.rules.rules.where((r) => r.builtin).toList();
      await pumpHub(tester, firstReview: false, agent: m);

      expect(
        find.text(l.agentAllowlistSubtitleEnabled(
            enabledGroupCount(builtin), totalGroupCount(builtin))),
        findsOneWidget,
        reason: '关闭一个分组后 hub 上的计数必须跟着变 —— 这是 spec D8'
            '「收进子页后仍能在首页看到当前值」的兑现',
      );
    });

    testWidgets('助手记忆：四项都直接展开在 hub 上（不再多一层子页）',
        (tester) async {
      final m = await newAgentManager();
      await pumpHub(tester, firstReview: false, agent: m);

      // 段头保留分组语义
      expect(find.text(l.agentMemorySection), findsOneWidget,
          reason: '「助手记忆」这个概念不能丢 —— 它和权限档性质不同');
      // 四项都在首屏，不用点进去
      expect(find.text(l.agentInstructionsEntry), findsOneWidget);
      expect(find.text(l.agentSkillsEntry), findsOneWidget);
      expect(find.text(l.agentServerNotesOverviewEntry), findsOneWidget);
      expect(find.text(l.agentKnowledgeCaptureTitle), findsOneWidget);
    });

    testWidgets('点说明行直接进编辑页 —— 中间那一层子页已删', (tester) async {
      final m = await newAgentManager();
      await pumpHub(tester, firstReview: false, agent: m);

      await tester.tap(find.text(l.agentInstructionsEntry));
      await tester.pumpAndSettle();

      expect(find.byType(AgentInstructionsScreen), findsOneWidget,
          reason: '展开回 hub 的意义就是少一层点击（原为三层深）');
    });

    testWidgets('说明行的 subtitle 反映当前值', (tester) async {
      final m = await newAgentManager();
      expect(m.instructions, isNull);
      await pumpHub(tester, firstReview: false, agent: m);
      expect(find.text(l.agentInstructionsEntryEmpty), findsOneWidget);
    });

    testWidgets('沉淀开关直接在 hub 上可切', (tester) async {
      final m = await newAgentManager();
      expect(m.knowledgeCaptureEnabled, isTrue);
      await pumpHub(tester, firstReview: false, agent: m);

      await tester.tap(find.widgetWithText(
          SwitchListTile, l.agentKnowledgeCaptureTitle));
      await tester.pumpAndSettle();

      expect(m.knowledgeCaptureEnabled, isFalse);
    });
  });

  group('firstReview 入口', () {
    testWidgets('firstReview:false 不显示说明条与「去过目」按钮', (tester) async {
      final m = await newAgentManager();
      await pumpHub(tester, firstReview: false, agent: m);

      expect(find.text(l.agentRulesFirstReview), findsNothing);
      expect(find.text(l.agentRulesGoReview), findsNothing);
    });

    testWidgets(
        'firstReview:true 显示说明条；点「去过目」进清单页，返回后标记已过目并关闭',
        (tester) async {
      final m = await newAgentManager();
      expect(m.hasReviewedRules, isFalse);
      await pumpHub(tester, firstReview: true, agent: m);

      expect(find.text(l.agentRulesFirstReview), findsOneWidget);
      expect(find.text(l.agentRulesGoReview), findsOneWidget);

      await tester.tap(find.text(l.agentRulesGoReview));
      await tester.pumpAndSettle();

      // 按钮把用户送到清单页 —— 强制过目的语义是「过目放行清单」，
      // 停在一个没有清单的 hub 页不算过目。
      expect(find.byType(AgentAllowlistScreen), findsOneWidget);
      // 还没返回 hub，此时不该标记已过目。
      expect(m.hasReviewedRules, isFalse,
          reason: '进入清单页但还没退出时，不能提前算作已过目');

      // 从清单页返回 → 标记已过目并 pop 掉 hub。用 AppBar 上那个真实的
      // 返回按钮触发（`pageBack` 在这套测试树里找不到 Cupertino 风格按钮），
      // 不能用 `Navigator.pop` 直调 —— 那样绕过了「返回后再标记」这个时序。
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(m.hasReviewedRules, isTrue);
      expect(find.byType(AgentSettingsScreen), findsNothing);
    });

    testWidgets('两个入口的交互（点 bypass 弹确认框）在 firstReview 两种取值下一致',
        (tester) async {
      for (final firstReview in [false, true]) {
        // 每轮重置——上一轮已经把 mode 落到 bypass，不重置的话第二轮进来
        // 就已经是 bypass，点「全部放行」变成点已选中项，验证的就不是这
        // 条路径了。
        SharedPreferences.setMockInitialValues({});
        final m = await newAgentManager();
        await pumpHub(tester, firstReview: firstReview, agent: m);

        await tester.tap(find.byKey(const Key('mode-seg-bypass')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget,
            reason: 'firstReview=$firstReview 时点 bypass 段仍应弹确认框');

        await tester.tap(find.text(MaterialLocalizations.of(
                tester.element(find.byType(AlertDialog)))
            .okButtonLabel));
        await tester.pumpAndSettle();
        expect(m.defaultMode, PermissionMode.bypass);
      }
    });
  });
}
