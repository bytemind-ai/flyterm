// SPDX-License-Identifier: GPL-3.0-or-later
/// Transport protocol selected by user in Server form.
///
/// QUIC is strict — connection failure surfaces as an error, no silent
/// fallback to SSH. Users who want SSH must explicitly set `transport=ssh`.
enum Transport {
  /// SSH only — broadest compatibility.
  ssh,

  /// SSH bootstrap + Mosh UDP — good for flaky / mobile networks.
  mosh,

  /// QUIC — low latency + network roaming. Strict: no fallback on failure.
  quic,
}
