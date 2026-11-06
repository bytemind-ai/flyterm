import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/tool_call_card.dart';

/// 同一条调用的两种状态。内容完全一致，只差「壳」。
///
/// 计划草稿用的是 `systemctl status nginx` + `检查 nginx 是否在跑`——在
/// 360dp 宽度下，这段描述+命令拼接后的富文本会折成两行（真实测得
/// dense=52px），把比值推到 0.59，让这条断言在**实现完全正确**的情况下
/// 都过不去。换成这条更短的组合以避免折行带来的噪声：断言要测的是「脱掉
/// 边框/背景/padding 之后矮了多少」，不是「文字折不折行」——折行行为已经
/// 由 `dense_event_row_test.dart` 的「长文本折行而不截断」专门覆盖。
ToolCallEvent _event(ToolCallStatus status) => ToolCallEvent(
      seq: 0,
      callId: 'c1',
      toolName: 'bash',
      displayCommand: 'nginx -t',
      description: '检查配置',
      check: const CheckResult(decision: ToolDecision.allow),
      status: status,
    )..output = 'active (running)';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 360, child: child),
        ),
      ),
    );

void main() {
  // 这条是 AI 面板信息密度改版的核心成功判定：流水行高度 ≤ 完整卡的一半。
  //
  // 对照态必须是 deferred，不能是 running 或 failed：
  //   - failed 本身就渲染成流水行，拿它当基线是自证成立
  //   - running 多一行秒表，基线虚高，此时就算忘了压 IconButton
  //     （行被撑到 48px）比值仍然可能过关，测试会失去拦截力
  // deferred 是唯一「内容与 done 相同、只差一层壳」的完整卡状态。
  //
  // 外层包一层 SingleChildScrollView 给出无界高度：Scaffold.body 若直接
  // 收窄到屏幕高度这类有界约束，Column 默认 mainAxisSize.max 会把两种
  // 状态都撑满整个视口高度（实测两者都是 600px），比值恒为 1、断言失去
  // 意义。无界高度下 Column 退化成按内容大小排布，这才是要测的那个高度。
  testWidgets('流水行高度 ≤ 完整卡的一半', (t) async {
    await t.pumpWidget(
        _wrap(ToolCallCard(event: _event(ToolCallStatus.deferred))));
    final full = t.getSize(find.byType(ToolCallCard)).height;

    await t.pumpWidget(
        _wrap(ToolCallCard(event: _event(ToolCallStatus.done))));
    final dense = t.getSize(find.byType(ToolCallCard)).height;

    expect(dense, lessThanOrEqualTo(full * 0.5),
        reason: '流水行 ${dense}px vs 完整卡 ${full}px');
  });
}
