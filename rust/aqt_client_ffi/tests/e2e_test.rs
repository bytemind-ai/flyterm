// SPDX-License-Identifier: GPL-3.0-or-later
//! End-to-end test: start flyterm-server in-process, do full client flow
//! via the same Rust functions that aqt_client_ffi exposes to Dart.

use aqt_client_ffi::client::{connect, make_client_endpoint};
use aqt_protocol::{
    decode_frame_header, encode_frame, FramePayload, Hello, HelloAck, OpenTab, OpenTabAck,
    OpenTabStatus, CAP_LZ4, PROTOCOL_VERSION,
};
use base64::Engine as _;
use bytes::{Buf, BytesMut};
use std::pin::Pin;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, BufReader};

/// Decodes the server's LZ4 PTY framing — `[u32 BE frame_len][size-prepended
/// LZ4 block]`, one independent block per PTY chunk — with the same
/// `lz4block::decompress_size_prepended` the client FFI uses.
///
/// A poll-based state machine rather than an `async fn`: the drain loops wrap
/// every read in `tokio::time::timeout`, and a cancelled `async fn` would drop
/// a half-read frame and desync the stream.
struct Lz4Reader<R> {
    inner: R,
    hdr: [u8; 4],
    hdr_got: usize,
    body: Vec<u8>,
    body_got: usize,
    out: Vec<u8>,
    out_pos: usize,
}

impl<R> Lz4Reader<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            hdr: [0; 4],
            hdr_got: 0,
            body: Vec::new(),
            body_got: 0,
            out: Vec::new(),
            out_pos: 0,
        }
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for Lz4Reader<R> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        loop {
            if this.out_pos < this.out.len() {
                let n = buf.remaining().min(this.out.len() - this.out_pos);
                buf.put_slice(&this.out[this.out_pos..this.out_pos + n]);
                this.out_pos += n;
                return Poll::Ready(Ok(()));
            }
            if this.hdr_got < 4 {
                let mut rb = tokio::io::ReadBuf::new(&mut this.hdr[this.hdr_got..]);
                ready!(Pin::new(&mut this.inner).poll_read(cx, &mut rb))?;
                let n = rb.filled().len();
                if n == 0 {
                    // Clean EOF only on a frame boundary.
                    return Poll::Ready(if this.hdr_got == 0 {
                        Ok(())
                    } else {
                        Err(std::io::ErrorKind::UnexpectedEof.into())
                    });
                }
                this.hdr_got += n;
                if this.hdr_got == 4 {
                    this.body = vec![0; u32::from_be_bytes(this.hdr) as usize];
                    this.body_got = 0;
                }
                continue;
            }
            if this.body_got < this.body.len() {
                let mut rb = tokio::io::ReadBuf::new(&mut this.body[this.body_got..]);
                ready!(Pin::new(&mut this.inner).poll_read(cx, &mut rb))?;
                let n = rb.filled().len();
                if n == 0 {
                    return Poll::Ready(Err(std::io::ErrorKind::UnexpectedEof.into()));
                }
                this.body_got += n;
                continue;
            }
            this.out =
                aqt_protocol::lz4block::decompress_size_prepended(&this.body).map_err(|e| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{e:?}"))
                })?;
            this.out_pos = 0;
            this.hdr_got = 0;
        }
    }
}

/// Erased AsyncRead over either the raw PTY stream or its LZ4-decoded form.
/// Lets the comparison test funnel both modes through the same drain loop.
enum PtyReader {
    Plain(BufReader<quinn::RecvStream>),
    Lz4(Lz4Reader<BufReader<quinn::RecvStream>>),
}

impl AsyncRead for PtyReader {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            PtyReader::Plain(r) => Pin::new(r).poll_read(cx, buf),
            PtyReader::Lz4(r) => Pin::new(r).poll_read(cx, buf),
        }
    }
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
                buf.advance(hlen);
                let payload = buf.split_to(len);
                let mut p: &[u8] = &payload;
                return P::decode(&mut p).map_err(|e| anyhow::anyhow!("decode: {e:?}"));
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn full_client_flow_spki_pinning() -> anyhow::Result<()> {
    // ── Start server ─────────────────────────────────────────
    let tls = flyterm_server::tls::generate_ephemeral()?;
    let spki_bytes = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&tls.spki_base64)?;

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
        ring_size_bytes: 64 * 1024,
        parser_scrollback_rows: 1000,
        max_tabs_per_session: 8,
        term: "xterm-256color".into(),
        allow_compression: false,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(ep, store, cfg));
    tokio::time::sleep(Duration::from_millis(50)).await;

    println!("Server on 127.0.0.1:{port}, SPKI len={}", spki_bytes.len());

    // ── Client with SPKI pinning (same path as aqt_client_ffi) ──
    let client_ep = make_client_endpoint(spki_bytes)?;
    let addr: std::net::SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = connect(&client_ep, addr, "aqt").await?;
    println!("✓ QUIC connected (SPKI pinning passed)");

    // ── HELLO / HELLO_ACK ──────────────────────────────────────
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
    let _ack: HelloAck = read_frame(&mut ctrl_rx).await?;
    println!("✓ HELLO_ACK received");

    // ── OPEN_TAB ───────────────────────────────────────────────
    let mut buf = BytesMut::new();
    encode_frame(
        &OpenTab {
            cols: 80,
            rows: 24,
            term: "xterm-256color".into(),
            cwd: "".into(),
            cmd: "".into(),
            preload_history: None,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: OpenTabAck = read_frame(&mut ctrl_rx).await?;
    println!(
        "✓ OPEN_TAB_ACK tab_id={} status={:?}",
        ack.tab_id, ack.status
    );
    assert!(
        matches!(ack.status, OpenTabStatus::Ok),
        "OPEN_TAB failed: {:?}",
        ack.status
    );

    // ── Accept PTY stream + echo test ──────────────────────────
    let (mut pty_tx, mut pty_rx) = conn.accept_bi().await?;
    println!("✓ PTY bidi stream accepted");

    pty_tx.write_all(b"echo aqt-e2e-ok\n").await?;

    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline {
        let mut tmp = [0u8; 1024];
        match tokio::time::timeout(Duration::from_millis(300), pty_rx.read(&mut tmp)).await {
            Ok(Ok(Some(n))) => {
                out.extend_from_slice(&tmp[..n]);
                if String::from_utf8_lossy(&out).contains("aqt-e2e-ok") {
                    println!("✓ PTY echo 'aqt-e2e-ok' received");
                    // End the shell so the server's spawn_blocking PTY reader
                    // hits EOF. The session outlives the connection (for
                    // RESUME), so otherwise that reader blocks forever and
                    // the test runtime's shutdown waits on it — the test
                    // passes but the process never exits.
                    pty_tx.write_all(b"exit\n").await?;
                    let mut sink = [0u8; 1024];
                    let _ = tokio::time::timeout(Duration::from_secs(2), async {
                        while let Ok(Some(_)) = pty_rx.read(&mut sink).await {}
                    })
                    .await;
                    return Ok(());
                }
            }
            _ => {}
        }
    }
    panic!(
        "PTY echo not received. Got: {:?}",
        String::from_utf8_lossy(&out)
    );
}

/// Reproduces the "scroll-up sees corrupted bytes" symptom: send a deterministic,
/// high-volume PTY input that crosses MANY LZ4 block boundaries, drain the
/// decompressed output, then check every line for bit-exact integrity. If any
/// byte is corrupted, dropped, or duplicated by the encoder/decoder pair, the
/// pattern check will catch it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lz4_streaming_no_corruption_over_long_session() -> anyhow::Result<()> {
    // ── Server ────────────────────────────────────────────────────────────
    let tls = flyterm_server::tls::generate_ephemeral()?;
    let spki_bytes = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&tls.spki_base64)?;
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
        // Big ring so nothing is evicted during the test.
        ring_size_bytes: 4 * 1024 * 1024,
        parser_scrollback_rows: 1000,
        max_tabs_per_session: 8,
        term: "xterm-256color".into(),
        allow_compression: true,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(ep, store, cfg));
    tokio::time::sleep(Duration::from_millis(50)).await;

    // ── Client connects, HELLO with CAP_LZ4 ───────────────────────────────
    let client_ep = make_client_endpoint(spki_bytes)?;
    let addr: std::net::SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = connect(&client_ep, addr, "aqt").await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;
    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: CAP_LZ4,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: HelloAck = read_frame(&mut ctrl_rx).await?;
    assert!(
        ack.server_caps & CAP_LZ4 != 0,
        "server did NOT confirm CAP_LZ4 — test cannot prove the compressed path"
    );

    // ── OPEN_TAB ──────────────────────────────────────────────────────────
    let mut buf = BytesMut::new();
    encode_frame(
        &OpenTab {
            cols: 200,
            rows: 80,
            term: "xterm-256color".into(),
            cwd: "".into(),
            cmd: "".into(),
            preload_history: None,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: OpenTabAck = read_frame(&mut ctrl_rx).await?;
    assert!(matches!(ack.status, OpenTabStatus::Ok));

    // Accept the server-initiated PTY bidi.
    let (mut pty_tx, pty_rx) = conn.accept_bi().await?;

    // ── Wrap recv-half in the SAME decoder client FFI uses ────────────────
    let buf_reader = BufReader::new(pty_rx);
    let mut decoder = Lz4Reader::new(buf_reader);

    // Disable PTY echo so the command itself doesn't appear in the output,
    // then send the test payload. Wait for the stty to settle before sending
    // the rest so the for-loop output isn't echoed back.
    pty_tx.write_all(b"stty -echo; clear\n").await?;
    tokio::time::sleep(Duration::from_millis(500)).await;
    // Drain prompt / echo before measurement.
    let mut sink = vec![0u8; 64 * 1024];
    let _ = tokio::time::timeout(Duration::from_millis(300), decoder.read(&mut sink)).await;

    const N: usize = 2000;
    // 2000 lines × ~100 bytes ≈ 200 KB raw, easily crosses many LZ4 block
    // boundaries (each PTY chunk → one independent block). Each line has: 4-digit idx | UTF-8 中文 | ANSI red | tail.
    let cmd = format!(
        "for i in $(seq -f '%04g' 1 {N}); do \
           printf '%s|中文-pad-pad-pad|\\033[31mRED-%s\\033[0m|END\\n' \"$i\" \"$i\"; \
         done; printf '@@END_OF_LZ4_TEST@@\\n'\n",
        N = N
    );
    eprintln!("→ sending {} bytes of input", cmd.len());
    pty_tx.write_all(cmd.as_bytes()).await?;

    // ── Drain decompressed output until the sentinel ─────────────────────
    let mut acc = Vec::with_capacity(N * 80);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    let mut iter = 0;
    while tokio::time::Instant::now() < deadline {
        let mut tmp = vec![0u8; 16 * 1024];
        let r = tokio::time::timeout(Duration::from_millis(300), decoder.read(&mut tmp)).await;
        iter += 1;
        match r {
            Ok(Ok(0)) => {
                eprintln!("[iter {}] decoder.read returned 0 — EOF", iter);
                break;
            }
            Ok(Ok(n)) => {
                acc.extend_from_slice(&tmp[..n]);
                if iter < 5 || iter % 20 == 0 {
                    eprintln!("[iter {}] got {} bytes (total {})", iter, n, acc.len());
                }
                let s = String::from_utf8_lossy(&acc);
                if s.contains("@@END_OF_LZ4_TEST@@") {
                    eprintln!("[iter {}] sentinel found at {} bytes", iter, acc.len());
                    break;
                }
            }
            Ok(Err(e)) => {
                eprintln!("[iter {}] decoder error: {:?}", iter, e);
                break;
            }
            Err(_) => {
                eprintln!(
                    "[iter {}] 300ms read timeout (total {} bytes)",
                    iter,
                    acc.len()
                );
            }
        }
    }
    let text = String::from_utf8_lossy(&acc).into_owned();
    assert!(
        text.contains("@@END_OF_LZ4_TEST@@"),
        "sentinel missing — got {} bytes:\n{:?}\n…",
        acc.len(),
        &text.chars().take(400).collect::<String>(),
    );

    // ── Verify every line, in order, with bit-exact content ──────────────
    let mut missing = Vec::new();
    let mut corrupted = Vec::new();
    for i in 1..=N {
        let expected = format!(
            "{i:04}|中文-pad-pad-pad|\x1b[31mRED-{i:04}\x1b[0m|END",
            i = i
        );
        if !text.contains(&expected) {
            let prefix = format!("{:04}|", i);
            if text.contains(&prefix) {
                corrupted.push(i);
            } else {
                missing.push(i);
            }
            if missing.len() + corrupted.len() > 8 {
                break;
            }
        }
    }
    assert!(
        missing.is_empty() && corrupted.is_empty(),
        "lz4 path corrupted output: missing lines {:?}, corrupted lines {:?} (text len {})",
        missing,
        corrupted,
        text.len(),
    );

    println!(
        "✓ lz4 integrity OK across {} lines ({} bytes decompressed)",
        N,
        text.len()
    );
    Ok(())
}

/// Stress test for the "scrolling shows corruption" symptom. Pushes a
/// TUI-like rapid screen-clear-and-redraw pattern many times, simulating what
/// htop/nvim/Claude Code do during interactive use. If LZ4 block boundaries
/// or the length-prefix framing mis-handle this pattern, the buffered scrollback (which
/// xterm builds from the decoded stream) will show wrong bytes when scrolled.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lz4_streaming_no_corruption_under_redraw_storm() -> anyhow::Result<()> {
    let tls = flyterm_server::tls::generate_ephemeral()?;
    let spki_bytes = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&tls.spki_base64)?;
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
        allow_compression: true,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(ep, store, cfg));
    tokio::time::sleep(Duration::from_millis(50)).await;

    let client_ep = make_client_endpoint(spki_bytes)?;
    let addr: std::net::SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = connect(&client_ep, addr, "aqt").await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;
    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: CAP_LZ4,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: HelloAck = read_frame(&mut ctrl_rx).await?;
    assert!(
        ack.server_caps & CAP_LZ4 != 0,
        "server did NOT confirm CAP_LZ4"
    );

    let mut buf = BytesMut::new();
    encode_frame(
        &OpenTab {
            cols: 200,
            rows: 80,
            term: "xterm-256color".into(),
            cwd: "".into(),
            cmd: "".into(),
            preload_history: None,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let _ack: OpenTabAck = read_frame(&mut ctrl_rx).await?;
    let (mut pty_tx, pty_rx) = conn.accept_bi().await?;

    let buf_reader = BufReader::new(pty_rx);
    let mut decoder = Lz4Reader::new(buf_reader);

    pty_tx.write_all(b"stty -echo; clear\n").await?;
    tokio::time::sleep(Duration::from_millis(400)).await;
    let mut sink = vec![0u8; 64 * 1024];
    let _ = tokio::time::timeout(Duration::from_millis(300), decoder.read(&mut sink)).await;

    // 40 rounds × 100 unique numbered lines = 4000 lines, each round preceded
    // by ESC[2J (clear screen) + ESC[H (home). This is the "redraw" pattern
    // that produces many small LZ4 blocks mid-stream.
    const ROUNDS: usize = 40;
    const LINES_PER_ROUND: usize = 100;
    let cmd = format!(
        "for r in $(seq 1 {R}); do \
           printf '\\033[2J\\033[H'; \
           for i in $(seq -f '%03g' 1 {L}); do \
             printf 'R%02d:L%s|payload-payload-payload|\\033[32mGREEN-%s\\033[0m|done\\n' \"$r\" \"$i\" \"$i\"; \
           done; \
         done; printf '@@REDRAW_TEST_DONE@@\\n'\n",
        R = ROUNDS,
        L = LINES_PER_ROUND
    );
    pty_tx.write_all(cmd.as_bytes()).await?;

    let mut acc = Vec::with_capacity(ROUNDS * LINES_PER_ROUND * 100);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while tokio::time::Instant::now() < deadline {
        let mut tmp = vec![0u8; 16 * 1024];
        let r = tokio::time::timeout(Duration::from_millis(400), decoder.read(&mut tmp)).await;
        match r {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                acc.extend_from_slice(&tmp[..n]);
                let s = String::from_utf8_lossy(&acc);
                if s.contains("@@REDRAW_TEST_DONE@@") {
                    break;
                }
            }
            Ok(Err(_)) => break,
            Err(_) => {}
        }
    }
    let text = String::from_utf8_lossy(&acc).into_owned();
    assert!(
        text.contains("@@REDRAW_TEST_DONE@@"),
        "sentinel missing — got {} bytes",
        acc.len(),
    );

    // Each (round, line) should appear at least once.
    let mut bad = Vec::new();
    'outer: for r in 1..=ROUNDS {
        for l in 1..=LINES_PER_ROUND {
            let expected = format!(
                "R{r:02}:L{l:03}|payload-payload-payload|\x1b[32mGREEN-{l:03}\x1b[0m|done",
                r = r,
                l = l
            );
            if !text.contains(&expected) {
                bad.push((r, l));
                if bad.len() > 12 {
                    break 'outer;
                }
            }
        }
    }
    assert!(
        bad.is_empty(),
        "redraw storm corrupted output: missing (round, line) tuples = {:?} (total {} bytes)",
        bad,
        text.len(),
    );
    println!(
        "✓ lz4 integrity OK across {} rounds × {} lines = {} lines, {} bytes",
        ROUNDS,
        LINES_PER_ROUND,
        ROUNDS * LINES_PER_ROUND,
        text.len()
    );
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn spki_mismatch_rejected() -> anyhow::Result<()> {
    let tls = flyterm_server::tls::generate_ephemeral()?;
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
        ring_size_bytes: 64 * 1024,
        parser_scrollback_rows: 1000,
        max_tabs_per_session: 8,
        term: "xterm-256color".into(),
        allow_compression: false,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(ep, store, cfg));
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Use WRONG SPKI bytes → should fail TLS verification
    let wrong_spki = vec![0u8; 32];
    let client_ep = make_client_endpoint(wrong_spki)?;
    let addr: std::net::SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let result = connect(&client_ep, addr, "aqt").await;
    assert!(result.is_err(), "Expected SPKI mismatch error, got Ok");
    println!("✓ SPKI mismatch correctly rejected: {:?}", result.err());
    Ok(())
}

// Run one session against the given server: HELLO with chosen caps, OPEN_TAB,
// send `command`, read raw bytes from the PTY recv stream (decompressing if
// `use_lz4`) until `sentinel` is observed. Returns everything from `start`
// (inclusive) to `end` (exclusive). Stripping shell prompts and echoed input
// out lets us compare two sessions byte-by-byte.
async fn capture_pty_window(
    addr: std::net::SocketAddr,
    spki_bytes: Vec<u8>,
    use_lz4: bool,
    command: &[u8],
    start_marker: &str,
    end_marker: &str,
) -> anyhow::Result<Vec<u8>> {
    let client_ep = make_client_endpoint(spki_bytes)?;
    let conn = connect(&client_ep, addr, "aqt").await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;
    let caps = if use_lz4 { CAP_LZ4 } else { 0 };
    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0x42; 16],
            capabilities: caps,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: HelloAck = read_frame(&mut ctrl_rx).await?;
    let actual_lz4 = (ack.server_caps & CAP_LZ4) != 0;
    assert_eq!(
        actual_lz4, use_lz4,
        "server caps mismatch — expected lz4={} got={}",
        use_lz4, actual_lz4,
    );

    let mut buf = BytesMut::new();
    encode_frame(
        &OpenTab {
            cols: 200,
            rows: 80,
            term: "xterm-256color".into(),
            cwd: "".into(),
            cmd: "".into(),
            preload_history: None,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let _ack: OpenTabAck = read_frame(&mut ctrl_rx).await?;

    let (mut pty_tx, pty_rx) = conn.accept_bi().await?;

    // Read all available output via the appropriate path.
    let buf_reader = BufReader::new(pty_rx);
    let mut decoder = if use_lz4 {
        PtyReader::Lz4(Lz4Reader::new(buf_reader))
    } else {
        PtyReader::Plain(buf_reader)
    };

    // Settle: drain initial prompt before sending the command.
    pty_tx.write_all(b"stty -echo; clear\n").await?;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut sink = vec![0u8; 64 * 1024];
    let _ = tokio::time::timeout(Duration::from_millis(300), decoder.read(&mut sink)).await;

    // Send the test command.
    pty_tx.write_all(command).await?;

    // Drain until end marker.
    let mut acc = Vec::with_capacity(128 * 1024);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    while tokio::time::Instant::now() < deadline {
        let mut tmp = vec![0u8; 16 * 1024];
        let r = tokio::time::timeout(Duration::from_millis(500), decoder.read(&mut tmp)).await;
        match r {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                acc.extend_from_slice(&tmp[..n]);
                if find_substr(&acc, end_marker.as_bytes()).is_some() {
                    break;
                }
            }
            _ => {}
        }
    }

    let start = find_substr(&acc, start_marker.as_bytes())
        .ok_or_else(|| anyhow::anyhow!("start marker missing"))?;
    let end = find_substr(&acc, end_marker.as_bytes())
        .ok_or_else(|| anyhow::anyhow!("end marker missing"))?;
    Ok(acc[start..end + end_marker.len()].to_vec())
}

fn find_substr(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// CROSS-MODE COMPARISON: same deterministic shell command run twice
/// against the same server — once with compression off, once with compression
/// on. The decoded byte windows MUST match. If they don't, compression is
/// altering bytes in production (and the simpler bit-exact stress test
/// missed it). If they DO match, the rendering-residue bug observed in the
/// real app is downstream of decompression — likely a chunk-size or timing
/// effect in xterm.dart or the FFI poller.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn byte_streams_match_across_compression_modes() -> anyhow::Result<()> {
    let tls = flyterm_server::tls::generate_ephemeral()?;
    let spki_bytes = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&tls.spki_base64)?;
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
        // Server willing to negotiate either mode; client chooses by setting
        // CAP_LZ4 in Hello.capabilities.
        allow_compression: true,
        history_root: None,
        notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(ep, store, cfg));
    tokio::time::sleep(Duration::from_millis(50)).await;
    let addr: std::net::SocketAddr = format!("127.0.0.1:{port}").parse()?;

    // Mixed-content payload: index + UTF-8 中文 + truecolor SGR + extended
    // SGR forms (38;2;R;G;B) + cursor moves + SGR reset. Each line ends with
    // a \r\n so the PTY's line discipline doesn't fold them.
    let cmd = b"\
        stty -echo;\
        printf '\\n@@START@@\\n';\
        for i in $(seq -f '%04g' 1 500); do \
          printf '%s|\\033[38;2;100;200;50mZ-%s-Z\\033[0m|\\xe4\\xb8\\xad\\xe6\\x96\\x87|\\033[7;1H\\033[%s;1H|END\\n' \"$i\" \"$i\" \"$i\"; \
        done; \
        printf '@@END@@\\n'\n";

    let plain = capture_pty_window(
        addr,
        spki_bytes.clone(),
        false,
        cmd,
        "@@START@@\r\n",
        "@@END@@\r\n",
    )
    .await?;

    let lz4 =
        capture_pty_window(addr, spki_bytes, true, cmd, "@@START@@\r\n", "@@END@@\r\n").await?;

    println!("plain window: {} bytes", plain.len());
    println!("lz4   window: {} bytes", lz4.len());

    if plain == lz4 {
        println!("✓ BYTE STREAMS IDENTICAL — compression preserves content; rendering issue is downstream.");
        return Ok(());
    }

    // Hashes to spot quick "size matches but content differs".
    eprintln!("✗ BYTE STREAMS DIFFER");
    eprintln!("  plain len: {}  lz4 len: {}", plain.len(), lz4.len());
    let limit = plain.len().min(lz4.len());
    let mut first_diff = None;
    for i in 0..limit {
        if plain[i] != lz4[i] {
            first_diff = Some(i);
            break;
        }
    }
    if let Some(i) = first_diff {
        let lo = i.saturating_sub(40);
        let hi_p = (i + 40).min(plain.len());
        let hi_z = (i + 40).min(lz4.len());
        eprintln!(
            "  first diff at byte {} (out of {} common):\n    plain[..]: {:?}\n    lz4  [..]: {:?}",
            i,
            limit,
            String::from_utf8_lossy(&plain[lo..hi_p]),
            String::from_utf8_lossy(&lz4[lo..hi_z]),
        );
    } else if plain.len() != lz4.len() {
        eprintln!(
            "  first {} bytes match; length differs by {}",
            limit,
            plain.len().abs_diff(lz4.len())
        );
        // Show extra tail
        if plain.len() > lz4.len() {
            eprintln!(
                "    plain tail: {:?}",
                String::from_utf8_lossy(&plain[limit..(limit + 80).min(plain.len())])
            );
        } else {
            eprintln!(
                "    lz4   tail: {:?}",
                String::from_utf8_lossy(&lz4[limit..(limit + 80).min(lz4.len())])
            );
        }
    }
    panic!("byte stream divergence");
}

// ── Characterization tests: behaviour the quinn/rustls migration must keep ──

/// Plain (uncompressed) in-process server; returns its address and the SPKI
/// the client should pin.
async fn start_plain_server() -> anyhow::Result<(std::net::SocketAddr, Vec<u8>)> {
    let tls = flyterm_server::tls::generate_ephemeral()?;
    let spki = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&tls.spki_base64)?;
    let ep = flyterm_server::endpoint::build_endpoint(
        "127.0.0.1:0".parse()?,
        &tls,
        flyterm_server::cli::CongestionKind::Cubic,
    )?;
    let addr = format!("127.0.0.1:{}", ep.local_addr.port()).parse()?;
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
        notify_sock: Some(std::path::PathBuf::from("/tmp/flyterm-test-notify.sock")),
    };
    tokio::spawn(flyterm_server::endpoint::accept_loop(ep, store, cfg));
    tokio::time::sleep(Duration::from_millis(50)).await;
    Ok((addr, spki))
}

/// HELLO → HELLO_ACK on a fresh control stream; returns the stream halves.
async fn hello(conn: &quinn::Connection) -> anyhow::Result<(quinn::SendStream, quinn::RecvStream)> {
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
    Ok((tx, rx))
}

/// The client's SPKI pin is only half the check: the server must also prove
/// it holds the private key by signing the TLS 1.3 handshake. A peer that
/// presents the pinned (public) certificate but signs with another key —
/// i.e. a MITM that copied the cert — must be rejected.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pinned_cert_with_wrong_key_rejected() -> anyhow::Result<()> {
    use std::sync::Arc;

    #[derive(Debug)]
    struct WrongKey(Arc<rustls::sign::CertifiedKey>);
    impl rustls::server::ResolvesServerCert for WrongKey {
        fn resolve(
            &self,
            _: rustls::server::ClientHello<'_>,
        ) -> Option<Arc<rustls::sign::CertifiedKey>> {
            Some(self.0.clone())
        }
    }

    let pinned = flyterm_server::tls::generate_ephemeral()?;
    let other = flyterm_server::tls::generate_ephemeral()?;
    let wrong_key = rustls::crypto::ring::sign::any_supported_type(&other.private_key)
        .map_err(|e| anyhow::anyhow!("signing key: {e:?}"))?;
    let certified = Arc::new(rustls::sign::CertifiedKey::new(
        pinned.cert_chain.clone(),
        wrong_key,
    ));
    let mut server_crypto = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_no_client_auth()
    .with_cert_resolver(Arc::new(WrongKey(certified)));
    server_crypto.alpn_protocols = vec![aqt_protocol::ALPN.to_vec()];
    let server = quinn::Endpoint::server(
        quinn::ServerConfig::with_crypto(Arc::new(
            quinn::crypto::rustls::QuicServerConfig::try_from(server_crypto)?,
        )),
        "127.0.0.1:0".parse()?,
    )?;
    let addr = server.local_addr()?;
    tokio::spawn(async move {
        while let Some(incoming) = server.accept().await {
            if let Ok(connecting) = incoming.accept() {
                let _ = connecting.await;
            }
        }
    });

    let spki = base64::engine::general_purpose::STANDARD_NO_PAD.decode(&pinned.spki_base64)?;
    let client_ep = make_client_endpoint(spki)?;
    let result = connect(&client_ep, addr, "aqt").await;
    let err = format!(
        "{:#}",
        result.err().expect("handshake with wrong key must fail")
    );
    assert!(
        !err.contains("SPKI mismatch"),
        "rejected by the pin, not the signature check — the cert matched, so \
         this must fail on key possession: {err}"
    );
    Ok(())
}

/// The client's liveness probes are 1-byte QUIC datagrams; the server must
/// keep advertising datagram support or every heartbeat fails.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn server_accepts_heartbeat_datagrams() -> anyhow::Result<()> {
    let (addr, spki) = start_plain_server().await?;
    let client_ep = make_client_endpoint(spki)?;
    let conn = connect(&client_ep, addr, "aqt").await?;
    let _ctrl = hello(&conn).await?;
    assert!(
        conn.max_datagram_size().is_some(),
        "peer does not accept datagrams"
    );
    assert!(conn
        .send_datagram(bytes::Bytes::from_static(b"\x00"))
        .is_ok());
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(conn.close_reason().is_none(), "{:?}", conn.close_reason());
    Ok(())
}

/// quinn's default idle timeout is 10 s. Both peers set 90 s (with a 15 s
/// keep-alive); if either side lost that setting the connection would die
/// here, since the effective timeout is the minimum of the two.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn idle_connection_survives_past_default_timeout() -> anyhow::Result<()> {
    let (addr, spki) = start_plain_server().await?;
    let client_ep = make_client_endpoint(spki)?;
    let conn = connect(&client_ep, addr, "aqt").await?;
    let (mut ctrl_tx, mut ctrl_rx) = hello(&conn).await?;

    tokio::time::sleep(Duration::from_secs(12)).await;
    assert!(conn.close_reason().is_none(), "{:?}", conn.close_reason());

    // Prove the control stream still round-trips after the idle period.
    let mut buf = BytesMut::new();
    encode_frame(
        &OpenTab {
            cols: 80,
            rows: 24,
            term: "xterm-256color".into(),
            cwd: "".into(),
            cmd: "".into(),
            preload_history: None,
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack: OpenTabAck = read_frame(&mut ctrl_rx).await?;
    assert!(matches!(ack.status, OpenTabStatus::Ok));

    // Exit the shell so the server's blocking PTY reader can finish (see
    // full_client_flow_spki_pinning).
    let (mut pty_tx, mut pty_rx) = conn.accept_bi().await?;
    pty_tx.write_all(b"exit\n").await?;
    let mut sink = [0u8; 1024];
    let _ = tokio::time::timeout(Duration::from_secs(2), async {
        while let Ok(Some(_)) = pty_rx.read(&mut sink).await {}
    })
    .await;
    Ok(())
}
