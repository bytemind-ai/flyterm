# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Open-sourced under GPL-3.0-or-later.
- CI gate on pull requests: analyze, dual test run, Android build.
- `-PallowDebugSigning` so the project builds without release credentials.
- `docs/ARCHITECTURE.md` as the single source of truth for the layering,
  provider wiring, route table and the non-obvious design constraints.
- `docs/protocols/ssp-v2.md` and `docs/protocols/aqt.md` describing the Mosh
  and QUIC implementations.

### Changed
- Builds from source are now fully unlocked. The in-app-purchase path is opt-in
  via `--dart-define=FLYTERM_ENABLE_IAP=true` and is used only for store builds.
- Building the Rust components now requires Rust 1.99 (pinned in
  `rust/rust-toolchain.toml`; rustup fetches it automatically).

### Security
- QUIC transport upgraded to quinn 0.11 / rustls 0.23 (ring backend). Fixes
  remotely triggerable denial-of-service and memory-exhaustion issues in
  flyterm-server's UDP endpoint (RUSTSEC-2026-0037, -0185, -0338, -0339,
  -0342) and TLS secrets exposed through `Debug` output (RUSTSEC-2026-0346).
  Also fixed along the way: RUSTSEC-2025-0009 (ring), RUSTSEC-2026-0349
  (rustls), RUSTSEC-2026-0190 (anyhow), RUSTSEC-2026-0009 (time) and
  RUSTSEC-2026-0386 (tokio).
  **Update flyterm-server on your hosts.** Old and new App/server versions
  were verified to connect and run a terminal session with each other;
  session resume across versions has not been verified on a device yet.
- Dropped *ring* 0.16, whose OpenSSL/SSLeay-licensed code was incompatible
  with the GPL.

## [2.3.7] - 2026-10

### Fixed
- Backspace held down produced no repeat under some IMEs; the app now
  synthesises the repeat itself.
- A second focus ring appeared around the key-bar sequence editor.
- SFTP opened a bare channel per `sftpOpsFromClient` call, exhausting the
  server's `MaxSessions`.
- The agent's speculative-execution check compared commands by value where it
  meant identity, so every speculatively-started command ran twice on the
  remote host.
- `scripts/build_apk.sh --help` was truncated and hid the second half of its
  own documentation.

### Added
- `@file` completion now runs against a background directory index.
- `/` commands can be triggered mid-message.

### Removed
- Scheduled tasks. The feature's four agent tools, settings screens, route and
  localisation strings are gone, and database migration v43 drops its three
  tables.
