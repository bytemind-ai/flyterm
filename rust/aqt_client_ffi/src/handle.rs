// SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex, RwLock};

pub struct AqtEvent {
    pub kind: AqtEventKind,
    pub tab_id: u32,
    /// For Notify (kind=8): the self-describing binary payload produced by
    /// `ffi::encode_notify_payload` — see that function's doc comment for
    /// the exact byte layout (event_id/ts_unix_ms/tab_id-or-sentinel/text).
    /// Packed into the existing generic `data` buffer (same idiom as
    /// HistoryPreloadDone's `preloaded_bytes`, below) rather than adding one
    /// dedicated struct field per Notify sub-value, and rather than
    /// widening `aqt_poll_event`'s C ABI with new out-params — both would
    /// need to ripple through every event kind's call sites for a payload
    /// only one kind uses.
    pub data: Vec<u8>,
    /// For HistoryPreloadDone: total bytes replayed from history.
    pub preloaded_bytes: u64,
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AqtEventKind {
    Connected = 0,
    Disconnected = 1,
    Failed = 2,
    PtyOutput = 3,
    TabOpened = 4,
    TabClosed = 5,
    HistoryPreloadDone = 6,
    TicketReceived = 7,
    /// Server-pushed self-hosted-notification event, delivered over its own
    /// dedicated QUIC uni stream (Route B — see ffi.rs's
    /// `notify_accept_loop`/connection.rs's `spawn_notify_push_task`).
    Notify = 8,
    // 9 曾是 ScrollbackChunk（FetchScrollback 的响应）。整条通道随
    // PROTOCOL_VERSION 2 删除，**不要复用这个编号** —— Dart 侧按整数值
    // 分派，复用会让旧 .so 的事件被解成新语义。
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnState {
    Connecting = 0,
    Connected = 1,
    Reconnecting = 2,
    Closed = 3,
    Failed = 4,
}

pub struct TabHandle {
    /// Send PTY input to the forwarding task which writes to the QUIC PTY stream.
    pub pty_tx: mpsc::Sender<Vec<u8>>,
}

pub struct SessionHandle {
    /// Events from Rust → Dart poll
    pub event_rx: Mutex<mpsc::UnboundedReceiver<AqtEvent>>,
    pub event_tx: mpsc::UnboundedSender<AqtEvent>,
    pub conn_state: Arc<Mutex<ConnState>>,
    /// Quinn Endpoint that produced the connection. Held so `aqt_rebind`
    /// can call `endpoint.rebind(new_socket)` for true RFC 9000 §9
    /// connection migration on positively-identified network interface
    /// change (Wi-Fi ↔ cellular). Dropping this would tear down the I/O
    /// driver and kill the connection.
    pub endpoint: Arc<RwLock<Option<quinn::Endpoint>>>,
    /// Routed UDP socket under `endpoint` (real-destination switching).
    pub routed: std::sync::Mutex<Option<Arc<crate::routed_socket::RoutedSocket>>>,
    /// Active QUIC connection (set after QUIC handshake completes)
    pub conn: Arc<RwLock<Option<quinn::Connection>>>,
    /// Write half of the control stream (set after HELLO handshake)
    pub ctrl_tx: Arc<Mutex<Option<quinn::SendStream>>>,
    /// Read half of the control stream (set after HELLO handshake)
    pub ctrl_rx: Arc<Mutex<Option<quinn::RecvStream>>>,
    /// Per-tab PTY input senders
    pub tabs: Arc<RwLock<HashMap<u32, TabHandle>>>,
    /// Session token from HELLO_ACK — used for 0-RTT RESUME on reconnect.
    pub session_token: tokio::sync::Mutex<Option<[u8; 32]>>,
    /// Negotiated at HELLO (or read from RESUME_ACK). True ⇒ every PTY recv
    /// stream is wrapped in an LZ4 block decoder before its bytes become PtyOutput
    /// events.
    pub compression_enabled: Mutex<bool>,
    /// 服务端在 RESUME_ACK 里下发的 session TTL（秒）。0 = 还没拿到。
    ///
    /// 客户端据此判会话过期。常量在两侧各写一份是「服务端 7 天 vs 客户端
    /// 110 分钟」那个 bug 的根源 —— 锁屏过夜后服务端会话还活着，客户端已经
    /// 把 token 删了。让服务端下发，两侧就不可能再漂移。
    pub last_resume_ttl_secs: std::sync::atomic::AtomicU64,
    /// 服务端在最近一次 RESUME_ACK 里下发的本 tab 快照字节数。0 有三种
    /// 成因，无法区分：旧服务端不发这个字段、非 Restored 处置（没开流、
    /// 没有快照）、以及还没 RESUME 过（本字段的初始值）。
    ///
    /// **只喂诊断**，见 `aqt_protocol::frame::ResumeAck::prelude_lens` 的
    /// 文档：客户端拿它算「快照流完了没有」这个时刻，不做任何分派。
    pub last_resume_prelude_len: std::sync::atomic::AtomicU64,
    /// Count of consecutive heartbeat send failures. Reset to 0 on success.
    /// Connection is closed only after reaching HB_CLOSE_THRESHOLD AND when
    /// app is in foreground. In background (Doze/sleep) the OS blocks network
    /// I/O entirely; heartbeat failure there is not evidence of a dead
    /// connection — just OS throttling. Closing would force an unnecessary
    /// RESUME + ring-buffer replay cycle that the user can't even see.
    pub hb_consecutive_failures: AtomicU32,
    /// Whether the app is in foreground. Set by aqt_set_foreground.
    /// In background, heartbeat send failures are NOT treated as connection
    /// death (would trigger needless reconnect cycles). Foreground transition
    /// runs an immediate heartbeat probe on the Dart side, which catches
    /// truly-dead connections when the user returns.
    pub is_foreground: AtomicBool,
    /// 最近一次 RESUME_ACK 里这个 handle 那个 tab 的处置。
    ///
    /// 这里曾经是 `last_resume_server_out_off` 与 `last_resume_replay_bytes`
    /// 两个原子量，Dart 侧读走后用 `server_out_off - replay_bytes` 的算术
    /// 反推「服务端是续传还是重建」。那个判据在服务端一改语义时就静默失效
    /// （d7dc3ef → e382759），是这次重新设计要消除的核心问题 —— 现在服务端
    /// 直接说，客户端不推断。
    ///
    /// `Option` + `Mutex` 而不是原子量，是因为 `Restored` 携带屏幕快照
    /// （几 KB 的 Vec）。取走即清空（take 语义）：同一次 RESUME 的快照只能
    /// 取一次，留着会让「重连时机不巧、把上一次的快照又灌一遍」变成可能。
    /// 那在幂等模型下不会损坏状态，但会把用户的屏幕拽回过去。
    pub last_resume_disposition: tokio::sync::Mutex<Option<aqt_protocol::Disposition>>,
    /// QUIC connection migration counter (debug overlay). Bumped each time
    /// the connection's remote_address() changes — i.e. the path 4-tuple
    /// changed from the client's POV. Currently incremented lazily by
    /// `aqt_get_path_stats` (compares current remote_address vs.
    /// `last_observed_addr`). 0 means "no migrations observed yet".
    pub migration_count: AtomicU32,
    /// NAT rebinding counter (sibling to `migration_count`). Currently
    /// always 0 — local-socket rebinding detection requires hooking the
    /// Endpoint's bind() path which we'll add in a follow-up. The field
    /// is reserved so the FFI struct layout doesn't shift.
    pub rebinding_count: AtomicU32,
    /// Last `Connection::remote_address()` observed by
    /// `aqt_get_path_stats`. Compared on each call to detect migrations.
    pub last_observed_addr: tokio::sync::Mutex<Option<std::net::SocketAddr>>,
    /// Monotonic millis (relative to handle's connect-time epoch) when quinn
    /// last observed an inbound packet on this connection. Updated lazily by
    /// a 1Hz background task that polls `conn.stats().udp_rx.bytes` —
    /// any increase bumps the timestamp to `monotonic_ms()`. Sentinel `0`
    /// means "no inbound observed yet". Read via `aqt_get_last_recv_age_ms`
    /// so the Dart foreground watchdog can detect silent path death within
    /// ~7s instead of the 15-30s quinn keep_alive cycle.
    pub last_recv_at_ms: AtomicU64,
}

impl SessionHandle {
    pub fn new() -> (Arc<Self>, mpsc::UnboundedSender<AqtEvent>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let tx2 = tx.clone();
        (
            Arc::new(Self {
                event_rx: Mutex::new(rx),
                event_tx: tx,
                conn_state: Arc::new(Mutex::new(ConnState::Connecting)),
                endpoint: Arc::new(RwLock::new(None)),
                routed: std::sync::Mutex::new(None),
                conn: Arc::new(RwLock::new(None)),
                ctrl_tx: Arc::new(Mutex::new(None)),
                ctrl_rx: Arc::new(Mutex::new(None)),
                tabs: Arc::new(RwLock::new(HashMap::new())),
                session_token: tokio::sync::Mutex::new(None),
                compression_enabled: Mutex::new(false),
                last_resume_ttl_secs: std::sync::atomic::AtomicU64::new(0),
                last_resume_prelude_len: std::sync::atomic::AtomicU64::new(0),
                hb_consecutive_failures: AtomicU32::new(0),
                is_foreground: AtomicBool::new(true), // assume foreground until set otherwise
                last_resume_disposition: tokio::sync::Mutex::new(None),
                migration_count: AtomicU32::new(0),
                rebinding_count: AtomicU32::new(0),
                last_observed_addr: tokio::sync::Mutex::new(None),
                last_recv_at_ms: AtomicU64::new(0),
            }),
            tx2,
        )
    }
}

/// Monotonic milliseconds since process start (single shared epoch via
/// OnceLock). Stable across system clock changes. Used by the 1Hz
/// recv_bytes poll in ffi.rs and by `aqt_get_last_recv_age_ms` —
/// both must agree on the epoch.
pub fn monotonic_ms() -> u64 {
    use std::sync::OnceLock;
    static EPOCH: OnceLock<std::time::Instant> = OnceLock::new();
    let e = EPOCH.get_or_init(std::time::Instant::now);
    e.elapsed().as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticket_received_kind_is_seven() {
        // ABI contract: TicketReceived must be 7 (next after HistoryPreloadDone=6).
        // Dart side (aqt_ffi.dart AqtEventKind) reads this u8 directly.
        assert_eq!(AqtEventKind::TicketReceived as u8, 7);
    }

    #[test]
    fn notify_kind_is_eight() {
        // ABI contract: Notify must be 8 (next after TicketReceived=7).
        // Dart side (aqt_ffi.dart AqtEventKind) reads this u8 directly.
        assert_eq!(AqtEventKind::Notify as u8, 8);
    }
}
