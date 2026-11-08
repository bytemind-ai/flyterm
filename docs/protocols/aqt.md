# AQT — FlyTerm's QUIC terminal protocol

AQT ("AQ Transport") is a QUIC-based protocol between the FlyTerm app and a
small Rust daemon, `flyterm-server`, running on the remote host. It is the
default transport for a FlyTerm server record (`connection_strategy` defaults
to `'quic'`); SSH remains available and is still used to bootstrap AQT the
first time.

Three Rust crates and one Dart package make up the implementation:

```
rust/aqt_protocol/src/      sans-IO protocol layer — no I/O, no async runtime
  lib.rs                    PROTOCOL_VERSION, ALPN, CAP_* bits, re-exports
  frame.rs                  Opcode + every frame struct + Disposition
  codec.rs                  length-prefixed field helpers
  varint.rs                 varint encode/decode
  session.rs                Session, State, Event, InputReplayBuffer,
                            TabOffsetTracker, TabOffsets
  ring.rs                   ScrollbackRing
  lz4block.rs               LZ4 block framing
  error.rs                  DecodeError, ProtocolError

rust/flyterm-server/src/    the remote daemon
  main.rs                   once-mode / daemon-mode startup, signals
  cli.rs                    arg parsing, CongestionKind
  endpoint.rs               QUIC endpoint construction
  connection.rs             per-connection state, stream multiplexing
  session.rs                SessionStore, tokens, TTL
  pty_task.rs               PTY spawn, env scrubbing, scrollback
  snapshot.rs               idempotent screen/scrollback snapshot for RESUME
  tls.rs                    generate_ephemeral / load_or_generate_persistent
  bootstrap.rs              the AQT_* stdout lines and daemon.info parsing
  installer.rs              `--install` self-upgrade and orphan reaping
  notify/                   queue.rs, listener.rs, text.rs, mod.rs
  history/, file_handler.rs, audit.rs, persistent.rs, b64.rs, error.rs

rust/aqt_client_ffi/src/    the client, exposed to Dart over a C ABI
  ffi.rs                    every `extern "C"` entry point
  client.rs                 QUIC connect, SpkiPinVerifier, TLS session store
  runtime.rs                AsyncRuntime — tokio on a dedicated "aqt-rt" thread
  session.rs, handle.rs     session/tab handles, AqtEvent / AqtEventKind
  error.rs                  AqtError

lib/ssh/aqt/                the Dart side
  aqt_ffi.dart              dart:ffi bindings, PathStats
  aqt_transport.dart        AqtTransport — implements RemoteTransport
  aqt_transport_factory.dart connect / resume / install orchestration
  aqt_bootstrap.dart        SSH-side bootstrap, AqtServerNotInstalledException
  aqt_server_installer.dart  AqtServerInstaller — SFTP deploy + self-upgrade
  aqt_install_dialog.dart   showAqtInstallDialog, AqtInstallChoice
  aqt_session_state.dart    AqtSessionState(+Repository), FlutterAqtSecureStore
  session_resume_coordinator.dart, prewarm_pool.dart
  notify_dedup.dart, notify_seen_store.dart, notify_deep_link.dart
  conn/, file_transfer/
```

---

## 1. Why not plain SSH

SSH is still in the product and still used for bootstrap, host-key TOFU, SFTP
and orphan cleanup. AQT exists because three properties a phone needs are not
reachable over an SSH-over-TCP connection:

**Survival across a network change.** A TCP connection is pinned to a 4-tuple.
Every Wi-Fi→cellular switch, every tunnel exit, every NAT rebinding kills the
SSH session and with it the shell. QUIC identifies a connection by a connection
ID rather than an address, and AQT layers an explicit `Resume` frame on top:
`aqt_roam` / `aqt_rebind` migrate the path, and if that fails the client
reconnects and sends `Resume` with a stored session token and the tab ids it
wants back. `flyterm-server` holds the PTYs alive in its `SessionStore` across
the gap, so the shell — and the program running in it — never notices.

**Fast resume, including 0-RTT.** Reattaching costs a TCP handshake, an SSH
key exchange, userauth, and a channel open before the first byte of shell
output. AQT reuses rustls session tickets (`TLS_SESSION_STORE` in `client.rs`)
so a reconnect can be 0-RTT/0.5-RTT, and `main.dart` goes further: at cold
start it fires a RESUME for the last-active QUIC tab in the background, so by
the time the user reaches the terminal screen the transport is often already
connected.

**Congestion control FlyTerm can choose.** On TCP the algorithm belongs to the
remote kernel. With QUIC it is a `TransportConfig` setting, and `cli.rs` makes
it a flag (`CongestionKind::Cubic` / `CongestionKind::Bbr`) with the reasoning
written out in its doc comment. Loss-based CUBIC caps throughput around
`MSS / (RTT × √p)`; a measured field case (82 ms RTT, 1.1 % loss, 1200 B MTU)
predicted ≈139 KB/s against an observed 147 KB/s for a 268 KB resume snapshot.
Resume was not bandwidth-limited — CUBIC was reading mobile *random* loss as
congestion and cutting the window. BBR models bandwidth × RTT and does not, so
the option matters on exactly the networks phones live on.

Two smaller consequences fall out of QUIC's stream model: PTY output, file
transfer and notifications ride independent streams, so a large file upload
does not head-of-line block keystrokes the way it would inside one SSH channel;
and the server can push a `Notify` frame unprompted, which is what makes
lock-screen notifications from a long-running remote command possible.

The cost is honest and should be stated: AQT needs a binary on the host (§3)
and a reachable UDP port. When either is missing, FlyTerm falls back to SSH.

---

## 2. Wire format

### Framing

Control messages are length-prefixed frames on QUIC bidirectional streams.
There is no serde framework involved — `frame.rs` hand-writes `encode`/`decode`
per message behind the `FramePayload` trait. A frame is:

```
[ u8 opcode ] [ varint payload_len ] [ payload ]
```

Fixed-width fields use `bytes`' big-endian `put_u32` / `put_u64`; variable
fields are `varint(len)` followed by bytes or UTF-8 (`codec.rs`).

`Opcode` (`frame.rs`) is `#[repr(u8)]`:

| Group | Opcodes |
|---|---|
| Handshake | `Hello = 0x01`, `HelloAck = 0x02` |
| Tabs | `OpenTab = 0x10`, `OpenTabAck = 0x11`, `Resize = 0x12`, `Signal = 0x13`, `CloseTab = 0x14` |
| Resume | `Resume = 0x20`, `ResumeAck = 0x21` |
| Files | `OpenFile = 0x30`, `OpenFileAck = 0x31`, `FileProgress = 0x32`, `FileDone = 0x33` |
| History | `ListHistory = 0x40`, `ListHistoryResp = 0x41`, `HistoryPreloadDone = 0x42` |
| Notify | `Notify = 0x50`, `NotifyAck = 0x51` |

`0x60` and `0x61` are **permanently retired**. They were `FetchScrollback` /
`ScrollbackChunk`; history now travels inside the RESUME payload. Leaving the
numbers vacant makes a stale client fail loudly at `Opcode::from_u8` with
`UnknownOpcode` instead of parsing a different frame.

PTY data does not use frames. Each tab gets its own stream, and terminal bytes
flow raw.

### Version and ALPN

```rust
pub const PROTOCOL_VERSION: u8 = 2;
pub const ALPN: &[u8] = b"aqt/2";
```

**These must be bumped together**, and the reason is worth internalising
because it is a silent-corruption bug, not a connection failure.
`Disposition`'s wire form is positional — consecutive `put_u64` calls with no
tags. A v1 server emits one extra `u64` after the `Restored` discriminant; a v2
client reads it as `server_in_seen_off`, and every field after it
(`compression_enabled`, `session_ttl_secs`) shifts. Nothing errors.

`PROTOCOL_VERSION` alone cannot stop this: the version check lives in the
`Hello` branch in `connection.rs`, and the `Resume` frame carries no version
field. The prewarm path RESUMEs straight from a persisted token without going
through SSH bootstrap at all, so no version comparison ever happens on it.
ALPN is the only gate that applies to *every* connection and fires before any
frame is exchanged: a mismatch fails the QUIC handshake, the client treats it
as "path not up", and eventually falls back to SSH bootstrap — where
`_serverVersionSufficient` in `aqt_transport_factory.dart` compares versions
and upgrades the remote binary.

### Capabilities

Negotiated as a bitmask in `Hello.capabilities` / `HelloAck`:

- `CAP_ZSTD = 0x01` — deprecated, kept only so the bit is never reused.
- `CAP_LZ4 = 0x02` — when both sides set it, every server→client PTY stream is
  LZ4-block compressed as `[u32 BE frame_len][lz4_flex block]`. Input is *not*
  compressed; keystroke volume does not justify the CPU.

---

## 3. Deployment: a static binary shipped inside the APK

AQT needs code on the host. FlyTerm refuses to make that a package-manager
problem.

### The asset

`scripts/build-server-assets.sh` cross-compiles `flyterm-server` as a **musl
static binary** for `x86_64-unknown-linux-musl` and
`aarch64-unknown-linux-musl`, gzips each, and drops them into
`assets/flyterm-server/` alongside a `VERSION` file. `pubspec.yaml` declares
that directory as an asset, so the binaries ride inside the APK. The binaries
themselves are **not committed** — `.gitignore` excludes
`assets/flyterm-server/flyterm-server-linux-*` and
`assets/flyterm-server/VERSION`; the script regenerates them and smart-skips
when the bundled artefacts already match the current source, so Gradle can call
it on every build.

Static musl linking is the whole point: no glibc version to match, no runtime
dependency, no root. The binary lands in the user's home directory and runs as
the user.

### First connection

1. `AqtTransportFactory.connectWithCredentials` opens SSH as usual, then calls
   into `aqt_bootstrap.dart` to start the server:
   - **Once mode** (`Server.useDaemon == false`) — exec the binary, which
     prints its bootstrap lines on stdout
     (`AQT_VER` / `AQT_PORT` / `AQT_PUBKEY` / `AQT_TOKEN`) and lives for the
     duration of the SSH exec.
   - **Daemon mode** — probe `flyterm-server --status` first; if nothing is
     running, spawn with `setsid nohup "$BIN" --listen <ports> … & disown` and poll
     `~/.flyterm-server/state/` for `daemon.info` on a real 5-second wall-clock
     deadline. `setsid` is required, not decorative: on hosts with
     systemd-logind `KillUserProcesses=yes` (the Debian/Ubuntu default) the
     whole SSH session cgroup is killed on channel close, and `nohup` alone
     does not escape it. The spawn command also `unset`s
     `TMUX`/`TMUX_PANE`/`TERM_PROGRAM*`, because an SSH exec runs under the
     login shell and may inherit tmux variables that make TUIs render in
     tmux-compatibility mode under a PTY that no tmux wraps.
     `<ports>` is the server record's UDP port range (`Server.aqtPorts`,
     default `61001-61999`), so users can open it in a firewall ahead of
     time; flyterm-server binds a free port in it, starting from a random
     offset so several users' daemons on one host spread out. Binaries too
     old to parse a range (their `--help` lacks `START-END`) get `--listen 0`.
     A daemon already running outside the range is only restarted after the
     user confirms, since that ends every AQT session on the host.
   - If `daemon.info` never appears, `AqtDaemonStartFailedException` carries
     the tail of `daemon.log` so the error names the cause.
2. If the binary is not on `PATH` and not at
   `$HOME/.flyterm-server/bin/flyterm-server`, bootstrap throws
   **`AqtServerNotInstalledException`** (`aqt_bootstrap.dart`).
3. The factory catches it and runs `AqtTransportFactory.runInstallFlow`:
   - `AqtServerInstaller.detectArch(client)` — returns `null` for anything that
     is not x86_64 or aarch64 Linux, and the flow aborts **before** showing a
     dialog the user could not act on.
   - `AqtServerInstaller.loadBinaryAsset(arch)` reads
     `assets/flyterm-server/flyterm-server-linux-<arch>.gz` from the bundle, so
     the dialog can state the exact download size.
   - `showAqtInstallDialog(...)` asks for consent and returns an
     `AqtInstallChoice` (`install` / `postpone`). Installation is never
     silent on the first-deploy path.
   - `AqtServerInstaller.uploadBinary` SFTPs the gzip to
     `$HOME/.flyterm-server/bin/flyterm-server.tmp.gz`, gunzips it remotely,
     `chmod 755`, and `mv`s it onto `$HOME/.flyterm-server/bin/flyterm-server`
     — same filesystem, so the final step is atomic. The version, architecture
     and timestamp are appended to `~/.flyterm-server/install.log`.
     `kRemoteServerBin` names the canonical path.
   - `AqtServerInstaller.verifyInstall` runs `--version` and requires exit 0.
   - Bootstrap is then retried exactly once; a second
     `AqtServerNotInstalledException` propagates.
4. Declining, or any failure, re-throws `AqtServerNotInstalledException`.
   `classifyConnectError` (`lib/ssh/session_manager.dart`) maps it to
   `ErrCategory.notInstalled` so the UI can say so. There is **no silent SSH
   fallback** on this path — a user who said "later" gets an explicit error, not
   a mystery downgrade.

Upgrades reuse the same machinery with `silent: true`, plus
`AqtServerInstaller.uploadAndSelfInstall` and the server's own `--install`
subcommand (`installer.rs`), which replaces the binary atomically and reaps
daemons still executing the old inode (`reapable_pids` only considers processes
whose `/proc/<pid>/exe` resolves to the canonical path, tolerating the
`" (deleted)"` suffix, and never touches a process it cannot read).

Uninstalling is `rm -rf ~/.flyterm-server`.

---

## 4. Session model and RESUME

`Hello` carries `{version: u8, client_id: [u8; 16], capabilities: u32}`;
`HelloAck` returns a `session_token: [u8; 32]`. Tabs are `u32` ids within a
session.

On the client, `AqtSessionState` + `AqtSessionStateRepository`
(`aqt_session_state.dart`) are the single entry point for persisting that
state — deliberately so, because the fields are split across two stores: the
32-byte `sessionToken` goes to secure storage via `FlutterAqtSecureStore`
(Keychain / Keystore), while `port`, `spki` and `aqtTabId` go to the
`aqt_session_state` SQLite table as non-sensitive protocol metadata. Having one
repository over two backends is what stops "updated one store, forgot the
other" half-writes.

### SPKI pinning

The daemon's TLS material comes from `tls.rs`:
`load_or_generate_persistent(state_dir)` for daemon mode (a stable keypair, so
`daemon.info` can advertise a stable SPKI) and `generate_ephemeral()` for once
mode. The SPKI is handed to the app in the `AQT_PUBKEY` bootstrap line over the
already-authenticated SSH channel.

On the client, `SpkiPinVerifier` (`client.rs`) is a `rustls`
`ServerCertVerifier` that compares the end-entity certificate's SPKI against
the pinned bytes and returns `ServerCertVerified::assertion()` only on an exact
match, otherwise `rustls::Error::General("SPKI mismatch")`. There is no CA, no
hostname validation, and no trust store — SSH already proved who the host is,
and the pin carries that proof into QUIC. A daemon restart that regenerates its
certificate shows up as `AqtResumeFailReason.handshakeFailed`, which
`main.dart` treats as "credentials are dead" and deletes the stored state.

### Resume

```rust
Resume { session_token: [u8; 32], tabs: Vec<u32> }
```

The frame is deliberately **idempotent and offset-free**. The client names the
tabs it wants; the server answers per tab with an explicit `Disposition`:

- `Restored { server_in_seen_off: u64 }` — session and PTY are alive.
- `NewSession` — token expired or unknown; the client resets the terminal.
- `TabGone { exit_status: Option<i32> }` — the process exited; show the status,
  do **not** reset the terminal.

Earlier versions carried client-side output offsets (`last_out_off` and
friends) in this frame. They were removed, and `Disposition`'s doc comment
explains why: those values described *client* state ("how far have I read"),
six different call sites each computed one, none was authoritative, and a
single tab could have three generations of the value in flight at once. That is
not fixable by being careful — the field had to go.

`server_in_seen_off` survives because it is the opposite kind of value: it is
*server* state ("how many input bytes I actually received"), there is exactly
one authority for it, and the client uses it to replay the keystrokes that were
in flight when the link dropped, from `InputReplayBuffer`.

### Screen replay

The restored screen is **not** in `ResumeAck`. `snapshot.rs` builds an
idempotent reconstruction — a hard reset, safe-default DEC private modes, then
the scrollback and visible screen rendered row by row — and it is written as
the *first bytes of the new PTY stream*. The client needs no special handling:
the bytes flow into the emulator exactly like live output, on the same ordered
stream.

Two details are load-bearing. Each row is emitted with an explicit attribute
reset before it, because the row formatter assumes every line starts from
default attributes and only emits SGR on deviation — concatenating rows without
the reset bleeds an inverse-video line's attributes into the next one. And the
history budget applies only to primary scrollback (oldest dropped first); the
visible screen and the alternate-screen snapshot are always sent in full,
because they *are* the current state.

A previous design put a `screen: Vec<u8>` field (up to 256 KiB) in the control
frame. That forced the client to buffer a whole frame before decoding, copy it
twice across the FFI boundary, and write it in one go. Moving it to the stream
removed all three problems.

`ScrollbackRing` (`ring.rs`) is the bounded buffer behind this, and it tracks
alternate-screen state (`is_alt_buffer()`, matching the `ESC[?1049` prefix) so
a snapshot taken while a full-screen program is running restores correctly.

---

### SSH relay (when UDP is blocked)

When the daemon's UDP port is unreachable (only port 22 open, or the phone's
network drops UDP), AQT does not change protocol — it changes carrier. The
App opens an SSH exec channel running `flyterm-server --relay <daemon port>`
(`rust/flyterm-server/src/relay.rs`) and a local UDP socket on 127.0.0.1
(`AqtSshRelay`, `lib/ssh/aqt/aqt_ssh_relay.dart`); the QUIC client dials the
local socket and every datagram crosses the channel as one frame, `u16
big-endian length + packet`. The relay is stateless and exits when the
channel closes, so TLS/SPKI pinning, streams, RESUME and Notify all run end
to end and the daemon simply sees a 127.0.0.1 peer.

- **Route.** `AqtRoute.direct | viaSsh`. On a server's first connection both
  routes race: direct starts first, the relay joins after 300 ms (at once if
  the cache says this server last used the relay), first success wins and the
  loser is closed; `Server.aqtViaSsh` goes straight to the relay. The route is
  cached per server for the run (`AqtRouteCache`), persisted per session
  (`aqt_session_state.via_ssh`), and can change *during* a session (below).
- **Ports.** The persisted port is always the daemon's; the relay's local port
  only lives as long as its transport (`AqtTransport.attachRelay`).
- **RESUME** of a relayed session first opens a relay (8 s, outside the RESUME
  budget) over the tab's auxiliary SSH connection, or over the reconnect
  path's own SSH client; failure falls back to a full reconnect. A direct
  RESUME that fails with a network-class error (`networkTimeout`,
  `unknownError`) is retried once over the relay with its own budget;
  `sessionNotFound` and `handshakeFailed` do not change route.
- **Cost.** QUIC over TCP has head-of-line blocking on lossy links.

#### Seamless path switching

The client never gives QUIC a real peer address. `RoutedSocket`
(`rust/aqt_client_ffi/src/routed_socket.rs`, a quinn `AsyncUdpSocket`) wraps
the real UDP socket (still bound `0.0.0.0:0`) and presents the fixed virtual
peer `127.0.0.2:<daemonPort>`: outgoing packets to the virtual peer are
rewritten to the current target, and incoming packets from the current or
previous target are rewritten to come from the virtual peer (others are
dropped; keeping `previous` saves in-flight packets at the switch). SNI and
what the server sees are unchanged.

Switching route is therefore just changing the target: the server sees a
standard QUIC connection migration (RFC 9000 section 9), so the session
survives with no RESUME. Only the daemon's address is ever persisted; the
virtual peer is internal (the debug overlay shows the real host and route).

FFI (`lib/ssh/aqt/aqt_ffi.dart`, exported in `ios/Runner/aqt_exports.exports`):

- `aqt_set_path(handle, ip, port)` sets the target and sends a 1-byte
  datagram to wake the new path. 0 on success, negative on error.
- `aqt_probe_direct(host, port, spki, spki_len, timeout_ms)` does a throwaway
  SPKI-verified QUIC handshake on a temporary endpoint and closes it without
  HELLO. `aqt_probe_result` reads the outcome: 1 reachable, 0 unreachable or
  timed out, negative error. It never touches the live session.

Driven by `AqtPathController` (`lib/ssh/aqt/aqt_path_controller.dart`, one per
session) and `conn_machine`:

- **Direct to relay.** Inbound silence beyond 6 s (3 s when a blind gap is
  known) emits `StartPathSwitch`. The controller opens a relay (8 s budget); if
  packets resume meanwhile it aborts. On success it calls `aqt_set_path` to
  `127.0.0.1:<relay port>`. While a switch is in flight, death detection is
  deferred up to `kPathSwitchBudgetMs` = 12 s, after which the normal
  recovering flow takes over.
- **Relay to direct.** Foreground only, one probe at a time: immediately on
  network change, otherwise every 60 s, backing off to 120 s then 300 s on
  failure (reset on network change or successful switch). After a successful
  probe the target is set to the daemon; if no packet arrives within 2 s the
  controller switches back to the relay and counts a failed probe.
- **Network change.** On direct, `aqt_rebind` as before. On the relay, the
  SSH carrier dies, so a direct probe and a relay rebuild race and the first
  success wins. A relay that drops by itself is rebuilt (plus a probe).
- Each direction fires at most once per live period to avoid flapping. No
  switching in the background or when `aqtViaSsh` is set.

- **Known limitation.** The daemon sees every relayed peer as 127.0.0.1, so
  the (off-by-default) history feature's per-IP session key lumps relayed
  devices together.

---

## 5. Notifications and the offline window

A command on the remote host can call `flyterm notify <text>`. In daemon mode,
`notify/listener.rs` accepts that on a Unix socket (`pty_task.rs` injects
`FLYTERM_NOTIFY_SOCK` and `FLYTERM_TAB_ID` into every PTY's environment, and
only when the daemon actually has a listener). Once mode has no persistent
socket and skips the binding.

**Server side.** `notify/queue.rs` holds a `NotifyQueue` per session:

```rust
pub const MAX_QUEUED_EVENTS: usize = 50;
pub const EVENT_TTL_MS: u64 = 24 * 3600 * 1000;
```

Events get a per-session `event_id` from a counter starting at 0. The queue
holds them until the client acks (`NotifyAck` / `aqt_notify_ack`), evicting
the oldest past 50 entries or 24 hours. That is the **offline redelivery
window**: a notification raised while the phone was off the network is still
delivered on reconnect, as long as it is within those bounds.
`notify/text.rs` sanitises the text (control characters stripped) before it
ever reaches a notification.

**Client side.** The client keeps its own window so a redelivered event is not
shown twice. `NotifyDedup` (`lib/ssh/aqt/notify_dedup.dart`) holds the last
`kWindow = 200` seen event ids, with `shouldShow`, `remember` (which trims to
the cap on every write, even if the incoming list was already over) and
`shouldSuppressSystemNotification` (used by `NotifyOrchestrator` to keep a
system notification from firing for a tab that is visible on screen).

`NotifySeenStore` (`notify_seen_store.dart`) persists that 200-entry list in
`shared_preferences` under `notify_seen_<tabId>` — not secure storage, because
a list of integers is not a credential.

Two scoping rules are mandatory and both have bitten before:

- **The key is per *tab*, not per server.** `event_id` is only unique inside
  one QUIC session, and each tab opens its own `AqtTransport.connect()`, hence
  its own session, hence its own counter starting at 0. Merging two tabs of the
  same host into one `seen` list makes the newer tab's genuinely-new
  notifications collide with ids the older tab already recorded — they are
  dropped permanently, the server never learns, and nothing surfaces until the
  TTL or the 50-event cap pushes them out. Opening two tabs on a favourite
  server is an everyday action, not an edge case.
- **A fresh `Hello` must `clear()` that tab's store first.** If the server-side
  session restarted from zero, its small event ids will collide with the
  previous generation's remembered ids and be swallowed. The handshake layer
  knows whether this was a resume or a new session and is responsible for the
  reset.

`NotifyOrchestrator` (`lib/ui/notifications/notify_orchestrator.dart`) ties it
together: `load` → `shouldShow` → `shouldSuppressSystemNotification` →
display → `remember` → `save`. Agent approval prompts deliberately do **not**
use this machinery — they have no offline-redelivery semantics (the loop dies
with the process), so `AgentSessionManager` dedupes with an in-memory `Set`.

---

## 6. The FFI boundary

Dart does not speak QUIC. `aqt_client_ffi` is a `cdylib` wrapping `quinn` +
`rustls` behind a C ABI; `lib/ssh/aqt/aqt_ffi.dart` is the Dart side.

### Loading and binding

`DynamicLibrary.open('libaqt_client_ffi.so')` on Android,
`DynamicLibrary.process()` on iOS (statically linked into the app binary).
Bindings are **hand-written** in `aqt_ffi.dart` — native/Dart typedef pairs
plus `lookup<NativeFunction<...>>(...).asFunction()`. There is no `ffigen` step
and no generated bindings file, so a signature change in `ffi.rs` must be
mirrored by hand. Nothing checks this at compile time; it is the sharpest edge
in the whole subsystem.

### Surface

All entry points are `pub unsafe extern "C"` in `ffi.rs`:

| Area | Functions |
|---|---|
| Lifecycle | `aqt_connect`, `aqt_resume`, `aqt_close`, `aqt_state` |
| Events | `aqt_poll_event` |
| Tabs | `aqt_open_tab`, `aqt_open_tab_v2`, `aqt_write_pty`, `aqt_resize_tab` |
| Liveness / paths | `aqt_heartbeat`, `aqt_roam`, `aqt_rebind`, `aqt_set_foreground`, `aqt_get_path_stats`, `aqt_get_last_recv_age_ms` |
| Notify | `aqt_notify_ack` |
| Files | `aqt_file_upload_start`, `aqt_file_download_start`, `aqt_file_cancel` |
| Resume results | `aqt_get_session_token`, `aqt_get_resume_disposition`, `aqt_get_resume_ttl_secs`, `aqt_get_resume_prelude_len`, `aqt_get_resume_in_seen_off`, `aqt_get_resume_exit_status` |

Connection parameters arrive as a `#[repr(C)] AqtConnectParams`
(`host: *const c_char`, `port: u16`, `spki_ptr`/`spki_len`, `token_ptr`,
`sni`).

### Threading

`runtime.rs` spins up **one** thread named `aqt-rt` running a
`new_current_thread` tokio runtime. FFI calls do not run async code on the
calling thread; they push a `BoxedFn` closure down an unbounded mpsc channel
and the runtime thread executes it with a `Handle`. The receive loop uses
`rx.recv().await` rather than a blocking `std::sync::mpsc::recv()` precisely so
the tokio event loop gets to run spawned tasks between dispatches — a blocking
receive starves every `rt.spawn` on that runtime.

### Events: polling, not callbacks

There are no callbacks across the boundary. Rust queues `AqtEvent`s
(`handle.rs`, tagged by `AqtEventKind`) and Dart drains them with
`aqt_poll_event`. This is intentional: invoking a Dart callback from an
arbitrary native thread requires the `Dart_PostCObject` / `NativePort`
machinery and an isolate the callback is bound to, and gets fragile the moment
a hot-restart tears that isolate down. A poll loop has one owner and one
lifetime.

### Memory ownership

- Strings cross as null-terminated `Pointer<Utf8>`; Rust borrows them with
  `CStr::from_ptr` and never frees them. Dart allocates and frees.
- Buffers cross as `Pointer<Uint8>` plus an explicit length; Rust views them
  with `slice::from_raw_parts` for the duration of the call only.
- The connection handle is an opaque `*mut c_void` returned by `aqt_connect`
  and passed back to every other function. Rust owns the `Arc` behind it;
  `aqt_close` drops it. Using a handle after `aqt_close` is undefined — Dart
  must null its reference at the same moment.
- Out-parameters (`aqt_get_session_token`, `aqt_get_resume_prelude_len`, …)
  write into caller-allocated memory. Nothing allocated in Rust is handed to
  Dart to free, so there is no cross-allocator free anywhere in the ABI.

`aqt_protocol` is `#![forbid(unsafe_code)]`; all `unsafe` is confined to
`aqt_client_ffi::ffi`.
