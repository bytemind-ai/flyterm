// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/server_note.dart';
import '../../data/repositories/server_notes_repository.dart';
import 'agent_instructions.dart' show kMaxInstructionBytes;

/// 一次写入的结果。
///
/// 两种失败必须分开，不能都折成「ok = false」：
///
/// - [ServerNoteSaveResult.rejected] 超限 —— [overflowBytes] 说明超了多少。
///   UI 和模型都要看到这个数字，否则只知道「存不进去」而不知道该精简多少
/// - [ServerNoteSaveResult.failed] 别的原因（最典型的是全局会话里没指定是
///   哪台机器，或者存量笔记本身已经超限）—— [error] 是给用户/模型看的原话。
///   **UI 侧提醒**：沉淀卡片将来要把 `error` 非 null 时直接渲染出来，所以
///   这个字符串必须是能原样展示给人看的完整句子，不是内部诊断信息。
///
/// 曾经打算只用 `rejected(0)` 表示后者，但「超了 0 字节」和「没指定机器」
/// 是两件完全不同的事，共用一个形状会让调用方给出驴唇不对马嘴的提示。
class ServerNoteSaveResult {
  final bool ok;
  final int overflowBytes;
  final String? error;

  const ServerNoteSaveResult.accepted()
      : ok = true,
        overflowBytes = 0,
        error = null;

  const ServerNoteSaveResult.rejected(this.overflowBytes)
      : ok = false,
        error = null;

  const ServerNoteSaveResult.failed(String this.error)
      : ok = false,
        overflowBytes = 0;
}

/// 机器笔记库。**全量在内存，库里是副本。**
///
/// ## 为什么必须有内存缓存
///
/// 与 `AgentSkillManager` 同一个理由，且更硬：`terminal_screen.dart` 的
/// `systemPromptProvider` 是个**同步**闭包，而机器笔记每一轮都要拼进那份
/// prompt，所以 [noteFor] 必须是同步 getter。这不是性能优化。
///
/// 与技能库不同的是这里**不需要把索引和正文劈开**：一台机器一份、上限
/// 4 KiB，全量放内存的成本可以忽略。
///
/// ## 为什么字节上限收口在这一层
///
/// 三条写入路径 —— 沉淀卡片、`save_note` 工具、设置里手工编辑 —— 全部
/// 经过 [appendNote] / [replaceNote]。笔记每轮随 system prompt 重发，漏掉
/// 任何一条就等于上限形同虚设。
///
/// 把检查放进 `ServerNotesRepository` 也能收口，但那会让 repo 从「纯 SQL」
/// 变成「带策略」，而迁移路径需要一个不查上限的写入口（见 [_adoptRaw]）。
/// 分层在这里是有用的。
class ServerNotesManager extends ChangeNotifier {
  final ServerNotesRepository _repo;

  /// serverId → 笔记。[noteFor] 的同步性全靠它。
  Map<String, ServerNote> _notes = const {};

  ServerNotesManager(this._repo);

  /// 全部笔记，按 `updatedAt` 倒序。总览列表用它。
  List<ServerNote> get notes {
    final list = _notes.values.toList()
      // tie-break 必须和 ServerNotesRepository.all() 的 ORDER BY 一致。
      // Dart 的 List.sort 在元素数 > 32 时不稳定，而同时间戳是常态 ——
      // 迁移对缺时间戳的条目一律用 DateTime.now()，同一批会全落在同一毫秒。
      ..sort((a, b) {
        final c = b.updatedAt.compareTo(a.updatedAt);
        return c != 0 ? c : a.serverId.compareTo(b.serverId);
      });
    return list;
  }

  /// 某台机器的笔记。**同步**，见类文档。null = 没有。
  String? noteFor(String serverId) => _notes[serverId]?.body;

  /// 从库里重读全量。构造之后必须调一次。
  Future<void> load() async {
    final rows = await _repo.all();
    _notes = {for (final n in rows) n.serverId: n};
    notifyListeners();
  }

  /// 整份替换。设置页的手工编辑走这条。
  ///
  /// 空白一律当成「删除」—— 库里留一个空串会让 [noteFor] 的 null 判断变成
  /// 两处（null 和 ''），迟早有一处漏掉。
  Future<ServerNoteSaveResult> replaceNote({
    required String serverId,
    required String body,
  }) async {
    final t = body.trim();
    if (t.isEmpty) {
      await delete(serverId);
      return const ServerNoteSaveResult.accepted();
    }
    final over = _overflowOf(t);
    if (over > 0) return ServerNoteSaveResult.rejected(over);

    await _repo.upsert(serverId: serverId, body: t);
    await load();
    return const ServerNoteSaveResult.accepted();
  }

  /// 在现有内容后面追加一小节。沉淀卡片与 `save_note` 工具都走这条。
  ///
  /// **读-改-写，绝不覆盖。** 让调用方整份替换等于给它一把能抹掉用户手写
  /// 内容的枪 —— 模型尤其危险，它看不到完整原文。
  Future<ServerNoteSaveResult> appendNote({
    required String serverId,
    required String heading,
    required String body,
  }) {
    if (body.trim().isEmpty) {
      // 空正文伪装成功没有意义：既不该写出一个光杆标题，也不该让调用方
      // 以为自己真的追加了什么。
      return Future.value(
          const ServerNoteSaveResult.failed('Nothing to append.'));
    }

    // 存量本身就超限时直接拦掉，不要走下面的拼接。
    //
    // 否则 rejected 报出的 overflowBytes 是「拼接后整份」超出多少，而调用方
    // （尤其是模型）只控制得了自己加的那一段 —— 存量 5000 字节时它删到空也
    // 砍不出 904 字节的缺口，只会反复重试、每轮白烧 token。
    //
    // 这种情形只可能来自迁移：adoptRaw 放行了超限的旧缓存。出路在设置页
    // 手工精简，不在模型手里，所以用 failed 而不是 rejected —— 前者的语义
    // 正是「这事你解决不了，去找用户」。
    final stale = _overflowOf(noteFor(serverId) ?? '');
    if (stale > 0) {
      return Future.value(ServerNoteSaveResult.failed(
          'This machine\'s notes are already $stale bytes over the limit '
          '(most likely carried over from an older version). They have to be '
          'trimmed in Settings before anything can be appended.'));
    }

    final next = composeAppendedNote(
      current: noteFor(serverId),
      heading: heading,
      body: body,
    );
    return replaceNote(serverId: serverId, body: next);
  }

  Future<void> delete(String serverId) async {
    // 没有这一条就不折腾库和监听者 —— 典型调用方是「清空输入框再保存」
    // 这类幂等操作，不该每次都触发一轮无意义的 UI 重建。
    if (!_notes.containsKey(serverId)) return;
    await _repo.delete(serverId);
    await load();
  }

  /// 某份文本超出上限多少字节。0 = 没超。
  int _overflowOf(String s) {
    final bytes = utf8.encode(s).length;
    return bytes > kMaxInstructionBytes ? bytes - kMaxInstructionBytes : 0;
  }

  /// 不查上限的写入口，**只给 [migrateFromPrefs] 内部用**，因此设为私有：
  /// 这个方法同时绕过上限检查、不刷内存缓存、不 notify，三条坏处一起生效，
  /// 而生产调用方只有一个且就在同一个类里。doc 劝不住类外面的人 —— 他们
  /// 多半只看方法名和签名，私有才是真正的收口。
  ///
  /// 旧缓存可能本来就超过 4 KiB（远端那份文件的上限一直只靠模型自觉）。
  /// 拒绝它等于在一次版本升级里静默丢掉老用户的内容；放进来、让他下次
  /// 编辑时看到超限提示，是两害相权的轻者。
  ///
  /// 不 load、不 notify：搬一批才刷新一次内存缓存（见 [migrateFromPrefs]
  /// 收尾的 load()），每搬一条重读一次全量是平方级的浪费。
  Future<void> _adoptRaw({
    required String serverId,
    required String body,
    required DateTime updatedAt,
  }) =>
      _repo.upsert(serverId: serverId, body: body, updatedAt: updatedAt);

  /// 一次性闸门的 key。搬完就落下，之后永不重扫。
  static const String _kMigratedKey = 'server_notes_migrated_v37';

  /// 旧的远端缓存 key 前缀。这两组 key 原本定义在
  /// `agent_session_manager.dart` 里，但它们随本次改造一起删了，所以
  /// 字面量在这里重新写一遍 —— 迁移代码必须能独立于被它取代的那套代码存在。
  static const String _kLegacyBodyPrefix = 'agent_remote_instructions_';
  static const String _kLegacyAtPrefix = 'agent_remote_instructions_at_';

  /// 把 prefs 里那批旧的远端笔记文件缓存副本搬进库。
  ///
  /// **不联网、不算「读服务器」** —— 这些内容早就在手机上了，是之前每次开
  /// 面板后台 `cat` 下来的副本。不搬等于在一次版本升级里让老用户的机器笔记
  /// 凭空消失（服务器那份从此也不再读）。
  ///
  /// 为什么不放在 DB 的 `_onUpgrade` 里：那一层只拿得到 `Database`，
  /// `database.dart` 里没有也不该有 SharedPreferences 依赖。
  ///
  /// 走 [_adoptRaw] 而不是 [replaceNote]：**不查上限**，理由见那个方法。
  ///
  /// 收尾会调一次 [load]：本方法自己把内存缓存刷热，而不是指望调用方记得
  /// 补一句。否则迁移结束的瞬间库里有笔记、内存里没有，紧跟着的第一次
  /// [appendNote] 会从 [noteFor] 读到 null，把整份当新笔记写回去 ——
  /// 覆盖掉刚搬进来的用户老笔记，正好击穿 appendNote「读-改-写绝不覆盖」
  /// 的承诺。闸门已经落下时本方法在第一行就直接 return，不会走到这个
  /// load() —— 调用方（`main.dart`）在那之后仍然需要自己每次冷启动都补
  /// 一次 [load]，那是另一件事：把库里**非迁移产生**的历史数据读进内存。
  Future<void> migrateFromPrefs(SharedPreferences prefs) async {
    if (prefs.getBool(_kMigratedKey) ?? false) return;

    // 先把 key 收集出来再改动 prefs —— 边遍历 getKeys() 边 remove 的行为
    // 不保证安全。
    //
    // 那个 !startsWith(_kLegacyAtPrefix) 过滤不能省：两个前缀是包含关系
    // （body 前缀是 at 前缀的前缀），不排掉的话时间戳 key 会被当成正文
    // key，解析出一个叫 `at_s1` 的假 serverId。
    final bodyKeys = prefs
        .getKeys()
        .where((k) =>
            k.startsWith(_kLegacyBodyPrefix) && !k.startsWith(_kLegacyAtPrefix))
        .toList();

    for (final key in bodyKeys) {
      final serverId = key.substring(_kLegacyBodyPrefix.length);

      try {
        final body = prefs.getString(key)?.trim() ?? '';
        final atMs = prefs.getInt('$_kLegacyAtPrefix$serverId');

        // 裸前缀 key（`agent_remote_instructions_` 后面什么都没有）会解析
        // 出 serverId == ''：落一行永远没有服务器匹配得上、也永远删不掉的
        // 幽灵笔记，所以这里不调 _adoptRaw，只负责把烂 key 清掉（见下面）。
        if (body.isNotEmpty && serverId.isNotEmpty) {
          await _adoptRaw(
            serverId: serverId,
            body: body,
            // 缺时间戳就用当前时间：内容比「最后更新于」准确更重要。
            updatedAt: atMs == null
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(atMs),
          );
        }
      } catch (e) {
        // 一条搬不动不该让整个 app 起不来，也不该让其余条目陪葬 —— 两害
        // 相权，丢一条搬不动的旧笔记，好过每次都崩在启动路径上。
        //
        // 这个 key 照样在下面被清掉，不留着「给下次启动重试」：闸门（见
        // 循环外）跟这次迁移是同一轮落下的，不会再有下一次重试机会——留着
        // 只是在 prefs 里攒一个没人会再看的死 key，不值得为了保留它再写一
        // 段特殊逻辑。
        debugPrint('[ServerNotesManager] 迁移 $serverId 失败，丢弃：$e');
      }

      // 不论迁移成功、失败，还是裸前缀 key，都要清掉 —— 留着一个不会再被
      // 用到的旧 key 没有任何用处，只会让下次有人 grep 到它时以为这套机制
      // 还活着。
      await prefs.remove(key);
      await prefs.remove('$_kLegacyAtPrefix$serverId');
    }

    // 孤儿 at_ key：只有时间戳、从没配对过正文 key（或者正文 key 在更早
    // 的某次失败迁移里已经被清掉，但那种情况正文 key 和 at_ key 会一起留
    // 着重试，不会走到这里）。闸门一落就再也扫不到，这是最后的清理机会。
    final orphanAtKeys = prefs.getKeys().where((k) {
      if (!k.startsWith(_kLegacyAtPrefix)) return false;
      final serverId = k.substring(_kLegacyAtPrefix.length);
      return !prefs.containsKey('$_kLegacyBodyPrefix$serverId');
    }).toList();
    for (final k in orphanAtKeys) {
      await prefs.remove(k);
    }

    await prefs.setBool(_kMigratedKey, true);
    await load();
  }
}

/// 把一小节拼到现有笔记后面。**纯函数**，便于单测与复用。
///
/// 抽出来是因为沉淀卡片那条路径（`knowledge_saver.dart`）要用同一套拼接
/// 规则，而它拿到的是 `KnowledgeCandidate` 不是散字段。两边各写一份的话
/// 迟早分叉。
String composeAppendedNote({
  required String? current,
  required String heading,
  required String body,
}) {
  // 正文是空白就什么都不追加，哪怕标题非空 —— 否则会写出一个只有标题的
  // 光杆小节。笔记每轮随 system prompt 重发，空节纯属浪费字节，模型看到
  // 空标题还可能反过来去猜它本该写什么。原样返回 current：既不新增内容，
  // 也不该把它 trim 掉（trim 是 replaceNote 那一层的事）。
  if (body.trim().isEmpty) return current ?? '';

  final h = heading.trim();
  final section = h.isEmpty ? body.trim() : '## $h\n\n${body.trim()}';
  final existing = (current ?? '').trimRight();
  return existing.isEmpty ? section : '$existing\n\n$section';
}
