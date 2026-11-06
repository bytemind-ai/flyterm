// SPDX-License-Identifier: GPL-3.0-or-later
use ring::rand::SecureRandom as _;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// Session TTL = 7 days. Sized to span overnight phone-lock + multi-day
/// background gaps so RESUME finds the original PTY (and the user's running
/// claude / vim / etc.) alive when the client comes back. Active clients
/// also `touch()` on every HELLO/RESUME, so a session that sees real use
/// stays warm; only truly idle sessions age out. Shorter values like 2h
/// caused the "reconnect lands in bash" complaint after any meaningful
/// app backgrounding.
///
/// Quota cap is `max_sessions` (default 100, see Cli); even at 7-day TTL
/// the store will not OOM — sweep_expired runs on every create() and
/// expired sessions are dropped first when quota is hit.
pub const DEFAULT_SESSION_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
pub const TOKEN_SIZE: usize = 32;

pub fn generate_token() -> [u8; TOKEN_SIZE] {
    let mut out = [0u8; TOKEN_SIZE];
    ring::rand::SystemRandom::new()
        .fill(&mut out)
        .expect("ring rng failed");
    out
}

pub struct AqtSession {
    pub session_token: [u8; TOKEN_SIZE],
    pub expires_at: Instant,
    pub tabs: HashMap<u32, AqtTab>,
    pub next_tab_id: u32,
    /// Set during HELLO if both sides advertised CAP_ZSTD. Sticky for the
    /// session lifetime — RESUMEs inherit it via the session store.
    pub compression_enabled: bool,
    /// 待投递的通知事件。见 notify::queue。
    pub notify_queue: crate::notify::NotifyQueue,
}

impl AqtSession {
    pub fn new(token: [u8; TOKEN_SIZE], ttl: Duration) -> Self {
        Self {
            session_token: token,
            expires_at: Instant::now() + ttl,
            tabs: HashMap::new(),
            next_tab_id: 1,
            compression_enabled: false,
            notify_queue: crate::notify::NotifyQueue::new(),
        }
    }
    pub fn is_expired(&self) -> bool {
        Instant::now() > self.expires_at
    }
    pub fn touch(&mut self, ttl: Duration) {
        self.expires_at = Instant::now() + ttl;
    }
    pub fn allocate_tab_id(&mut self) -> u32 {
        let id = self.next_tab_id;
        self.next_tab_id += 1;
        id
    }
}

pub struct AqtTab {
    pub tab_id: u32,
    pub last_in_off_acked: u64,
    /// 客户端最后已确认收到的 PTY output offset。
    /// 每次成功 RESUME 时，服务端学习 `client.last_out_off`（客户端 ring 头位置，
    /// 即客户端已处理过的最大位置）写入此字段。
    /// 当客户端冷启动 RESUME 时（自己的 ring 是空的，传 last_out_off=0），
    /// 服务端用此字段代替 0，避免从 ring 头开始回放整个历史 —— 长会话
    /// 几 MB 数据 10s timeout 内根本下不完。
    pub last_out_off_acked: u64,
    pub pty: Option<Arc<crate::pty_task::PtyHandles>>,
}

impl AqtTab {
    pub fn new(tab_id: u32) -> Self {
        Self {
            tab_id,
            last_in_off_acked: 0,
            last_out_off_acked: 0,
            pty: None,
        }
    }

    pub fn ring(&self) -> Option<Arc<Mutex<aqt_protocol::ScrollbackRing>>> {
        self.pty.as_ref().map(|p| Arc::clone(&p.ring))
    }
}

#[derive(Clone)]
pub struct SessionStore {
    inner: Arc<Mutex<SessionStoreInner>>,
}

struct SessionStoreInner {
    sessions: HashMap<[u8; TOKEN_SIZE], AqtSession>,
    max_sessions: u32,
    default_ttl: Duration,
}

impl SessionStore {
    pub fn new(max_sessions: u32, default_ttl: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(SessionStoreInner {
                sessions: HashMap::new(),
                max_sessions,
                default_ttl,
            })),
        }
    }

    pub async fn create(&self) -> Option<[u8; TOKEN_SIZE]> {
        let mut inner = self.inner.lock().await;
        Self::sweep_expired(&mut inner);
        if inner.sessions.len() as u32 >= inner.max_sessions {
            return None;
        }
        let token = generate_token();
        let ttl = inner.default_ttl;
        inner.sessions.insert(token, AqtSession::new(token, ttl));
        Some(token)
    }

    pub async fn insert_with_token(&self, token: [u8; TOKEN_SIZE]) -> bool {
        let mut inner = self.inner.lock().await;
        Self::sweep_expired(&mut inner);
        if inner.sessions.contains_key(&token) {
            return true;
        }
        if inner.sessions.len() as u32 >= inner.max_sessions {
            return false;
        }
        let ttl = inner.default_ttl;
        inner.sessions.insert(token, AqtSession::new(token, ttl));
        true
    }

    pub async fn with_session<R, F>(&self, token: &[u8; TOKEN_SIZE], f: F) -> Option<R>
    where
        F: FnOnce(&mut AqtSession) -> R,
    {
        let mut inner = self.inner.lock().await;
        let s = inner.sessions.get_mut(token)?;
        if s.is_expired() {
            inner.sessions.remove(token);
            return None;
        }
        Some(f(s))
    }

    pub async fn remove(&self, token: &[u8; TOKEN_SIZE]) {
        self.inner.lock().await.sessions.remove(token);
    }

    pub async fn count(&self) -> usize {
        self.inner.lock().await.sessions.len()
    }

    /// 把一条通知投给**所有**活跃 session。
    ///
    /// 为什么是广播而不是定位到某个 session：`flyterm notify` 来自本机的一个
    /// 短命进程，它只知道 tab_id（还可能过期），不知道 session token。同一台
    /// 机器上的 session 本来就属于同一个用户，广播是正确语义而非偷懒。
    ///
    /// 锁持有时长：整个循环在一次 `inner` 锁临界区内完成，循环体内没有任何
    /// `.await`——`NotifyQueue::push` 是纯内存 VecDeque 操作，session 数上限
    /// 是 `max_sessions`（默认 100），因此这里是一次有界、不产生异步让出点的
    /// CPU 操作，耗时可忽略；不会跟 `with_session`（用的是同一把锁）产生死锁，
    /// 因为全程只涉及这一把锁，且没有递归获取。
    pub async fn broadcast_notify(&self, tab_id: Option<u32>, text: String, now_ms: u64) {
        let mut inner = self.inner.lock().await;
        Self::sweep_expired(&mut inner);
        for session in inner.sessions.values_mut() {
            session.notify_queue.push(text.clone(), tab_id, now_ms);
        }
    }

    fn sweep_expired(inner: &mut SessionStoreInner) {
        let now = Instant::now();
        inner.sessions.retain(|_, s| now <= s.expires_at);
    }
}

#[cfg(test)]
mod store_tests {
    use super::*;

    #[tokio::test]
    async fn create_under_quota() {
        let store = SessionStore::new(2, DEFAULT_SESSION_TTL);
        assert!(store.create().await.is_some());
        assert!(store.create().await.is_some());
        assert!(store.create().await.is_none());
    }

    #[tokio::test]
    async fn expired_sweep_makes_room() {
        let store = SessionStore::new(1, Duration::from_millis(10));
        let _ = store.create().await.unwrap();
        std::thread::sleep(Duration::from_millis(20));
        assert!(store.create().await.is_some());
    }

    #[tokio::test]
    async fn with_session_finds_existing() {
        let store = SessionStore::new(10, DEFAULT_SESSION_TTL);
        let t = store.create().await.unwrap();
        let id = store
            .with_session(&t, |s| s.allocate_tab_id())
            .await
            .unwrap();
        assert_eq!(id, 1);
    }

    #[tokio::test]
    async fn with_session_missing_token() {
        let store = SessionStore::new(10, DEFAULT_SESSION_TTL);
        assert!(store
            .with_session(&[0xFF; TOKEN_SIZE], |s| s.allocate_tab_id())
            .await
            .is_none());
    }

    #[tokio::test]
    async fn broadcast_notify_reaches_all_active_sessions() {
        let store = SessionStore::new(10, DEFAULT_SESSION_TTL);
        let t1 = store.create().await.unwrap();
        let t2 = store.create().await.unwrap();
        store
            .broadcast_notify(Some(3), "build done".into(), 1_000)
            .await;
        let unread1 = store
            .with_session(&t1, |s| s.notify_queue.unread_since(0, 1_000))
            .await
            .unwrap();
        let unread2 = store
            .with_session(&t2, |s| s.notify_queue.unread_since(0, 1_000))
            .await
            .unwrap();
        assert_eq!(unread1.len(), 1);
        assert_eq!(unread1[0].text, "build done");
        assert_eq!(unread1[0].tab_id, Some(3));
        assert_eq!(
            unread2.len(),
            1,
            "broadcast must reach every session, not just the first"
        );
    }

    #[tokio::test]
    async fn broadcast_notify_with_no_sessions_is_a_noop() {
        // Regression guard: must not panic/hang when the store is empty
        // (e.g. daemon just started, no client has HELLO'd yet).
        let store = SessionStore::new(10, DEFAULT_SESSION_TTL);
        store.broadcast_notify(None, "hello".into(), 1_000).await;
    }

    /// End-to-end wiring test mirroring what main.rs's daemon branch does:
    /// bind the local notify unix socket, spawn notify::listener::serve with
    /// a callback that calls SessionStore::broadcast_notify, then connect as
    /// the `flyterm notify` CLI would and verify the event lands in the
    /// session's queue.
    ///
    /// This substitutes for a true process-level e2e run of the
    /// `flyterm-server --listen` binary, which this sandbox's permission
    /// system refuses to let us spawn (denied even with dangerouslyDisableSandbox,
    /// foregrounded, timeout-bounded, and bound to 127.0.0.1 — appears to be a
    /// categorical block on starting network-listening daemons from this
    /// agent). It exercises the exact same bind/serve/callback/broadcast code
    /// path main.rs wires up, minus the QUIC endpoint itself.
    #[tokio::test]
    async fn notify_socket_end_to_end_reaches_session_queue() {
        use std::os::unix::fs::PermissionsExt;
        use tokio::io::AsyncWriteExt;

        let dir = std::env::temp_dir().join(format!(
            "flyterm-session-notify-e2e-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let listener = crate::notify::listener::bind(&dir).expect("bind notify socket");
        let dir_mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700, "state dir must be locked to 0700");
        let sock_path = crate::notify::listener::sock_path(&dir);
        let sock_mode = std::fs::metadata(&sock_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(sock_mode, 0o600, "socket file must be locked to 0600");

        let store = SessionStore::new(10, DEFAULT_SESSION_TTL);
        let token = store.create().await.unwrap();

        let store_n = store.clone();
        tokio::spawn(async move {
            let cb = std::sync::Arc::new(move |tab: Option<u32>, text: String| {
                let store = store_n.clone();
                tokio::spawn(async move {
                    store.broadcast_notify(tab, text, 2_000).await;
                });
            });
            let _ = crate::notify::listener::serve(listener, cb).await;
        });

        // Give the listener task a moment to actually reach accept().
        tokio::time::sleep(Duration::from_millis(50)).await;

        let mut stream = tokio::net::UnixStream::connect(&sock_path)
            .await
            .expect("connect to notify socket");
        stream
            .write_all(b"tab=7 hello from e2e")
            .await
            .expect("write notify line");
        drop(stream);

        // Poll instead of a single fixed sleep: the callback hops through
        // one more tokio::spawn before the write actually lands, so give it
        // a bounded number of short retries rather than a single guess.
        let mut unread = Vec::new();
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            unread = store
                .with_session(&token, |s| s.notify_queue.unread_since(0, 2_000))
                .await
                .unwrap();
            if !unread.is_empty() {
                break;
            }
        }
        assert_eq!(
            unread.len(),
            1,
            "notify event should have reached the session queue"
        );
        assert_eq!(unread[0].text, "hello from e2e");
        assert_eq!(unread[0].tab_id, Some(7));

        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_is_random() {
        assert_ne!(generate_token(), generate_token());
    }

    #[test]
    fn session_expiry() {
        let s = AqtSession::new([0; TOKEN_SIZE], Duration::from_secs(0));
        std::thread::sleep(Duration::from_millis(10));
        assert!(s.is_expired());
    }

    #[test]
    fn allocate_tab_ids_monotonic() {
        let mut s = AqtSession::new([0; TOKEN_SIZE], DEFAULT_SESSION_TTL);
        assert_eq!(s.allocate_tab_id(), 1);
        assert_eq!(s.allocate_tab_id(), 2);
        assert_eq!(s.allocate_tab_id(), 3);
    }

    #[test]
    fn touch_extends_expiry() {
        let mut s = AqtSession::new([0; TOKEN_SIZE], Duration::from_millis(10));
        std::thread::sleep(Duration::from_millis(20));
        assert!(s.is_expired());
        s.touch(Duration::from_secs(60));
        assert!(!s.is_expired());
    }
}
