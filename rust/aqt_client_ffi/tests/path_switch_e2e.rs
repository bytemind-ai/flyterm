// SPDX-License-Identifier: GPL-3.0-or-later
//! Seamless path switching: direct -> relay -> direct in the middle of bulk
//! output must keep the SAME QUIC connection and session (no RESUME). The
//! client's UDP socket is a `RoutedSocket`; `set_target` swaps the real
//! destination underneath QUIC.
//!
//! Own test binary: the client's TLS session store is process-global.

use std::ffi::{c_void, CString};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use aqt_client_ffi::client::{connect, make_routed_endpoint};
use aqt_client_ffi::ffi::{aqt_path_rx_current, aqt_probe_direct, aqt_probe_result, aqt_set_path};
use aqt_client_ffi::handle::SessionHandle;
use aqt_protocol::{
    decode_frame_header, encode_frame, FramePayload, Hello, HelloAck, OpenTab, OpenTabAck,
    OpenTabStatus, PROTOCOL_VERSION,
};
use base64::Engine as _;
use bytes::{Buf, BytesMut};
use flyterm_server::relay::{encode_frame as relay_frame, FrameDecoder};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

async fn read_frame<P: FramePayload>(rx: &mut quinn::RecvStream) -> anyhow::Result<P> {
    let mut buf = BytesMut::new();
    loop {
        let mut tmp = [0u8; 4096];
        let n = rx
            .read(&mut tmp)
            .await?
            .ok_or_else(|| anyhow::anyhow!("eof"))?;
        buf.extend_from_slice(&tmp[..n]);
        let mut peek: &[u8] = &buf;
        if let Ok((_op, len)) = decode_frame_header(&mut peek) {
            if peek.len() >= len {
                let hlen = buf.len() - peek.len();
                buf.advance(hlen);
                let payload = buf.split_to(len);
                let mut p: &[u8] = &payload;
                return P::decode(&mut p).map_err(|e| anyhow::anyhow!("decode: {e:?}"));
            }
        }
    }
}

struct Daemon {
    port: u16,
    spki: Vec<u8>,
    store: flyterm_server::session::SessionStore,
}

async fn start_daemon() -> anyhow::Result<Daemon> {
    let allow_compression = false;
    let tls = flyterm_server::tls::generate_ephemeral()?;
    let spki = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&tls.spki_base64)?;
    let ep = flyterm_server::endpoint::build_endpoint(
        "127.0.0.1:0".parse()?,
        &tls,
        flyterm_server::cli::CongestionKind::Cubic,
    )?;
    let port = ep.local_addr.port();
    let store = flyterm_server::session::SessionStore::new(
        10,
        flyterm_server::session::DEFAULT_SESSION_TTL,
    );
    let cfg = flyterm_server::connection::ConnectionConfig {
        ring_size_bytes: 4 * 1024 * 1024,
        parser_scrollback_rows: 1000,
        max_tabs_per_session: 8,
        term: "xterm-256color".into(),
        allow_compression,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from(
            "/tmp/flyterm-test-notify-relay.sock",
        )),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(
        ep,
        store.clone(),
        cfg,
    ));
    tokio::time::sleep(Duration::from_millis(50)).await;
    Ok(Daemon { port, spki, store })
}

/// One "SSH channel": `relay::run` on one end, the phone-side pump on the
/// other. Returns the pump's local UDP address for the client to dial, plus
/// counters of datagrams forwarded (app->daemon, daemon->app).
async fn relay_path(
    daemon_port: u16,
) -> anyhow::Result<(SocketAddr, Arc<AtomicU64>, Arc<AtomicU64>)> {
    let a2d = Arc::new(AtomicU64::new(0));
    let d2a = Arc::new(AtomicU64::new(0));
    let (a2d_t, d2a_t) = (a2d.clone(), d2a.clone());
    let (server_end, phone_end) = tokio::io::duplex(256 * 1024);
    let (sr, sw) = tokio::io::split(server_end);
    tokio::spawn(flyterm_server::relay::run(daemon_port, sr, sw));

    let sock = tokio::net::UdpSocket::bind("127.0.0.1:0").await?;
    let addr = sock.local_addr()?;
    let (mut pr, mut pw) = tokio::io::split(phone_end);
    tokio::spawn(async move {
        let mut app: Option<SocketAddr> = None;
        let mut dec = FrameDecoder::new();
        let mut pkt = vec![0u8; 65535];
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            tokio::select! {
                r = sock.recv_from(&mut pkt) => {
                    let Ok((n, from)) = r else { return };
                    app = Some(from);
                    if pw.write_all(&relay_frame(&pkt[..n])).await.is_err() { return; }
                    a2d_t.fetch_add(1, Ordering::SeqCst);
                }
                r = pr.read(&mut chunk) => {
                    let n = match r { Ok(0) | Err(_) => return, Ok(n) => n };
                    let Ok(packets) = dec.push(&chunk[..n]) else { return };
                    if let Some(to) = app {
                        for p in packets {
                            let _ = sock.send_to(&p, to).await;
                            d2a_t.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                }
            }
        }
    });
    Ok((addr, a2d, d2a))
}

async fn hello(
    conn: &quinn::Connection,
) -> anyhow::Result<(quinn::SendStream, quinn::RecvStream, HelloAck)> {
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
    Ok((tx, rx, ack))
}

async fn open_tab(
    ctrl_tx: &mut quinn::SendStream,
    ctrl_rx: &mut quinn::RecvStream,
) -> anyhow::Result<u32> {
    let mut buf = BytesMut::new();
    encode_frame(
        &OpenTab {
            cols: 200,
            rows: 50,
            term: "xterm-256color".into(),
            cwd: "".into(),
            cmd: "".into(),
            preload_history: None,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: OpenTabAck = read_frame(ctrl_rx).await?;
    assert!(matches!(ack.status, OpenTabStatus::Ok), "{:?}", ack.status);
    Ok(ack.tab_id)
}

/// End the shell so the daemon's blocking PTY reader can finish (see
/// e2e_test's full_client_flow_spki_pinning) — otherwise the test process
/// never exits.
async fn exit_shell(tx: &mut quinn::SendStream, rx: &mut quinn::RecvStream) {
    let _ = tx.write_all(b"exit\n").await;
    let mut sink = [0u8; 1024];
    let _ = tokio::time::timeout(Duration::from_secs(2), async {
        while let Ok(Some(_)) = rx.read(&mut sink).await {}
    })
    .await;
}

/// Reads the PTY stream until `needle` appears, calling `on_progress` with
/// the number of complete bulk lines seen so far after every chunk.
async fn read_bulk(
    rx: &mut quinn::RecvStream,
    needle: &str,
    secs: u64,
    mut on_progress: impl FnMut(usize),
) -> String {
    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
    let mut tmp = vec![0u8; 16 * 1024];
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(300), rx.read(&mut tmp)).await {
            Ok(Ok(Some(n))) => {
                out.extend_from_slice(&tmp[..n]);
                let text = String::from_utf8_lossy(&out);
                on_progress(text.matches("|END").count());
                if text.contains(needle) {
                    break;
                }
            }
            Ok(Ok(None)) | Ok(Err(_)) => break,
            Err(_) => {}
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn path_switch_mid_bulk_keeps_session() -> anyhow::Result<()> {
    let d = start_daemon().await?;
    let (pump, a2d, d2a) = relay_path(d.port).await?;
    let direct: SocketAddr = format!("127.0.0.1:{}", d.port).parse()?;
    let (ep, routed) = make_routed_endpoint(d.spki.clone(), direct)?;
    let conn = connect(&ep, routed.virtual_peer(), "aqt").await?;
    let (mut ctrl_tx, mut ctrl_rx, ack) = hello(&conn).await?;
    open_tab(&mut ctrl_tx, &mut ctrl_rx).await?;
    let (mut pty_tx, mut pty_rx) = conn.accept_bi().await?;
    pty_tx.write_all(b"stty -echo\n").await?;
    tokio::time::sleep(Duration::from_millis(300)).await;

    const N: usize = 2000;
    let cmd = format!(
        "for i in $(seq -f '%04g' 1 {N}); do \
           printf '%s|path-switch-payload-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789|%s|END\\n' \"$i\" \"$i\"; \
         done; printf '@@DONE@@\\n'\n"
    );
    pty_tx.write_all(cmd.as_bytes()).await?;

    // Stage 0 direct; stage 1 via the relay (kept until the relay has
    // carried real traffic both ways); stage 2 direct again.
    let mut stage = 0;
    let (mut a2d_0, mut d2a_0) = (0, 0);
    let (mut a2d_1, mut d2a_1) = (0, 0);
    let (mut lines_2, mut lines_3) = (0, 0);
    let (mut a2d_3, mut d2a_3) = (0, 0);
    let text = read_bulk(&mut pty_rx, "@@DONE@@", 30, |lines| {
        let (a, b) = (a2d.load(Ordering::SeqCst), d2a.load(Ordering::SeqCst));
        if stage == 0 && lines >= 500 {
            assert_eq!((a, b), (0, 0), "pump used before the switch");
            routed.set_target(pump);
            (a2d_0, d2a_0) = (a, b);
            stage = 1;
        } else if stage == 1 && lines >= 1200 && a - a2d_0 >= 1 && b - d2a_0 >= 20 {
            assert!(routed.rx_from_current() > 0, "relay traffic not counted");
            routed.set_target(direct);
            assert_eq!(routed.rx_from_current(), 0, "switch resets the counter");
            (a2d_1, d2a_1) = (a, b);
            lines_2 = lines;
            stage = 2;
        } else if stage == 2 && lines >= lines_2 + 200 {
            // In-flight relay packets have drained; from here on the pump
            // must stay (nearly) silent while the rest of the bulk arrives.
            (a2d_3, d2a_3) = (a, b);
            lines_3 = lines;
            stage = 3;
        }
    })
    .await;
    assert_eq!(stage, 3, "bulk finished before all stages happened");
    let (a_end, b_end) = (a2d.load(Ordering::SeqCst), d2a.load(Ordering::SeqCst));
    assert!(
        N - lines_3 >= 200,
        "too few lines left after switch-back: {}",
        N - lines_3
    );
    assert!(
        a_end - a2d_3 <= 3 && b_end - d2a_3 <= 3,
        "pump still carrying traffic after switching back: a2d +{} d2a +{}",
        a_end - a2d_3,
        b_end - d2a_3
    );
    assert!(
        text.contains("@@DONE@@"),
        "sentinel missing ({} bytes)",
        text.len()
    );
    let mut pos = 0;
    for i in 1..=N {
        let line = format!("{i:04}|path-switch-payload-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789|{i:04}|END");
        let at = text[pos..]
            .find(&line)
            .unwrap_or_else(|| panic!("line {i} missing or out of order"));
        pos += at + line.len();
    }

    // The relay really carried the middle stage, in both directions...
    // app->daemon is mostly ACKs: count is timing-dependent (ack coalescing);
    // >=1 proves the route, daemon->app below proves data flowed.
    assert!(
        a2d_1 - a2d_0 >= 1,
        "app->daemon via relay: {}",
        a2d_1 - a2d_0
    );
    assert!(
        d2a_1 - d2a_0 >= 20,
        "daemon->app via relay: {}",
        d2a_1 - d2a_0
    );
    // Same connection, never resumed; the session is still in the store.
    assert!(conn.close_reason().is_none(), "{:?}", conn.close_reason());
    assert!(
        d.store
            .with_session(&ack.session_token, |_| ())
            .await
            .is_some(),
        "session gone from the server store"
    );
    exit_shell(&mut pty_tx, &mut pty_rx).await;
    Ok(())
}

/// What `aqt_rebind` does (`with_fresh_socket` + `rebind_abstract`), mid-bulk:
/// once on direct, then again after switching to the relay. The fresh socket
/// inherits the route, so the second rebind must keep using the relay. All
/// lines arrive in order on the same connection.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rebind_mid_bulk_keeps_session() -> anyhow::Result<()> {
    let d = start_daemon().await?;
    let (pump, a2d, d2a) = relay_path(d.port).await?;
    let direct: SocketAddr = format!("127.0.0.1:{}", d.port).parse()?;
    let (ep, routed) = make_routed_endpoint(d.spki.clone(), direct)?;
    let conn = connect(&ep, routed.virtual_peer(), "aqt").await?;
    let (mut ctrl_tx, mut ctrl_rx, ack) = hello(&conn).await?;
    open_tab(&mut ctrl_tx, &mut ctrl_rx).await?;
    let (mut pty_tx, mut pty_rx) = conn.accept_bi().await?;
    pty_tx.write_all(b"stty -echo\n").await?;
    tokio::time::sleep(Duration::from_millis(300)).await;

    const N: usize = 2000;
    let cmd = format!(
        "for i in $(seq -f '%04g' 1 {N}); do \
           printf '%s|rebind-payload-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789|%s|END\\n' \"$i\" \"$i\"; \
         done; printf '@@DONE@@\\n'\n"
    );
    pty_tx.write_all(cmd.as_bytes()).await?;

    let rebind = |cur: &Arc<aqt_client_ffi::routed_socket::RoutedSocket>| {
        let fresh = cur.with_fresh_socket().expect("fresh socket");
        ep.rebind_abstract(fresh.clone()).expect("rebind");
        fresh
    };

    // Stage 0 direct -> rebind (stage 1, still direct) -> relay (stage 2)
    // -> rebind on the relay (stage 3).
    let mut cur = routed;
    let mut stage = 0;
    let (mut a2d_3, mut d2a_3) = (0, 0);
    let text = read_bulk(&mut pty_rx, "@@DONE@@", 30, |lines| {
        let (a, b) = (a2d.load(Ordering::SeqCst), d2a.load(Ordering::SeqCst));
        if stage == 0 && lines >= 400 {
            cur = rebind(&cur);
            stage = 1;
        } else if stage == 1 && lines >= 800 {
            assert_eq!((a, b), (0, 0), "pump used before the switch");
            assert!(cur.rx_from_current() > 0, "fresh socket got no traffic");
            cur.set_target(pump);
            stage = 2;
        } else if stage == 2 && lines >= 1100 && b >= 20 {
            cur = rebind(&cur);
            (a2d_3, d2a_3) = (a, b);
            stage = 3;
        }
    })
    .await;
    assert_eq!(stage, 3, "bulk finished before all stages happened");
    assert!(
        text.contains("@@DONE@@"),
        "sentinel missing ({} bytes)",
        text.len()
    );
    let mut pos = 0;
    for i in 1..=N {
        let line = format!(
            "{i:04}|rebind-payload-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789|{i:04}|END"
        );
        let at = text[pos..]
            .find(&line)
            .unwrap_or_else(|| panic!("line {i} missing or out of order"));
        pos += at + line.len();
    }
    // The rebound socket kept the relay route and carried the rest.
    let (a_end, b_end) = (a2d.load(Ordering::SeqCst), d2a.load(Ordering::SeqCst));
    // app->daemon is mostly ACKs: count is timing-dependent (ack coalescing);
    // >=1 proves the rebound socket uses the relay, daemon->app proves data.
    assert!(
        a_end - a2d_3 >= 1,
        "app->daemon after relay rebind: {}",
        a_end - a2d_3
    );
    assert!(
        b_end - d2a_3 >= 20,
        "daemon->app after relay rebind: {}",
        b_end - d2a_3
    );
    assert!(conn.close_reason().is_none(), "{:?}", conn.close_reason());
    assert!(
        d.store
            .with_session(&ack.session_token, |_| ())
            .await
            .is_some(),
        "session gone from the server store"
    );
    exit_shell(&mut pty_tx, &mut pty_rx).await;
    Ok(())
}

#[test]
fn set_path_ffi_rejects_null_and_bad_ip() {
    let ip = CString::new("127.0.0.1").unwrap();
    let bad = CString::new("not-an-ip").unwrap();
    unsafe {
        assert!(aqt_set_path(std::ptr::null_mut(), ip.as_ptr(), 1) < 0);
        let (handle, _tx) = SessionHandle::new();
        let raw = Arc::into_raw(handle) as *mut c_void;
        assert!(aqt_set_path(raw, bad.as_ptr(), 1) < 0);
        assert!(aqt_set_path(raw, std::ptr::null(), 1) < 0);
        // Valid ip but no routed socket yet: NotConnected, also negative.
        assert!(aqt_set_path(raw, ip.as_ptr(), 1) < 0);
        drop(Arc::from_raw(raw as *const SessionHandle));
    }
}

#[test]
fn path_rx_current_ffi_negative_without_path() {
    unsafe {
        assert!(aqt_path_rx_current(std::ptr::null_mut()) < 0);
        let (handle, _tx) = SessionHandle::new();
        let raw = Arc::into_raw(handle) as *mut c_void;
        assert!(aqt_path_rx_current(raw) < 0, "no routed socket yet");
        drop(Arc::from_raw(raw as *const SessionHandle));
    }
}

/// Poll `aqt_probe_result` until it leaves -1 or `within` elapses.
async fn wait_probe(raw: *mut c_void, within: Duration) -> i32 {
    let deadline = std::time::Instant::now() + within;
    loop {
        let r = unsafe { aqt_probe_result(raw) };
        if r != -1 || std::time::Instant::now() >= deadline {
            return r;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe_direct_reports_reachable_and_unreachable() -> anyhow::Result<()> {
    let d = start_daemon().await?;
    let (handle, _tx) = SessionHandle::new();
    let raw = Arc::into_raw(handle) as *mut c_void;
    let ip = CString::new("127.0.0.1")?;

    // Live daemon: handshake succeeds well within 1 s.
    let rc = unsafe {
        aqt_probe_direct(
            raw,
            ip.as_ptr(),
            d.port,
            d.spki.as_ptr(),
            d.spki.len(),
            3000,
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(wait_probe(raw, Duration::from_secs(1)).await, 1);

    // Bound-but-silent UDP port: times out, reported as 0.
    let silent = std::net::UdpSocket::bind("127.0.0.1:0")?;
    let sport = silent.local_addr()?.port();
    let rc =
        unsafe { aqt_probe_direct(raw, ip.as_ptr(), sport, d.spki.as_ptr(), d.spki.len(), 500) };
    assert_eq!(rc, 0);
    assert_eq!(
        unsafe { aqt_probe_result(raw) },
        -1,
        "result must reset to in-progress on start"
    );
    assert_eq!(wait_probe(raw, Duration::from_secs(1)).await, 0);

    // Bad arguments are rejected synchronously.
    unsafe {
        assert!(aqt_probe_direct(raw, std::ptr::null(), 1, d.spki.as_ptr(), d.spki.len(), 1) < 0);
        assert!(
            aqt_probe_direct(
                std::ptr::null_mut(),
                ip.as_ptr(),
                1,
                d.spki.as_ptr(),
                d.spki.len(),
                1
            ) < 0
        );
        assert!(aqt_probe_result(std::ptr::null_mut()) < -1);
        drop(Arc::from_raw(raw as *const SessionHandle));
    }
    Ok(())
}
