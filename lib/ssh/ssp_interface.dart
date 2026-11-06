// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ssh/ssp_interface.dart
import 'dart:async';
import 'dart:typed_data';

/// Mosh State-Synchronization Protocol transport 顶层接口。
/// v1 (`ssp/ssp_transport.dart`) 与 v2 (`ssp_v2/transport/connection.dart`)
/// 各自实现，`MoshShell` 只依赖此接口。
abstract class SspTransport {
  /// 用户键入 / resize 等下行 bytes。
  void write(Uint8List bytes);

  /// 终端尺寸变化。
  void resize(int cols, int rows);

  /// 主动关闭连接。
  Future<void> close();

  /// 收到的服务端原始 host_bytes（喂给 xterm.Terminal）。
  Stream<Uint8List> get hostBytes;

  /// 连接活性事件（用于 ReconnectService）。
  Stream<SspLivenessEvent> get liveness;

  /// 当前 sentStates 长度（debug overlay 用）。
  int get pendingStateCount;

  /// 协议版本标记（"v1" / "v2"），便于 telemetry 区分。
  String get implVersion;
}

enum SspLivenessKind { healthy, gracePeriod, roaming, hardReconnectNeeded }

class SspLivenessEvent {
  final SspLivenessKind kind;
  final String? reason;
  const SspLivenessEvent(this.kind, {this.reason});
}
