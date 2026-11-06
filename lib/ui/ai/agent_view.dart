// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/agent/agent_loop.dart';
import '../../ai/agent/agent_skill_manager.dart';
import '../../ai/agent/ai_command_manager.dart';
import '../../ai/agent/knowledge.dart';
import '../../ai/agent/knowledge_saver.dart';
import '../../ai/agent/server_notes_manager.dart';
import '../../ai/agent/tool_models.dart';
import '../../ai/agent/turn_metrics.dart';
import '../../ai/ai_provider_service.dart';
import '../../ai/attachment.dart';
import '../../ai/attachment_downscale.dart';
import '../../ai/attachment_store.dart';
import '../../data/models/server.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import '../design/fly_tokens.dart';
import '../ui_flags.dart';
import 'attachment_picker.dart';
import 'latest_event_index.dart';
import 'mention.dart';
import 'widgets/app_change_card.dart';
import 'widgets/approval_card.dart';
import 'widgets/attachment_bar.dart';
import 'widgets/attachment_bubble.dart';
import 'widgets/batch_approval_card.dart';
import 'widgets/code_block.dart';
import 'widgets/compaction_card.dart';
import 'widgets/dense_event_row.dart';
import 'widgets/job_card.dart';
import 'widgets/knowledge_proposal_card.dart';
import 'widgets/mention_field.dart';
import 'widgets/message_copy_button.dart';
import 'widgets/plan_checklist.dart';
import 'widgets/plan_proposal_card.dart';
import 'widgets/running_bar_label.dart';
import 'widgets/superseded_group.dart';
import 'widgets/tool_call_card.dart';
import 'widgets/transfer_card.dart';

/// 把事件流切成渲染单元：普通事件各自一项，被重发取代的那一段合成一项。
///
/// 折叠边界是「带标记的 UserTurnEvent → 下一个 UserTurnEvent 之前」。
/// BackgroundJobEvent 例外，它不进折叠 —— 后台任务的生命周期独立于对话
/// 轮次，收起来会让用户失去 check_job 的入口。
@visibleForTesting
List<List<AgentEvent>> groupSupersededEvents(List<AgentEvent> events) {
  final groups = <List<AgentEvent>>[];
  List<AgentEvent>? current;
  for (final e in events) {
    final startsCollapsed = e is UserTurnEvent && e.supersededByEdit;
    if (startsCollapsed) {
      current = [e];
      groups.add(current);
      continue;
    }
    // BackgroundJobEvent **也留在组里**。
    //
    // 曾经把它排除在外，想让后台任务不被收起（免得用户失去 check_job 的
    // 入口）。但线性列表里做不到「它独立成组、而折叠区块跨过它继续」——
    // 组一旦提前 add 进 groups，后续再往里追加事件就会让渲染顺序错乱。
    // 当时的实际效果是 job 把 current 复位，于是它**之后**的工具卡全部
    // 脱离折叠：不淡化、不收起，看上去像是当前这一轮跑出来的，而它们其实
    // 属于被取代的那一轮。那比「多点一次展开」糟得多。
    //
    // 现在 job 留在组里，入口不丢的诉求改由渲染层满足：含 job 的组不折叠，
    // 整段淡化平铺（见 build 里的 hasBackgroundJob 分支）。
    if (current != null && e is! UserTurnEvent) {
      current.add(e);
      continue;
    }
    current = null;
    groups.add([e]);
  }
  return groups;
}

/// Agent 模式视图。
///
/// **只是视口** —— `AgentLoop` 由 `AgentSessionManager` 持有。关掉面板 loop
/// 继续跑，重开时事件流原样恢复。本 widget 不拥有任何会话状态。
class AgentView extends StatefulWidget {
  final AgentLoop loop;
  final String providerName;

  /// 用户点「去设置」时跳转（凭据缺失场景）。
  final VoidCallback? onOpenServerSettings;

  /// 点常驻任务条时跳看板。null = 宿主没装配（任务条仍显示，只是点不动）。
  ///
  /// **走回调而不是自己 `pushNamed`**：本 widget 是视口（见类文档「不拥有任何
  /// 会话状态」），路由是宿主的职责。与 [onOpenServerSettings] 同一个模式。
  final VoidCallback? onOpenJobs;

  /// 打开面板时预填并直接提交的问题（「长按报错行 → AI 分析」这类入口）。
  ///
  /// 只在这条 loop 还是全新的时候触发一次 —— loop 由
  /// `AgentSessionManager` 长期持有，面板可以反复开关，若不判空
  /// 每次重开都会把同一个问题再问一遍。
  final String? initialQuery;

  /// `DraggableScrollableSheet` 的 builder 交下来的 controller。
  ///
  /// **必须接到事件流的 `ListView` 上**，否则拖对话区域不能伸缩面板 ——
  /// sheet 靠这个 controller 感知「列表已经滚到顶了，接下来的下拉手势归
  /// 我」。用自己 new 的 controller 会让 sheet 完全收不到滚动信号，用户
  /// 只剩顶部那根小横条可拖。
  ///
  /// 它同时也是自动滚到底部用的那个 —— sheet 给的就是个普通
  /// `ScrollController`，两件事共用一个即可（直连模式也是这么做的）。
  final ScrollController? scrollController;

  /// 当前是否 bypass 档——审批卡据此决定是否显示「本轮不再问」。
  final bool bypassMode;

  /// 知识提议卡「存入」时，[KnowledgeTarget.skill] 分支的落地回调。
  ///
  /// 与 `AgentLoop.skillSaver`（`save_skill` 工具用的那个）故意分开注入，
  /// 而不是让本 view 直接掏 `widget.loop.skillSaver` 去用——两者语义不同：
  /// 那个是模型主动发起的工具调用，这个是用户在卡片上点了一下手动确认。
  /// 装配处（`ai_panel.dart` → `terminal_screen.dart`）目前两边接的是同一个
  /// `skills.save(...)` 实现，但保持独立注入点，未来两条路径想分叉（比如
  /// 给自动沉淀单独加一道审计）时不必再拆一次。
  final Future<void> Function(String name, String description, String body)?
  onSaveSkill;

  /// 把一条候选追加进这台机器的笔记。
  ///
  /// **I3 修复**：签名曾经是 `Future<ServerNoteSaveResult> Function(String
  /// text)`——调用方（本 view）得自己拼好「现有内容 + 新小节」整份文本再
  /// 传进来，这样一来「存量本身超限」这道守卫就被绕过了：
  /// `ServerNotesManager.appendNote` 开头那道守卫专门识别这种情形、回一句
  /// 「去设置里精简」的人话，而整份覆盖式调用只会在超限时报一个调用方砍不掉
  /// 的 `overflowBytes`（候选本身可能没那么大，超的是存量）。现在直接把
  /// `heading` / `body` 散字段交给调用方（装配在 `terminal_screen.dart`，
  /// 转调 `ServerNotesManager.appendNote`），拼接和守卫都收口在那一层，
  /// 本 view 不用再管「基底是什么」。
  ///
  /// 返回 [ServerNoteSaveResult] 而不是抛：超限是可预期的正常路径，要把
  /// 「超了多少」告诉用户，而不是弹一个异常字符串。
  final Future<ServerNoteSaveResult> Function(String heading, String body)?
  onWriteMachineNotes;

  /// 列一个远端目录 —— 只服务于输入框的 `@file` 补全。
  ///
  /// null = 这个会话没有可用的 SFTP 通道（本地 shell），`@` 浮层照常弹，
  /// 只是没有文件分组。装配在 `terminal_screen.dart`，与
  /// [onWriteMachineNotes] 同形。
  final RemoteDirLister? listRemoteDir;

  /// 把 `~` 起头的路径解析成绝对路径。与 [listRemoteDir] 同生共死。
  final RemotePathResolver? resolveRemotePath;

  /// `@server` 的候选来源。宿主传 `_serverCache` —— 那份缓存
  /// `_openAIPanel` 在建 loop 之前已经 `await _refreshServerCache()` 刷过。
  ///
  /// **不走 provider**：`List<Server>` 没有注册成 provider，而
  /// `ServerRepository.findAll()` 是异步的，在 build 里 await 不了。
  final List<Server> servers;

  /// 与 `agentToolSpecsFor(hasOtherServers: ...)` 同一个判据，由宿主的
  /// `_hasOtherServers` getter 传入。
  final bool hasOtherServers;

  /// 渲染历史气泡里已发送附件的缩略图。null = 拿不到文件（这个会话没有附件
  /// 能力，或文件已被清理），气泡退化成「图片已不可用」占位。
  ///
  /// 由 `terminal_screen.dart` 用 `store.fileFor` 填。**不直接把
  /// `AttachmentStore` 传下来** —— `AttachmentBubble` 那一层不该知道
  /// `AttachmentStore` 的存在，见其类文档。
  final File? Function(Attachment)? attachmentFileFor;

  /// 选新附件时落盘用的 store。null = 这个会话不支持附件——附件按钮不渲染
  /// （见 [build] 里 `onAttachTap` 的判断）。
  ///
  /// 与 [attachmentFileFor] 分开：那个只服务于「读」（渲染已发送的气泡），
  /// 这个服务于「写」（`prepareAttachment` 落盘新选中的文件）。两者在
  /// `terminal_screen.dart` 装配时其实是同一个 `AttachmentStore` 实例的两种
  /// 用法，但保持独立注入点，测试时能各自替换。
  final AttachmentStore? attachmentStore;

  /// 附件落盘路径里的 `<serverId>/` 段。与 [attachmentStore] 同生共死。
  final String? attachmentServerId;

  /// 事件流为空时显示在**列表区域**的内容。输入框不受影响，始终在底部。
  ///
  /// 收到的 `send` 回调用来让占位内容里的建议 chip 直接发出那句话 —— 事件流
  /// 由 `AgentLoop` 持有，外部拿不到输入框控制器（`_input`）往里面填字，与
  /// `DirectChatView.emptyBuilder` 同一个理由。
  ///
  /// null = 沿用原来的处理：列表区域渲染一个空的 `ListView`（没有任何占位
  /// 内容）。终端页 AI 面板走的就是这条路径，它的空状态不需要建议 chip。
  final Widget Function(void Function(String text) send)? emptyBuilder;

  const AgentView({
    super.key,
    required this.loop,
    required this.providerName,
    this.onOpenServerSettings,
    this.onOpenJobs,
    this.initialQuery,
    this.scrollController,
    this.bypassMode = false,
    this.onSaveSkill,
    this.onWriteMachineNotes,
    this.listRemoteDir,
    this.resolveRemotePath,
    this.servers = const [],
    this.hasOtherServers = false,
    this.attachmentFileFor,
    this.attachmentStore,
    this.attachmentServerId,
    this.emptyBuilder,
  });

  @override
  State<AgentView> createState() => _AgentViewState();
}

class _AgentViewState extends State<AgentView> {
  final TextEditingController _input = TextEditingController();

  /// 待发送的附件。持有在这一层而不是 [MentionField] —— 见该组件类文档。
  Attachment? _pendingAttachment;

  /// [_pendingAttachment] 是图片时的缩略图文件；text 类恒为 null（预览条
  /// 只显示文件名与大小，见 [AttachmentBar]）。
  File? _pendingThumbnailFile;

  /// text 类附件读出来的正文，发送时拼进 [_input] 的文字里。
  /// 图片类恒为 null——图片走 `attachments`，不进文字内容。
  String? _pendingAttachmentText;
  bool _pendingAttachmentTruncated = false;

  /// 上一次观察到的 `loop.isRunning`，用来在 _onLoopChanged 里识别
  /// "刚刚开始跑" 这个边沿（而不是运行期间每个事件都重复触发一次取消）。
  bool _wasRunning = false;

  /// 每秒重建一次，只为让运行中的工具卡上那个秒数往前走。
  ///
  /// 挂在 loop 的 running 边沿上而不是常开：常开的 1 秒 Timer 会让
  /// `pumpAndSettle` 在测试里永久超时，也会在面板开着但 agent 空闲时
  /// 白白每秒重建一次列表。
  Timer? _tick;

  void _syncTick() {
    // 不只看 isRunning：后台任务会在 loop 停下之后继续跑，那时卡上的
    // 时长还得往前走。
    final needTick = widget.loop.isRunning || widget.loop.hasRunningJobs;
    if (needTick && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needTick && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.loop.addListener(_onLoopChanged);
    widget.loop.onPendingReturned = _onPendingReturned;
    _wasRunning = widget.loop.isRunning;
    _syncTick();

    final q = widget.initialQuery?.trim();
    if (q != null &&
        q.isNotEmpty &&
        widget.loop.events.isEmpty &&
        !widget.loop.isRunning) {
      // 不能在 initState 里同步 send —— 它会立刻 notifyListeners，
      // 而此时 widget 还没完成首次构建。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.loop.send(q);
      });
    }
  }

  @override
  void didUpdateWidget(AgentView old) {
    super.didUpdateWidget(old);
    // loop 会被换掉：「清空对话」调 closeLoop 之后，下一次 build 时
    // loopFactory 会给出一个全新的 loop。listener 必须跟着搬家 —— 否则它
    // 还挂在已经 dispose 的旧 loop 上，界面从此不再更新。
    if (old.loop != widget.loop) {
      old.loop.removeListener(_onLoopChanged);
      widget.loop.addListener(_onLoopChanged);
      // onPendingReturned 同样要跟着搬家——理由与上面的 listener 一致：
      // 不摘的话旧 loop 还握着一个指向本 State 的回调，新 loop 上则没有
      // 人接非正常终止退回的文本。只在仍指向本 State 的 _onPendingReturned
      // 时才摘旧的，避免误摘掉别的持有者（如另一个 State 实例）挂上去的。
      if (identical(old.loop.onPendingReturned, _onPendingReturned)) {
        old.loop.onPendingReturned = null;
      }
      widget.loop.onPendingReturned = _onPendingReturned;
      _wasRunning = widget.loop.isRunning;
      _syncTick();
    }
  }

  @override
  void dispose() {
    widget.loop.removeListener(_onLoopChanged);
    // 同样做身份检查再摘——避免把已经被别处重新挂上的回调误摘掉。
    if (identical(widget.loop.onPendingReturned, _onPendingReturned)) {
      widget.loop.onPendingReturned = null;
    }
    _tick?.cancel();
    _input.dispose();
    // scrollController 不在这里 dispose —— 它归 DraggableScrollableSheet，
    // 我们只是借用。
    super.dispose();
  }

  void _onLoopChanged() {
    if (!mounted) return;
    final running = widget.loop.isRunning;
    if (running && !_wasRunning) {
      // agent 刚开始跑（用户发送，或头部🐛/📋预设按钮绕过输入框直接
      // loop.send）—— 曾经在这里主动打断正在进行的语音录音，因为麦克风
      // 按钮即将置灰、用户没法手动停。语音输入已从面板移除，这段随之删掉。
    }
    _wasRunning = running;
    _syncTick();
    setState(() {});
    _scheduleScrollToBottom();
  }

  /// 把列表带到最新内容，并**持续纠正**直到它真的停在底部。
  ///
  /// ## 为什么不能只算一次 maxScrollExtent
  ///
  /// 原来的写法是：post-frame 里读一次 `pos.maxScrollExtent`，然后
  /// `animateTo` 那个值。两个原因让它在真实使用中滚不到底：
  ///
  /// 1. **目标值是过期的。** `addPostFrameCallback` 跑在本帧布局之后，但
  ///    ListView 是懒构建的——新加进来的条目会在**接下来几帧**里陆续完成
  ///    布局，`maxScrollExtent` 跟着长。动画朝着一个陈旧的目标跑，到了就停，
  ///    此时内容已经又往下涨了一截。（回归测试里能稳定复现约 12px 的缺口，
  ///    流式输出时每一帧都在涨，缺口会持续累积。）
  /// 2. **动画被反复重启。** 流式输出每个 chunk 触发一次 `_safeNotify` →
  ///    一次 `_onLoopChanged` → 一次 `animateTo`。200ms 的动画永远走不完就
  ///    被下一个 chunk 打断重来，`pixels` 在半路震荡。
  ///
  /// 修法：动画结束后**复测**，若还不到底就再纠一次；用有限次重试兜底，
  /// 避免内容持续增长时陷入无限循环。
  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(attempt: 0);
    });
  }

  /// 单次纠偏。见 [_scheduleScrollToBottom] 的说明。
  ///
  /// [attempt] 用于封顶重试次数——内容在动画期间一直涨时，宁可停在
  /// 接近底部而不是把每一帧都排满动画。
  void _scrollToBottom({required int attempt}) {
    if (!mounted) return;
    final sc = widget.scrollController;
    if (sc == null || !sc.hasClients) return;
    final pos = sc.position;
    if (pos.maxScrollExtent <= 0) return;

    // 已经在底部（容 1px 取整误差）就不必再滚 —— 这是常态路径，流式输出
    // 期间大多数 chunk 都只会差几个像素。
    if ((pos.maxScrollExtent - pos.pixels).abs() <= 1.0) return;

    final target = pos.maxScrollExtent;
    final distance = (target - pos.pixels).abs();
    // 距离很短时直接跳，不用动画：动画的起步/收尾开销反而慢，而且下一个
    // chunk 很快就到，动画必被打断。
    if (distance < 24) {
      pos.jumpTo(target);
    } else {
      sc.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    // 动画跑完后再复测一次：布局可能在动画期间又長了。封顶 3 次，避免
    // 内容持续增长时无限排帧。
    if (attempt < 3) {
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        if (!mounted) return;
        final p = sc.hasClients ? sc.position : null;
        if (p == null) return;
        if ((p.maxScrollExtent - p.pixels).abs() > 1.0) {
          _scrollToBottom(attempt: attempt + 1);
        }
      });
    }
  }

  void _submit() {
    final typed = _input.text.trim();
    final attachment = _pendingAttachment;
    // 有待发附件时允许空文字发送（比如只发一张截图不加说明）；否则维持
    // 原有的「空文字不发送」门禁。
    if (typed.isEmpty && attachment == null) return;

    // text 类附件的正文没有单独的通道随请求走——它已经在 prepareAttachment
    // 里读出来了，这里拼进即将发送的文字。图片类不进这里：它走 attachments，
    // 混进文字反而会被模型当成一大段 base64 噪音。
    var text = typed;
    if (attachment != null && attachment.kind == AttachmentKind.text) {
      final body = _pendingAttachmentText ?? '';
      final note = _pendingAttachmentTruncated
          ? '\n${context.l10n.attachTextTruncated(AttachmentBar.formatBytes(attachment.bytes))}'
          : '';
      final block = '${attachment.name ?? ''}:\n$body$note';
      text = text.isEmpty ? block : '$text\n\n$block';
    }

    // 不再挡 isRunning：运行中发送直接走 `AgentLoop.send` 已有的排队
    // 分支——它自己会判断 isRunning 并把文本存进 _pendingInputs，轮
    // 边界再注入。这里不需要（也不该）重复那个判断。
    _input.clear();
    widget.loop.send(
      text,
      attachments: attachment == null ? null : [attachment],
    );
    if (attachment != null) _clearPendingAttachment();
  }

  /// 附件按钮灰着时点它：说明为什么，并给一个「仍要试一次」的出口。
  ///
  /// 灰掉的唯一原因是当前 provider 的 `supportsVision` 被翻成了 false，而那
  /// 个判定是启发式的（只看状态码），会误判 —— 一张损坏的图、一次超大的
  /// 请求体都返回 400/415。误判之后用户在这个 provider 实例上永久失去附件
  /// 能力，屏幕上却没有任何解释。
  ///
  /// 所以这里两件事一起做：把原因说出来，并允许推翻这个判定。真的不支持的
  /// 话，下一次带图请求会再把它翻回去，只多花一次流量。
  void _onAttachBlocked() {
    final svc = context.read<AIProviderService?>();
    final l = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l.attachUnsupportedVision),
        // 没有 provider 时不给这个动作 —— 那时按钮灰的原因不是「模型不支持」
        // 而是「还没配 AI」，推翻一个不存在的判定没有意义。
        action: svc?.provider == null
            ? null
            : SnackBarAction(
                label: l.attachTryAnyway,
                onPressed: svc!.retryVision,
              ),
      ),
    );
  }

  /// 弹系统文件选择器 → 校验落盘 → 按四种互斥情形提示或存入待发状态。
  ///
  /// `prepareAttachment` 本身不碰 UI（见其类文档），这里负责把结果翻译成
  /// 具体的 SnackBar 或 setState。
  Future<void> _pickAttachment() async {
    final store = widget.attachmentStore;
    final serverId = widget.attachmentServerId;
    if (store == null || serverId == null) return;

    final result = await FilePicker.platform.pickFiles();
    if (!mounted) return;
    final path = result?.files.singleOrNull?.path;

    // 「取消」与「选了但读不到」必须分开处理 —— 见 `classifyPick` 的文档。
    // 原先两者都是一句静默 `return`，于是云盘里的文件选完之后界面上什么都
    // 不发生，用户无从判断是自己没选中还是 App 坏了。
    switch (classifyPick(pickerReturned: result != null, path: path)) {
      case PickOutcome.cancelled:
        return;
      case PickOutcome.unreadable:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.attachUnreadable)));
        return;
      case PickOutcome.ok:
        break;
    }

    final prepared = await prepareAttachment(
      file: File(path!),
      serverId: serverId,
      store: store,
      downscale: downscaleImage,
    );
    if (!mounted) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    final reject = prepared.reject;
    if (reject != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            reject == AttachmentReject.binary
                ? l.attachRejectBinary
                : l.attachRejectEmpty,
          ),
        ),
      );
      return;
    }
    final tooLarge = prepared.tooLargeBytes;
    if (tooLarge != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.attachTooLarge(AttachmentBar.formatBytes(tooLarge))),
        ),
      );
      return;
    }
    if (prepared.saveFailed) {
      messenger.showSnackBar(SnackBar(content: Text(l.attachSaveFailed)));
      return;
    }
    final a = prepared.attachment;
    if (a == null) return; // 防御性——上面三支已经穷举了失败情形

    setState(() {
      _pendingAttachment = a;
      _pendingThumbnailFile = a.kind == AttachmentKind.image
          ? store.fileFor(a)
          : null;
      _pendingAttachmentText = prepared.text;
      _pendingAttachmentTruncated = prepared.truncated;
    });
  }

  void _clearPendingAttachment() {
    setState(() {
      _pendingAttachment = null;
      _pendingThumbnailFile = null;
      _pendingAttachmentText = null;
      _pendingAttachmentTruncated = false;
    });
  }

  /// 存入一条候选知识。
  ///
  /// 与提炼路径的「一律静默」相反：这里失败必须让用户看到 —— 他刚点了
  /// 存入，静默失败等于骗他。失败时也**不标记为已处理**，卡片留着，用户
  /// 能重试。
  Future<void> _saveKnowledge(
    KnowledgeProposalEvent ev,
    int index,
    KnowledgeCandidate c,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (c.target) {
        case KnowledgeTarget.skill:
          final saver = widget.onSaveSkill;
          if (saver == null) {
            throw StateError('onSaveSkill 未装配');
          }
          await saveKnowledgeSkill(c, saver: saver);
        case KnowledgeTarget.serverNote:
          // 改造前这里有一段「已知缺口」注释：基底取的是远端文件的会话级
          // 缓存，可能已经过期，整份写回会盖掉别的设备在同一台机器上的改动。
          //
          // 那个缺口随 app 端存储一起消失了 —— 现在的基底就是真相源本身，
          // 没有会过期的副本，也就没有「要不要多花一次 SSH 往返去读新鲜值」
          // 这个权衡。
          //
          // I3 修复：拼接（读现有内容、拼新小节）不再在这里做——交给
          // `onWriteMachineNotes` 背后的 `appendNote`，它既做拼接也做「存量
          // 超限」的守卫，两件事以前分别散在这里和 Manager 里，容易分叉。
          final writer = widget.onWriteMachineNotes;
          if (writer == null) {
            throw StateError('onWriteMachineNotes 未装配');
          }
          final r = await writer(c.name, c.body);
          if (!r.ok) {
            // failed 带的是现成的人话（比如「存量本身就超限，去设置里精简」），
            // 直接显示；rejected 只有一个数字，要套 l10n 模板。
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  r.error ?? l.agentKnowledgeNotesFull(r.overflowBytes),
                ),
              ),
            );
            return;
          }
      }
      if (!mounted) return;
      // 走 loop 而不是 `setState(() => ev.resolved.add(index))`：那样改的
      // 状态不会触发落盘，进程被杀后卡片变回未处理，再点一次就把同一段
      // 内容往本机笔记里追加第二遍。理由详见 `resolveKnowledgeProposal`。
      // notify 会经 `_onLoopChanged` 回来重建这一帧，不需要额外 setState。
      widget.loop.resolveKnowledgeProposal(ev, index);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// 撤回第 [index] 条待发消息，回填进输入框。
  ///
  /// 返回 null（越界）时什么都不做——那是一次良性竞态：用户点气泡的
  /// 同时轮边界正好把它注入掉了，气泡马上会随下一次 notify 消失。
  void _withdraw(int index) {
    final text = widget.loop.withdrawPendingInput(index);
    if (text == null) return;
    _appendToInput(text);
  }

  /// 编辑重发：把最后一轮的原文载回输入框，光标落末尾。
  ///
  /// 不选中全文 —— 沿用直连模式 `_editLastTurn` 的取舍：用户来点这个按钮多半
  /// 是要在原话上补一句或改个词，选中全文会让下一次按键把原文清空。
  void _startResend() {
    final text = widget.loop.prepareResend();
    if (text == null) return;
    setState(() {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  /// 重试：同一条路径，只是不改文本，直接重发。
  Future<void> _retryLastTurn() async {
    final text = widget.loop.prepareResend();
    if (text == null) return;
    await widget.loop.send(text);
  }

  /// 非正常终止（取消/报错/达上限）时，loop 把整批排队文本退回来。
  void _onPendingReturned(String text) {
    if (!mounted) return;
    _appendToInput(text);
  }

  /// 输入框里已有内容时换行拼接，避免连着退回/撤回的两段文字挤成一行。
  void _appendToInput(String text) {
    final existing = _input.text;
    _input.text = existing.isEmpty ? text : '$existing\n$text';
  }

  // 尤其是 agent 模式：语音识别出错会把错的话直接送进模型开始跑工具调用，
  // 审阅这一步不能省。
  //
  // 语音输入已从终端页 AI 面板移除（见 `PanelInputRow` 类文档）；
  // `_toggleVoice` 随之删除。
  /// 把 per-turn 计量导成 JSONL 分享出去。
  ///
  /// 走文件而不是纯文本分享：几十轮的 JSONL 会超过大多数 IM 的单条粘贴
  /// 上限，而这份数据的用法本来就是「拿到电脑上离线分析」。
  Future<void> _exportMetrics(BuildContext context, AgentLoop loop) async {
    final jsonl = loop.metrics.toJsonl();
    if (jsonl.isEmpty) return; // 还没跑过任何一轮，没东西可导
    final tmpDir = await getTemporaryDirectory();
    final path =
        '${tmpDir.path}/flyterm_agent_metrics_${DateTime.now().millisecondsSinceEpoch}.jsonl';
    final file = await File(path).writeAsString(jsonl);
    if (!context.mounted) return;
    await Share.shareXFiles([XFile(file.path)]);
  }

  @override
  Widget build(BuildContext context) {
    final loop = widget.loop;
    // 只在开发者模式（设置页版本号 7 连点）下暴露导出入口——这是给开发者
    // 排查耗时瓶颈用的诊断数据，不该出现在普通用户的界面里。用 watch 而非
    // read：面板开着的时候用户可能刚好在设置页切换这个开关。
    //
    // 类型故意写成可空的 `TerminalSettings?`：provider 包对可空类型的约定是
    // 「找不到就返回 null」而非抛 ProviderNotFoundException——AI 面板的现有
    // widget 测试大多不搭 `TerminalSettings` provider（历史上这个 view 从
    // 没依赖过它），写成不可空会让那一批测试全部因找不到 provider 而炸掉。
    final devMode = context.watch<TerminalSettings?>()?.debugOverlay ?? false;
    // 分组算一次，别在 itemBuilder 里每次都算——那是 O(n²)。
    final groups = groupSupersededEvents(loop.events);
    // 活性判定算一次。理由同上一行的分组：在 itemBuilder 里 whereType()
    // .last 是 O(n²)。
    final latest = LatestEventIndex.from(loop.events);
    // 「为空」不能只看 `loop.events.isEmpty`：用户发出第一句之后、模型还没
    // 吐出第一个事件之前有一个窗口，那时 events 可能仍是空的，但会话已经
    // 开始了——占位内容在那一瞬间闪回来会很刺眼（用户前一帧刚点掉建议
    // chip，输入框下方立刻又弹出同一批 chip）。`!loop.isRunning` 补上这个
    // 窗口：那个窗口里 loop 已经进了 thinking 状态，isRunning 为 true。
    //
    // 反过来，streamingText / pendingInputs 不需要单独并进判据——它们只会
    // 在 isRunning 为 true 时非空（流式文本只在运行中产生；排队输入只在
    // 运行中才会被存进队列而不是直接发送），所以 `!loop.isRunning` 已经
    // 蕴含了它们也是空的。
    final showEmpty = loop.events.isEmpty && !loop.isRunning;
    return Column(
      children: [
        Expanded(
          child: showEmpty && widget.emptyBuilder != null
              ? widget.emptyBuilder!((t) => widget.loop.send(t))
              : ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  // 三段：事件分组、（可能有的）正在流的那一句、排队待发的输入。
                  // 流式那段不在 loop.events 里（见 AgentLoop.streamingText 的
                  // 说明），排队输入也不在——它们还没被 loop 处理，充其量算「即将
                  // 发生的用户轮」，混进 events 会让归档 (toArchive) 把还没定稿
                  // 的东西当正式历史存下去。
                  itemCount:
                      groups.length +
                      (loop.streamingText != null ? 1 : 0) +
                      loop.pendingInputs.length,
                  // key 用 seq 而非 callId —— 后者只在一轮内唯一（Ollama 每轮
                  // 从 ollama_call_0 重新计数），跨轮重复会让 Flutter 抛异常。
                  itemBuilder: (_, i) {
                    if (i < groups.length) {
                      final g = groups[i];
                      final first = g.first;
                      final isCollapsed =
                          first is UserTurnEvent && first.supersededByEdit;
                      if (!isCollapsed) return _buildEvent(first, latest);
                      // 这一轮里有还在跑的后台任务时不收起 —— 收起来用户就得先想
                      // 起「它在被重发的那一轮里」才找得到 check_job 的入口。淡化
                      // 仍然保留，被取代这件事不能不告诉用户。
                      final hasBackgroundJob = g.any(
                        (e) => e is BackgroundJobEvent,
                      );
                      if (hasBackgroundJob) {
                        return Opacity(
                          opacity: 0.6,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: g
                                .map((e) => _buildEvent(e, latest))
                                .toList(),
                          ),
                        );
                      }
                      return SupersededGroup(
                        children: g.map((e) => _buildEvent(e, latest)).toList(),
                      );
                    }
                    final afterEvents = i - groups.length;
                    final hasStreaming = loop.streamingText != null;
                    if (hasStreaming && afterEvents == 0) {
                      return _StreamingBubble(text: loop.streamingText ?? '');
                    }
                    final j = afterEvents - (hasStreaming ? 1 : 0);
                    return _PendingBubble(
                      text: loop.pendingInputs[j],
                      onTap: () => _withdraw(j),
                    );
                  },
                ),
        ),
        // 运行中时用量**并入运行条那一行**（见下），不再单独起一行。
        //
        // 两条能同时出现（运行中 + 有 token 统计），而它们各自占一行 ——
        // 面板最小可拖到屏高的 25%（约 200dp），两行文字条的代价不小。
        // 用量本来就是右对齐的一行小字，塞进运行条右侧的空位正合适。
        //
        // 不运行时没有运行条，用量照旧自己占一行。
        if (!loop.totalUsage.isEmpty && !loop.isRunning)
          _UsageFooter(
            usage: loop.totalUsage,
            cumulative: loop.cumulativeUsage,
            onExport: devMode ? () => _exportMetrics(context, loop) : null,
          ),
        if (loop.isRunning)
          _RunningBar(
            loop: loop,
            // 并入的那份用量。null = 没有统计（新会话、或 provider 不给用量），
            // 此时运行条右侧什么也不显示。
            usage: loop.totalUsage.isEmpty ? null : loop.totalUsage,
            cumulative: loop.cumulativeUsage,
            onExportUsage:
                devMode ? () => _exportMetrics(context, loop) : null,
          ),
        // 与运行条的条件**互不依赖**：agent 收工之后任务还在跑，而那恰恰是
        // 最需要这条的时刻。挂进 _RunningBar 内部会让它在 isRunning 变 false
        // 时一起消失，等于没做。
        // `kShowJobBoard` 直接读而不是加一个穿透参数：终端页这条路径经
        // `ai_panel.dart` 转发 `onOpenJobs`，加参数要连它一起改，而本次下线
        // 只许动 ui_flags.dart / home_screen.dart / terminal_screen.dart /
        // global_ai_screen.dart / agent_view.dart。`AgentView` 因此确实对
        // 这个 UI 开关有了直接依赖，但两害相权——另一个选项是让
        // `ai_panel.dart` 也认识这个开关，污染面会更大。
        if (kShowJobBoard && loop.hasRunningJobs)
          _JobsBar(loop: loop, onOpen: widget.onOpenJobs),
        MentionField(
          ctrl: _input,
          hintText: context.l10n.agentInputHint,
          onSubmit: _submit,
          servers: widget.servers,
          hasOtherServers: widget.hasOtherServers,
          // 可空读取：与上面 `devMode` 那处 `TerminalSettings?` 同一个
          // 口径——AI 面板的既有 widget 测试大多不搭
          // `AgentSkillManager` / `AiCommandManager` provider，写成
          // 不可空会让那批测试全部因找不到 provider 而炸掉。缺 provider
          // 时退化成「没有技能/命令候选」，而不是崩溃——与
          // `MentionField` 对 `listRemoteDir == null` 的处理是同一个
          // 口径（`@` 是输入辅助，任何一处缺失都退化，绝不阻塞发送）。
          skills: context.read<AgentSkillManager?>()?.indexEntries ?? const [],
          commands: context.read<AiCommandManager?>()?.indexEntries ?? const [],
          listRemoteDir: widget.listRemoteDir,
          resolveRemotePath: widget.resolveRemotePath,
          // `./` 的基准。**从 loop 现取而不是新加字段** ——
          // `AgentLoop.cwdProvider` 是 public 字段且语义就是「每轮现
          // 取」（用户 cd 到别处之后不该还用旧值），正是这里需要的。
          // 这样也不必碰 agent_loop.dart。
          cwd: loop.cwdProvider?.call(),
          // null = 这个会话没有落盘能力（terminal_screen 没装配
          // AttachmentStore），附件按钮整个不渲染——与
          // `listRemoteDir == null` 时 `@file` 分组消失是同一个口径。
          onAttachTap:
              (widget.attachmentStore != null &&
                  widget.attachmentServerId != null)
              ? _pickAttachment
              : null,
          // 灰掉时点它 → 说明原因 + 给一个逃生口。**不能只靠 tooltip**
          // （手机上要长按），见 `PanelInputRow.onAttachBlockedTap`。
          onAttachBlockedTap:
              (widget.attachmentStore != null &&
                  widget.attachmentServerId != null)
              ? _onAttachBlocked
              : null,
          // 按钮渲染与否只看有没有落盘能力；灰不灰看当前模型支不支持
          // 视觉输入——两者是两件事：没装配 store 时按钮该消失，装配了
          // 但模型不支持时按钮该在、只是变灰并在点击时说明原因。
          //
          // 可空读取：与上面 skills/commands 同一个口径——既有 widget
          // 测试大多不搭 `AIProviderService` provider。
          attachEnabled:
              context.watch<AIProviderService?>()?.provider?.supportsVision ??
              false,
          pendingAttachment: _pendingAttachment,
          pendingThumbnailFile: _pendingThumbnailFile,
          onRemoveAttachment: _clearPendingAttachment,
        ),
      ],
    );
  }

  Widget _buildEvent(AgentEvent e, LatestEventIndex latest) => switch (e) {
    // 批次查不到时（归档恢复后撤销栈已空）卡片自己降级成一行历史说明。
    AppChangeEvent ev =>
      widget.loop.appControl == null
          ? const SizedBox.shrink()
          : AppChangeCard(
              service: widget.loop.appControl!,
              batchId: ev.batchId,
            ),
    UserTurnEvent ev => Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: FlyColors.userBubbleFill,
            border: Border.all(
              color: FlyColors.userBubbleBorder,
              width: kHairline,
            ),
            borderRadius: FlyRadius.bubbleRadius,
          ),
          child: Text(ev.text),
        ),
        for (final a in ev.attachments ?? const [])
          AttachmentBubble(
            attachment: a,
            fileFor: widget.attachmentFileFor ?? (_) => null,
          ),
        // 自己刚发的那条也值得能复制：手机上重发一条长指令的成本是
        // 整条重打，而这个面板最贵的操作就是打字。
        //
        // 编辑按钮只给最后一轮、且还没被重发过、且当前没在跑——
        // 中间轮次编辑要处理「其后多轮的工具调用」，是另一个量级的
        // 问题（同 `AgentLoop.prepareResend` 的门禁）。
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!ev.supersededByEdit &&
                  !widget.loop.isRunning &&
                  latest.isLatest(ev))
                MessageActionIcon(
                  icon: Icons.edit_outlined,
                  onTap: _startResend,
                  semanticLabel: context.l10n.aiEditAction,
                ),
              MessageCopyButton(text: ev.text),
            ],
          ),
        ),
      ],
    ),
    // 按 markdown 渲染，与直连模式同一套样式和 code block builder。
    // 模型的结论里常有列表、粗体、代码块 —— 早先用 SelectableText
    // 直接吐原文，`**这样**` 和 ``` 围栏全都以字面量出现在屏幕上。
    //
    // 注意工具卡里的命令输出**不能**这么做：那是 shell 的原始字节，
    // 里面的 * 和 _ 不是 markdown 记号。
    AssistantTextEvent ev => Padding(
      // 助手回答按裸 markdown 渲染，左右各留 12 与用户气泡（margin 8 +
      // 气泡内边距 12）和工具卡对齐全宽。
      //
      // 曾经在左侧画过一条 `tintBlue` 的 2dp 色条，想与用户气泡的 mint
      // 形成「一边一个色」的对话感。实际观感更像 markdown 引用块 ——
      // 用户看到的第一反应是「我引用了一段话？」，而不是「模型在说话」。
      // 语义靠气泡/卡片本身的留白已经够了，色条只添了误导。
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MarkdownBody(
            data: ev.text,
            selectable: true,
            styleSheet: aiProseStyle(context),
            // agent 模式的代码块不挂动作按钮：命令由模型发起、走审批
            // 卡，用户不需要也不该手动执行一段围栏内容。而围栏并不
            // 保证是命令 —— 判据只看有没有回调、不看 language，模型
            // 把一段中文计划用 ``` 包起来时，「执行」会把那段中文原样
            // 送进终端（2026-09-09 真机截图）。复制一并去掉：消息级
            // 已有复制按钮，代码块再挂一个是重复的。
            builders: aiMarkdownBuilders(showActions: false),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 重试按钮只给本轮最后一条助手消息——判据用「最后一条
                // 助手消息」而不是「事件流最后一条事件」：轮末的最后
                // 一条事件可能是 ToolCallEvent，那样按钮就没有落点。
                if (!widget.loop.isRunning && latest.isLatest(ev))
                  MessageActionIcon(
                    icon: Icons.refresh,
                    onTap: _retryLastTurn,
                    semanticLabel: context.l10n.aiRetryAction,
                  ),
                // 复制的是**原始 markdown**，不是渲染后的纯文本。
                // 转发给同事时对面多半也在 markdown 环境里，丢掉围栏
                // 和列表记号反而要对方自己重排。
                MessageCopyButton(text: ev.text),
              ],
            ),
          ),
        ],
      ),
    ),
    // `ask_user` 必须在这一支之前被放行：它借用 `awaitingApproval` 当
    // 挂起态（见 `ask_executors.dart`），漏掉这个守卫就会被这条 when
    // 抢先匹配成审批卡 —— 用户看到的是「允许一次 / 拒绝」而不是选项，
    // 且两个按钮都打不通：`respondApproval` 查的是 `_pending`，而提问
    // 的 completer 在 `_pendingAnswers` 里，点了等于没点。
    ToolCallEvent ev
        when ev.status == ToolCallStatus.awaitingApproval &&
            ev.toolName != 'ask_user' =>
      ApprovalCard(
        key: ValueKey(ev.seq),
        event: ev,
        providerName: widget.providerName,
        bypassMode: widget.bypassMode,
        onDecision: (d, rule, silence) => widget.loop.respondApproval(
          ev.seq,
          d,
          rememberRule: rule,
          silenceInSession: silence,
        ),
      ),
    ToolCallEvent ev => ToolCallCard(
      key: ValueKey(ev.seq),
      event: ev,
      // 只给有备份的写入卡。undoEdit 自己会再判一次状态，这里的判断
      // 只是为了不在无关卡片上摆一个按钮。
      onUndo: ev.backupPath == null ? null : () => widget.loop.undoEdit(ev.seq),
      // 只给提问卡。respondAnswer 对已应答的 seq 是静默丢弃，所以
      // 重复点击安全。
      onAnswer: ev.toolName != 'ask_user'
          ? null
          : (choice) => widget.loop.respondAnswer(ev.seq, choice),
    ),
    // 被后续 set_plan 取代的旧清单退成一行：一轮里改三次计划就会堆
    // 三张几乎一样的清单，而只有最后一张说明「现在做到哪」。旧的仍然
    // 可展开 —— 它是时间线的一部分，不能抹掉。
    PlanUpdatedEvent ev when !latest.isLatest(ev) => DenseEventRow(
      leading: Icon(
        Icons.playlist_add_check,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      spans: [
        TextSpan(
          text: context.l10n.agentPlanUpdatedCollapsed(ev.steps.length),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      expanded: (_) => PlanChecklist(steps: ev.steps, current: ev.current),
    ),
    PlanUpdatedEvent(:final steps, :final current) => PlanChecklist(
      steps: steps,
      current: current,
    ),
    PlanProposalEvent(:final calls) => PlanProposalCard(
      calls: calls,
      // approvePlan 返回 Future<void>——直接传给 VoidCallback 参数是
      // 合法的（Dart 允许非 void 返回值的函数用在 void 上下文，返回值
      // 被丢弃），analyze 对此没有意见，用不着额外包一层箭头函数。
      onApprove: widget.loop.approvePlan,
      onDiscard: widget.loop.discardPlan,
    ),
    KnowledgeProposalEvent ev => KnowledgeProposalCard(
      candidates: ev.candidates,
      resolved: ev.resolved,
      onSave: (i, c) => _saveKnowledge(ev, i, c),
      // 忽略只标记全部条目为已处理，**不从事件流里摘掉这张卡**：
      // 那条记录如实反映了「这次确实提议过、用户选择不存」。与
      // ToolCallEvent.superseded 压暗而不抹掉是同一个道理。
      // 同 `_saveKnowledge`：必须走 loop 才会落盘，否则进程被杀后
      // 这张已被忽略的卡会原样复活。
      onDismiss: () {
        for (var i = 0; i < ev.candidates.length; i++) {
          widget.loop.resolveKnowledgeProposal(ev, i);
        }
      },
    ),
    BatchApprovalEvent(:final calls, :final targets) => BatchApprovalCard(
      calls: calls,
      targets: targets,
      onApproveAll: widget.loop.approveBatch,
      onDiscard: widget.loop.discardBatch,
    ),
    StoppedEvent ev => _StoppedBanner(
      reason: ev.reason,
      maxTurns: widget.loop.maxTurns,
      errorMessage: widget.loop.errorMessage,
      metrics: widget.loop.metrics.turns.isEmpty
          ? null
          : widget.loop.metrics.currentRunTotals,
      isLatest: latest.isLatest(ev),
      onContinue: () => widget.loop.send('continue'),
    ),
    SessionInterruptedEvent ev => _InterruptedBanner(
      lastCalls: ev.lastCalls,
      isLatest: latest.isLatest(ev),
      onResume: () => widget.loop.resume(),
    ),
    BackgroundJobEvent ev => JobCard(
      key: ValueKey('job-${ev.seq}'),
      event: ev,
      onKill: () => widget.loop.killJob(ev.jobId),
    ),
    TransferEvent ev => TransferCard(
      key: ValueKey('transfer-${ev.seq}'),
      event: ev,
      onCancel: ev.running ? () => widget.loop.cancelTransfer(ev.seq) : null,
      onOpen: ev.localPath == null ? null : () => OpenFilex.open(ev.localPath!),
      // credentialDeny 的禁用在 TransferCard 内部强制执行，这里照常传。
      onLetAiRead: ev.localPath == null
          ? null
          : () => widget.loop.injectLocalFile(ev.localPath!),
      onShare: ev.localPath == null
          ? null
          : () => Share.shareXFiles([XFile(ev.localPath!)]),
    ),
    CompactedEvent ev => CompactionCard(
      key: ValueKey('compact-${ev.droppedMessages}-${ev.summary.length}'),
      event: ev,
    ),
    TruncatedEvent(:final droppedEvents) => DenseEventRow(
      leading: Icon(
        Icons.unfold_less,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      spans: [
        TextSpan(
          text: context.l10n.agentTruncated(droppedEvents),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  };
}

/// 一条排队待发的输入。样式仿 `UserTurnEvent` 的气泡（同色、同形状），
/// 但降低不透明度并加一个钟表图标——视觉上要一眼区分「已经说出去的话」
/// 和「还没轮到它」，否则用户会以为排队的内容已经发给模型了。
///
/// 点击撤回：`InkWell` + `Semantics(button: true)` 让它既有触觉反馈
/// 也对无障碍可读。
class _PendingBubble extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _PendingBubble({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Semantics(
      button: true,
      hint: context.l10n.agentPendingWithdrawHint,
      child: InkWell(
        onTap: onTap,
        borderRadius: FlyRadius.bubbleRadius,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: FlyColors.userBubbleFill.withValues(alpha: 0.5),
            border: Border.all(
              color: FlyColors.userBubbleBorder.withValues(alpha: 0.6),
              width: kHairline,
            ),
            borderRadius: FlyRadius.bubbleRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(text)),
              const SizedBox(width: 6),
              Icon(
                Icons.schedule,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RunningBar extends StatelessWidget {
  final AgentLoop loop;

  /// 并入本行的用量。null = 不显示（无统计，或不运行时由 `_UsageFooter` 自己显示）。
  ///
  /// 2026-10-13 并入：用量与运行条能同时出现，而面板最小可拖到屏高的 25%
  /// —— 两条独立小字行在那里太贵。用量本来就是右对齐的一行小字，而运行条
  /// 的 label 用的是 `Expanded`，中间本来就有空位。
  final TokenUsage? usage;
  final TokenUsage cumulative;
  final VoidCallback? onExportUsage;

  const _RunningBar({
    required this.loop,
    this.usage,
    this.cumulative = const TokenUsage(),
    this.onExportUsage,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // 文案分支全在 runningBarLabel 里，那边有单测。这里只负责把 loop 上
    // 的输入喂进去。
    //
    // elapsed 用 DateTime.now() 现算：本 widget 由 _AgentViewState._tick
    // 每秒 setState 一次带着重建（条件是 loop.isRunning，恰好覆盖运行条
    // 会渲染的全部状态），所以秒数天然会走，不需要自己持有 Timer。
    //
    // `runToolCalls` 取的是 `currentRunTotals`（本轮到目前为止，**实时**
    // 累加），不是 `current`（最后一次 LLM 请求）。后者会把「最后一步」
    // 当成「本轮」——那一步是模型给最终文本那次，没有工具调用。这是
    // 2026-09-15 的真机回归，收工总结那里已经踩过同一坑
    // （见 `MetricsRecorder.currentRunTotals` 文档）。
    final startedAt = loop.phaseStartedAt;
    final totals = loop.metrics.currentRunTotals;
    final label = runningBarLabel(
      l,
      state: loop.state,
      elapsed: startedAt == null ? null : DateTime.now().difference(startedAt),
      runningCommands: loop.runningCalls.map((e) => e.displayCommand).toList(),
      rateLimitRemaining: loop.rateLimitRemaining,
      runToolCalls: totals.toolCalls,
    );
    final u = usage;
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall;
    final usageStyle = theme.textTheme.labelSmall;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 停止按钮按自然宽度先扣掉（它永不缩，是 escape hatch）。
          // TextButton.icon 的宽度随主题/字号变，靠测得才准。
          final stopW = _measure('/**/', theme.textTheme.labelLarge) +
              _kStopButtonChrome;

          // ## 单行放得下吗？测一测，别猜
          //
          // 2026-10-14：**方案 C** —— 宽度够一行，不够拆两行；
          // 而不是把用量省略号截断（截了就不叫「显示 token 统计」了）。
          //
          // 不用固定断点：中英文/数字长度差很大，同一句文案在两种语言下
          // 宽度能差一倍。用 `TextPainter` 拿真宽，与 Row 自己的布局同源。
          final labelW = _measure(label, labelStyle);
          final usageW =
              u == null ? 0.0 : _measure(_usageText(context, u, cumulative), usageStyle);
          const spinnerW = _kSpinner + _kGap + _kGap + _kGap + _kStopGap;
          final oneLineNeed = spinnerW + labelW + usageW + stopW;

          if (oneLineNeed <= constraints.maxWidth) {
            return Row(
              children: [
                const SizedBox(
                  width: _kSpinner,
                  height: _kSpinner,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: _kGap),
                // 放得下时两者各取自然宽，空白留在中间（2026-10-13 的初衷）。
                // `Flexible` 仍留着兜底：测量与实际布局极小概率差一个像素，
                // 有它就不会溢出。
                Flexible(
                  child: Text(
                    label,
                    style: labelStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (u != null) ...[
                  const SizedBox(width: _kGap),
                  Flexible(
                    child: usageFooterLabel(context, u, cumulative,
                        onExport: onExportUsage, shrink: true),
                  ),
                ],
                const SizedBox(width: _kStopGap),
                _stopButton(l),
              ],
            );
          }

          // ## 窄屏：拆两行（方案 C）
          //
          // 第一行「⏺ 阶段文案 ……… 停止」，第二行用量整宽右对齐。
          // 用量**不再截断** —— 这正是用户报的「token 统计显示不全」。
          //
          // 代价是多占约 16dp 高度；面板最小高度（屏高 25% ≈ 200dp）下
          // 可接受，而信息完整比省这一行重要。
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: _kSpinner,
                    height: _kSpinner,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: _kGap),
                  Expanded(
                    child: Text(
                      label,
                      style: labelStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: _kStopGap),
                  _stopButton(l),
                ],
              ),
              if (u != null)
                Padding(
                  // 对齐上面那一行的文字起点（spinner + gap）。
                  padding: const EdgeInsets.only(
                      left: _kSpinner + _kGap, top: 2),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: usageFooterLabel(context, u, cumulative,
                        onExport: onExportUsage),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _stopButton(AppLocalizations l) => TextButton.icon(
        onPressed: loop.cancel,
        icon: const Icon(Icons.stop_circle_outlined, size: 16),
        label: Text(l.agentStop),
      );
}

// 运行条的尺寸常量。抽成顶层是为了让「测量」与「布局」用同一组数字 ——
// 两处各写字面量的话，改了其中一处测量就不再反映真实布局（而那是很难
// 发现的：只在特定宽度下多一行/少一行）。
const double _kSpinner = 12;
const double _kGap = 8;
const double _kStopGap = 4;

/// 停止按钮除文字外的开销（左右 padding + 图标 + 图标与文字间距）。
/// 估不准也无妨：[_measure] 的误差只会让极端宽度下多/少一行，不会溢出
/// （两个分支都用了 `Flexible`/`Expanded` 兜底）。
const double _kStopButtonChrome = 52;

/// 一句文案在给定样式下占多宽。
///
/// 用 `TextPainter` 而不是 `Row` 试着放：后者只能靠 `RenderFlex` 的
/// overflow 错误反推，那是运行期异常不是可查询的状态。
///
/// 不 `layout(maxWidth: infinity)` 之外的处理：这里问的是「自然宽度」，
/// 给无限约束正是要它别折行。
double _measure(String text, TextStyle? style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  return tp.width;
}

/// 与 `usageFooterLabel` 同一份文案 —— 直接调 [usageFooterText]，不另拼一套。
/// 测量拿到的字符串与最终画出来的不一致时，断行判定会错，而且只在特定
/// 宽度下错 —— 那是最难发现的边界，所以这里刻意不留第二份实现。
String _usageText(BuildContext context, TokenUsage usage, TokenUsage cumulative) =>
    usageFooterText(context, usage, cumulative);

/// 未收尾的后台任务的常驻条。
///
/// ## 为什么不挂在运行条里
///
/// 运行条只在 `loop.isRunning` 时渲染。而后台任务的整个意义就是「agent 收工
/// 了它还在跑」—— 挂进去等于在最需要它的时刻把它藏起来。两个条的条件因此
/// 互不依赖，可以同时出现。
///
/// ## 为什么显示「最旧」的确认时间
///
/// 多任务时取所有任务里**最久没核实**的那个。显示最近的会让人对整体过于
/// 乐观：「3 分钟前」应当意味着「所有任务都在 3 分钟内被核实过」，而不是
/// 「至少有一个是」。
class _JobsBar extends StatelessWidget {
  final AgentLoop loop;
  final VoidCallback? onOpen;

  const _JobsBar({required this.loop, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jobs = loop.events
        .whereType<BackgroundJobEvent>()
        .where((e) => e.running)
        .toList();
    // 调用点已经判过 hasRunningJobs，这里是防御 —— 两处判据必须同源，
    // 否则会渲染出一个空条。
    if (jobs.isEmpty) return const SizedBox.shrink();

    final oldestChecked = jobs
        .map((e) => e.lastCheckedAtMs)
        .reduce((a, b) => a < b ? a : b);

    // 单任务时给它的描述（比「1 个后台任务」有用得多）；描述为空时退回命令。
    final single = jobs.length == 1 ? jobs.single : null;
    final title = single != null
        ? (single.description.isNotEmpty ? single.description : single.command)
        : context.l10n.agentJobsBarCount(jobs.length);

    return InkWell(
      key: const Key('jobsBar'),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.settings_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    jobCheckedLabel(context, oldestChecked),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onOpen != null)
              Icon(
                Icons.chevron_right,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

class _StoppedBanner extends StatelessWidget {
  final AgentStopReason reason;
  final int maxTurns;
  final String? errorMessage;
  final VoidCallback onContinue;

  /// 刚结束这一次提问的计量合计。null = 秤上没有数据(计量是纯旁路,采集
  /// 失败时就是这个值),此时整行总结不渲染。
  ///
  /// **是整次提问的合计,不是最后一条 `TurnMetrics`**：后者的粒度是一次
  /// LLM 请求,而末次请求正是模型给最终文本的那一次、没有工具调用 ——
  /// 直接用它会把跑了 4 个工具的一轮显示成「0 次调用」(2026-09-15 回归)。
  final RunTotals? metrics;

  /// 这是不是事件流里最新的一条 StoppedEvent。
  ///
  /// false 时不渲染「继续」按钮。历史位置上的那个按钮点下去会真的
  /// `send('continue')`，而用户以为自己在续上半小时前那一轮。收工总结
  /// 照常显示 —— 它是纯信息，没有误触的余地。
  final bool isLatest;

  const _StoppedBanner({
    required this.reason,
    required this.maxTurns,
    required this.errorMessage,
    required this.onContinue,
    required this.metrics,
    required this.isLatest,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);

    // 收工总结只给最新那一条。
    //
    // `metrics.current` 的定义是 `_turns.last`（turn_metrics.dart:125），而
    // 每轮正常结束都会 add 一条 StoppedEvent —— 跑了五轮的会话里就有五条
    // 总结行，五条显示的全是第五轮的时长/调用次数/token。历史位置上那些
    // 数字是错的，而错的数字比一个可点的旧按钮更难被发现。
    //
    // 要让历史各自显示自己那一轮，得把 TurnMetrics 快照挂到事件上（agent_
    // loop.dart 加字段 + 归档序列化），超出本次范围。在那之前宁可不显示。
    final summary = isLatest ? _summary(context) : null;

    // 正常结束不显示横幅 —— 结论已经在 assistant 文本里了。但收工总结要
    // 显示:一轮跑了多久、动了几次手,恰恰在正常结束时最有意义。
    if (reason == AgentStopReason.completed) {
      return summary ?? const SizedBox.shrink();
    }

    final (text, showContinue) = switch (reason) {
      AgentStopReason.maxTurns => (l.agentStoppedMaxTurns(maxTurns), true),
      AgentStopReason.tokenBudget => (l.agentStoppedTokenBudget, true),
      AgentStopReason.userCancelled => (l.agentStoppedCancelled, false),
      AgentStopReason.invalidArgs => (l.agentStoppedInvalidArgs, false),
      AgentStopReason.error => (errorMessage ?? 'error', false),
      AgentStopReason.completed => ('', false),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: FlyRadius.cardRadius,
          ),
          child: Row(
            children: [
              Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
              if (showContinue && isLatest)
                TextButton(onPressed: onContinue, child: Text(l.agentContinue)),
            ],
          ),
        ),
        if (summary != null) summary,
      ],
    );
  }

  /// 一行收工总结。null = 没有计量数据。
  Widget? _summary(BuildContext context) {
    final m = metrics;
    if (m == null) return null;
    final l = context.l10n;
    final theme = Theme.of(context);
    final tok = m.tokens;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
      child: Tooltip(
        // turnTotalMs 用的 Stopwatch 会把 app 切到后台的时间一并算进来
        // (turn_metrics.dart 自述)。不为这个低频场景引入生命周期监听,
        // 而是把口径说清楚。
        message: l.agentTurnSummaryTooltip,
        child: Text(
          l.agentTurnSummary(
            formatTurnDuration(m.totalMs),
            m.toolCalls,
            tok < 1000 ? '$tok' : '${(tok / 1000).toStringAsFixed(1)}k',
          ),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 上次会话被硬杀之后的横幅。与 `_StoppedBanner` 分开:那个是正常终止的
/// 说明,这个要给出一个动作(继续),且要如实说明中断处的状态未知。
class _InterruptedBanner extends StatelessWidget {
  final List<String> lastCalls;
  final VoidCallback onResume;

  /// 这是不是事件流里最新的一条 SessionInterruptedEvent。
  ///
  /// false 时不渲染「继续」按钮 —— 理由同 `_StoppedBanner.isLatest`：
  /// 历史位置上的恢复入口点下去语义不对，标题（中断记录本身）不受影响。
  final bool isLatest;

  const _InterruptedBanner({
    required this.lastCalls,
    required this.onResume,
    required this.isLatest,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: FlyRadius.cardRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.agentInterruptedTitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                if (lastCalls.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    l.agentInterruptedRunning(lastCalls.join(', ')),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (isLatest)
            TextButton(
              onPressed: onResume,
              child: Text(l.agentInterruptedResume),
            ),
        ],
      ),
    );
  }
}

/// `usageFooterLabel` 的**纯文本**。抽出来是因为运行条那一行要在布局前
/// 先量宽（`_measure`）才能决定一行还是两行，而量宽只需要字符串。
///
/// 两处（渲染 / 测量）必须同源：测量拿到的字符串与最终画出来的不一致时，
/// 断行判定就会错，而且只在特定宽度下错 —— 那是最难发现的边界。
String usageFooterText(
  BuildContext context,
  TokenUsage usage,
  TokenUsage cumulative,
) {
  final session = usage.cachedTokens > 0
      ? context.l10n.agentUsageCached(
          _kTokens(usage.totalInput),
          _kTokens(usage.cachedTokens),
          _kTokens(usage.outputTokens),
        )
      : context.l10n
          .agentUsage(_kTokens(usage.totalInput), _kTokens(usage.outputTokens));
  // 累计那一截用 totalInput + output 而不是把三档都列出来：它的作用是
  // 「我总共用了多少」，不是拆账。本会话那一行已经拆过了。
  return cumulative.isEmpty
      ? session
      : context.l10n.agentUsageCumulative(
          session,
          _kTokens(cumulative.totalInput + cumulative.outputTokens),
        );
}

/// 用量页脚。缓存命中率是唯一能验证 caching 真的生效的信号 —— 位置对不对、
/// 前缀够不够长，都只在这个数字上体现。
class _UsageFooter extends StatelessWidget {
  final TokenUsage usage;

  /// 跨会话累计。空（或没注入累计时）不追加那一截。
  final TokenUsage cumulative;

  /// 点一下导出 per-turn 计量。null = 开发者模式没开，这一行只是文字。
  final VoidCallback? onExport;

  const _UsageFooter({
    required this.usage,
    this.cumulative = const TokenUsage(),
    this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: usageFooterLabel(context, usage, cumulative, onExport: onExport),
      ),
    );
  }
}

/// 用量文案（本会话 + 可选累计），以及可选的导出入口。
///
/// **抽成顶层函数而不是留在 `_UsageFooter` 里**：2026-10-13 之后用量有两
/// 个落点 —— 不运行时自己占一行（`_UsageFooter`），运行时并入运行条那一行
/// （`_RunningBar`）。两处各写一套的话，同一个数在两种状态下会长得不一样
/// （位数格式、缓存那截的有无、导出图标…），而那种不一致最难被发现。
///
/// [shrink] = true 时给文字加 `ellipsis` 并允许被压缩 —— 只有运行条那一行
/// 需要（那里宽度要和运行文案、停止按钮分）。自己占一行的 `_UsageFooter` 走
/// 默认值：那一行整宽都是它的，截断只会白白丢信息。
Widget usageFooterLabel(
  BuildContext context,
  TokenUsage usage,
  TokenUsage cumulative, {
  VoidCallback? onExport,
  bool shrink = false,
}) {
  final theme = Theme.of(context);
  final text = usageFooterText(context, usage, cumulative);
  final color = theme.colorScheme.onSurfaceVariant;
  // 被压缩时才截断（[shrink]）；否则按自然宽度渲染。两条分支共用同一份
  // `maxLines`/`softWrap` 口径，不然同一种字号会在两种状态下折行行为不同。
  final textStyle = theme.textTheme.labelSmall?.copyWith(color: color);
  Widget textWidget(String s) => Text(
        s,
        style: textStyle,
        maxLines: 1,
        softWrap: false,
        overflow: shrink ? TextOverflow.ellipsis : TextOverflow.clip,
      );
  if (onExport == null) {
    return textWidget(text);
  }
  // 与同文件的 `_PendingBubble` 对齐：`Semantics(button:)` + 一个够手指点的
  // 热区。这一段只在开发者模式下存在，所以放大 padding 不会影响普通用户
  // 看到的页脚高度（那条走上面的分支）。
  //
  // `hint` 而不是 `label`：可见文字是 token 用量，label 会把它整段替换成
  // 「导出耗时计量」，屏幕阅读器就再也读不到用量数字了。hint 是追加的
  // 「点下去会发生什么」，两者都保得住。
  return Semantics(
    button: true,
    hint: context.l10n.agentExportMetrics,
    child: InkWell(
      onTap: onExport,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        // 12px 图标 + 一行 labelSmall 约 16px 高，纵向各加 8 才够到 Material
        // 建议的最小触摸目标附近。视觉尺寸不变，放大的只是可点区域。
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 纯文字可点没有任何提示——加一个不起眼的小图标暗示这里能导
            // 出，但不用 IconButton（点击热区太显眼），诊断入口不该抢用户
            // 注意力。
            Icon(Icons.ios_share, size: 12, color: color),
            const SizedBox(width: 4),
            // 外层若把它放进 Flexible，这里得能收（[shrink]）；否则
            // `Row` 按自然宽度撑开、外面的压缩就白费了。
            if (shrink) Flexible(child: textWidget(text)) else textWidget(text),
          ],
        ),
      ),
    ),
  );
}

/// `1.2k` 这类缩写。1000 以下原样显示。
String _kTokens(int n) =>
    n < 1000 ? '$n' : '${(n / 1000).toStringAsFixed(1)}k';


/// 正在流式到达的助手文本。
///
/// **用 Text 而不是 MarkdownBody。** 半截 markdown 渲染起来会跳：一个还没
/// 闭合的 ``` 围栏会让后面所有文字先变成代码块，下一帧收到闭合符号又全部
/// 变回去；`**` 也一样。定稿之后走 `AssistantTextEvent` 那条路才用 markdown，
/// 那时结构是完整的。
///
/// 代价是流式过程中用户看到几个字面量的 `*` 和 ```，一两帧之后就被定稿版
/// 替换掉 —— 比整段文字反复变形好得多。
class _StreamingBubble extends StatelessWidget {
  final String text;
  const _StreamingBubble({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}
