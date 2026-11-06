// AgentAllowlistScreen（放行清单子页）的行为测试。
//
// 这些断言原先住在 `agent_settings_screen_test.dart` 里 —— 那时清单是 hub
// 首页底部的折叠区，测试要先 `_expandDetails` 点开。2026-10-14 拆分成子页
// 后，这一页直接就是清单，展开那一步没了，断言内容基本原样保留 —— 能力一个
// 没少（简化只做在信息层级上，不做在能力上），这正是本文件要锚住的。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/permission_rules.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/agent_allowlist_screen.dart';

import 'agent_settings_test_helpers.dart';

void main() {
  initFfi();

  final l = lookupAppLocalizations(const Locale('zh'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpAllowlist(WidgetTester tester) async {
    useBigViewport(tester);
    final m = await newAgentManager();
    await pumpWithProviders(
      tester,
      agent: m,
      child: const AgentAllowlistScreen(),
    );
  }

  group('概览', () {
    testWidgets('两行只读概览在页顶 —— 不看 22 条 pattern 也知道总规则',
        (tester) async {
      await pumpAllowlist(tester);

      expect(find.text(l.agentCapabilityAutoLabel), findsOneWidget);
      expect(find.text(l.agentCapabilityAskLabel), findsOneWidget);
    });

    testWidgets('清单页不再折叠：分组直接可见（点进来就是为看它）',
        (tester) async {
      await pumpAllowlist(tester);

      expect(find.text(l.agentRuleGroupServiceTitle), findsOneWidget,
          reason: '搬成子页后套一层折叠等于让用户点两次才看到想看的东西');
    });
  });

  group('分组开关', () {
    testWidgets('切「文件内容」组 → 组内所有 pattern 的 enabled 一起变', (tester) async {
      useBigViewport(tester);
      final m = await newAgentManager();
      await pumpWithProviders(
        tester,
        agent: m,
        child: const AgentAllowlistScreen(),
      );

      final filesRules = [
        'ls *',
        'cat *',
        'head *',
        'tail *',
        'grep *',
        'stat *'
      ];
      for (final p in filesRules) {
        expect(m.rules.rules.firstWhere((r) => r.pattern == p).enabled,
            isTrue,
            reason: '默认应全部启用');
      }

      await tester.tap(find.byKey(const ValueKey('rule_group_switch_files')));
      await tester.pumpAndSettle();

      for (final p in filesRules) {
        expect(
            m.rules.rules.firstWhere((r) => r.pattern == p).enabled,
            isFalse,
            reason: '切分组开关应该让组内每一条 pattern 一起变成禁用：$p');
      }
      // 没被这组覆盖的规则不该被连坐。
      expect(m.rules.rules.firstWhere((r) => r.pattern == 'ps *').enabled,
          isTrue);
    });

    testWidgets('「文件内容」组的敏感提醒不用展开就该看到', (tester) async {
      await pumpAllowlist(tester);

      // sensitive 组的 warning 不受 expanded 控制 —— 用户不需要展开
      // pattern 列表就该知道"这组会把文件内容发给 AI"。
      expect(find.text(l.agentRuleGroupFilesWarning), findsOneWidget);
    });
  });

  group('兜底：分组表没覆盖到的 builtin 规则落入「其他」组', () {
    testWidgets('不丢，且仍可单独关闭', (tester) async {
      // 模拟 defaultAllowRules 将来新增了一条、分组表还没跟上的场景：
      // 直接往落盘的规则集里加一条分组表 6 组都没提到的 builtin pattern。
      final extraRules = [
        ...defaultAllowRules,
        const PermissionRule(pattern: 'lsof *', builtin: true),
      ];
      SharedPreferences.setMockInitialValues({
        'agent_rules_global': jsonEncode(PermissionRuleSet(extraRules).toJson()),
      });

      useBigViewport(tester);
      final m = await newAgentManager();
      await pumpWithProviders(
        tester,
        agent: m,
        child: const AgentAllowlistScreen(),
      );

      expect(find.text(l.agentRuleGroupOtherTitle), findsOneWidget,
          reason: '分组表没覆盖到的 builtin 规则必须出现在"其他"组，而不是从 UI 上消失');

      await tester.tap(find.byKey(const ValueKey('rule_group_expand_other')));
      await tester.pumpAndSettle();

      final tile = find.widgetWithText(SwitchListTile, 'lsof *');
      expect(tile, findsOneWidget,
          reason: '"其他"组展开后应该能看到那条没被分组表覆盖的 pattern');

      await tester.tap(find.descendant(
          of: tile, matching: find.byType(Switch)));
      await tester.pumpAndSettle();

      expect(
          m.rules.rules.firstWhere((r) => r.pattern == 'lsof *').enabled,
          isFalse,
          reason: '"其他"组里的规则必须仍然可以单独关闭');
    });
  });

  group('用户规则', () {
    testWidgets('空时显示提示，有规则时逐条列出且可删', (tester) async {
      useBigViewport(tester);
      final m = await newAgentManager();
      await pumpWithProviders(
        tester,
        agent: m,
        child: const AgentAllowlistScreen(),
      );

      expect(find.text(l.agentRulesEmpty), findsOneWidget);

      m.addRule(const PermissionRule(pattern: 'my-cmd *', builtin: false));
      await tester.pumpAndSettle();

      expect(find.text('my-cmd *'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(m.rules.rules.any((r) => r.pattern == 'my-cmd *'), isFalse);
    });
  });
}
