// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dartssh2/dartssh2.dart';
import '../../util/dlog.dart';

import '../../data/models/server.dart';
import '../../data/secure_storage.dart';
import '../../ssh/dead_ssh_clients.dart';
import '../../ssh/ssh_connection.dart';

class AgentCredentials {
  final String? password;
  final String? privateKeyPem;

  const AgentCredentials({this.password, this.privateKeyPem});

  bool get isUsable =>
      (password != null && password!.isNotEmpty) ||
      (privateKeyPem != null && privateKeyPem!.isNotEmpty);
}

class AgentCredentialsUnavailable implements Exception {
  @override
  String toString() =>
      'AgentCredentialsUnavailable: 没有已保存的凭据，无法为 agent 建立执行连接';
}

/// 持有一条**专供 agent 工具执行**的 SSH 连接。
///
/// 懒建立：第一次工具调用时才连。大多数会话不会用 agent，不该为它白挂一条
/// 连接；而懒建立可随时重建，避开「QUIC 活着 / SSH 死了」的状态同步问题。
///
/// SSH / Mosh 会话通过 [reuseProvider] 复用已有连接（`SshTransport.sshClient`）。
///
/// QUIC 会话**也可能**复用：`ReconnectService._warmupAuxSshClient` 会给 QUIC
/// tab 后台预热一条 exec-only 的辅助 SSH 并挂在 `tab.connection` 上，而
/// [reuseProvider] 取的正是它。只有在那条辅助连接不存在或已 closed 时，才
/// 用 [SecureStorageService] 里的凭据自己新开一条。
/// （早前这里写的是「QUIC 会话一律新开」，那是 aux 预热引入之前的事实。）
class AgentExecChannel {
  final Server server;
  final SecureStorageService storage;

  /// SSH / Mosh 路径提供已认证的 client；QUIC 路径传 null。
  final SSHClient? Function()? reuseProvider;

  SSHClient? _owned;

  /// 被判定为「开不出 channel」的复用连接，**本 channel 内的快照**。
  ///
  /// 真正跨组件生效的是 [DeadSshClients]（[invalidate] 会同时写两处）——
  /// SFTP 等其它消费者看的是那边，不是这个私有字段。这个字段留着只是为了
  /// 最小改动：[_log] 里还要区分「tab 连接已 closed」和「tab 连接已被(本
  /// channel)拉黑」这两种日志措辞，且改动范围小，便于审查。
  ///
  /// 它的 `isClosed` 仍是 false，所以只能靠实例身份拉黑。等 tab 那边换上
  /// 新的辅助连接（新实例）后，这条拉黑自动失效 —— 不需要额外的解除逻辑。
  SSHClient? _blockedReuse;

  AgentExecChannel({
    required this.server,
    required this.storage,
    this.reuseProvider,
  });

  /// 正在进行中的建连。**同一时刻最多一条。**
  ///
  /// 没有它的话，两次并发 `obtain()` 会各自完整跑一遍 TCP+KEX+auth：
  /// `_owned = client` 只在 `await sshConnectForExec(...)` **返回之后**才
  /// 赋值，所以在那之前到达的第二个调用者看到的 `_owned` 仍是空的。后完成
  /// 的那条覆盖 `_owned`，先完成的那条 SSHClient 再也没人关得掉
  /// （`dispose()` 只关 `_owned`）—— 一条永久泄漏的 SSH 连接。
  ///
  /// 这个竞态本来就存在（并行桶同时发三条打同一台机的命令），但**连接预热**
  /// 让它在单条调用上也必然触发：预热起飞几毫秒后 `StreamDone` 就到了，
  /// `_executeOne` 紧接着 `run()` → `clientProvider()`，此时预热那条握手
  /// 八字还没一撇。净效果会是「比不预热还慢，外加每次泄漏一条连接」——
  /// 正好把预热的收益反过来。
  Future<SSHClient>? _connecting;

  /// 现在就能拿到连接吗？**不建连、无副作用。**
  ///
  /// 复用的是 [obtain] 开头那两道同步判定（复用 tab 连接 / 复用自有连接),
  /// 没有新逻辑。
  ///
  /// **与随后的 [obtain] 之间存在 TOCTOU 窗口** —— 这里判 true，等真去
  /// `obtain()` 时连接可能已经断了。调用方只能拿它做排序/优先级一类的
  /// 软判断（看板用它决定「先扫哪台机器」），**不能当正确性依赖**：判错的
  /// 代价必须只是「那台机器慢一点」。
  bool get hasLiveConnection {
    final reused = reuseProvider?.call();
    if (_canReuse(reused)) return true;
    return _isReusable(_owned);
  }

  /// 取一条可用连接。断了会重建。
  ///
  /// 抛 [AgentCredentialsUnavailable] 时调用方应把 agent 模式标为不可用并
  /// 指向服务器编辑页 —— **不要弹密码框**，loop 中途弹密码框是最差体验。
  Future<SSHClient> obtain() async {
    final reused = reuseProvider?.call();
    if (_canReuse(reused)) {
      _log('obtain → 复用 tab 连接');
      return reused!;
    }
    _log(reused == null
        ? 'obtain: tab 没有可复用连接'
        : (identical(reused, _blockedReuse)
            ? 'obtain: tab 连接已被拉黑（开不出 channel），不复用'
            : 'obtain: tab 连接已 closed，不复用'));

    final owned = _owned;
    if (_isReusable(owned)) {
      _log('obtain → 复用自有连接');
      return owned!;
    }
    if (owned != null) _log('obtain: 自有连接已 closed，重建');

    // 上面三道判定全是同步的，而 `async` 方法体在遇到第一个 `await` 之前
    // 也是同步执行的 —— 所以走到这里时，「检查有没有在飞的建连」与「把
    // 自己登记为在飞的那一条」之间不存在任何让出点，两个并发调用者不可能
    // 都认为自己是第一个。这条同步性是去重成立的全部前提，往上面几行里
    // 插入任何 `await` 都会悄悄破坏它。
    final pending = _connecting;
    if (pending != null) {
      _log('obtain → 汇入正在进行的建连');
      return pending;
    }
    final fut = _connectNew();
    _connecting = fut;
    try {
      return await fut;
    } finally {
      // 只清自己那一条：失败时也要清，否则一次握手失败会让此后每次
      // `obtain()` 都返回同一个已经 reject 的 Future，连接再也建不起来。
      if (identical(_connecting, fut)) _connecting = null;
    }
  }

  Future<SSHClient> _connectNew() async {
    final creds = await loadCredentials();
    if (!creds.isUsable) {
      _log('obtain FAIL: 凭据不可用 '
          '(authType=${server.authType} keyId=${server.keyId} '
          'pw=${creds.password != null} pem=${creds.privateKeyPem != null})');
      throw AgentCredentialsUnavailable();
    }

    final via = creds.privateKeyPem != null ? 'key' : 'password';
    _log('obtain: 建连 ${server.host}:${server.port} '
        'user=${server.username} via=$via');
    final sw = Stopwatch()..start();
    try {
      final client = await sshConnectForExec(
        host: server.host,
        port: server.port,
        username: server.username,
        password: creds.password,
        privateKeyPem: creds.privateKeyPem,
      );
      _owned = client;
      _log('obtain OK (${sw.elapsedMilliseconds}ms)');
      return client;
    } catch (e) {
      // 这里是 agent「一发指令就失败」的唯一连接层出口。命令被规则层
      // 拦下不会走到这儿 —— 两种失败在日志里由此分开。
      _log('obtain FAIL (${sw.elapsedMilliseconds}ms): ${e.runtimeType}: $e');
      rethrow;
    }
  }

  void _log(String msg) {
    final sid = server.id.length > 4 ? server.id.substring(0, 4) : server.id;
    dlog('AgentExec', '[$sid] $msg');
  }

  Future<AgentCredentials> loadCredentials() async {
    final password = await storage.loadPassword(server.id);
    final keyId = server.keyId;
    final pem = keyId == null ? null : await storage.loadPrivateKey(keyId);
    return AgentCredentials(password: password, privateKeyPem: pem);
  }

  /// agent 模式是否可用（UI 在打开面板时调用，避免用户点了才失败）。
  ///
  /// **判据必须与 [obtain] 逐字一致**（都走 [_isReusable]）。早前这里只判
  /// `!= null` 而 obtain 还要求 `!isClosed`：辅助连接一旦断掉，面板据此判定
  /// 「可用」并进入 agent 模式，而 obtain 会绕开这条死连接改走凭据分支 ——
  /// 用户看到的就是「进了 agent 模式，一发指令就失败」。判据分叉本身就是 bug。
  Future<bool> isAvailable() async {
    if (_canReuse(reuseProvider?.call())) {
      _log('isAvailable → true (可复用 tab 连接)');
      return true;
    }
    final usable = (await loadCredentials()).isUsable;
    _log('isAvailable → $usable (无可复用连接，按凭据判定)');
    return usable;
  }

  /// 一条连接是否还能用。既看 dartssh2 的 `isClosed`，也看跨组件共享的拉黑
  /// 登记处 [DeadSshClients]（经 [isSshClientDead]）—— 否则 SFTP 那边判定
  /// 的半死连接，agent 这里还会继续复用，重现「一边已拉黑、另一边照用」。
  static bool _isReusable(SSHClient? c) => c != null && !isSshClientDead(c);

  /// 复用 tab 那条辅助连接的完整判据 = 没死（见 [_isReusable]）**且**没被
  /// 本 channel 拉黑过。[isAvailable] 与 [obtain] 必须共用它，判据分叉本身
  /// 就是 bug。`!identical(c, _blockedReuse)` 这半句理论上已被 [_isReusable]
  /// 内的 [DeadSshClients] 检查覆盖（[invalidate] 两处都写），留着是双保险，
  /// 不是冗余的活代码。
  bool _canReuse(SSHClient? c) =>
      _isReusable(c) && !identical(c, _blockedReuse);

  /// 标记 [bad] 开不出 channel，下次 [obtain] 会绕开它。
  ///
  /// 由 [SshCommandRunner] 在 `execute()` 撞上 channel 建立失败时回调。这是
  /// `isClosed` 判不出来的那类半死连接（见 `isSshChannelSetupFailure`）——
  /// 不主动丢弃的话，它会被反复复用，agent 每条命令都失败且永不自愈。
  void invalidate(SSHClient bad) {
    if (identical(bad, _owned)) {
      _log('invalidate: 关闭并丢弃自有连接');
      _owned?.close();
      _owned = null;
      return;
    }
    // 复用来的连接属于 tab（SFTP 等可能还在用它），**不能替别人关掉**，
    // 只在本 channel 内拉黑；同时写入跨组件登记处，让 SFTP 等其它消费者
    // 也能看到这条连接已经废了 —— 否则会复现「agent 已拉黑、SFTP 照用」
    // 的空目录 bug。tab 侧的重建由 ReconnectService 负责。
    _log('invalidate: 拉黑 tab 的复用连接（不关闭，归 tab 所有）');
    _blockedReuse = bad;
    DeadSshClients.mark(bad);
  }

  void dispose() {
    // 只关自己开的那条；复用来的连接由 transport 管理。
    if (_owned != null) _log('dispose: 关闭自有连接');
    _owned?.close();
    _owned = null;
  }
}
