// SPDX-License-Identifier: GPL-3.0-or-later
//! 0-RTT resumption on reconnect.
//!
//! Its own test binary on purpose: the client's TLS session store is a
//! process-wide static keyed by server name ("aqt"), so tickets issued by
//! other tests' servers would make a 0-RTT attempt here fall back to 1-RTT
//! nondeterministically.

use aqt_client_ffi::client::{connect, connect_0rtt, make_client_endpoint};
use aqt_protocol::{
    decode_frame_header, encode_frame, FramePayload, Hello, HelloAck, PROTOCOL_VERSION,
};
use base64::Engine as _;
use bytes::{Buf, BytesMut};
use std::time::Duration;

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
                buf.advance(hlen);
                let payload = buf.split_to(len);
                let mut p: &[u8] = &payload;
                return P::decode(&mut p).map_err(|e| anyhow::anyhow!("decode: {e:?}"));
            }
        }
    }
}

async fn hello(conn: &quinn::Connection) -> anyhow::Result<()> {
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
    let _ack: HelloAck = read_frame(&mut rx).await?;
    Ok(())
}

/// After one full handshake, reconnecting (as after a Wi-Fi ↔ cellular
/// switch) must reuse the ticket and have its early data accepted — saving
/// a round trip on every reconnect.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn zero_rtt_accepted_on_reconnect() -> anyhow::Result<()> {
    let tls = flyterm_server::tls::generate_ephemeral()?;
    let spki = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&tls.spki_base64)?;
    let ep = flyterm_server::endpoint::build_endpoint(
        "127.0.0.1:0".parse()?,
        &tls,
        flyterm_server::cli::CongestionKind::Cubic,
    )?;
    let addr: std::net::SocketAddr = format!("127.0.0.1:{}", ep.local_addr.port()).parse()?;
    let store = flyterm_server::session::SessionStore::new(
        10,
        flyterm_server::session::DEFAULT_SESSION_TTL,
    );
    let cfg = flyterm_server::connection::ConnectionConfig {
        ring_size_bytes: 64 * 1024,
        parser_scrollback_rows: 1000,
        max_tabs_per_session: 8,
        term: "xterm-256color".into(),
        allow_compression: false,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from(
            "/tmp/flyterm-test-notify-0rtt.sock",
        )),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(ep, store, cfg));
    tokio::time::sleep(Duration::from_millis(50)).await;

    let client_ep = make_client_endpoint(spki)?;

    // First connection: full handshake; tickets arrive after it completes.
    let conn1 = connect(&client_ep, addr, "aqt").await?;
    hello(&conn1).await?;
    conn1.close(0u32.into(), b"");
    tokio::time::sleep(Duration::from_millis(100)).await;

    let (conn2, accepted) = connect_0rtt(&client_ep, addr, "aqt").await?;
    assert!(accepted, "server did not accept 0-RTT on reconnect");
    hello(&conn2).await?;
    Ok(())
}
