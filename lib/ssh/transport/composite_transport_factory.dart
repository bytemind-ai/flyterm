// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/widgets.dart' show BuildContext;

import '../../data/models/server.dart';
import '../../platform_capabilities.dart';
import '../aqt/aqt_transport_factory.dart';
import 'local_transport_factory.dart';
import 'remote_transport.dart';
import 'ssh_transport_factory.dart';
import 'transport_factory.dart';

class CompositeTransportFactory implements TransportFactory {
  final SshTransportFactory _ssh;
  final LocalTransportFactory _local;
  final AqtTransportFactory _aqt;

  /// 平台能力注入点。生产用 [PlatformCapabilities.instance]（按 `Platform` 判定），
  /// 测试注入 `const PlatformCapabilities.limited()` 覆盖 iOS 行为。
  final PlatformCapabilities Function() _caps;

  CompositeTransportFactory({
    SshTransportFactory? ssh,
    LocalTransportFactory? local,
    AqtTransportFactory? aqt,
    PlatformCapabilities Function()? capabilities,
  })  : _ssh = ssh ?? SshTransportFactory(),
        _local = local ?? LocalTransportFactory(),
        _aqt = aqt ?? AqtTransportFactory(),
        _caps = capabilities ?? PlatformCapabilities.instance;

  /// 本地 shell 不可用（iOS / 非 Android 平台）时抛出的异常。
  ///
  /// 不同于 Mosh 那两条「不支持走 CompositeTransportFactory」的配置错误
  /// —— 这条是**平台能力缺失**，消息要说清「不是配置问题，是这个平台
  /// 没有本地终端」。UI 侧 `TerminalScreen` 会把 `TransportConnectException`
  /// 转成 `_connectError` 展示，用户看到的是可读的一句话而非 crash。
  static TransportConnectException _localUnsupported(Server server) =>
      TransportConnectException(
        'Local shell is not available on this platform '
        '(server "${server.name}"). '
        'iOS has no local terminal — connect to a remote host instead.',
      );

  @override
  Future<RemoteTransport> connect(
    Server server, {
    BuildContext? dialogContext,
  }) async {
    if (server.serverType == 'local') {
      if (!_caps().hasLocalShell) throw _localUnsupported(server);
      return _local.connect(server);
    }

    switch (server.transport) {
      case Transport.ssh:
        return _ssh.connect(server);
      case Transport.mosh:
        throw TransportConnectException(
          'Mosh connect via CompositeTransportFactory is not supported — use ReconnectService',
        );
      case Transport.quic:
        // Strict mode: no SSH fallback. Failure propagates as
        // TransportConnectException, caller (UI) shows error toast.
        return _aqt.connect(
          server,
          dialogContext: dialogContext,
        );
    }
  }

  @override
  Future<RemoteTransport> reconnect({
    required Server server,
    required ReconnectCredentials creds,
    RemoteTransport? previous,
    BuildContext? dialogContext,
    Future<void> Function()? onPurgeSession,
  }) async {
    if (server.serverType == 'local') {
      if (!_caps().hasLocalShell) throw _localUnsupported(server);
      return _local.reconnect(
          server: server, creds: creds, previous: previous);
    }

    switch (server.transport) {
      case Transport.ssh:
        return _ssh.reconnect(
            server: server, creds: creds, previous: previous);
      case Transport.mosh:
        throw TransportConnectException(
          'Mosh reconnect via CompositeTransportFactory is not supported — use ReconnectService',
        );
      case Transport.quic:
        return _aqt.reconnect(
          server: server,
          creds: creds,
          previous: previous,
          dialogContext: dialogContext,
          onPurgeSession: onPurgeSession,
        );
    }
  }
}
