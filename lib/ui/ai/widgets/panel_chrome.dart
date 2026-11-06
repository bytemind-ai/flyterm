// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../design/fly_tokens.dart';

// ---------------------------------------------------------------------------
// Model switch title tile — shared by the terminal AI panel and the global AI
// page so the two entry points can never drift apart.
// ---------------------------------------------------------------------------

/// 「标题 + 当前模型名 + 下拉箭头」的模型切换入口。
///
/// **两处必须长得一样**：终端页的 `PanelHeader` 和全局 AI 页的 `AppBar`
/// 都用它。抽出来是因为两处的入口一度完全不同 —— 面板是「两行标题区 + 下拉
/// 箭头」，全局页是一个 `Icons.tune` 裸图标，而且全局页根本不显示当前模型
/// （用户跑半天不知道用的哪个）。共用同一个组件之后，改一处两处生效，不会再
/// 各自漂移。
///
/// **必须是 Flexible 容器里的东西，且模型名必须 ellipsis。** [modelLabel] 来自
/// `AIProvider.displayName`，真实形状是 `Anthropic (claude-sonnet-4-5-
/// 20250929)` 这种四十来字符的串。不加约束时它会把标题区撑到 275px 开外，
/// Row 溢出、右侧被静默裁掉，最先消失的就是最右边的新建会话按钮 —— 用户报的
/// 「新会话按钮没有了」就是这个。
///
/// 这里选择截断模型名而不是截断别的：图标是操作入口，少一个就是功能消失；
/// 模型名是次要信息，前缀足够辨识是哪一个。
class ModelTitleTile extends StatelessWidget {
  /// 第一行。终端页会按视图在「AI 助手 / 历史会话」之间切换；
  /// 全局页恒为「AI 助手」。
  final String title;

  /// 第二行的当前模型名。null = 不渲染第二行。
  final String? modelLabel;

  /// 点整块切模型。null = 不可切，此时不显示下拉箭头、不画可点反馈。
  final VoidCallback? onSwitchModel;

  const ModelTitleTile({
    super.key,
    required this.title,
    this.modelLabel,
    this.onSwitchModel,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onSwitchModel,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (onSwitchModel != null)
                  const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
            if (modelLabel != null)
              Text(
                modelLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal widgets
// ---------------------------------------------------------------------------

class PanelHandle extends StatelessWidget {
  const PanelHandle({super.key});

  /// 视觉上仍是 4px 的细条，但 margin 撑出 32px 的可命中高度 —— 外面那层
  /// `HitTestBehavior.opaque` 的 GestureDetector 认的是这个尺寸。原先上下各
  /// 8px、总共 20px，比 Material 的最小触摸目标小一半还多，盲点基本点不中。
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(80),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// Which surface `AIPanel`'s body is currently showing. Kept here (rather
/// than in `ai_panel.dart`) so `PanelHeader` can switch on it without a
/// circular import.
enum AIPanelMode { agent, direct }

class PanelHeader extends StatelessWidget {
  final VoidCallback onClear;
  final VoidCallback? onAnalyzeError;
  final VoidCallback? onSummary;

  /// 打开历史会话列表。null = 当前模式没有会话归档（直连模式）。
  ///
  /// 渲染成头部裸图标，**不**进溢出菜单 —— 见下方用户可见性说明。
  final VoidCallback? onHistory;

  /// true = 面板此刻正显示历史会话列表（而不是对话）。
  ///
  /// 历史列表是**面板内的视图切换**，不是一层路由 —— 见 `AIPanel._showHistory`
  /// 的文档（两层 `DraggableScrollableSheet` 会抢拖拽手势）。代价是列表里
  /// 没有系统返回键可用，用户得有明确的退路。
  ///
  /// 这一版把「退路」做成头部整体变脸：显示列表时标题换成「历史会话」、
  /// 左侧的 `auto_awesome` 换成 `arrow_back`（点它退出），同时右侧那个
  /// `history` 开关不再渲染。旧版只把 `history` 图标本身换方向，但图标在
  /// 头部最右侧、且和「新建会话」并排 —— 用户会以为那个返回键只作用于
  /// 某一项，而不是整页。
  final bool historyOpen;

  /// false = **完全不渲染**「分析错误」「会话总结」两个按钮。
  ///
  /// 必须与「回调为 null」区分开，因为那两个按钮传 null 时是渲染成 dimmed 的
  /// —— 那表达的是「按钮在，但此刻没有终端上下文可用」，是刻意的。
  ///
  /// agent 模式传 false：那两件事已经交给 `read_terminal` 工具，按钮不是「暂时
  /// 不可用」而是不该存在，留个灰图标只是白占头部两个格子。
  final bool showPresets;

  /// true = 该服务器当前处于 bypass（全部放行）模式。bypass 是「开了就忘」
  /// 的设置，后果却是 agent 可以无声执行破坏性命令 —— 提醒必须出现在风险
  /// 实际发生的地方（用户正看着 agent 干活的面板），不能只藏在三级设置页里。
  final bool bypassActive;

  /// 当前模型名，显示在标题下方。null = 不显示。
  final String? modelLabel;

  /// 点标题区切换模型。null = 不可切。
  final VoidCallback? onSwitchModel;

  const PanelHeader({
    super.key,
    required this.onClear,
    this.onAnalyzeError,
    this.onSummary,
    this.onHistory,
    this.historyOpen = false,
    this.showPresets = true,
    this.bypassActive = false,
    this.modelLabel,
    this.onSwitchModel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          // 历史列表打开时，左侧图标兼作返回键。
          //
          // 用 `arrow_back` 而不是把右侧的 `history` 换个方向：返回是
          // 「整页」的动作，摆在头部最左、紧贴标题才符合直觉；右下角与
          // 「新建会话」并排的那个图标，用户读起来像只作用于当前这一项。
          // 点击走 [onHistory] —— 它在打开态下的语义就是「再点一次退出」
          // （见 `AIPanel._buildHeader`），不需要新加一个回调。
          if (historyOpen && onHistory != null)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onHistory,
            )
          else ...[
            const SizedBox(width: 12),
            const Icon(Icons.auto_awesome, size: 18),
            const SizedBox(width: 8),
          ],
          // 标题区兼作切模型入口，**不占图标位** —— 头部右侧已有一个溢出
          // 菜单和一个新建按钮，再加一个会挤掉标题。外观与全局 AI 页共用
          // [ModelTitleTile]，两处永远一致。
          //
          // 宽度约束（Flexible + ellipsis + 截断模型名而非图标）的完整理由
          // 在 [ModelTitleTile] 的类文档里，不在这里重复。
          Flexible(
            child: ModelTitleTile(
              // 列表打开时标题改成「历史会话」：头部只剩一个返回键时，标题是
              // 唯一告诉用户「现在在哪」的东西；同时不显示模型名、不可切
              // （正在看历史，切模型没有落点）。
              title: historyOpen
                  ? context.l10n.aiSessionHistory
                  : context.l10n.aiAssistant,
              modelLabel: historyOpen ? null : modelLabel,
              onSwitchModel: historyOpen ? null : onSwitchModel,
            ),
          ),
          if (bypassActive) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: context.l10n.agentPanelBypassActiveTooltip,
              child: Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const Spacer(),
          // 这里曾经有个模式切换按钮。去掉了 —— AI 助手对用户只该是一个
          // 入口。能用 agent 就用 agent，模型不支持 tool calling 时自动
          // 退回直连问答，用户不需要（也不该需要）理解这两种模式的区别。
          //
          // ## 头部图标布局（2026-10 二次调整）
          //
          // 一次调整曾把「分析错误 / 总结 / 历史 / 导出」四个低频项全塞进
          // 溢出菜单，头部只留「新建」。二次调整把其中两个拿了出来：
          //
          // - **历史会话还原成裸图标。** 它是会话管理里最高频的导航动作
          //   （看一眼、切回去），而 agent 模式下菜单里本来也只剩它一项
          //   —— 一个只有一项的菜单不如直接把那项摆出来。
          // - **导出彻底移出头部。** 它确实低频，但历史列表里每一行都
          //   有自己的导出菜单（`SessionHistoryView`），入口没有丢。
          //
          // 剩下的溢出菜单只装**直连模式**的「分析错误 / 会话总结」；
          // agent 模式那两件事已交给 `read_terminal` 工具，菜单一项不剩，
          // 于是整个 `more_vert` 按钮都不渲染。
          //
          // 历史排在「新建」左边：新建是最常点的那一个，始终占最右侧。
          //
          // 列表**已经打开**时这个开关不再渲染：退出已经交给头部左侧那个
          // arrow_back，两个入口干同一件事只会让人猜它们有什么区别。
          if (onHistory != null && !historyOpen)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: context.l10n.aiSessionHistory,
              onPressed: onHistory,
            ),
          if (showPresets && (onAnalyzeError != null || onSummary != null))
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: context.l10n.aiMoreActions,
              onSelected: (v) {
                switch (v) {
                  case 'analyze':
                    onAnalyzeError?.call();
                  case 'summary':
                    onSummary?.call();
                }
              },
              itemBuilder: (_) => [
                if (onAnalyzeError != null)
                  PopupMenuItem(
                    value: 'analyze',
                    child: _MenuRow(
                      icon: Icons.bug_report_outlined,
                      label: context.l10n.aiAnalyzeErrorChip,
                    ),
                  ),
                if (onSummary != null)
                  PopupMenuItem(
                    value: 'summary',
                    child: _MenuRow(
                      icon: Icons.summarize_outlined,
                      label: context.l10n.sessionSummary,
                    ),
                  ),
              ],
            ),
          // 新建会话
          //
          // **图标不能是垃圾桶。** 这个动作的语义从「删除」变成了「归档当前 +
          // 开新的」，delete_outline 会让用户以为点了就没了，于是不敢点 —— 而它
          // 恰恰是新流程里最常用的动作。
          //
          // 参数名仍叫 onClear：改名要动所有调用点，而语义变化已经由图标、
          // tooltip 和这段注释表达清楚了。
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: context.l10n.aiNewSession,
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

/// 溢出菜单里的一行：图标 + **文字**。
///
/// 文字是重点。改造前这些操作只有裸图标，用户得靠猜；而 `CLAUDE.md` 里
/// 记着一个真 bug：「tooltip 在手机上要长按才显示……用户点一下什么都不会
/// 发生 —— 与「App 坏了」无法区分」。菜单里带文字就不依赖 tooltip 了。
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 12),
      Text(label, style: FlyText.body),
    ],
  );
}

class PanelInputRow extends StatelessWidget {
  final TextEditingController ctrl;
  final VoidCallback onSubmit;

  /// false 时输入框与发送按钮一起置灰。
  ///
  /// agent 模式过去在 loop 运行期间把这里传 false 挡住输入——2026-08-30
  /// 推翻了这个取舍：运行期间禁用输入意味着用户排查到一半想起
  /// 补充信息（"顺便也查一下 nginx 日志"）时无处可说，只能干等当前这轮
  /// 跑完。现在 agent 模式恒传 true，运行中发送的内容改走 `AgentLoop`
  /// 已有的排队机制（`send()` 在 `isRunning` 时入队，等轮边界再注入），
  /// 面板上以「待发」气泡呈现，点击可撤回。这里不再是挡输入的开关。
  final bool enabled;

  /// 覆盖默认提示文案。agent 模式问的是「要排查什么」，
  /// 不是直连模式那句「输入你的问题」。
  final String? hintText;

  /// 点击附件按钮。null = 不渲染附件按钮（例如直连模式尚未接入附件）。
  final VoidCallback? onAttachTap;

  /// false 时附件按钮**看起来**置灰（例如当前模型不支持图片输入），但仍然
  /// 点得动 —— 点击走 [onAttachBlockedTap]。
  final bool attachEnabled;

  /// 按钮置灰时点它。null = 退回真正的禁用（`onPressed: null`）。
  ///
  /// ## 为什么不能只靠 tooltip
  ///
  /// 原先禁用时把原因写在 `tooltip` 里就算完了，但 **tooltip 在手机上要长按
  /// 才显示**。用户点一下灰按钮，屏幕上什么都不会发生 —— 与「App 坏了」
  /// 无法区分。真机反馈（2026-09-13）里「附件上传有问题」有一半是这个。
  ///
  /// 所以灰按钮保留可点击：视觉上告诉你「现在不能用」，点下去告诉你
  /// 「为什么」，外加一个逃生口。
  final VoidCallback? onAttachBlockedTap;

  const PanelInputRow({
    super.key,
    required this.ctrl,
    required this.onSubmit,
    this.enabled = true,
    this.hintText,
    this.onAttachTap,
    this.attachEnabled = true,
    this.onAttachBlockedTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 寸土寸金：面板最小可以拖到屏高的 25%（约 200dp），这一行的
      // padding 那时会占相当可观的比例。
      //
      // 上下 padding 2026-10-13 从 8/12 收到 6/8，配合下面 contentPadding
      // 的 10→8，整行 68dp → 58dp。
      //
      // 底部仍然要加 `viewInsets.bottom`（键盘高度）：键盘弹起时输入行要顶
      // 到键盘上方，那个值不能省。
      padding: EdgeInsets.fromLTRB(
        12,
        6,
        12,
        MediaQuery.of(context).viewInsets.bottom + 8,
      ),
      child: Row(
        children: [
          if (onAttachTap != null) ...[
            // 放在输入框**之外**，而不是塞进 suffixIcon：前者是项目里已经
            // 确立的口径（用户否决过把控件挪进输入框内部的版本，理由是输入
            // 框自己的 OutlineInputBorder 不再是视觉边界、且命中区会小于
            // 48×48）。
            IconButton(
              // 手动置灰而不是靠 `onPressed: null`：那样按钮就真的点不动了，
              // 用户也就永远读不到原因（tooltip 要长按）。见
              // [onAttachBlockedTap] 的文档。
              //
              // 收紧内外边距：默认 `IconButton` 的 48×48 命中区在垂直方向
              // 比 40dp 的输入框高，会把整行撑到 48。`visualDensity` 只动
              // 视觉密度、命中区仍满足 Material 最小值。
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.attach_file,
                size: 20,
                color: attachEnabled ? null : Theme.of(context).disabledColor,
              ),
              tooltip: attachEnabled
                  ? context.l10n.attachPick
                  : context.l10n.attachUnsupportedVision,
              onPressed: attachEnabled ? onAttachTap : onAttachBlockedTap,
            ),
          ],
          Expanded(
            child: TextField(
              controller: ctrl,
              enabled: enabled,
              decoration: InputDecoration(
                hintText: hintText ?? context.l10n.aiInputHint,
                // 胶囊形而不是 `FlyRadius.controlRadius`（全局输入框的标准
                // 圆角）：底部输入框是**对话 UI 的一部分**，与气泡同形，
                // 与设置页那些方角表单不是同一种东西。
                //
                // 但**高度必须回到全局口径**（`vertical: FlySpace.sm`）——
                // 2026-10-13 之前这里写自己的 vertical（先 10、后 8），
                // 结果它是全 app 最矮的输入框，旁边的图标按钮也对不齐。
                // 圆角与高度是两件事：前者可以不同（形态），后者必须一致
                // （尺度）。
                border: const OutlineInputBorder(
                  borderRadius: FlyRadius.pillRadius,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: FlySpace.lg,
                  vertical: FlySpace.sm,
                ),
                isDense: true,
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.send),
            onPressed: enabled ? onSubmit : null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Blinking cursor — shown at end of streaming assistant messages
// ---------------------------------------------------------------------------

class BlinkingCursor extends StatefulWidget {
  const BlinkingCursor({super.key});

  @override
  State<BlinkingCursor> createState() => BlinkingCursorState();
}

class BlinkingCursorState extends State<BlinkingCursor> {
  bool _visible = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (mounted) setState(() => _visible = !_visible);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      _visible ? '▋' : ' ',
      style: const TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 13,
        color: FlyColors.active,
      ),
    ),
  );
}
