// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../util/dlog.dart';
import 'dart:io'
    show
        InternetAddress,
        InternetAddressType,
        RawSocketOption,
        Socket,
        SocketException,
        SocketOption;
import 'dart:typed_data' show Uint8List;
import 'package:dartssh2/dartssh2.dart';
import 'dead_ssh_clients.dart';
import 'host_key_verifier.dart';
import 'jump_host_resolver.dart';
import 'ssh_connection_pool.dart';

// Preferred SSH algorithms ordered fastest-first.
//
// KEX: x25519 first (fastest 1-RTT ECDH). DH group-exchange variants
//      (dhGexSha256/dhGexSha1) are intentionally excluded — they require an
//      extra client→server round trip for group negotiation. Fixed-group DH
//      (dh14Sha256, dh14Sha1) kept as fallback for legacy servers.
//
// Cipher: chacha20-poly1305 first — pure-Dart software crypto, performs well
//         on ARM without crypto HW. Then CTR, with CBC as legacy fallback.
//         GCM intentionally excluded — dartssh2 2.17 GCM is opt-in/incomplete
//         and causes SSHAuthAbortError on reconnect (server closes connection
//         during auth). Revisit once GCM is stable upstream.
//
// MAC: ETM variant preferred (encrypt-then-MAC is more secure than MAC-then-encrypt).
//      hmacSha1 kept for legacy server compatibility.
const _kPreferredAlgorithms = SSHAlgorithms(
  kex: [
    SSHKexType.x25519, // curve25519-sha256, fastest 1-RTT KEX
    SSHKexType.nistp256, // fallback
    SSHKexType.nistp384,
    SSHKexType.nistp521,
    SSHKexType.dh14Sha256, // fixed-group DH (no extra RTT unlike dhGex)
    SSHKexType.dh14Sha1, // legacy
    // dhGexSha256 / dhGexSha1 excluded: require extra RTT for group exchange
  ],
  hostkey: [
    SSHHostkeyType.ed25519,
    SSHHostkeyType.rsaSha256,
    SSHHostkeyType.rsaSha512,
    SSHHostkeyType.rsaSha1,
    SSHHostkeyType.ecdsa256,
    SSHHostkeyType.ecdsa384,
    SSHHostkeyType.ecdsa521,
  ],
  cipher: [
    // chacha20-poly1305 first: pure-Dart software crypto runs faster
    // than software AES on ARM devices without crypto extensions.
    // GCM excluded: dartssh2 2.17 GCM causes SSHAuthAbortError on reconnect.
    SSHCipherType.chacha20Poly1305,
    // aes128gcm / aes256gcm intentionally omitted — see comment above
    SSHCipherType.aes128ctr,
    SSHCipherType.aes256ctr,
    SSHCipherType.aes128cbc, // legacy fallback
    SSHCipherType.aes256cbc,
  ],
  mac: [
    SSHMacType.hmacSha256Etm,
    SSHMacType.hmacSha256,
    SSHMacType.hmacSha1, // legacy server fallback
  ],
);

/// Build a per-connection [SSHAlgorithms] honouring runtime settings.
/// Currently only swaps the compression preference: when the user has
/// disabled SSH compression we advertise `['none']` only so the
/// negotiation can't pick zlib. Other algorithm preferences stay at
/// the constant [_kPreferredAlgorithms] values.
SSHAlgorithms _algorithmsFor({required bool sshCompression}) {
  if (sshCompression) return _kPreferredAlgorithms;
  return SSHAlgorithms(
    kex: _kPreferredAlgorithms.kex,
    hostkey: _kPreferredAlgorithms.hostkey,
    cipher: _kPreferredAlgorithms.cipher,
    mac: _kPreferredAlgorithms.mac,
    compress: const ['none'],
  );
}

// TCP socket tuning constants (Linux values; silently ignored on unsupported platforms).
const int _kSolSocket = 1;
const int _kSoRcvBuf = 8;
const int _kSoSndBuf = 7;
const int _kIpprotoTcp = 6;
const int _kSoKeepalive = 9;
const int _kTcpKeepidle = 4;
const int _kTcpKeepcnt = 6;
const int _kTcpKeepintvl = 5;

/// SSH socket wrapper that enables TCP_NODELAY (disables Nagle's algorithm).
/// Eliminating Nagle buffering removes up to 40 ms of artificial keystroke delay.
class _TcpNoDelaySocket implements SSHSocket {
  final Socket _socket;
  _TcpNoDelaySocket(this._socket);

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();
}

/// Resolve [host] honouring [addressFamily]:
///   • 'auto'  — Dart's default (returns first available, family is OS-pref)
///   • 'ipv4'  — `Socket.connect` filters via InternetAddressType.IPv4
///   • 'ipv6'  — same with IPv6
/// For literal IP strings the filter is a no-op (Dart accepts them as-is).
Future<Socket> _resolveAndConnect(
  String host,
  int port, {
  required String addressFamily,
  required Duration timeout,
}) async {
  if (addressFamily == 'auto') {
    return Socket.connect(host, port, timeout: timeout);
  }
  // 'ipv4' or 'ipv6' — resolve only that family to avoid silent
  // fall-through (e.g. on a host that has both AAAA and A records,
  // we never want to silently accept the wrong family when the user
  // explicitly forced one).
  final type =
      addressFamily == 'ipv6'
          ? InternetAddressType.IPv6
          : InternetAddressType.IPv4;
  final addrs = await InternetAddress.lookup(host, type: type);
  if (addrs.isEmpty) {
    throw SocketException('No $addressFamily address for $host');
  }
  return Socket.connect(addrs.first, port, timeout: timeout);
}

Future<SSHSocket> _makeTcpNoDelaySocket(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 15),
  String addressFamily = 'auto',
}) async {
  final socket = await _resolveAndConnect(
    host,
    port,
    addressFamily: addressFamily,
    timeout: timeout,
  );
  socket.setOption(SocketOption.tcpNoDelay, true);
  try {
    socket.setRawOption(
      RawSocketOption.fromInt(_kSolSocket, _kSoRcvBuf, 262144),
    ); // 256 KB
    socket.setRawOption(
      RawSocketOption.fromInt(_kSolSocket, _kSoSndBuf, 131072),
    ); // 128 KB
  } catch (_) {}
  try {
    socket.setRawOption(RawSocketOption.fromInt(_kSolSocket, _kSoKeepalive, 1));
    socket.setRawOption(
      RawSocketOption.fromInt(_kIpprotoTcp, _kTcpKeepidle, 5),
    ); // first probe after 5 s idle (was 10)
    socket.setRawOption(
      RawSocketOption.fromInt(_kIpprotoTcp, _kTcpKeepintvl, 3),
    ); // probe every 3 s (was 5)
    socket.setRawOption(
      RawSocketOption.fromInt(_kIpprotoTcp, _kTcpKeepcnt, 3),
    ); // 5 + 3×3 = 14 s max to detect dead TCP (was 25 s)
  } catch (_) {}
  return _TcpNoDelaySocket(socket);
}

class SSHConnectionException implements Exception {
  final String message;
  SSHConnectionException(this.message);
  @override
  String toString() => 'SSHConnectionException: $message';
}

/// Connect and authenticate without opening any SSH channel.
/// Used by MoshHandshake: it only needs an exec channel, not a PTY shell.
/// Skipping the shell open saves ~3 RTTs vs using SSHConnection.connect().
/// 判断异常是否属于「连接还活着、但开不出新 channel」这一类失败。
///
/// 这正是 `SSHClient.isClosed` 覆盖不到的那个状态：Android 切后台或换网之后
/// dartssh2 仍报 `isClosed == false`（它只反映 socket 的 done，见
/// ssh_transport.dart:83），而服务端早已拒绝新的 session channel。凡是**复用**
/// 连接的地方（连接池、agent exec、SFTP）都必须用同一个判据识别它，否则那条
/// 半死连接会被反复递给下一个调用方。
bool isSshChannelSetupFailure(Object e) {
  if (e is SSHChannelOpenError) return true;
  if (e is StateError) {
    final message = e.message.toString();
    return message.contains('SSH channel setup failed') ||
        message.contains('SSHChannelOpenError');
  }
  return e.toString().contains('SSHChannelOpenError');
}

/// 这条连接还能不能用来开新 channel。
///
/// 两个判据缺一不可：[SSHClient.isClosed] 覆盖「明确关闭」，[DeadSshClients]
/// 覆盖「socket 还开着但开不出 channel」那类半死（见该类文档）。
///
/// **凡是复用别处连接的地方都该走这个函数**，不要各自写 `isClosed` —— 判据
/// 分叉正是「agent 已拉黑、SFTP 照用」那个 bug 的成因。
bool isSshClientDead(SSHClient client) =>
    client.isClosed || DeadSshClients.isMarked(client);

Future<SSHClient> sshConnectForExec({
  required String host,
  required int port,
  required String username,
  String? password,
  String? privateKeyPem,
  List<SSHKeyPair> keyPairs = const [],
  HostKeyVerifier? hostKeyVerifier,
  Duration timeout = const Duration(seconds: 20),
  bool sshCompression = true,
  /// Callback fired with elapsed milliseconds once the TCP socket is
  /// connected and TCP_NODELAY is set, but BEFORE SSH userauth begins.
  /// Lets AQT factory split tcp vs auth phases in ConnectTimings.
  void Function(int tcpMs)? onTcpConnected,
}) async {
  final swatch = Stopwatch()..start();
  final socket = await _makeTcpNoDelaySocket(host, port);
  onTcpConnected?.call(swatch.elapsedMilliseconds);
  final client = SSHClient(
    socket,
    username: username,
    onPasswordRequest: password != null ? () => password : null,
    identities:
        keyPairs.isNotEmpty
            ? keyPairs
            : (privateKeyPem != null ? SSHKeyPair.fromPem(privateKeyPem) : []),
    keepAliveInterval: const Duration(seconds: 8),
    algorithms: _algorithmsFor(sshCompression: sshCompression),
    onVerifyHostKey:
        hostKeyVerifier == null
            ? null
            : asDartsshHandler(hostKeyVerifier, host: host, port: port),
  );
  await client.authenticated.timeout(
    timeout,
    onTimeout: () => throw TimeoutException('SSH authentication timed out'),
  );
  return client;
}

class SSHConnection {
  SSHClient? _client;
  SSHClient? _jumpClient;
  SSHSession? _shell;
  Future<void> _done = Future.value();
  // Set when [_client] is owned by a [SshConnectionPool] under
  // [_pooledKey] — close() releases through the pool instead of
  // calling _client.close() directly so other tabs sharing the same
  // client aren't torn down with us.
  SshConnectionPool? _pool;
  String? _pooledKey;

  bool get isConnected => _client != null && !(_client!.isClosed);
  Future<void> get done => _done;
  SSHSession? get shell => _shell;
  SSHClient? get client => _client;

  bool _isChannelSetupFailure(Object e) => isSshChannelSetupFailure(e);

  Future<SSHSession?> connect({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,

    /// Pre-parsed key pairs. When non-empty, used directly instead of parsing
    /// [privateKeyPem], avoiding repeated RSA/Ed25519 PEM parsing on reconnects.
    List<SSHKeyPair> keyPairs = const [],
    String? jumpHost,
    int? jumpPort,
    String? jumpUsername,
    String? jumpPassword,
    String? jumpPrivateKeyPem,
    List<SSHKeyPair> jumpKeyPairs = const [],

    /// When non-empty, enables SSH agent forwarding: the remote host can request
    /// signing via these key pairs through the agent channel.
    List<SSHKeyPair> agentKeyPairs = const [],
    // When false, authenticate only — skip opening a PTY shell channel.
    // Saves 3 RTTs (channel-open + pty-req + shell) for mosh tabs that
    // use the SSH client solely for exec channels (TmuxHelper).
    // Callers can open the PTY lazily via openShell() if needed later.
    bool openShell = true,
    bool firstAttempt = true,

    /// Optional host-key policy. When provided, wired into both the
    /// jump host (if any) and the target. Verifier is consulted on
    /// every fresh connection — it is responsible for caching its own
    /// known_hosts state.
    HostKeyVerifier? hostKeyVerifier,

    /// Optional connection multiplexing pool. When provided AND the
    /// connection meets the pooling criteria (no jump host + key
    /// auth), the underlying SSHClient may be reused across tabs.
    /// New shell channels are still opened per call.
    SshConnectionPool? pool,

    /// Stable identifier for the auth key (server.keyId in app data).
    /// Used by the pool to key by `(host, port, user, keyId)`. Pass
    /// null for password auth.
    String? keyId,

    /// When non-null and a jump host is configured, the pool keys
    /// jump-host clients separately. Currently jump-host paths
    /// bypass pooling entirely (v1 scope).
    String? jumpHostId,

    /// IP version policy: 'auto' / 'ipv4' / 'ipv6'. See
    /// [Server.addressFamily]. Forwarded to both the jump host and
    /// the target socket; the OS resolver is filtered accordingly.
    String addressFamily = 'auto',

    /// Whether to advertise zlib compression in KEX. Default true
    /// (saves bandwidth on slow links); user can disable via the
    /// terminal settings to save CPU on fast LAN connections.
    bool sshCompression = true,
  }) async {
    // Tear down any partial connection left by a previous failed attempt so we
    // don't leak sockets across retries (e.g. auth-timeout leaves _client set).
    _releaseOrClose();
    _jumpClient?.close();
    _jumpClient = null;
    _shell = null;
    try {
      if (jumpHost != null && jumpUsername != null) {
        return await _connectViaJump(
          host: host,
          port: port,
          username: username,
          password: password,
          privateKeyPem: privateKeyPem,
          keyPairs: keyPairs,
          jumpHost: jumpHost,
          jumpPort: jumpPort ?? 22,
          jumpUsername: jumpUsername,
          jumpPassword: jumpPassword,
          jumpPrivateKeyPem: jumpPrivateKeyPem,
          jumpKeyPairs: jumpKeyPairs,
          agentKeyPairs: agentKeyPairs,
          openShell: openShell,
          firstAttempt: firstAttempt,
          hostKeyVerifier: hostKeyVerifier,
          addressFamily: addressFamily,
          sshCompression: sshCompression,
        );
      }
      return await _connectDirect(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKeyPem: privateKeyPem,
        keyPairs: keyPairs,
        agentKeyPairs: agentKeyPairs,
        openShell: openShell,
        firstAttempt: firstAttempt,
        hostKeyVerifier: hostKeyVerifier,
        pool: pool,
        keyId: keyId,
        addressFamily: addressFamily,
        sshCompression: sshCompression,
      );
    } catch (e) {
      // On any failure (TCP, auth, shell setup): release the partial client
      // so isConnected returns false. Without this, a successful-auth-but-
      // failed-shell attempt leaves _client non-null/isClosed=false, causing
      // _reconnectDisconnected() to skip the tab until keepalive times out.
      _releaseOrClose();
      _jumpClient?.close();
      _jumpClient = null;
      rethrow;
    }
  }

  /// Release the current client back to the pool (if pooled) or
  /// close it directly. Idempotent.
  void _releaseOrClose() {
    if (_pool != null && _pooledKey != null) {
      _pool!.release(_pooledKey!, _client);
      _pool = null;
      _pooledKey = null;
      _client = null;
      return;
    }
    _client?.close();
    _client = null;
  }

  /// 验证这条连接确实能开出 exec channel，验不过就把它从池里剔除并断开。
  ///
  /// **为什么需要它**：`connect()` 里唯一的半死连接探测藏在 `shell()` 的
  /// catch 中（见其中的 channel-setup 兜底重连），而 `openShell: false` 的
  /// 连接在那之前就 return 了 —— QUIC 会话的辅助连接正是这一类，它完全绕开
  /// 了探测。于是一条 `isClosed == false` 却开不出 channel 的连接会被挂到
  /// tab 上，随后 SFTP 和 agent 都复用它，两个功能一起废。
  ///
  /// 剔除时必须 `invalidate` 而不只是 `release`：池只看 `isClosed`，被
  /// release 回去的半死连接会继续被下一个 tab acquire 到
  /// （见 ssh_connection_pool.dart 中 [SshConnectionPool.invalidate] 的说明）。
  ///
  /// 返回 true 表示连接可用；false 表示已被丢弃，[client] 随之变为 null。
  Future<bool> verifyExecChannel({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final c = _client;
    if (c == null || c.isClosed) return false;
    try {
      // `true` 是 shell 内建，几乎零成本；这里要的只是「channel 能不能开」。
      final session = await c.execute('true').timeout(timeout);
      session.close();
      return true;
    } catch (_) {
      // 任何失败都判为不可用 —— 这条连接是要交给 SFTP / agent 复用的，
      // 验不过就不该留着让它们各自去撞。
      final pool = _pool;
      final key = _pooledKey;
      if (pool != null && key != null) {
        pool.invalidate(key, c);
        pool.release(key, c);
        _pool = null;
        _pooledKey = null;
      } else {
        c.close();
      }
      _client = null;
      return false;
    }
  }

  /// Open a PTY shell on an already-authenticated connection.
  /// Call when the initial [connect] used [openShell]=false and a shell
  /// is needed later (e.g. mosh graceful degradation to plain SSH).
  Future<SSHSession> openShell() async {
    if (_client == null) throw StateError('Not connected');
    try {
      _shell = await _client!.shell(
        pty: const SSHPtyConfig(width: 80, height: 24, type: 'xterm-256color'),
      );
    } catch (e) {
      // dartssh2 internal: _channels[id]! can be null when Channel_Open_Confirmation
      // and Channel_Close arrive in the same TCP segment and the async continuation
      // runs after the channel has been removed.  Re-throw as StateError so callers
      // see a meaningful message instead of "Null check operator used on a null value".
      throw StateError('SSH channel setup failed: $e');
    }
    return _shell!;
  }

  Future<SSHSession?> _connectDirect({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    List<SSHKeyPair> keyPairs = const [],
    List<SSHKeyPair> agentKeyPairs = const [],
    bool openShell = true,
    bool firstAttempt = true,
    HostKeyVerifier? hostKeyVerifier,
    SshConnectionPool? pool,
    String? keyId,
    String addressFamily = 'auto',
    bool sshCompression = true,
  }) async {
    final tcpTimeout =
        firstAttempt ? const Duration(seconds: 5) : const Duration(seconds: 12);
    final authTimeout =
        firstAttempt ? const Duration(seconds: 8) : const Duration(seconds: 15);
    final agent =
        agentKeyPairs.isNotEmpty ? SSHKeyPairAgent(agentKeyPairs) : null;
    if (agent != null) {
      dlog('SSH',
        'Agent forwarding enabled with ${agentKeyPairs.length} key(s)',
      );
    }

    // Pool-eligibility check. The pool computes its own key — if it
    // returns null the connection bypasses pooling (e.g., password
    // auth, jump host). Agent forwarding does NOT block pooling here:
    // only the first acquire registers the agent handler; subsequent
    // tabs reuse the same SSHClient and inherit it. That's an
    // accepted v1 simplification — agent-forwarding is a per-server
    // setting in practice.
    final authType =
        (keyPairs.isNotEmpty || privateKeyPem != null) ? 'key' : 'password';
    final poolKey =
        pool == null
            ? null
            : SshConnectionPool.keyFor(
              host: host,
              port: port,
              username: username,
              authType: authType,
              keyId: keyId,
            );

    if (pool != null && poolKey != null) {
      _client = await pool.acquire(poolKey, () async {
        final socket = await _makeTcpNoDelaySocket(
          host,
          port,
          timeout: tcpTimeout,
          addressFamily: addressFamily,
        );
        final c = SSHClient(
          socket,
          username: username,
          onPasswordRequest: password != null ? () => password : null,
          identities:
              keyPairs.isNotEmpty
                  ? keyPairs
                  : (privateKeyPem != null
                      ? SSHKeyPair.fromPem(privateKeyPem)
                      : []),
          agentHandler: agent,
          keepAliveInterval: const Duration(seconds: 8),
          algorithms: _algorithmsFor(sshCompression: sshCompression),
          onVerifyHostKey:
              hostKeyVerifier == null
                  ? null
                  : asDartsshHandler(hostKeyVerifier, host: host, port: port),
        );
        await c.authenticated.timeout(
          authTimeout,
          onTimeout:
              () =>
                  throw TimeoutException(
                    'Authentication timed out. Check credentials or server availability.',
                  ),
        );
        return c;
      });
      _pool = pool;
      _pooledKey = poolKey;
      _done = _client!.done;
    } else {
      final socket = await _makeTcpNoDelaySocket(
        host,
        port,
        timeout: tcpTimeout,
      );
      _done = socket.done;
      _client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: password != null ? () => password : null,
        identities:
            keyPairs.isNotEmpty
                ? keyPairs
                : (privateKeyPem != null
                    ? SSHKeyPair.fromPem(privateKeyPem)
                    : []),
        agentHandler: agent,
        keepAliveInterval: const Duration(seconds: 8),
        algorithms: _algorithmsFor(sshCompression: sshCompression),
        onVerifyHostKey:
            hostKeyVerifier == null
                ? null
                : asDartsshHandler(hostKeyVerifier, host: host, port: port),
      );
      await _client!.authenticated.timeout(
        authTimeout,
        onTimeout:
            () =>
                throw TimeoutException(
                  'Authentication timed out. Check credentials or server availability.',
                ),
      );
    }

    if (!openShell) return null;
    try {
      _shell = await _client!.shell(
        pty: const SSHPtyConfig(width: 80, height: 24, type: 'xterm-256color'),
      );
    } catch (e) {
      // A pooled client can be half-dead after app backgrounding/network
      // changes: dartssh2 still reports !isClosed, but the server rejects new
      // session channels. If we only release it, the pool keeps the bad client
      // warm and every later tab repeats the same SSHChannelOpenError until app
      // restart. Invalidate it and retry once with a fresh client.
      if (pool != null && poolKey != null && _isChannelSetupFailure(e)) {
        final badClient = _client;
        if (badClient != null) {
          pool.invalidate(poolKey, badClient);
          // This connection acquired one reference before the channel-open
          // failure. After switching to a fresh non-pooled client it no longer
          // owns that old transport, so drop the acquired reference. Other tabs
          // that were already using it keep their own references until close().
          pool.release(poolKey, badClient);
        }
        _pool = null;
        _pooledKey = null;
        _client = null;
        final socket = await _makeTcpNoDelaySocket(
          host,
          port,
          timeout: tcpTimeout,
          addressFamily: addressFamily,
        );
        final fresh = SSHClient(
          socket,
          username: username,
          onPasswordRequest: password != null ? () => password : null,
          identities:
              keyPairs.isNotEmpty
                  ? keyPairs
                  : (privateKeyPem != null
                      ? SSHKeyPair.fromPem(privateKeyPem)
                      : []),
          agentHandler: agent,
          keepAliveInterval: const Duration(seconds: 8),
          algorithms: _algorithmsFor(sshCompression: sshCompression),
          onVerifyHostKey:
              hostKeyVerifier == null
                  ? null
                  : asDartsshHandler(hostKeyVerifier, host: host, port: port),
        );
        await fresh.authenticated.timeout(
          authTimeout,
          onTimeout:
              () =>
                  throw TimeoutException(
                    'Authentication timed out. Check credentials or server availability.',
                  ),
        );
        _client = fresh;
        _done = fresh.done;
        _shell = await fresh.shell(
          pty: const SSHPtyConfig(
            width: 80,
            height: 24,
            type: 'xterm-256color',
          ),
        );
        return _shell!;
      }
      throw StateError('SSH channel setup failed: $e');
    }
    return _shell!;
  }

  Future<SSHSession?> _connectViaJump({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    List<SSHKeyPair> keyPairs = const [],
    required String jumpHost,
    required int jumpPort,
    required String jumpUsername,
    String? jumpPassword,
    String? jumpPrivateKeyPem,
    List<SSHKeyPair> jumpKeyPairs = const [],
    List<SSHKeyPair> agentKeyPairs = const [],
    bool openShell = true,
    bool firstAttempt = true,
    HostKeyVerifier? hostKeyVerifier,
    String addressFamily = 'auto',
    bool sshCompression = true,
  }) async {
    final tcpTimeout =
        firstAttempt ? const Duration(seconds: 5) : const Duration(seconds: 12);
    final authTimeout =
        firstAttempt ? const Duration(seconds: 8) : const Duration(seconds: 15);
    final jumpSocket = await _makeTcpNoDelaySocket(
      jumpHost,
      jumpPort,
      timeout: tcpTimeout,
      addressFamily: addressFamily,
    );
    _done = jumpSocket.done;
    _jumpClient = SSHClient(
      jumpSocket,
      username: jumpUsername,
      onPasswordRequest: jumpPassword != null ? () => jumpPassword : null,
      identities:
          jumpKeyPairs.isNotEmpty
              ? jumpKeyPairs
              : (jumpPrivateKeyPem != null
                  ? SSHKeyPair.fromPem(jumpPrivateKeyPem)
                  : []),
      keepAliveInterval: const Duration(seconds: 8),
      algorithms: _algorithmsFor(sshCompression: sshCompression),
      onVerifyHostKey:
          hostKeyVerifier == null
              ? null
              : asDartsshHandler(
                hostKeyVerifier,
                host: jumpHost,
                port: jumpPort,
              ),
    );
    await _jumpClient!.authenticated.timeout(
      authTimeout,
      onTimeout:
          () => throw TimeoutException('Jump host authentication timed out.'),
    );

    try {
      final channel = await _jumpClient!.forwardLocal(host, port);
      final agent =
          agentKeyPairs.isNotEmpty ? SSHKeyPairAgent(agentKeyPairs) : null;
      _client = SSHClient(
        SshChannelTransport(channel),
        username: username,
        onPasswordRequest: password != null ? () => password : null,
        identities:
            keyPairs.isNotEmpty
                ? keyPairs
                : (privateKeyPem != null
                    ? SSHKeyPair.fromPem(privateKeyPem)
                    : []),
        agentHandler: agent,
        keepAliveInterval: const Duration(seconds: 8),
        algorithms: _algorithmsFor(sshCompression: sshCompression),
        onVerifyHostKey:
            hostKeyVerifier == null
                ? null
                : asDartsshHandler(hostKeyVerifier, host: host, port: port),
      );
      await _client!.authenticated.timeout(
        authTimeout,
        onTimeout:
            () =>
                throw TimeoutException(
                  'Target server authentication timed out.',
                ),
      );
      if (!openShell) return null;
      try {
        _shell = await _client!.shell(
          pty: const SSHPtyConfig(
            width: 80,
            height: 24,
            type: 'xterm-256color',
          ),
        );
      } catch (e) {
        throw StateError('SSH channel setup failed: $e');
      }
      return _shell!;
    } catch (e) {
      _jumpClient?.close();
      _jumpClient = null;
      rethrow;
    }
  }

  void resizeTerminal(int width, int height) {
    _shell?.resizeTerminal(width, height);
  }

  /// Close only the PTY shell, keeping the SSH client alive for exec channels.
  /// Call after a successful mosh handshake so the idle SSH PTY is freed on
  /// the server while TmuxHelper (exec-based) can still use the connection.
  void closeShell() {
    _shell?.close();
    _shell = null;
  }

  Future<void> close() async {
    // Always close our own shell channel first — that's per-tab and
    // safe regardless of whether the underlying client is shared.
    _shell?.close();
    _shell = null;
    _releaseOrClose();
    _jumpClient?.close();
    _jumpClient = null;
  }
}
