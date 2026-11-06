// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

/// secure storage 的最小接口，便于测试替身注入（真机上是 Keychain /
/// Keystore，单测里换成内存 map，见 `test/ssh/aqt/aqt_session_state_test.dart`
/// 的 `FakeSecureStore`）。
abstract class AqtSecureStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class FlutterAqtSecureStore implements AqtSecureStore {
  final FlutterSecureStorage _s;
  FlutterAqtSecureStore([FlutterSecureStorage? s])
      : _s = s ?? const FlutterSecureStorage();

  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// 一个 tab 的 QUIC 会话状态——**逻辑上是一份，物理上跨两个存储**。
///
/// 以前这份状态被切成两半、各自演化：`AqtSessionStore`（Keychain 里存
/// port/spki/token/tabId 的 JSON）和 `scrollback_store.dart`（SQLite 里存
/// 屏幕内容与 ring 位置）。后果是同一件事——比如 TTL 判定——在两侧各写一份，
/// 一侧改了另一侧没跟上：服务端 `DEFAULT_SESSION_TTL` 是 7 天
/// （`rust/flyterm-server/src/session.rs`），客户端却曾经写死 110 分钟并在
/// `AqtSessionStore.load()` 里直接删掉 token，锁屏过夜后会话必丢。
///
/// 这个类把「一份状态」重新合成一个逻辑对象，但读写强制走
/// [AqtSessionStateRepository] 这一个入口——`sessionToken` 是 32 字节凭据，
/// **必须**留在 secure storage（不能进明文 SQLite），其余字段进 SQLite。
/// 调用方不再有机会只改一侧、忘了另一侧。
class AqtSessionState {
  final String tabId;
  final int port;
  final List<int> spki;
  final List<int> sessionToken;

  /// QUIC 协议层的数字 tab id（服务端 `AqtSession::allocate_tab_id` 分配，
  /// 从 1 起，见 `rust/flyterm-server/src/session.rs`）。RESUME 请求要靠它在
  /// `Resume.tabs: Vec<u32>` 里点名要恢复哪个 tab——服务端按这个 id 在
  /// `session.tabs` 里查 PTY（`connection.rs` 的 `Opcode::Resume` 分支），
  /// 查不到就返回 `TabGone`，跟真的 tab 已退出一模一样。也就是说这个字段
  /// 存错或存丢，冷启动 RESUME 会静默走进"进程已退出"分支，而不是报错。
  ///
  /// 0 表示还没连过一次（真实 id 从 1 起，0 天然是安全的"未知"哨兵）。
  ///
  /// 没有单独放进 [AqtSessionStateRepository] 的 SQLite 列：本任务开始时
  /// QUIC 协议层的数字 tab id。
  ///
  /// RESUME 帧靠它点名恢复哪个 tab —— 服务端查不到就直接判 TabGone
  /// （见 `connection.rs`）。与 [tabId]（客户端自己的 SessionTab 标识）
  /// 不是一回事，两者都要存。
  ///
  /// 放 SQL 列而不是 secure storage：它是非敏感协议元数据，跟 port/spki
  /// 同类。secure storage 是给凭据的，走 IPC 慢，而且多一个 key 就多一处
  /// 可能不一致 —— token 写成功而它写失败，会得到「有凭据但不知道恢复
  /// 哪个 tab」的状态。
  final int aqtTabId;

  /// **已废弃，恒为 0**。曾经存「已经拿到的 scrollback 最旧行号」，供
  /// `FetchScrollback` 预取从这里继续往上走。
  ///
  /// 那条通道随协议版本 2 删掉了（恢复负载现在自带整段历史），于是这一列
  /// 再没有写入方，也从来没有过读取方。列本身留着 —— 删它要一次 DB 迁移，
  /// 而它是个 `INTEGER NOT NULL DEFAULT 0`，留着零成本。
  final int scrollbackCursor;

  /// 服务端在 `ResumeAck.session_ttl_secs` 里下发的 TTL（单位秒）。
  /// null 表示还没成功连过一次、拿不到下发值，走 [_kFallbackTtl] 兜底。
  ///
  /// 过期判定**必须**用这个字段而不是本地写死的常量——那正是 110 分钟
  /// vs 7 天错配这个 bug 的根源。本地常量只在这里出现一次，作兜底用。
  final int? serverTtlSecs;

  /// 这份状态最后一次被确认「服务端仍认为活着」的时间。服务端的 TTL 是
  /// 从**最后一次 touch**（见 `AqtSession::touch`）算起，不是从会话创建
  /// 算起——所以每次成功 RESUME 之后落盘，都必须把这个字段刷新成
  /// `DateTime.now()`，否则 [isExpired] 会拿一个早已过时的起点去算，即使
  /// 会话刚刚被服务端续期也可能被客户端误判为过期。[copyWith] 因此把
  /// `savedAt` 也开放为可覆盖参数——调用方刷新 `serverTtlSecs` 时应当
  /// 一并刷新它。
  final DateTime savedAt;

  const AqtSessionState({
    required this.tabId,
    required this.port,
    required this.spki,
    required this.sessionToken,
    // 默认 0（"未知"哨兵）——保持对既有调用点（包括测试）的兼容，它们
    // 是在这个字段加入之前写的，不该被迫补一个它们根本不关心的参数。
    this.aqtTabId = 0,
    required this.scrollbackCursor,
    required this.serverTtlSecs,
    required this.savedAt,
  });

  /// 拿不到服务端下发值时的兜底，与 `session.rs` 的 `DEFAULT_SESSION_TTL`
  /// 一致——但权威永远在服务端下发值，这里只是「还没连过一次」时的临时
  /// 假设。
  static const Duration _kFallbackTtl = Duration(days: 7);

  /// 落进这个容差窗口就主动判过期，不拿一个马上会被服务端拒绝的 token
  /// 去试——那样只会多一次注定失败的 RESUME，比直接开新会话更慢。
  static const Duration _kMargin = Duration(hours: 2);

  bool get isExpired {
    final ttl =
        serverTtlSecs != null ? Duration(seconds: serverTtlSecs!) : _kFallbackTtl;
    final usable = ttl > _kMargin ? ttl - _kMargin : ttl;
    return DateTime.now().difference(savedAt) > usable;
  }

  AqtSessionState copyWith({
    int? aqtTabId,
    int? scrollbackCursor,
    int? serverTtlSecs,
    DateTime? savedAt,
  }) =>
      AqtSessionState(
        tabId: tabId,
        port: port,
        spki: spki,
        sessionToken: sessionToken,
        aqtTabId: aqtTabId ?? this.aqtTabId,
        scrollbackCursor: scrollbackCursor ?? this.scrollbackCursor,
        serverTtlSecs: serverTtlSecs ?? this.serverTtlSecs,
        savedAt: savedAt ?? this.savedAt,
      );
}

/// [AqtSessionState] 的唯一读写入口。
///
/// 拆分存储但合并入口：token 写 secure store，其余字段写 `aqt_session_state`
/// 表（见 `lib/data/database.dart` DB v32），两次写在 [save] 里顺序发生、
/// 对调用方呈现为一次操作——不会再出现「改了 DB 忘了改 Keychain」那种
/// 半吊子更新。
///
/// key 前缀故意跟旧的 `AqtSessionStore`（`aqt_session_<tabId>`）不同：
/// 这里从不读旧 key，用不同前缀避免任何误把旧 JSON blob 当新格式 token
/// 解出来的可能——协议已经破坏兼容，旧数据的去留见类文档注释。
class AqtSessionStateRepository {
  final Database _db;
  final AqtSecureStore _secure;
  static const _table = 'aqt_session_state';

  AqtSessionStateRepository(this._db, this._secure);

  static String _tokenKey(String tabId) => 'aqt_token_$tabId';


  Future<void> save(AqtSessionState s) async {
    await _secure.write(_tokenKey(s.tabId), base64.encode(s.sessionToken));
    await _db.insert(
      _table,
      {
        'tab_id': s.tabId,
        'aqt_tab_id': s.aqtTabId,
        'port': s.port,
        // BLOB 列显式转 Uint8List——sqflite 的 BLOB 绑定认这个类型，直接塞
        // List<int> 在部分平台通道上不可靠（本仓库其它 BLOB 列，如
        // aqt_file_transfer_state.sha256_full，也统一走 Uint8List）。
        'spki': Uint8List.fromList(s.spki),
        'scrollback_cursor': s.scrollbackCursor,
        'server_ttl_secs': s.serverTtlSecs,
        'saved_at': s.savedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取某个 tab 的会话状态。以下两种情况都返回 null 并顺手清掉痕迹，
  /// 不留给调用方分辨「没有」和「有但坏了」的负担：
  ///  - DB 有行但 secure store 没 token（卸载重装、用户清了 Keychain）——
  ///    没有凭据的那一行已经没用了，留着只会让下次又查一遍 DB 再发现拿
  ///    不到凭据。
  ///  - 有 token 但按 [AqtSessionState.isExpired] 判定已过期。
  Future<AqtSessionState?> load(String tabId) async {
    final rows = await _db.query(_table, where: 'tab_id = ?', whereArgs: [tabId]);
    if (rows.isEmpty) return null;

    final tokenRaw = await _secure.read(_tokenKey(tabId));
    if (tokenRaw == null) {
      await remove(tabId);
      return null;
    }

    // 解析失败（不该发生，但 secure storage 是外部可清的用户态存储，不能
    // 让一个坏掉的整数字符串把整条 load 炸掉）就退回哨兵值 0——效果等同
    // "还没连过一次"，下一次 RESUME 会用 0 去问，服务端查不到会当作
    // TabGone，比在这里抛异常更安全。

    final r = rows.first;
    final s = AqtSessionState(
      tabId: tabId,
      port: r['port'] as int,
      spki: (r['spki'] as List).cast<int>(),
      sessionToken: base64.decode(tokenRaw),
      aqtTabId: r['aqt_tab_id'] as int? ?? 0,
      scrollbackCursor: r['scrollback_cursor'] as int,
      serverTtlSecs: r['server_ttl_secs'] as int?,
      savedAt: DateTime.fromMillisecondsSinceEpoch(r['saved_at'] as int),
    );

    if (s.isExpired) {
      await remove(tabId);
      return null;
    }
    return s;
  }

  Future<void> remove(String tabId) async {
    await _secure.delete(_tokenKey(tabId));
    await _db.delete(_table, where: 'tab_id = ?', whereArgs: [tabId]);
  }
}
