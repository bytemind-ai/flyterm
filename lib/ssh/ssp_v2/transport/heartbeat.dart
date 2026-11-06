// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::Connection::SEND_INTERVAL_MIN/MAX, ACK_INTERVAL in
// src/network/network.cc
class Heartbeat {
  static const Duration kSendIntervalMin = Duration(milliseconds: 20);
  static const Duration kSendIntervalMax = Duration(milliseconds: 250);
  static const Duration kAckInterval = Duration(milliseconds: 3000);

  Duration currentInterval = kSendIntervalMin;

  /// Track smoothed RTT and grow the send interval up to half of it,
  /// clamped to [SEND_INTERVAL_MIN, SEND_INTERVAL_MAX].
  void updateSrtt(Duration srtt) {
    final candidate = srtt ~/ 2;
    if (candidate < kSendIntervalMin) {
      currentInterval = kSendIntervalMin;
    } else if (candidate > kSendIntervalMax) {
      currentInterval = kSendIntervalMax;
    } else {
      currentInterval = candidate;
    }
  }
}
