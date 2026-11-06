// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/agent_session.dart';

/// 全局 AI tab 用的保留 serverId。
///
/// **定义在这里而不是 `ai_engine.dart`**：会话的**存储配额**按它区分
/// （见 [sessionQuotaFor]），而配额属于 data 层。定义留在 ai 层会让 data 层
/// 不得不反过来 import ai 层 —— 依赖方向逆转，而且 `ai_engine.dart` 拖着
/// shared_preferences / flutter/foundation，对一个纯 DB 层太重。
///
/// `ai_engine.dart` 把它 re-export 出去，所以 `AIEngine.kGlobalServerId`
/// 这个既有写法仍然可用。
const String kGlobalServerId = '__global__';

/// 普通服务器保留的**非标星**段数。标星的不计入这个配额。
///
/// 2026-10-13 从 20 提到 50。
const int kSessionsPerServer = 50;

/// 全局 AI tab 保留的非标星段数，比普通服务器宽。
///
/// 分两档而不是一个常量：全局 tab 是「随手问 + 跨机器排查」的地方，会话密度
/// 远高于单台服务器；而单台服务器的历史多数是一次性排查（当时看过了就不会
/// 再回看），给同样宽的配额只是白占存储。
///
/// 上限的意义不只是存储：列表、搜索都是全量读进内存的（见
/// `SessionHistoryView`），配额就是它们的规模上限。
const int kSessionsGlobal = 100;

/// 某台服务器（含全局 AI）的保留段数。
int sessionQuotaFor(String serverId) =>
    serverId == kGlobalServerId ? kSessionsGlobal : kSessionsPerServer;

class AgentSessionRepository {
  final Database _db;
  static const _table = 'agent_sessions';

  /// 某段会话被删除时，把它引用的附件相对路径报出去。
  ///
  /// **repository 不碰文件系统**：它是纯 DB 层。真正的删除由 `main.dart` 注入
  /// 的 `AttachmentStore.deleteAll` 完成 —— 与 `sftpOpsProvider` /
  /// `relayTempDirProvider` / `downloadDirProvider` 同一种注入风格。
  final Future<void> Function(List<String> relPaths)? onAttachmentsOrphaned;

  AgentSessionRepository(this._db, {this.onAttachmentsOrphaned});

  /// 从一段归档里挖出所有附件相对路径。
  ///
  /// 坏 JSON 返回空列表而不是抛：删会话这个动作不该因为归档格式坏了而失败。
  static List<String> attachmentPathsOf(String archive) {
    try {
      final m = jsonDecode(archive) as Map;
      final out = <String>[];
      void collect(Object? list) {
        if (list is! List) return;
        for (final item in list) {
          if (item is! Map) continue;
          final atts = item['attachments'];
          if (atts is! List) continue;
          for (final a in atts) {
            if (a is Map && a['relPath'] is String) {
              out.add(a['relPath'] as String);
            }
          }
        }
      }

      collect(m['events']);
      collect(m['history']);
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 返回新行的 id。
  Future<int> insert(AgentSession s) => _db.insert(_table, s.toMap());

  /// 覆盖某一行的内容。**不动 `starred` 与 `created_at`。**
  ///
  /// 「当前活跃段」靠这个方法反复落盘：每次 loop 到终态就覆盖它自己那一行，
  /// 于是一段会话永远只占一行 —— 既不吃 [kSessionsPerServer] 配额，也让
  /// 「进程被杀」不再是数据丢失。
  ///
  /// 不动 `starred` 是必须的：用户可能打开了一段标星的历史继续问，这里若把
  /// 它一并写掉，标星就在下一轮悄悄丢了。`created_at` 同理 —— 那是这段会话
  /// **开始**的时间，不该随每次落盘往后跑。
  Future<void> updateContent(
    int id, {
    required String? title,
    required String archive,
    required int eventCount,
    required DateTime updatedAt,
  }) =>
      _db.update(
        _table,
        {
          'title': title,
          'archive': archive,
          'event_count': eventCount,
          'updated_at': updatedAt.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  /// 某台服务器的全部归档，最近的在前。
  Future<List<AgentSession>> listForServer(String serverId) async {
    final rows = await _db.query(
      _table,
      where: 'server_id = ?',
      whereArgs: [serverId],
      orderBy: 'updated_at DESC, id DESC',
    );
    return rows.map(AgentSession.fromMap).toList();
  }

  Future<AgentSession?> byId(int id) async {
    final rows = await _db.query(_table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : AgentSession.fromMap(rows.first);
  }

  /// `updated_at` 最大的那段。app 重启后用它恢复。
  Future<AgentSession?> mostRecent(String serverId) async {
    final rows = await _db.query(
      _table,
      where: 'server_id = ?',
      whereArgs: [serverId],
      orderBy: 'updated_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : AgentSession.fromMap(rows.first);
  }

  Future<void> setStarred(int id, bool starred) => _db.update(
        _table,
        {'starred': starred ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> delete(int id) async {
    final cb = onAttachmentsOrphaned;
    if (cb == null) {
      await _db.delete(_table, where: 'id = ?', whereArgs: [id]);
      return;
    }
    final rows = await _db.query(_table,
        columns: ['archive'], where: 'id = ?', whereArgs: [id]);
    final paths = rows.isEmpty
        ? const <String>[]
        : attachmentPathsOf(rows.first['archive'] as String? ?? '');
    // 先删行后删文件：中途崩溃时留下的是孤儿（清扫能兜），而不是引用悬空。
    await _db.delete(_table, where: 'id = ?', whereArgs: [id]);
    if (paths.isNotEmpty) await cb(paths);
  }

  /// 全部归档里引用到的附件相对路径。孤儿清扫的「被引用集合」。
  ///
  /// 只 SELECT archive 一列 —— 表里每台最多 `sessionQuotaFor` 段（50 / 全局
  /// 100），但 archive 本身可能几百 KB，`SELECT *` 会把事件流全读进内存。
  Future<Set<String>> allAttachmentPaths() async {
    final rows = await _db.query(_table, columns: ['archive']);
    final out = <String>{};
    for (final r in rows) {
      out.addAll(attachmentPathsOf(r['archive'] as String? ?? ''));
    }
    return out;
  }

  /// 删掉该 server 超出配额的**非标星**段，最旧的先删。
  ///
  /// `LIMIT -1 OFFSET n` 是 SQLite 的惯用法：跳过前 n 行、取剩下全部。写成
  /// 子查询是因为 SQLite 的 DELETE 不支持 ORDER BY + LIMIT（除非编译时开了
  /// `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`，Android 自带的那个没开）。
  ///
  /// 标星段既不被删、也不占配额 —— 标星的语义就是「别动它」，让它挤掉普通段
  /// 的额度会导致「标了几个星之后新会话开始神秘消失」。
  Future<void> pruneNonStarred(String serverId,
      {int keep = kSessionsPerServer}) async {
    final cb = onAttachmentsOrphaned;
    List<Map<String, Object?>> victims = const [];
    if (cb != null) {
      // rawDelete 用子查询一次删多行，删完就拿不到被删行的内容了 ——
      // 必须在删之前用同样的条件把 id/archive 先查出来。
      victims = await _db.rawQuery(
        '''
        SELECT id, archive FROM $_table
        WHERE server_id = ? AND starred = 0
        ORDER BY updated_at DESC, id DESC
        LIMIT -1 OFFSET ?
        ''',
        [serverId, keep],
      );
    }
    await _db.rawDelete(
      '''
      DELETE FROM $_table
      WHERE id IN (
        SELECT id FROM $_table
        WHERE server_id = ? AND starred = 0
        ORDER BY updated_at DESC, id DESC
        LIMIT -1 OFFSET ?
      )
      ''',
      [serverId, keep],
    );
    if (cb != null && victims.isNotEmpty) {
      final paths = <String>[
        for (final r in victims)
          ...attachmentPathsOf(r['archive'] as String? ?? ''),
      ];
      if (paths.isNotEmpty) await cb(paths);
    }
  }
}
