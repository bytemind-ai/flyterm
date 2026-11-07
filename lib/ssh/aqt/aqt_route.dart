// SPDX-License-Identifier: GPL-3.0-or-later
/// How an AQT session reaches its daemon.
///
/// - [direct]: QUIC over UDP straight to the daemon's port.
/// - [viaSsh]: QUIC over an SSH exec channel (`flyterm-server --relay`), for
///   when UDP is blocked. See `aqt_ssh_relay.dart`.
///
/// Probed once, on a server's first connection in this app run; persisted
/// per session so every reconnect / RESUME (including after a cold start)
/// takes the same route without probing again.
enum AqtRoute { direct, viaSsh }
