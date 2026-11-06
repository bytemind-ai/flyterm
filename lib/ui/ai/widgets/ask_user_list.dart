// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/agent_loop.dart';
import '../../../ai/agent/ask_option.dart';
import '../../../l10n/l10n.dart';
import 'dense_event_row.dart';

/// `ask_executors.dart` 里会话被取消时固定写入 `ev.output` 的文案。与真实
/// 失败原因（参数非法、一轮问两次）区分开——这条不算「原因」，用户本来就
/// 没有答案，不值得给一个展开入口。
const _cancelledOutput = 'The user did not answer (session cancelled).';

/// `ask_user` 的三态渲染。
///
/// ## 为什么没有卡片外壳
///
/// 与 `PlanChecklist` 同一个理由（见那个文件的注释）：提问是**当前状态**，
/// 答完就该让位给 AI 的结论。它比清单更短命——清单会更新好几轮，提问答完
/// 就没了。
///
/// 三态靠字符表达：
///   挂起  `?` 主色 + 每个选项 `○`，末尾 `✎ 其他…`
///   已答  `✓` 主色，折叠成一行 `问题 → 答案`
///   未答  `✗` 灰，`问题 → 未回答`（取消、参数非法、从归档恢复都落这支）
///
/// **前缀不能用 `❓`（U+2753）。** 它在 Unicode 的 emoji 数据里有条目，
/// Android 上会被 emoji 字体接管、渲染成彩色字形，而彩色字形自带颜色——
/// 代码里设的 `color` 对它完全无效。`PlanChecklist` 的注释记着同一个坑的
/// 实拍（`☑` 变成一屏蓝方块）。这里用到的 `? ○ ✓ ✗ ✎ →` 都不在 emoji 表里。
///
/// **没有「选中待确认」这一态。** 点一下即提交——多一步确认等于把「点一下」
/// 变成「点两下」，而这个功能的全部价值就是那一下。
class AskUserList extends StatefulWidget {
  final ToolCallEvent event;

  /// 点选项 / 提交自由输入时的回调。null = 只读。目前没有任何构造点会传
  /// null——唯一的构造点 `agent_view.dart` 只按 `toolName` 决定传不传这个
  /// 回调，不看 `status`。从归档恢复出来的事件也拿到非 null 的回调，它是
  /// 靠下面的 `status` 走只读支的，不是靠这个回调为空。
  final void Function(String choice)? onAnswer;

  const AskUserList({super.key, required this.event, this.onAnswer});

  @override
  State<AskUserList> createState() => _AskUserListState();
}

class _AskUserListState extends State<AskUserList> {
  bool _otherOpen = false;
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submitOther() {
    final text = _ctrl.text.trim();
    // 空白不提交、不关闭输入框。`respondAnswer` 之后这次提问就永久结束了,
    // 误触一次就得让 agent 在没有答案的情况下继续。
    if (text.isEmpty) return;
    widget.onAnswer!(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final ev = widget.event;
    final question = ev.displayCommand.replaceFirst('ask: ', '');
    // 判据是「还没到终态」而不是「正好等于 awaitingApproval」。
    //
    // 事件建出来时 status 的默认值是 `running`，executor 要再走几行才把它
    // 翻成 `awaitingApproval`。眼下那几行里没有 await、画不出帧，所以两种
    // 判据等价；但只要将来谁在中间插一次异步调用（哪怕只是记一行日志），
    // 按前一种判据就会先闪一个「✗ 未回答」再变成问题——用户被告知他没回答
    // 一个还没显示出来的问题。这里多认一个状态，把那颗地雷提前拆掉。
    final pending = !isTerminal(ev.status) && widget.onAnswer != null;

    if (!pending) {
      final done = ev.status == ToolCallStatus.done;
      final answer = done && (ev.output?.isNotEmpty ?? false)
          ? ev.output!
          : l.agentAskUnanswered;
      // `failed` 混进「未回答」会让人以为自己没被问过，其实 `ev.output`
      // 里有真实原因（参数非法、一轮问两次）。取消（`respondAnswer` 找不到
      // completer 时 executor 写的固定文案）不算「原因」，不值得占一个展开
      // 入口——那种情况下用户确实什么都没答，「未回答」已经是完整信息。
      final hasFailureReason = ev.status == ToolCallStatus.failed &&
          (ev.output?.isNotEmpty ?? false) &&
          ev.output != _cancelledOutput;
      return DenseEventRow(
        leading: _Mark(done ? '✓' : '✗', primary: done),
        spans: [
          if (ev.description.isNotEmpty)
            TextSpan(
              text: '[${ev.description}] ',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          TextSpan(text: question),
          TextSpan(
            text: ' → $answer',
            style: TextStyle(
              color: done
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        expanded: hasFailureReason
            ? (context) => Text(
                  ev.output!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
            : null,
      );
    }

    final opts = ev.askOptions ?? const <AskOption>[];
    return Padding(
      // 水平 8 与 DenseEventRow、PlanChecklist、各完整卡一致：同一条流里
      // 混排时左边缘不跳。
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(
            mark: const _Mark('?', primary: true),
            child: Text.rich(
              TextSpan(children: [
                if (ev.description.isNotEmpty)
                  TextSpan(
                    text: '[${ev.description}] ',
                    style:
                        TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                TextSpan(text: question),
              ]),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
            ),
          ),
          for (final o in opts)
            // prompt 里已经让模型别自己造「其他」选项，但它可能不听。若模型
            // 塞进来一个 label 跟 `l.agentAskOther`（trim 后）撞了，跳过它：
            // 下面本来就有一个等价且更好的「✎ 其他…」入口（能打字，选项那个
            // 只会把一个零信息的字符串原样发回模型），重复渲染只会让用户点
            // 到那个死的。
            if (o.label.trim() != l.agentAskOther.trim())
              // 点一下即提交、不可撤回——比 dense_event_row.dart:88-94 记的
              // 28×20「不好点」热区代价更高：那边点错只是多展开一次。垂直
              // 6 撑到约 30px 高，离推荐的 48 还差一截，但这段清单要跟上下文
              // 的流水行保持密度，一味撑满会把「答完就让位」的设计打回原形。
              //
              // **`Padding` 必须在 `InkWell` 里面。** 反过来包的话 padding
              // 属于外层 `Padding` 的 RenderBox，不参与 InkWell 的命中测试——
              // 行距变宽了、热区一点没变，而这个错误任何 `find.text().tap()`
              // 的测试都抓不到（它命中的是文字本身，怎么套都过）。
              InkWell(
                onTap: () => widget.onAnswer!(o.label),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: _Line(
                    mark: const _Mark('○', primary: true),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          o.label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.35,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        if (o.description != null)
                          Text(
                            o.description!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.35,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          if (!_otherOpen)
            // 同上：`Padding` 在 `InkWell` 里面，否则热区不变。
            InkWell(
              onTap: () => setState(() => _otherOpen = true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: _Line(
                  mark: const _Mark('✎', primary: false),
                  child: Text(
                    l.agentAskOther,
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.35,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          else
            _Line(
              mark: const _Mark('✎', primary: true),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      autofocus: true,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitOther(),
                      style: theme.textTheme.bodySmall,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: _submitOther,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 定宽标记列。
///
/// 固定宽度而不是指定等宽字体：`? ○ ✎` 未必都在某一个字体里有字形，缺字形
/// 时 fallback 到系统字体、宽度就各不相同，几行的文字左缘会参差。
///
/// 16 + 间隔 6 = 22，与 `DenseEventRow` 的图标列一致——同一条提问从挂起态
/// 切到折叠态时，文字左缘不跳。
///
/// `plan_checklist.dart` 里有同样的定宽约定（不同的数值）。目前只有两处，
/// 各自的字符集和取值都不同，为了消除一次重复去提公共常量不划算；出现第
/// 三处再考虑。
class _Mark extends StatelessWidget {
  final String char;
  final bool primary;

  const _Mark(this.char, {required this.primary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 16,
      child: Text(
        char,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.35,
          color: primary
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 一行「标记列 + 内容」。三处调用点共用（问题行、每个选项行、输入框行），
/// 抽出来是为了让三者的标记列宽度、间隔都锁在一处——单独改一处很容易漏改
/// 另外两处，导致几行的文字左缘各跑各的。
///
/// **不在这里加 padding**：它同时被不可点的问题行、输入框行和需要更大点击
/// 热区的可点行（见调用点上关于热区大小的注释）复用，给它加纵向 padding
/// 会把不需要那份空间的行也一起撑开。
class _Line extends StatelessWidget {
  final Widget mark;
  final Widget child;

  const _Line({required this.mark, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          mark,
          const SizedBox(width: 6),
          Expanded(child: child),
        ],
      ),
    );
  }
}
