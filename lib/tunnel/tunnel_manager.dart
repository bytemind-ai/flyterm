// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/models/server.dart';
import '../data/models/tunnel_config.dart';
import '../data/repositories/server_repository.dart';
import '../data/repositories/tunnel_repository.dart';
import '../data/secure_storage.dart';
import '../ssh/jump_host_resolver.dart';
import 'socks5_handler.dart';
import 'tunnel_entry.dart';

class _TunnelResources {
  SSHClient? ownedClient;
  SSHClient? jumpClient;
  SSHClient? activeClient;
  ServerSocket? serverSocket;
  // Optional second listener bound to the IPv6 loopback so clients
  // that resolve "localhost" to ::1 (most browsers, Happy Eyeballs)
  // can connect without first failing over to 127.0.0.1.
  ServerSocket? serverSocket6;
  SSHRemoteForward? remoteForward;
  StreamSubscription<SSHForwardChannel>? remoteForwardSub;
  SecureStorageService? storage; // kept for auto-retry after drop
}

class TunnelManager extends ChangeNotifier {
  final List<TunnelEntry> _tunnels = [];
  final _resources = <String, _TunnelResources>{};
  final TunnelRepository? _repo;
  final ServerRepository? _serverRepo;

  TunnelManager({TunnelRepository? repository, ServerRepository? serverRepo})
      : _repo = repository,
        _serverRepo = serverRepo;

  List<TunnelEntry> get tunnels => List.unmodifiable(_tunnels);

  // ─── One-time (unsaved) tunnel via existing SSH connection ───────────────

  Future<TunnelEntry> addTunnel({
    required SSHClient existingClient,
    required Server server,
    required TunnelDirection direction,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    required String label,
  }) async {
    final entry = TunnelEntry(
      server: server,
      direction: direction,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      label: label,
      saved: false,
    );
    _tunnels.add(entry);
    notifyListeners();

    final resources = _TunnelResources();
    _resources[entry.id] = resources;
    try {
      await _activate(entry, existingClient, resources);
    } catch (e) {
      entry.status = TunnelStatus.error;
      entry.errorMessage = e.toString();
    }
    notifyListeners();
    return entry;
  }

  // ─── One-time (unsaved) tunnel with its own SSH connection ───────────────

  Future<TunnelEntry> addTunnelForServer({
    required Server server,
    required SecureStorageService storage,
    required TunnelDirection direction,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    required String label,
    String? password,
  }) async {
    final entry = TunnelEntry(
      server: server,
      direction: direction,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      label: label,
      saved: false,
    );
    _tunnels.add(entry);
    notifyListeners();

    final resources = _TunnelResources();
    _resources[entry.id] = resources;
    try {
      await _connectAndActivate(entry, server, storage, resources, password: password);
    } catch (e) {
      entry.status = TunnelStatus.error;
      entry.errorMessage = e.toString();
      resources.ownedClient?.close();
    }
    notifyListeners();
    return entry;
  }

  // ─── Saved tunnel: persists to DB + activates ────────────────────────────

  Future<TunnelEntry> saveAndAdd({
    required SSHClient? existingClient,
    required Server server,
    required SecureStorageService? storage,
    required TunnelDirection direction,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    required String label,
    required bool autoStart,
    String? password,
  }) async {
    final id = const Uuid().v4();
    final entry = TunnelEntry(
      id: id,
      server: server,
      direction: direction,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      label: label,
      autoStart: autoStart,
      saved: true,
    );

    await _repo?.insert(TunnelConfig(
      id: id,
      serverId: server.id,
      direction: direction,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      label: label,
      autoStart: autoStart,
    ));

    _tunnels.add(entry);
    notifyListeners();

    final resources = _TunnelResources();
    _resources[entry.id] = resources;
    try {
      if (existingClient != null) {
        await _activate(entry, existingClient, resources);
      } else if (storage != null) {
        await _connectAndActivate(entry, server, storage, resources, password: password);
      }
      // If both null (test path), entry stays in connecting state
    } catch (e) {
      entry.status = TunnelStatus.error;
      entry.errorMessage = e.toString();
      resources.ownedClient?.close();
    }
    notifyListeners();
    return entry;
  }

  // ─── Reactivate a stopped saved entry ────────────────────────────────────

  Future<void> reactivate(String id, SecureStorageService storage) async {
    final entry = _tunnels.firstWhere((t) => t.id == id);
    entry.status = TunnelStatus.connecting;
    entry.errorMessage = null;
    notifyListeners();

    await _stopResources(id);
    final resources = _TunnelResources();
    _resources[id] = resources;
    try {
      await _connectAndActivate(entry, entry.server, storage, resources);
    } catch (e) {
      entry.status = TunnelStatus.error;
      entry.errorMessage = e.toString();
      resources.ownedClient?.close();
    }
    notifyListeners();
  }

  // ─── Persistence helpers ─────────────────────────────────────────────────

  Future<void> removeSaved(String id) async {
    await _stopResources(id);
    _tunnels.removeWhere((t) => t.id == id);
    await _repo?.delete(id);
    notifyListeners();
  }

  Future<void> setAutoStart(String id, bool autoStart) async {
    final entry = _tunnels.firstWhere((t) => t.id == id);
    entry.autoStart = autoStart;
    await _repo?.updateAutoStart(id, autoStart);
    notifyListeners();
  }

  Future<void> restoreFromDb(
      ServerRepository serverRepo, SecureStorageService? storage) async {
    if (_repo == null) return;
    final configs = await _repo.findAll();
    for (final config in configs) {
      final server = await serverRepo.findById(config.serverId);
      if (server == null) continue;
      final entry = _entryFromConfig(config, server);
      _tunnels.add(entry);
      notifyListeners();
      if (config.autoStart && storage != null) {
        _activateFromStorage(entry, storage);
      }
    }
  }

  // ─── stopTunnel — behavior depends on saved flag ─────────────────────────

  Future<void> stopTunnel(String id) async {
    final idx = _tunnels.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final entry = _tunnels[idx];
    await _stopResources(id);
    if (entry.saved) {
      entry.status = TunnelStatus.stopped;
    } else {
      _tunnels.removeAt(idx);
    }
    notifyListeners();
  }

  Future<void> stopAll() async {
    final ids = _tunnels.map((t) => t.id).toList();
    for (final id in ids) {
      await stopTunnel(id);
    }
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  TunnelEntry _entryFromConfig(TunnelConfig config, Server server) =>
      TunnelEntry(
        id: config.id,
        server: server,
        direction: config.direction,
        localPort: config.localPort,
        remoteHost: config.remoteHost,
        remotePort: config.remotePort,
        label: config.label,
        autoStart: config.autoStart,
        saved: true,
        status: TunnelStatus.stopped,
      );

  Future<void> _activateFromStorage(
      TunnelEntry entry, SecureStorageService storage) async {
    final resources = _TunnelResources()..storage = storage;
    _resources[entry.id] = resources;
    entry.status = TunnelStatus.connecting;
    notifyListeners();
    try {
      await _connectAndActivate(entry, entry.server, storage, resources);
      entry.retryCount = 0;
      _watchConnection(entry, resources);
    } catch (e) {
      entry.status = TunnelStatus.error;
      entry.errorMessage = e.toString();
      resources.ownedClient?.close();
      notifyListeners();
      _scheduleRetry(entry, storage);
      return;
    }
    notifyListeners();
  }

  // ─── Auto-retry helpers ───────────────────────────────────────────────────

  static const _retryDelays = [5, 10, 20, 40, 60]; // seconds

  void _scheduleRetry(TunnelEntry entry, SecureStorageService storage) {
    if (!entry.saved || !entry.autoStart) return;
    if (entry.retryCount >= TunnelEntry.maxRetries) {
      entry.errorMessage =
          '已重试 ${TunnelEntry.maxRetries} 次，停止自动重连';
      notifyListeners();
      return;
    }
    final delay = _retryDelays[entry.retryCount.clamp(0, _retryDelays.length - 1)];
    entry.retryCount++;
    entry.status = TunnelStatus.connecting;
    notifyListeners();
    Future.delayed(Duration(seconds: delay), () {
      if (!_tunnels.contains(entry)) return;
      if (entry.status == TunnelStatus.stopped) return;
      _activateFromStorage(entry, storage);
    });
  }

  void _watchConnection(TunnelEntry entry, _TunnelResources resources) {
    final client = resources.ownedClient;
    if (client == null) return;
    client.done.then((_) {
      if (!_tunnels.contains(entry)) return;
      if (entry.status == TunnelStatus.stopped) return;
      entry.status = TunnelStatus.error;
      entry.errorMessage = '连接已断开';
      notifyListeners();
      final storage = resources.storage;
      if (storage != null) _scheduleRetry(entry, storage);
    });
  }

  Future<void> _connectAndActivate(
    TunnelEntry entry,
    Server server,
    SecureStorageService storage,
    _TunnelResources resources, {
    String? password,
  }) async {
    String? privateKeyPem;
    if (server.authType == 'key' && server.keyId != null) {
      privateKeyPem = await storage.loadPrivateKey(server.keyId!);
    }

    SSHClient client;

    JumpHostParams? jump;
    if (_serverRepo != null) {
      jump = await resolveJumpParams(server, _serverRepo!, storage);
    }

    if (jump != null) {
      final j = jump;
      final jumpSocket = await SSHSocket.connect(
        j.host, j.port,
        timeout: const Duration(seconds: 15),
      );
      final jumpClient = SSHClient(
        jumpSocket,
        username: j.username,
        onPasswordRequest: j.password != null ? () => j.password! : null,
        identities: j.privateKeyPem != null
            ? SSHKeyPair.fromPem(j.privateKeyPem!)
            : [],
      );
      await jumpClient.authenticated;
      resources.jumpClient = jumpClient;

      try {
        final channel = await jumpClient.forwardLocal(server.host, server.port);
        client = SSHClient(
          SshChannelTransport(channel),
          username: server.username,
          onPasswordRequest: password != null ? () => password : null,
          identities:
              privateKeyPem != null ? SSHKeyPair.fromPem(privateKeyPem) : [],
        );
        await client.authenticated;
      } catch (e) {
        resources.jumpClient?.close();
        resources.jumpClient = null;
        rethrow;
      }
    } else {
      final socket = await SSHSocket.connect(
        server.host, server.port,
        timeout: const Duration(seconds: 15),
      );
      client = SSHClient(
        socket,
        username: server.username,
        onPasswordRequest: password != null ? () => password : null,
        identities:
            privateKeyPem != null ? SSHKeyPair.fromPem(privateKeyPem) : [],
      );
      await client.authenticated;
    }

    resources.ownedClient = client;
    await _activate(entry, client, resources);
  }

  Future<void> _activate(
      TunnelEntry entry, SSHClient client, _TunnelResources res) async {
    res.activeClient = client;
    try {
      if (entry.direction == TunnelDirection.local) {
        await _startLocal(entry, client, res);
      } else if (entry.direction == TunnelDirection.remote) {
        await _startRemote(entry, client, res);
      } else {
        await _startSocks5(entry, client, res);
      }
      entry.status = TunnelStatus.active;
    } catch (e) {
      entry.status = TunnelStatus.error;
      entry.errorMessage = e.toString();
    }
  }

  Future<void> _startLocal(
      TunnelEntry entry, SSHClient client, _TunnelResources res) async {
    Future<void> bridge(Socket socket) async {
      try {
        final channel =
            await client.forwardLocal(entry.remoteHost, entry.remotePort);
        socket.listen(
          (data) => channel.sink.add(data),
          onDone: () => channel.close(),
          onError: (_) => channel.close(),
          cancelOnError: true,
        );
        channel.stream.listen(
          (data) => socket.add(data),
          onDone: () => socket.close(),
          onError: (_) => socket.close(),
          cancelOnError: true,
        );
      } catch (_) {
        await socket.close();
      }
    }

    // Bind on both 127.0.0.1 and ::1 so clients resolving "localhost"
    // to either family connect without a fallback round-trip. The
    // IPv4 socket is the source of truth for the port number — if v4
    // bind fails we abort entirely; if v6 bind fails we keep v4 only
    // (some platforms / containers disable IPv6).
    res.serverSocket =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, entry.localPort);
    res.serverSocket!.listen(bridge);
    try {
      res.serverSocket6 = await ServerSocket.bind(
          InternetAddress.loopbackIPv6, entry.localPort,
          v6Only: true);
      res.serverSocket6!.listen(bridge);
    } catch (_) {
      // IPv6 unavailable — keep v4 only.
    }
  }

  // Stage 3 TODO: when TunnelManager gains a RemoteTransport reference for the
  // session that owns this tunnel, gate _startRemote with:
  //   if (!transport.capabilities.contains(TransportCapability.reverseForward))
  //     throw UnsupportedError('...');
  // For now TunnelManager always opens its own SSH connection (SSHClient), so
  // reverse forwarding is implicitly SSH-only and capability gating is a no-op.
  Future<void> _startRemote(
      TunnelEntry entry, SSHClient client, _TunnelResources res) async {
    final remoteForward =
        await client.forwardRemote(port: entry.remotePort);
    if (remoteForward == null) {
      throw Exception(
          'Server refused remote forwarding on port ${entry.remotePort}');
    }
    res.remoteForward = remoteForward;
    res.remoteForwardSub =
        remoteForward.connections.listen((channel) async {
      try {
        final socket =
            await Socket.connect('127.0.0.1', entry.localPort);
        channel.stream.listen(
          (data) => socket.add(data),
          onDone: () => socket.close(),
          onError: (_) => socket.close(),
          cancelOnError: true,
        );
        socket.listen(
          (data) => channel.sink.add(data),
          onDone: () => channel.close(),
          onError: (_) => channel.close(),
          cancelOnError: true,
        );
      } catch (_) {
        await channel.close();
      }
    });
  }

  Future<void> _startSocks5(
      TunnelEntry entry, SSHClient client, _TunnelResources res) async {
    final serverSocket = await ServerSocket.bind('127.0.0.1', entry.localPort);
    res.serverSocket = serverSocket;
    serverSocket.listen(
      (socket) async {
        Socks5Connection? conn;
        try {
          conn = await socks5Handshake(socket);
          final channel = await client.forwardLocal(conn.host, conn.port);
          conn.pipeSocketTo(channel.sink);
          channel.stream.listen(
            (data) => socket.add(data),
            onDone: () => socket.close(),
            onError: (_) => socket.close(),
            cancelOnError: true,
          );
        } catch (_) {
          conn?.cancel();
          await socket.close();
        }
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  Future<void> _stopResources(String id) async {
    final res = _resources.remove(id);
    if (res == null) return;
    await res.serverSocket?.close();
    await res.serverSocket6?.close();
    await res.remoteForwardSub?.cancel();
    if (res.remoteForward != null && res.activeClient != null) {
      await res.activeClient!.cancelForwardRemote(res.remoteForward!);
    }
    res.ownedClient?.close();
    res.jumpClient?.close();
  }

  @override
  void dispose() {
    for (final entry in List.of(_tunnels)) {
      final res = _resources[entry.id];
      if (res == null) continue;
      res.remoteForwardSub?.cancel();
      res.serverSocket?.close();
      res.serverSocket6?.close();
      res.ownedClient?.close();
      res.jumpClient?.close();
    }
    _tunnels.clear();
    _resources.clear();
    super.dispose();
  }
}
