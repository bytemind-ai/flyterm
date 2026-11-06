// SPDX-License-Identifier: GPL-3.0-or-later
//! Protocol-level integration tests — no PTY required, run in standard CI.
//!
//! Covers:
//!   1. handshake_no_pty_hello_ack      — HELLO → HELLO_ACK at protocol level
//!   2. resume_invalid_token             — RESUME with bad token rejected
//!   3. resume_then_hello_fallback       — RESUME fails → HELLO succeeds (App flow)
//!   4. quota_not_exhausted_by_failed_resumes — failed RESUMEs don't consume quota
//!   5. notify_pushed_over_control_loop_and_not_redelivered_after_ack —
//!      control_loop's select!-driven 500ms notify push + NotifyAck cursor

use aqt_protocol::{
    decode_frame_header, encode_frame, Disposition, FramePayload, Hello, HelloAck, OpenTab,
    OpenTabAck, OpenTabStatus, Resume, ResumeAck, ALPN, PROTOCOL_VERSION,
};
// Notify/NotifyAck aren't re-exported at the aqt_protocol crate root (only
// aqt_protocol::frame::*) — same reason as connection.rs's import.
use aqt_protocol::frame::{Notify, NotifyAck};
use bytes::{Buf, BytesMut};
use quinn::{ClientConfig, Connection, Endpoint};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

// ── Test helpers ─────────────────────────────────────────────────────────────

/// Accepts any server, including any handshake signature: these tests
/// exercise the protocol, not TLS. Never use outside tests.
#[derive(Debug)]
struct SkipVerification;
impl rustls::client::danger::ServerCertVerifier for SkipVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn make_client_ep() -> Endpoint {
    let mut crypto = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .unwrap()
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(SkipVerification))
    .with_no_client_auth();
    crypto.alpn_protocols = vec![ALPN.to_vec()];
    let mut cfg = ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(crypto).unwrap(),
    ));
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    cfg.transport_config(Arc::new(transport));
    let mut ep = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    ep.set_default_client_config(cfg);
    ep
}

async fn read_frame<P: FramePayload>(rx: &mut quinn::RecvStream) -> anyhow::Result<P> {
    let mut buf = BytesMut::new();
    loop {
        let mut tmp = [0u8; 1024];
        let n = rx
            .read(&mut tmp)
            .await?
            .ok_or_else(|| anyhow::anyhow!("eof"))?;
        buf.extend_from_slice(&tmp[..n]);
        let mut peek: &[u8] = &buf;
        if let Ok((_op, len)) = decode_frame_header(&mut peek) {
            if peek.len() >= len {
                let hlen = buf.len() - peek.len();
                let _ = buf.split_to(hlen);
                let payload = buf.split_to(len);
                let mut p: &[u8] = &payload;
                return P::decode(&mut p).map_err(|e| anyhow::anyhow!("decode: {e:?}"));
            }
        }
    }
}

fn start_server(
    max_sessions: u32,
) -> (
    u16,
    Arc<tokio::sync::Notify>,
    flyterm_server::session::SessionStore,
) {
    let tls = flyterm_server::tls::generate_ephemeral().expect("ephemeral tls");
    let ep = flyterm_server::endpoint::build_endpoint(
        "127.0.0.1:0".parse().unwrap(),
        &tls,
        flyterm_server::cli::CongestionKind::Cubic,
    )
    .expect("build endpoint");
    let port = ep.local_addr.port();
    let shutdown = ep.shutdown.clone();
    let store = flyterm_server::session::SessionStore::new(
        max_sessions,
        flyterm_server::session::DEFAULT_SESSION_TTL,
    );
    let cfg = flyterm_server::connection::ConnectionConfig {
        ring_size_bytes: 64 * 1024,
        parser_scrollback_rows: 1000,
        max_tabs_per_session: 8,
        term: "xterm-256color".into(),
        allow_compression: false,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
    };
    let store_for_loop = store.clone();
    tokio::spawn(async move {
        let _ = flyterm_server::endpoint::accept_loop(ep, store_for_loop, cfg).await;
    });
    (port, shutdown, store)
}

// ── Test 1: HELLO handshake (no PTY) ─────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn handshake_no_pty_hello_ack() -> anyhow::Result<()> {
    let (port, _sd, _store) = start_server(10);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;

    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: 0,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;

    let ack: HelloAck = read_frame(&mut ctrl_rx).await?;
    assert_ne!(
        ack.session_token, [0u8; 32],
        "session token must be non-zero"
    );
    assert_eq!(ack.server_caps, 0, "no compression negotiated");
    Ok(())
}

// ── Test 2: RESUME with invalid token rejected ───────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resume_invalid_token() -> anyhow::Result<()> {
    let (port, _sd, _store) = start_server(100);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;

    let mut buf = BytesMut::new();
    encode_frame(
        &Resume {
            session_token: [0xFF; 32],
            tabs: vec![1],
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;

    // Server must reject: EOF or error expected, never a successful RESUME_ACK.
    let result = tokio::time::timeout(Duration::from_secs(2), ctrl_rx.read(&mut [0u8; 256])).await;
    match result {
        Ok(Ok(None)) | Ok(Err(_)) => {} // rejected correctly
        Ok(Ok(Some(n))) => panic!("expected rejection but received {n} bytes"),
        Err(_) => panic!("server did not close connection within 2 s"),
    }
    Ok(())
}

// ── Test 3: RESUME fails → HELLO fallback succeeds (mirrors App flow) ─────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resume_then_hello_fallback() -> anyhow::Result<()> {
    let (port, _sd, _store) = start_server(100);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;

    // Step 1: RESUME with stale token → expect rejection
    let c1 = ep.connect(addr, "aqt")?.await?;
    let (mut tx1, mut rx1) = c1.open_bi().await?;
    let mut buf = BytesMut::new();
    encode_frame(
        &Resume {
            session_token: [0xAB; 32],
            tabs: vec![1],
        },
        &mut buf,
    )?;
    tx1.write_all(&buf).await?;
    let _ = tokio::time::timeout(Duration::from_secs(2), rx1.read(&mut [0u8; 64])).await;
    drop(c1);
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Step 2: HELLO fallback → must succeed
    let c2 = ep.connect(addr, "aqt")?.await?;
    let (mut tx2, mut rx2) = c2.open_bi().await?;
    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: 0,
        },
        &mut buf,
    )?;
    tx2.write_all(&buf).await?;
    let ack: HelloAck = read_frame(&mut rx2).await?;
    assert_ne!(
        ack.session_token, [0u8; 32],
        "HELLO after failed RESUME must succeed"
    );
    Ok(())
}

// ── Test 4: Failed RESUMEs don't exhaust session quota ───────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn quota_not_exhausted_by_failed_resumes() -> anyhow::Result<()> {
    let (port, _sd, _store) = start_server(3); // tight quota
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;

    // 5 failed RESUMEs → must not consume any quota slots
    for i in 0..5u8 {
        let conn = ep.connect(addr, "aqt")?.await?;
        let (mut tx, mut rx) = conn.open_bi().await?;
        let mut buf = BytesMut::new();
        encode_frame(
            &Resume {
                session_token: [i; 32],
                tabs: vec![1],
            },
            &mut buf,
        )?;
        tx.write_all(&buf).await?;
        let _ = tokio::time::timeout(Duration::from_secs(1), rx.read(&mut [0u8; 64])).await;
        drop(conn);
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    // All 3 HELLO quota slots must still be available
    let mut tokens = Vec::new();
    for idx in 0..3usize {
        let conn = ep.connect(addr, "aqt")?.await?;
        let (mut tx, mut rx) = conn.open_bi().await?;
        let mut buf = BytesMut::new();
        encode_frame(
            &Hello {
                version: PROTOCOL_VERSION,
                client_id: [0x42; 16],
                capabilities: 0,
            },
            &mut buf,
        )?;
        tx.write_all(&buf).await?;
        let ack: HelloAck = read_frame(&mut rx).await?;
        assert_ne!(
            ack.session_token, [0u8; 32],
            "HELLO {idx} must succeed — quota must not be consumed by failed RESUMEs"
        );
        tokens.push(ack.session_token);
        std::mem::forget(conn); // keep alive
    }
    assert_ne!(tokens[0], tokens[1]);
    assert_ne!(tokens[1], tokens[2]);
    Ok(())
}

// ── Test 4b: Notify is pushed over its own dedicated uni stream, ────────────
//    and NotifyAck (sent on the control stream) stops redelivery ───────────
//
// Route B rework: Notify no longer shares the control bi-stream with
// OpenTab/Resize/Signal/CloseTab. The server opens a dedicated uni stream
// right after HELLO/RESUME succeeds and pushes onto it from a standalone
// 500ms-tick task; NotifyAck still travels back over the control stream
// (control_loop's Opcode::NotifyAck arm is unchanged). This test exercises
// that split end to end: HELLO → broadcast_notify → accept_uni() must
// deliver a real Notify frame on the new stream, without a client-issued
// OpenTab in between. Then sends a real NotifyAck frame on the control
// stream and asserts the event is NOT redelivered on the next tick — this is
// the guard rail for the "last_acked only advances on a genuine NotifyAck"
// invariant (never optimistically in the push path), now shared as an
// Arc<AtomicU64> between control_loop (writer) and the push task (reader).

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn notify_pushed_over_control_loop_and_not_redelivered_after_ack() -> anyhow::Result<()> {
    let (port, _sd, store) = start_server(10);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;

    // Step 1: HELLO → get the session token.
    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: 0,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: HelloAck = read_frame(&mut ctrl_rx).await?;
    // Not consumed further: broadcast_notify below fans out to every active
    // session rather than targeting this token by design — HELLO here only exists to give the server exactly one
    // active session to broadcast into.
    let _token = ack.session_token;

    // Step 2: push a notification straight into the session's queue, exactly
    // as main.rs's notify-socket callback does via SessionStore::broadcast_notify.
    //
    // Deliberately BEFORE the accept_uni() below: the server calls
    // conn.open_uni() right after HELLO succeeds, but quinn does not surface
    // an opened-yet-unwritten uni stream to the peer — the peer's
    // accept_uni() only resolves once the first byte actually goes out on
    // the wire. The push task's tick loop only writes once there's a
    // pending event, so if we awaited accept_uni() before broadcasting,
    // nothing would ever get written and this test would deadlock forever
    // (the notify_tick.tick()/write_frame combination that would eventually
    // produce bytes lives entirely on the OTHER side of the very await
    // we'd be stuck on). Broadcasting first guarantees the push task has
    // something to write on its very next tick.
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    store
        .broadcast_notify(Some(5), "build done".into(), now_ms)
        .await;

    // The server opens its dedicated Notify push stream right after HELLO
    // succeeds (see connection.rs's `handle()`, right before control_loop is
    // called) — accept_uni() here mirrors what a real client's persistent
    // accept_uni() dispatch loop would do. Resolves once the push task's
    // next tick (≤500ms) writes the frame queued above. Explicitly
    // timeout-guarded (unlike a bare `.await?`) so a genuine regression here
    // fails the test with a clear message instead of hanging the run
    // indefinitely.
    let mut notify_rx = tokio::time::timeout(Duration::from_secs(2), conn.accept_uni())
        .await
        .map_err(|_| anyhow::anyhow!("server never opened the notify uni stream within 2s"))??;

    // Step 3: the push task's 500ms tick must deliver it as a real Notify
    // frame on the dedicated uni stream within ~1s (worst case: just missed
    // one tick, catches the next).
    let notify: Notify = tokio::time::timeout(Duration::from_secs(1), read_frame(&mut notify_rx))
        .await
        .map_err(|_| anyhow::anyhow!("did not receive Notify frame within 1s"))??;
    assert_eq!(notify.text, "build done");
    assert_eq!(notify.tab_id, Some(5));

    // Step 4: acknowledge it on the control stream — this must be the ONLY
    // thing that can advance the shared last_acked cursor (never the push
    // path itself).
    buf.clear();
    encode_frame(
        &NotifyAck {
            last_event_id: notify.event_id,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;

    // Step 5: wait past another full tick and confirm the same event is NOT
    // redelivered on the uni stream. A regression here (e.g. last_acked
    // advanced eagerly in the push path, or ack() not actually trimming the
    // queue) would show up as a second Notify frame arriving instead of a
    // timeout.
    let mut tmp = [0u8; 256];
    let after_ack =
        tokio::time::timeout(Duration::from_millis(900), notify_rx.read(&mut tmp)).await;
    assert!(
        after_ack.is_err(),
        "notify must not be redelivered after NotifyAck, but more bytes arrived: {after_ack:?}"
    );

    Ok(())
}

// ── Test 4c: WITHOUT an ack, the same event must keep being redelivered ─────
//
// This is the actual enforcement of "last_acked only advances on a genuine
// NotifyAck, never optimistically in the push path" — the previous test
// (notify_pushed_over_control_loop_and_not_redelivered_after_ack) always
// sends a real NotifyAck at step 4, so Opcode::NotifyAck's
// `notify_queue.ack()` call physically trims the event out of the queue
// regardless of whether `last_acked` was *also* bumped eagerly inside the
// tick branch. A correct implementation and a buggy one that advances
// `last_acked` on push both converge to "no redelivery" once a real ack
// shows up, so that test cannot tell them apart (verified by actually
// injecting the eager-advance bug — see this commit's message / the report
// for the injection experiment).
//
// This test never sends an ack at all. That means the ONLY way redelivery
// could stop is if the tick branch bumped `last_acked` itself — which is
// exactly the bug this guards against. A correct control_loop must keep
// re-pushing the unacknowledged event on every 500ms tick, forever. This is
// the direct test of the notify channel's core design tradeoff:
// "would rather redeliver duplicates (client dedupes by event_id) than
// silently drop a notification."
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unacked_notify_is_redelivered_until_client_confirms() -> anyhow::Result<()> {
    let (port, _sd, store) = start_server(10);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;

    // Step 1: HELLO → give the server exactly one active session to
    // broadcast into (same rationale as the previous test).
    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: 0,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let _ack: HelloAck = read_frame(&mut ctrl_rx).await?;

    // Step 2: push one notification — deliberately BEFORE the accept_uni()
    // below. quinn only surfaces an opened uni stream to the peer once the
    // first byte is actually written on it, and the push task's tick loop
    // only writes once there's a pending event; awaiting accept_uni() first
    // would deadlock forever (see the sibling test's comment on this exact
    // ordering requirement).
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    store
        .broadcast_notify(Some(9), "unacked".into(), now_ms)
        .await;

    // Same as the sibling test: Notify travels on its own dedicated uni
    // stream, opened by the server right after HELLO succeeds. Timeout-
    // guarded so a regression fails clearly instead of hanging.
    let mut notify_rx = tokio::time::timeout(Duration::from_secs(2), conn.accept_uni())
        .await
        .map_err(|_| anyhow::anyhow!("server never opened the notify uni stream within 2s"))??;

    // Step 3: wait for the first delivery. Generous margin (2s ≈ 4x the
    // 500ms tick period) to absorb CI scheduling jitter — same reasoning as
    // the sibling test, just applied on both waits here since this test has
    // two sequential ones.
    let first: Notify = tokio::time::timeout(Duration::from_secs(2), read_frame(&mut notify_rx))
        .await
        .map_err(|_| anyhow::anyhow!("did not receive first Notify frame within 2s"))??;
    assert_eq!(first.text, "unacked");

    // Step 4: deliberately send NO NotifyAck.

    // Step 5: wait past at least one more full tick and assert the SAME
    // event_id is redelivered — not silently dropped.
    let second: Notify = tokio::time::timeout(Duration::from_secs(2), read_frame(&mut notify_rx))
        .await
        .map_err(|_| anyhow::anyhow!("event was NOT redelivered without an ack"))??;
    assert_eq!(
        second.event_id, first.event_id,
        "redelivery must be the same event, not a new one"
    );
    assert_eq!(second.text, "unacked");

    Ok(())
}

// ── Test 5: RESUME delivers live PTY data without a prelude ──────────────────
//
// Root cause: the old prelude (HARD_RESET + 256 KB ring replay) flowed through
// transport.output and inflated serverRingOff by ~256 KB on every cold-start
// RESUME. Subsequent hot-RESUMEs then sent lastOutOff > ring.tail → server
// returned RingSlice::Empty → xterm received only HARD_RESET → blank screen.
//
// Fix: remove the prelude entirely. RESUME delivers only the live PTY delta.
// This test verifies the PTY stream does NOT start with the RIS hard-reset byte.
//
// `#[ignore]` because PTY allocation is not always available in CI.
// Run locally: `cargo test -p flyterm-server --test protocol_integration -- --ignored`

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires allocatable PTY; run locally"]
async fn resume_sends_live_data_without_prelude() -> anyhow::Result<()> {
    let _ = env_logger::builder()
        .is_test(true)
        .filter_level(log::LevelFilter::Info)
        .try_init();

    let (port, _sd, _store) = start_server(10);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;

    // === Conn 1: HELLO + OPEN_TAB ===
    let conn1 = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx1, mut ctrl_rx1) = conn1.open_bi().await?;

    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: 0,
        },
        &mut buf,
    )?;
    ctrl_tx1.write_all(&buf).await?;

    let ack: HelloAck = read_frame(&mut ctrl_rx1).await?;
    let token = ack.session_token;

    buf.clear();
    encode_frame(
        &OpenTab {
            cols: 80,
            rows: 24,
            term: "xterm-256color".into(),
            cwd: String::new(),
            cmd: String::new(),
            preload_history: None,
        },
        &mut buf,
    )?;
    ctrl_tx1.write_all(&buf).await?;
    let open_ack: OpenTabAck = read_frame(&mut ctrl_rx1).await?;
    assert_eq!(open_ack.status, OpenTabStatus::Ok);
    let tab_id = open_ack.tab_id;

    // Accept the PTY bi stream and read some bytes so we know the shell
    // has actually produced output (prompt + OSC-7).
    let (_pty_send1, mut pty_recv1) = conn1.accept_bi().await?;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut tmp = [0u8; 4096];
    let _ = tokio::time::timeout(Duration::from_secs(1), pty_recv1.read(&mut tmp)).await;

    drop(conn1);
    tokio::time::sleep(Duration::from_millis(200)).await;

    // === Conn 2: RESUME ===
    let conn2 = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx2, mut ctrl_rx2) = conn2.open_bi().await?;

    buf.clear();
    encode_frame(
        &Resume {
            session_token: token,
            tabs: vec![tab_id],
        },
        &mut buf,
    )?;
    ctrl_tx2.write_all(&buf).await?;

    let resume_ack: ResumeAck = read_frame(&mut ctrl_rx2).await?;
    assert_eq!(resume_ack.tabs.len(), 1);

    // The server performs a deferred wiggle-resize (~40 ms after RESUME_ACK) to
    // force SIGWINCH → shell repaint → PTY bytes → Quinn delivers accept_bi().
    let (_pty_send2, mut pty_recv2) = conn2.accept_bi().await?;
    let mut first_bytes = Vec::new();
    let read_fut = async {
        let mut chunk = [0u8; 4096];
        loop {
            match tokio::time::timeout(Duration::from_millis(600), pty_recv2.read(&mut chunk)).await
            {
                Ok(Ok(Some(n))) => {
                    first_bytes.extend_from_slice(&chunk[..n]);
                    break; // one burst is enough
                }
                Ok(Ok(None)) => break, // stream closed (no data yet)
                Ok(Err(_)) => break,
                Err(_) => break, // timeout — shell hasn't sent anything yet
            }
        }
        Ok::<(), anyhow::Error>(())
    };
    tokio::time::timeout(Duration::from_secs(3), read_fut).await??;

    // The PTY stream must NOT start with RIS (\x1bc = hard reset).
    // If a prelude is still being emitted, the first byte will be 0x1b ('ESC')
    // followed by 'c' — the RIS sequence that clears xterm's scrollback.
    assert!(
        !first_bytes.starts_with(b"\x1bc"),
        "RESUME must not emit hard-reset prelude; first {} bytes: {:?}",
        first_bytes.len(),
        &first_bytes[..first_bytes.len().min(40)],
    );

    Ok(())
}
