// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../../util/dlog.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/agent_session.dart';
import '../../data/repositories/agent_session_repository.dart';
import 'agent_exec_channel.dart';
import 'agent_loop.dart';
import 'agent_tools.dart';
import 'approval_notification.dart';
import 'permission_rules.dart';
import 'tool_registry.dart';

/// App 级持有者：规则集、permission mode、活跃 loop。
///
/// **loop 由它持有而不是 widget** —— 面板只是视口。关掉面板 loop 继续跑，
/// 重开时从这里恢复完整事件流。
class AgentSessionManager extends ChangeNotifier {
  final SharedPreferences _prefs;
  final Map<String, AgentLoop> _loops = {};
  final Map<String, VoidCallback> _listeners = {};

  /// 一台服务器一个 exec channel，与 loop 同生命周期 —— 原来挂在
  /// `_TerminalScreenState` 上，screen pop 时被 dispose，而 loop（挂在这个
  /// manager 上）活得比 screen 久，之后每次工具调用都会在孤儿 channel 上
  /// 开一条永不关闭的新连接。挪到这里，两者生命周期才对得上。
  final Map<String, AgentExecChannel> _channels = {};

  /// 由 main.dart 注入 —— manager 不认识通知实现，只发出「有一条待审批」。
  void Function(String serverId, ToolCallEvent event)? onApprovalPending;

  /// 已经通知过的 (serverId, callId, seq) 组合 —— 见 [approvalDedupKey]
  /// 为什么 seq 不能省（edit_file 的读、写两次审批共用同一个 callId）。
  /// 纯内存 —— 审批没有离线补投语义，进程重启后 loop 本身也随之消失，
  /// 不需要落盘。
  final Set<String> _notified = {};

  /// 历史会话归档。**可选** —— 不给的话历史功能整体失效（归档 no-op、列表恒
  /// 空），其余功能照常。
  ///
  /// 做成可选是为了那十几个只关心 UI 的 widget 测试（设置页、面板渲染）：它们
  /// 不碰历史，强迫每个都建一个 in-memory DB 是让测试为实现细节付代价。生产代码
  /// （main.dart）永远会传。
  final AgentSessionRepository? _sessions;

  // 这里曾有一个 `_activeStarred` map：打开标星会话时记住 starred，归档时
  // 作为新行的字段带回去。改成「活跃段固定占一行、持续 UPDATE」之后它没有
  // 用处了 —— 那一行从来没被删过，starred 一直在库里，而 `updateContent`
  // 刻意不碰这一列。留着一个只写不读的字段只会让下一个人以为标星还需要在
  // 内存里搬运。

  AgentSessionManager(this._prefs, [this._sessions]);

  static String _modeKey(String serverId) => 'agent_mode_$serverId';
  static String _archiveKey(String serverId) => 'agent_archive_$serverId';

  /// 权限模式的**全局默认**。per-server 的 `_modeKey` 现在表示「覆盖」。
  static const String _kModeDefaultKey = 'agent_mode_default';

  /// 放行规则清单是**全局**的。
  ///
  /// 原本按服务器存，但规则表达的主要是「这类命令我信任」——更接近对命令
  /// 的判断而非对机器的判断。真正随机器变的是「这台我敢让 agent 做多少」，
  /// 那件事由权限模式的 per-server 覆盖承担。
  static const String _kRulesKey = 'agent_rules_global';

  /// 首次过目标记是**全局**的：规则变全局之后，「用 agent 前先过目一次
  /// 放行清单」这件事也只该发生一次。
  static const String _kReviewedKey = 'agent_rules_reviewed_global';
  /// 用户在设置里手写的那份，**全局共用**。null = 没写过。
  ///
  /// 这里放的是跟服务器无关的偏好：「回答简洁点」「用中文」「先说结论再说
  /// 过程」。机器级的差异（用 podman、日志在 /data/logs）归
  /// `ServerNotesManager`，按 serverId 存在 app 端的 `server_notes` 表里。
  ///
  /// ## 为什么机器笔记不跟着机器走
  ///
  /// 这一层曾经按服务器存，后来搬到了远端服务器上的一个笔记文件，2026-10
  /// 又搬回 app 端。**不要再搬回去。**
  ///
  /// 支持远端的那套论证（换手机还在、多设备共享、agent 自己也能维护、
  /// 「这台机器的事」该跟着机器走）本身没错，它只是优化错了目标：那些解决
  /// 的是**持久性**，而真正的痛点是**可管理性** —— 知识散在 N 台机器上，
  /// 用户在 app 里看不到全貌、删不掉、导不出；而一台机器重装或换 IP，那份
  /// 笔记照样会丢，持久性优势并不如看上去稳固。
  ///
  /// 判准是：**单一真相源优先于跟随载体。** 代价（换手机会丢）是明确接受的。
  static const String _kInstructionsKey = 'agent_instructions_global';
  static const String _kKnowledgeCaptureKey = 'agent_knowledge_capture';

  // ---- 规则 ----

  /// 已解析的规则集缓存。null = 还没读过，下次 [rules] 现解析。
  ///
  /// 缓存有两个理由，**第二个才是主要的**：
  ///
  /// 1. 这个 getter 每次都 `jsonDecode` 一整个规则表，而它在每条工具调用
  ///    上要被读好几次（分桶一次、执行判定一次、抢跑起飞/落地各一次），
  ///    还会被设置页的 build 读。
  /// 2. **返回值的对象身份保持稳定。** 调用方不该依赖身份（`AgentLoop` 那
  ///    边已经改成按值比较了），但「每读一次 new 一个」本身是个容易引诱人
  ///    踩的形状 —— 抢跑重复执行那个 bug 就是这么来的。这里让身份稳定是
  ///    纵深防御的第二层，不是第一层。
  PermissionRuleSet? _rulesCache;

  /// 读规则集。首次读取返回默认规则集（不落盘 —— 让默认集将来能随版本
  /// 更新，用户改过的才落盘）。
  PermissionRuleSet get rules => _rulesCache ??= _readRules();

  PermissionRuleSet _readRules() {
    final raw = _prefs.getString(_kRulesKey);
    if (raw == null) return const PermissionRuleSet(defaultAllowRules);
    try {
      return PermissionRuleSet.fromJson(jsonDecode(raw) as List<dynamic>);
    } catch (_) {
      return const PermissionRuleSet(defaultAllowRules);
    }
  }

  void _saveRules(List<PermissionRule> next) {
    // 缓存与落盘必须在同一个方法里更新。这是本类**唯一**写 [_kRulesKey]
    // 的地方；将来若新增第二条写入路径，它也必须经过这里，否则缓存会读到
    // 过期的规则（比落盘漏写更难发现：重启一次就「自愈」了）。
    _rulesCache = PermissionRuleSet(next);
    _prefs.setString(_kRulesKey, jsonEncode(PermissionRuleSet(next).toJson()));
    notifyListeners();
  }

  void addRule(PermissionRule rule) {
    final next = List.of(rules.rules);
    if (next.any((r) => r.pattern == rule.pattern)) return;
    next.add(rule);
    _saveRules(next);
  }

  void removeRule(String pattern) {
    _saveRules(rules.rules.where((r) => r.pattern != pattern).toList());
  }

  void setRuleEnabled(String pattern, bool enabled) {
    _saveRules(rules.rules
        .map((r) => r.pattern == pattern ? r.copyWith(enabled: enabled) : r)
        .toList());
  }

  /// 把默认规则整组开关（设置页里的「默认规则组」开关）。
  void setBuiltinGroupEnabled(bool enabled) {
    _saveRules(rules.rules
        .map((r) => r.builtin ? r.copyWith(enabled: enabled) : r)
        .toList());
  }

  // ---- 自定义指令 ----

  /// 见 [_kInstructionsKey] 上的说明。
  String? get instructions {
    final s = _prefs.getString(_kInstructionsKey);
    if (s == null || s.trim().isEmpty) return null;
    return s;
  }

  /// 空白一律当成「清空」——盘上留一个空字符串会让 [instructions] 的
  /// null 判断变成两处（null 和 ''），迟早有一处漏掉。
  set instructions(String? text) {
    if (text == null || text.trim().isEmpty) {
      _prefs.remove(_kInstructionsKey);
    } else {
      _prefs.setString(_kInstructionsKey, text.trim());
    }
    notifyListeners();
  }

  /// 收尾时是否自动提议沉淀知识。
  ///
  /// **默认开**：一次提炼约 2000 token（输入几百 + skill 索引 900 + 输出
  /// 几百），相对一次值得沉淀的完整排查（几万 token）是零头，而门控会挡掉
  /// 大多数会话。
  bool get knowledgeCaptureEnabled =>
      _prefs.getBool(_kKnowledgeCaptureKey) ?? true;

  set knowledgeCaptureEnabled(bool v) {
    _prefs.setBool(_kKnowledgeCaptureKey, v);
    notifyListeners();
  }

  // ---- 存档 ----

  /// 一段会话的标题：首条用户提问，退回首条助手文本，都没有就 null。
  ///
  /// 从「长按报错行 → AI 分析」进来的会话没有 `UserTurnEvent`，那时首条是助手
  /// 文本 —— 不退回的话这类会话在列表里全是无标题，而它们恰恰是最需要能认出来的
  /// （用户当时在查一个具体报错）。
  static String? _titleOf(AgentLoop loop) {
    for (final e in loop.events) {
      if (e is UserTurnEvent && e.text.trim().isNotEmpty) {
        return _clip(e.text);
      }
    }
    for (final e in loop.events) {
      if (e is AssistantTextEvent && e.text.trim().isNotEmpty) {
        return _clip(e.text);
      }
    }
    return null;
  }

  static String _clip(String s) {
    final one = s.trim().replaceAll('\n', ' ');
    return one.length <= 60 ? one : '${one.substring(0, 60)}…';
  }

  /// 当前活跃段在表里的行 id，按 serverId。
  ///
  /// 有它就 UPDATE 那一行，没有就 INSERT 一行并记下来。这是「一段会话只占
  /// 一行」的全部机制 —— 落盘可以发生任意多次而不吃
  /// [kSessionsPerServer] 配额。
  ///
  /// 内存态，app 重启后为空：那时靠 [takeMostRecent] 把最近那一行认领回来。
  final Map<String, int> _activeRowId = {};

  /// 运行期节流落盘的窗口。
  ///
  /// 3 秒：太短会让长时间连续输出的流式段几乎等同于「每次 notify 都写」，
  /// 失去节流的意义；太长则进程被杀时可能丢掉好几秒（甚至更久，若期间
  /// 一直在流）的最新进展。3 秒是两者之间一个不精确但够用的折中。
  static const Duration _kPersistThrottle = Duration(seconds: 3);

  /// 按 serverId 记录当前挂起的节流定时器。
  final Map<String, Timer> _persistTimers = {};

  /// 诊断/测试用：`_persistActive` 被调用了多少次（不论是否真的写了库）。
  ///
  /// 计数点放在 `_persistActive` 最开头，而不是只在真正 UPDATE/INSERT 时才
  /// 加 —— 测试需要能区分「落盘被调用但提前 skip」和「压根没被调用」，
  /// 这两种在节流逻辑写错时都可能发生（前者是 skip 分支误判，后者是
  /// 定时器根本没建上）。
  @visibleForTesting
  int debugPersistCount = 0;

  /// 运行期的尾沿节流：到点落盘一次，**不是**防抖。
  ///
  /// 关键在于「已有定时器就不再重新排」——如果改成每次调用都重新计时
  /// （防抖），流式输出期间 notify 几乎不会停顿超过节流窗口，定时器会被
  /// 一次次推迟，真正到「进程被杀」的那一刻，反而什么都没落盘，这正是
  /// 尾沿节流要防的场景：持续活动期间也必须按固定节奏落一次盘。
  void _schedulePersist(String serverId) {
    if (_persistTimers.containsKey(serverId)) return;
    _persistTimers[serverId] = Timer(_kPersistThrottle, () {
      _persistTimers.remove(serverId);
      unawaited(_enqueuePersist(serverId));
    });
  }

  /// 每台服务器一条落盘队列。见 [_persistActive]。
  final Map<String, Future<void>> _persistChains = {};

  /// 把 [serverId] 的落盘排到它自己那条队列的末尾，并返回「到它为止」。
  ///
  /// ## 这个队列防的是什么
  ///
  /// `_persistActive` 内部是「读 `_activeRowId` → 没有就 INSERT」两步，而
  /// INSERT 是一次 await。两次落盘重叠时（第一次还卡在 INSERT 的 await 里，
  /// `_activeRowId` 仍是空），第二次进来看到 `existing == null`，于是也
  /// INSERT —— 同一段会话在表里变成好几行，各带部分内容，历史列表里出现
  /// 肉眼可见的重复条目。
  ///
  /// 而重叠在真实使用中就会发生：调用方是从**同步**回调里
  /// `unawaited(_persistActive)` 起的（见 `_onLoopChanged` 与
  /// [_schedulePersist]），用户连发几句话就让它们摞在一起。
  ///
  /// ## 为什么不靠「先占位再 await」
  ///
  /// 那条路得先往 `_activeRowId` 里塞一个假 id（真 id 要 await 才知道），
  /// 而第二个调用会把那个假 id 当成「已存在的行」去 UPDATE —— 写一个不
  /// 存在的 id，静默丢内容。串行化是明确的：第二个进来时第一个已经完成，
  /// `_activeRowId` 已经有真值。
  ///
  /// ## 失败不阻断后来的
  ///
  /// `_persistActive` 自己咽掉所有异常（见它的 try/catch），所以链上不会
  /// 积累失败。这里再包一层 catch 是为了防「将来有人把异常抛出来」把整条
  /// 链弄死 —— 那时后续落盘会永久不再执行，而症状是「历史又莫名其妙不更新
  /// 了」，与本类当初要解决的那个问题一模一样。
  /// [after] 在这台服务器的落盘**之后**、且在队列上**原子地**执行。
  ///
  /// 给 [archiveCurrent] 用：它的「松开 `_activeRowId`」必须紧跟在落盘
  /// 之后、且不能被另一个已排队的落盘插到中间（那个落盘会 UPDATE 刚被封存
  /// 的那一行，把新会话的内容写进旧段）。传 null = 没有额外动作。
  Future<void> _enqueuePersist(String serverId, {void Function()? after}) {
    final prev = _persistChains[serverId] ?? Future<void>.value();
    final next = prev
        .then((_) => _persistActive(serverId))
        .then((_) => after?.call())
        .catchError((Object e) {
      lastPersistNote = 'CHAIN-ERR:$e';
      dlog('agent', 'persist chain for $serverId failed: $e');
    });
    _persistChains[serverId] = next;
    // 链尾跑完就清掉，否则这个 map 会随服务器数只涨不落（几百字节的事，
    // 但库里的会话会一直被清，长期跑着的 app 不该有只涨不落的结构）。
    //
    // 比较 identity：只有「自己仍是链尾」时才清 —— 若期间又排了一次，
    // 新的那个才是链尾，不能把它的引用抹掉。
    unawaited(next.whenComplete(() {
      if (identical(_persistChains[serverId], next)) {
        _persistChains.remove(serverId);
      }
    }));
    return next;
  }

  /// 调试面板用：最后一次落盘 / 恢复各自实际发生了什么。
  ///
  /// 这两条纯粹是诊断。落盘和恢复的每一个失败分支本来都是**静默**的
  /// （`repo == null` 直接 return、写库异常被 catch 咽掉、表里没有行返回
  /// null）—— 静默是对的，一次写失败不该打断用户的排查，但它也意味着
  /// 「历史没恢复」在真机上无从下手：日志要 adb，而用户手上只有手机。
  ///
  /// 不触发 `notifyListeners` —— 调试面板有自己的 500ms ticker，为诊断字段
  /// 唤醒整个 UI 树是本末倒置。
  String? lastPersistNote;
  String? lastRestoreNote;

  /// 把当前活跃段落盘。**幂等**：同一段反复调只会覆盖同一行。
  ///
  /// 空会话不写：随手打开面板又关掉不该在列表里留碎片。
  ///
  /// 写入失败不抛，只打日志。它挂在 loop 的终态回调上，一次写失败不该让
  /// 排查中断；下一轮终态还会再试。
  Future<void> _persistActive(String serverId) async {
    // 放在最前面，早于任何 skip 分支——测试需要知道「落盘被触发过」，
    // 与「触发了但被 skip 掉」是两回事。
    debugPersistCount++;
    final repo = _sessions;
    if (repo == null) {
      lastPersistNote = 'skip:norepo';
      return;
    }
    final loop = _loops[serverId];
    if (loop == null) {
      lastPersistNote = 'skip:noloop';
      return;
    }
    if (loop.events.isEmpty) {
      lastPersistNote = 'skip:empty';
      return;
    }
    final now = DateTime.now();
    final archive = jsonEncode(loop.toArchive());
    final title = _titleOf(loop);
    final count = loop.events.length;
    try {
      final existing = _activeRowId[serverId];
      if (existing != null) {
        await repo.updateContent(
          existing,
          title: title,
          archive: archive,
          eventCount: count,
          updatedAt: now,
        );
        lastPersistNote = 'upd row=$existing n=$count';
        return;
      }
      _activeRowId[serverId] = await repo.insert(AgentSession(
        serverId: serverId,
        title: title,
        archive: archive,
        eventCount: count,
        // 新起的一段本来就没标星。打开历史段那条路径由 [takeById] 把行 id
        // 认领进 `_activeRowId`，走的是上面的 UPDATE 分支 —— 而 UPDATE 不
        // 碰 starred，所以那一段的标星自然保留。
        starred: false,
        createdAt: now,
        updatedAt: now,
      ));
      lastPersistNote = 'ins row=${_activeRowId[serverId]} n=$count';
      // 只在真的新增了一行时才修剪。UPDATE 不增加行数，没必要每轮都跑一次
      // DELETE。
      //
      // 额度按 serverId 取：全局 AI tab 比普通服务器宽（见
      // `sessionQuotaFor`）。
      await repo.pruneNonStarred(serverId, keep: sessionQuotaFor(serverId));
    } catch (e) {
      lastPersistNote = 'ERR:$e';
      dlog('agent', 'persist active session failed: $e');
    }
  }

  /// 封存当前活跃段，让下一段落到新的一行。
  ///
  /// 「新建会话」和「打开另一段」这两个动作调它 —— 它们是**会话边界**，
  /// 而落盘时机不是：落盘由 [_persistActive] 在每次终态持续做。
  /// 这两件事此前被混为一谈，结果当前段全程不入表，杀掉 app 就是
  /// 一次静默丢失 —— 设计上明确不接受这种行为。
  Future<void> archiveCurrent(String serverId) async {
    // **落盘与「松开这一行」必须在同一条队列上原子完成。**
    //
    // 分开写（`await _enqueuePersist` 再 `remove`）有个真实的坏窗口：若期间
    // 又排了一次落盘，它会在我们 `await` 返回后的那个 microtask 之前就轮
    // 到执行 —— 而那时 `_activeRowId` 还没被 remove，于是它 UPDATE 了刚被封
    // 存的那一行，把新会话的内容写进旧段。这正是「分段」想避免的事。
    //
    // 排进队列、让 remove 成为队列里的一个动作，就没有这个窗口。
    await _enqueuePersist(serverId, after: () {
      // 松开这一行：下次落盘会 INSERT 新的。
      _activeRowId.remove(serverId);
    });
  }

  /// app 重启后恢复最近那一段，并把它认领为当前活跃段。
  ///
  /// **不再从表里删除。** 删除曾是刻意的（避免一段会话同时存在于表和内存
  /// 两处、列表显示旧那份），但它让反复「杀 app 重启」变成累积丢失：每次
  /// 重启取走一段，再被杀就彻底没了。
  ///
  /// 改成持续 UPDATE 之后那个顾虑自然消解 —— 表里那一行一直是最新的。
  Future<Map<String, dynamic>?> takeMostRecent(String serverId) async {
    final repo = _sessions;
    if (repo == null) {
      lastRestoreNote = 'skip:norepo';
      return null;
    }
    final row = await repo.mostRecent(serverId);
    if (row == null) {
      lastRestoreNote = 'none sid=${_tailOf(serverId)}';
      return null;
    }
    _activeRowId[serverId] = row.id!;
    try {
      final m = (jsonDecode(row.archive) as Map).cast<String, dynamic>();
      final n = (m['events'] as List?)?.length ?? 0;
      lastRestoreNote = 'row=${row.id} n=$n';
      return m;
    } catch (e) {
      lastRestoreNote = 'BADJSON row=${row.id}';
      return null;
    }
  }

  /// serverId 的尾 6 位。诊断里要能一眼看出「读的是哪台」——完整的 id 太长，
  /// 挤掉调试面板一整行。
  static String _tailOf(String id) =>
      id.length <= 6 ? id : id.substring(id.length - 6);

  /// 打开列表里指定的那一段，同样认领为当前活跃段（不删除）。
  Future<Map<String, dynamic>?> takeById(int id) async {
    final repo = _sessions;
    if (repo == null) return null;
    final row = await repo.byId(id);
    if (row == null) return null;
    _activeRowId[row.serverId] = id;
    try {
      return (jsonDecode(row.archive) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// 某台服务器当前活跃段所在的行 id；没有活跃段、或这一段还没落过盘时为
  /// null。
  ///
  /// 给「导出」用：活跃段那一行按 `updated_at DESC` 排在历史列表**第一条**，
  /// 而 [archiveById] 读到的是节流落盘的版本（见 [_kPersistThrottle]），随时
  /// 可能落后内存好几轮。调用方拿它判断「这一行是不是当前正在跑的那段」，
  /// 是就改从内存里的 `loop.events` 取，否则导出的是一份缺尾巴的记录 ——
  /// 而且缺得**没有任何提示**。
  int? activeRowIdFor(String serverId) => _activeRowId[serverId];

  /// 只读地取某一段的归档，**不**认领为活跃段。
  ///
  /// 导出历史列表里的某一段要用这个，而不是 [takeById]：后者会把
  /// `_activeRowId[serverId]` 改成这一行，之后当前正在跑的那段一旦触发落盘
  /// （节流定时器、终态回调……都不受导出这个动作控制），就会把新内容写到
  /// 被导出的这一行上，而不是当前活跃那一段本该落的行——是一次悄悄的数据
  /// 错位，且不会立刻暴露。导出只是想读一眼内容，不该有这个副作用。
  Future<Map<String, dynamic>?> archiveById(int id) async {
    final repo = _sessions;
    if (repo == null) return null;
    final row = await repo.byId(id);
    if (row == null) return null;
    try {
      return (jsonDecode(row.archive) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// 下一次为某台服务器构造 loop 时要用的归档，取走即清空。
  ///
  /// 需要这个中转，是因为 loop 由 `TerminalScreen._agentLoopFor` 构造，而「打开
  /// 哪一段」的决定发生在 AI 面板里 —— 两者之间需要一个交接处，而这个 manager
  /// 已经是它们共同的依赖。
  final Map<String, Map<String, dynamic>> _pendingRestore = {};

  void seedRestore(String serverId, Map<String, dynamic> archive) {
    _pendingRestore[serverId] = archive;
    notifyListeners();
  }

  Map<String, dynamic>? takePendingRestore(String serverId) =>
      _pendingRestore.remove(serverId);

  Future<List<AgentSession>> sessionsFor(String serverId) async =>
      await _sessions?.listForServer(serverId) ?? const <AgentSession>[];

  Future<void> setStarred(int id, bool starred) async {
    await _sessions?.setStarred(id, starred);
    notifyListeners();
  }

  Future<void> deleteSession(int id) async {
    await _sessions?.delete(id);
    notifyListeners();
  }

  /// 把旧的 `agent_archive_<serverId>` 搬进表，然后删 key。
  ///
  /// **必须在运行时做**：v31 的 SQL migration 只能建表，旧数据在
  /// SharedPreferences 里，SQLite 读不到。不迁移就是升级即失去当前会话 —— 而那
  /// 正是这个功能要解决的问题本身。
  ///
  /// 幂等靠删 key 保证：key 没了就不会再搬。
  Future<void> migrateLegacyArchives(List<String> serverIds) async {
    final repo = _sessions;
    // 没有 repo 时**不动旧 key** —— 删了就再也搬不回来了。这只会发生在没传
    // repository 的测试场景里，生产代码永远有。
    if (repo == null) return;
    for (final id in serverIds) {
      final key = _archiveKey(id);
      final raw = _prefs.getString(key);
      if (raw == null) continue;
      try {
        final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
        final events = decoded['events'];
        final count = events is List ? events.length : 0;
        if (count > 0) {
          final now = DateTime.now();
          await repo.insert(AgentSession(
            serverId: id,
            title: _titleFromArchive(decoded),
            archive: raw,
            eventCount: count,
            createdAt: now,
            updatedAt: now,
          ));
        }
      } catch (e) {
        // 坏 JSON：删掉就好，没有可挽救的东西。
        dlog('agent', 'legacy archive for $id is corrupt: $e');
      }
      await _prefs.remove(key);
    }
  }

  /// 从归档 JSON 里直接取标题（迁移时没有活的 loop 可用）。
  static String? _titleFromArchive(Map<String, dynamic> archive) {
    final events = archive['events'];
    if (events is! List) return null;
    for (final e in events) {
      if (e is Map && e['t'] == 'user') {
        final t = e['text'];
        if (t is String && t.trim().isNotEmpty) return _clip(t);
      }
    }
    for (final e in events) {
      if (e is Map && e['t'] == 'assistant') {
        final t = e['text'];
        if (t is String && t.trim().isNotEmpty) return _clip(t);
      }
    }
    return null;
  }

  // ---- permission mode ----

  /// 这台服务器**实际生效**的权限模式：有覆盖用覆盖，否则用全局默认。
  ///
  /// 判定层（`checkCommand` / `checkFileWrite`）和 `modeProvider` 都只认这个
  /// 方法，签名与两级化之前完全一致 —— 那是刻意的：**如果判定层需要为了
  /// 两级而改，说明这个抽象漏到了不该漏的地方**。
  PermissionMode modeFor(String serverId) =>
      modeOverrideFor(serverId) ?? defaultMode;

  /// 这台服务器的**覆盖**值。null = 跟随全局。
  ///
  /// 键沿用 `agent_mode_<id>`，语义从「这台的模式」变成「这台的覆盖」。
  /// 复用而不是新建 override 键，是为了让迁移零成本：已经显式设过档的
  /// 服务器自动成为覆盖，没设过的自动成为跟随。
  ///
  /// 存了坏值时返回 null（视为无覆盖）而不是抛或兜到某个具体档 —— 一个
  /// 存坏的偏好不该让这台服务器悄悄换一种权限行为。
  PermissionMode? modeOverrideFor(String serverId) {
    final raw = _prefs.getString(_modeKey(serverId));
    if (raw == null) return null;
    return _parseMode(raw);
  }

  /// 解析档位字符串，**兼容旧值**。
  ///
  /// `plan` 是 v2.3 时代的档名，2026-10-13 的重设计把它降格为 `ask` 档内的
  /// 呈现（见 `PermissionMode` 的 dartdoc）。两者在命令判定上完全一致，所以
  /// 映射到 `ask` 不改变任何行为。
  ///
  /// ## 为什么在这里映射，而不写一次性迁移代码
  ///
  /// 迁移代码只在升级后跑一次，而惰性映射在任何时候都对。更要紧的是：老的
  /// `plan` 字符串在新枚举里不存在，若不映射就会落进"未知值"分支 ——
  /// [modeOverrideFor] 对未知值返回 null（视为**跟随全局**），那是一次**静默的
  /// 覆盖丢失**。惰性映射顺手把这个洞堵上。
  static PermissionMode? _parseMode(String raw) {
    if (raw == 'plan') return PermissionMode.ask;
    for (final m in PermissionMode.values) {
      if (m.name == raw) return m;
    }
    return null;
  }

  /// 设置覆盖。传 null **清除**覆盖（改回跟随全局）。
  ///
  /// 清除而不是「写入当前全局值」：后者会让以后改全局默认时这台服务器不
  /// 跟着变，而用户选「跟随全局」表达的正是「以后也跟着」。
  void setModeOverride(String serverId, PermissionMode? mode) {
    if (mode == null) {
      _prefs.remove(_modeKey(serverId));
    } else {
      _prefs.setString(_modeKey(serverId), mode.name);
    }
    notifyListeners();
  }

  /// 全局默认档。新用户与所有「跟随全局」的服务器用它。
  ///
  /// 坏值兜到 `ask`（会问）—— 与 [modeOverrideFor] 的兜底方向一致：一个存坏
  /// 的偏好不该让 agent 悄悄获得更多权限。
  PermissionMode get defaultMode {
    final raw = _prefs.getString(_kModeDefaultKey);
    if (raw != null) {
      final parsed = _parseMode(raw);
      if (parsed != null) return parsed;
    }
    return PermissionMode.ask;
  }

  set defaultMode(PermissionMode mode) {
    _prefs.setString(_kModeDefaultKey, mode.name);
    notifyListeners();
  }

  static const String _kToolTierKey = 'agent_tool_tier';

  // ---- 工具分档 ----

  /// 用户在设置里选的档。null = 自动（按 provider 判定）。
  ///
  /// 全局而非按 serverId：档位跟的是**模型能力**，不是哪台服务器。
  AgentToolTier? get toolTierOverride {
    final raw = _prefs.getString(_kToolTierKey);
    if (raw == null) return null;
    // 坏值按「自动」处理 —— 一个存坏了的偏好不该让 agent 模式打不开。
    for (final t in AgentToolTier.values) {
      if (t.name == raw) return t;
    }
    return null;
  }

  set toolTierOverride(AgentToolTier? tier) {
    if (tier == null) {
      _prefs.remove(_kToolTierKey);
    } else {
      _prefs.setString(_kToolTierKey, tier.name);
    }
    notifyListeners();
  }

  // ---- 首次过目 ----

  bool get hasReviewedRules => _prefs.getBool(_kReviewedKey) ?? false;

  void markRulesReviewed() {
    _prefs.setBool(_kReviewedKey, true);
    notifyListeners();
  }

  // ---- exec channel ----

  /// 按 serverId 复用同一个 [AgentExecChannel]；只在没有的时候才调用
  /// [create]。
  AgentExecChannel channelFor(
    String serverId,
    AgentExecChannel Function() create,
  ) =>
      _channels.putIfAbsent(serverId, create);

  // ---- loop ----

  AgentLoop? loopFor(String serverId) => _loops[serverId];

  void register(String serverId, AgentLoop loop) {
    closeLoop(serverId);
    _loops[serverId] = loop;
    // listener 必须存下来 —— `removeListener` 按引用相等匹配，传闭包时不存
    // 引用就永远摘不掉，loop 会在 dispose 后继续回调。
    void listener() => _onLoopChanged(serverId);
    _listeners[serverId] = listener;
    loop.addListener(listener);
    notifyListeners();
  }

  void closeLoop(String serverId) {
    final loop = _loops.remove(serverId);
    final listener = _listeners.remove(serverId);
    if (loop != null && listener != null) loop.removeListener(listener);
    loop?.dispose();
    // 会话关掉了，挂起的节流定时器不该在之后凭空触发一次落盘——那时
    // _loops[serverId] 已经没有这个 loop 了，_persistActive 会走
    // skip:noloop，白白多一次数据库往返（更糟的是万一同一 serverId 之后
    // 注册了新 loop，会错误地把新 loop 的内容落到旧的那次触发上）。
    _persistTimers.remove(serverId)?.cancel();
    notifyListeners();
  }

  void _onLoopChanged(String serverId) {
    final loop = _loops[serverId];
    // 终态立即落盘，运行态走节流（3 秒）。
    //
    // **这里曾经只在终态落盘**，理由是「流式 token、工具执行、审批都会触发
    // 这个回调，跟着写库等于把 SQLite 当高频写入点用」。那个理由本身没错，
    // 但它的结论错了：代价不是「多写几次库」，而是**进程被杀时正在跑的那一
    // 整段（十几个工具调用、几分钟排查）一个字都没存过**——不是恢复不了，是
    // 根本没存。2026-08-30 据此改成两档，用节流而不是不写来控制频率。
    //
    // 更早之前这里什么都不做，理由是「否则 20 段的配额几轮空转就用光了」——
    // （那个数字现在是 50 / 全局 100，见 `sessionQuotaFor`；当时那条理由本身
    // 就站不住，与配额大小无关。）
    // 那个理由只在「每次落盘都 INSERT 新行」时成立。`_persistActive` 走
    // UPDATE，一段会话永远只占一行，配额问题不存在。
    //
    // 不 await：这是个 ChangeNotifier 回调，签名是同步的。写失败已经在
    // `_persistActive` 内部咽掉并打日志了。
    _loopChangeCount++;
    lastLoopNote = loop == null
        ? 'chg=$_loopChangeCount NOLOOP sid=${_tailOf(serverId)}'
        : 'chg=$_loopChangeCount st=${loop.state.name} '
            'sr=${loop.stopReason?.name ?? 'null'}';
    if (loop != null && !loop.isRunning && loop.stopReason != null) {
      // 终态马上就要立即落盘一次——之前运行期挂起的节流定时器（如果有）
      // 这时已经没用了，反而会在几秒后对着一段早已经落盘过的终态再多写
      // 一次冗余的、内容更旧的 UPDATE。顺手取消掉，且这也堵上了它在测试
      // 里跨用例泄漏、之后对着别的用例的 db 写脏数据的口子（这条节流
      // timer 本来就该在「这段会话有了更权威的落盘结果」时立刻失效）。
      _persistTimers.remove(serverId)?.cancel();
      unawaited(_enqueuePersist(serverId));
    } else if (loop != null && loop.isRunning) {
      // 运行期间也要落盘,只是节流——否则进程在一段很长的排查中途被杀,
      // 整段过程（可能是几十次工具调用、好几分钟）只因为还没跑到终态就
      // 完全没有痕迹。见 [_schedulePersist] 为什么是尾沿节流而非防抖。
      _schedulePersist(serverId);
    }
    _checkPendingApprovals();
    notifyListeners();
  }

  /// 诊断：这个回调被触发了多少次、最后一次看到 loop 处于什么状态。
  ///
  /// `apsv:never` 单独看是歧义的 —— 它既可能是「这个回调压根没被调用」
  /// （listener 没挂上、或者面板里的 loop 不是 `_loops` 里那一个），也可能
  /// 是「调用了但条件不满足」（卡在 awaitingApproval，或走了某条不设
  /// stopReason 的终止路径）。这两种的修法完全不同，必须先分开。
  int _loopChangeCount = 0;
  String? lastLoopNote;

  /// 遍历全部 loop（而不只是变化的那个）—— 成本可忽略（loop 数等于服务器
  /// 数），换来的是不用担心漏掉哪条触发路径。新出现的 `pendingApprovals`
  /// 通过 [onApprovalPending] 交给 main.dart 接的通知层；同一 (serverId,
  /// callId, seq) 只会经 [_notified] 触发一次 —— seq 不能省，见
  /// [approvalDedupKey]。
  ///
  /// 每次都对 [_notified] 做一次对账（见 [reconcileNotified]）：只保留
  /// **此刻仍在等审批**的 key。不这样做的话，这个集合会随着一段长期会话
  /// 只涨不落，而且被应答掉的卡会永久压住同 key 的下一次审批。
  void _checkPendingApprovals() {
    // 先收齐「此刻仍在等审批」的全部事件，再对 [_notified] 对账 —— 对账必须
    // 在看到完整集合之后做，不能边遍历边删（那会让顺序影响结果）。
    final pending = <(String, ToolCallEvent)>[];
    final stillPending = <String>{};
    for (final entry in _loops.entries) {
      for (final ev in entry.value.pendingApprovals) {
        pending.add((entry.key, ev));
        stillPending.add(approvalDedupKey(entry.key, ev.callId, ev.seq));
      }
    }

    final kept = reconcileNotified(
      notified: _notified,
      stillPending: stillPending,
    );
    _notified
      ..clear()
      ..addAll(kept);

    for (final (serverId, ev) in pending) {
      if (_notified.add(approvalDedupKey(serverId, ev.callId, ev.seq))) {
        onApprovalPending?.call(serverId, ev);
      }
    }
  }

  /// 去重集合当前大小 —— 仅供回归测试断言「应答后的 key 真的被对账清掉了」。
  /// 生产代码不应该拿它做任何决策。
  @visibleForTesting
  int get notifiedApprovalCountForTesting => _notified.length;

  /// 所有服务器上仍在等审批的调用 —— 通知层用它决定推不推。
  Map<String, List<ToolCallEvent>> get allPendingApprovals => {
        for (final e in _loops.entries)
          if (e.value.pendingApprovals.isNotEmpty)
            e.key: e.value.pendingApprovals,
      };

  // ---- 待投递 prompt ----

  /// 待投递的 prompt，按 serverId。
  ///
  /// 看板是独立路由（`/jobs`，可从设置页进），`pop` 回不到终端，所以「让模型
  /// 接手」不能靠 Navigator 传参 —— 经这个槽转交给 `terminal_screen`。
  ///
  /// **不持久化。** 它的寿命是「从点按钮到面板打开」这几百毫秒；写进
  /// SharedPreferences 会让一次崩溃在下次启动时凭空发出一句话。
  final Map<String, String> _stagedPrompts = {};

  void stagePrompt(String serverId, String prompt) {
    _stagedPrompts[serverId] = prompt;
  }

  /// 取走并清空。**取一次就没了** —— 重复消费会让同一句话发两遍。
  String? takeStagedPrompt(String serverId) => _stagedPrompts.remove(serverId);

  /// 槽里有没有东西——**不消费**。
  ///
  /// `terminal_screen` 的 `didPopNext`（回到终端页时判断要不要自动打开 AI
  /// 面板）需要在「决定要不要打开」和「真正打开、消费掉这句话」之间隔一步：
  /// 真正的消费仍然只在 `_openAIPanel` 内部发生一次。如果这里也 take，
  /// `_openAIPanel` 再 take 就会拿到 null——两处都 take 等于取两次。
  bool hasStagedPrompt(String serverId) => _stagedPrompts.containsKey(serverId);

  @override
  void dispose() {
    for (final serverId in _loops.keys.toList()) {
      final listener = _listeners[serverId];
      if (listener != null) _loops[serverId]!.removeListener(listener);
      _loops[serverId]!.dispose();
    }
    _loops.clear();
    _listeners.clear();
    for (final timer in _persistTimers.values) {
      timer.cancel();
    }
    _persistTimers.clear();
    // 落盘队列不清空内容（里面的 Future 已经在跑了，取消不掉），只丢掉
    // 引用 —— dispose 后不应再有新东西进来引用它。正在跑的那一次会自然
    // 结束（`_persistActive` 自己咽异常），完成后它的 `whenComplete` 发现
    // 自己不再是链尾（map 已空）就不做任何事。
    _persistChains.clear();
    for (final c in _channels.values) {
      c.dispose();
    }
    _channels.clear();
    super.dispose();
  }
}
