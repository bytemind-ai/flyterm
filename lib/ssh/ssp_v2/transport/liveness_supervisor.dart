// SPDX-License-Identifier: GPL-3.0-or-later
// 4-layer watchdog state machine: tracks gap since the last inbound
// authenticated packet and emits liveness events at 30s/40s/45s thresholds.
//
//   0–30s:  healthy
//   30–40s: gracePeriod   (UI shows "reconnecting"; no action yet — wait for OS)
//   40–45s: roaming       (rebind UDP source port)
//   >45s:   hardReconnect (give up; let ReconnectService re-handshake)
//
// Resetting via onPacket() requires *any* authenticated packet from the
// server, which is what makes mosh's roaming work — mid-network-change a
// previously-stuck packet finally arrives, and the supervisor pops back
// to healthy without having to call roam().
import '../../ssp_interface.dart';

class LivenessSupervisor {
  // Mosh's reference implementation uses MOSH_SERVER_NETWORK_TMOUT (default
  // hours). For mobile we want quicker recovery, but the old 30/40/45s
  // window was too aggressive — every cellular handoff (~25-35s) tripped
  // it. New schedule gives the roam path 30s to drag a response back
  // before declaring the session dead, matching v1's looser stable-idle
  // 40s timeout.
  static const kGraceAfter = Duration(seconds: 30);
  static const kRoamAfter = Duration(seconds: 45);
  static const kHardAfter = Duration(seconds: 75);

  // Re-emit roaming event every kRoamRetryInterval while supervisor remains
  // stuck in roaming state. A single roam attempt at 45 s often fails on
  // 4G→WiFi handoffs because the OS routing table hasn't switched yet;
  // re-emitting lets MoshV2Connection keep rebinding until a packet arrives.
  static const kRoamRetryInterval = Duration(seconds: 15);

  DateTime lastInbound = DateTime.now();
  SspLivenessKind state = SspLivenessKind.healthy;
  DateTime? _lastRoamEmitAt;

  SspLivenessEvent? evaluate(DateTime now) {
    final gap = now.difference(lastInbound);
    if (gap > kHardAfter && state != SspLivenessKind.hardReconnectNeeded) {
      state = SspLivenessKind.hardReconnectNeeded;
      return SspLivenessEvent(
        SspLivenessKind.hardReconnectNeeded,
        reason: 'no auth packet for ${gap.inSeconds}s',
      );
    }
    if (gap > kRoamAfter && state != SspLivenessKind.hardReconnectNeeded) {
      // Re-fire roaming every kRoamRetryInterval while still stale — the
      // first roam at 45 s often fires before OS routing has switched.
      if (state != SspLivenessKind.roaming ||
          _lastRoamEmitAt == null ||
          now.difference(_lastRoamEmitAt!) >= kRoamRetryInterval) {
        state = SspLivenessKind.roaming;
        _lastRoamEmitAt = now;
        return SspLivenessEvent(
          SspLivenessKind.roaming,
          reason: 'no auth packet for ${gap.inSeconds}s',
        );
      }
    }
    if (gap > kGraceAfter && state == SspLivenessKind.healthy) {
      state = SspLivenessKind.gracePeriod;
      return SspLivenessEvent(
        SspLivenessKind.gracePeriod,
        reason: 'no auth packet for ${gap.inSeconds}s',
      );
    }
    return null;
  }

  void onPacket(DateTime now) {
    lastInbound = now;
    state = SspLivenessKind.healthy;
    _lastRoamEmitAt = null;
  }
}
