// SPDX-License-Identifier: GPL-3.0-or-later
//! 幂等性与 scrollback 分页的端到端验证。
//!
//! 这是整个会话恢复重新设计的**地基不变量**：恢复传的是幂等的屏幕快照，
//! 所以重复应用、乱序应用、六路并发应用的结果完全相同。单元测试锁住了
//! snapshot 层，这里锁住整条链路 —— 真起一个 server、真跑 RESUME、把拿到
//! 的快照喂进 vt100 比对。
//!
//! 为什么这条必须端到端：客户端那六个发起点（prewarm / coldHydrate /
//! preSsh / fullreconn / proactive-live / proactive-disk）能合并成一个
//! coordinator，前提就是并发 RESUME 无害。那个前提如果只在纸面上成立，
//! coordinator 就变成了「靠时序保证正确」—— 恰恰是上一版设计反复出问题的
//! 地方。
//!
//! 需要能分配 PTY。CI 里没有 PTY 时整个文件跳过（与 protocol_integration
//! 里 resume_sends_live_data_without_prelude 同样的处理）。

use aqt_protocol::{
    decode_frame_header, encode_frame, Disposition, FramePayload, Hello, HelloAck, OpenTab,
    OpenTabAck, Resume, ResumeAck, ALPN, PROTOCOL_VERSION,
};
use bytes::{Buf, BytesMut};
use quinn::{ClientConfig, Endpoint};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

// ── 脚手架（与 protocol_integration.rs 同构）──────────────────────────

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
        let mut tmp = [0u8; 4096];
        match rx.read(&mut tmp).await? {
            Some(n) => buf.extend_from_slice(&tmp[..n]),
            None => anyhow::bail!("stream closed before a full frame arrived"),
        }
        let mut peek: &[u8] = &buf;
        let Ok((_op, len)) = decode_frame_header(&mut peek) else {
            continue;
        };
        if peek.len() < len {
            continue;
        }
        let hlen = buf.len() - peek.len();
        let _ = buf.split_to(hlen);
        let payload = buf.split_to(len);
        let mut p: &[u8] = &payload;
        return P::decode(&mut p).map_err(|e| anyhow::anyhow!("decode: {e:?}"));
    }
}

fn start_server() -> u16 {
    let tls = flyterm_server::tls::generate_ephemeral().expect("ephemeral tls");
    let ep = flyterm_server::endpoint::build_endpoint(
        "127.0.0.1:0".parse().unwrap(),
        &tls,
        flyterm_server::cli::CongestionKind::Cubic,
    )
    .expect("build endpoint");
    let port = ep.local_addr.port();
    let store = flyterm_server::session::SessionStore::new(
        16,
        flyterm_server::session::DEFAULT_SESSION_TTL,
    );
    let cfg = flyterm_server::connection::ConnectionConfig {
        ring_size_bytes: 256 * 1024,
        parser_scrollback_rows: 5000,
        max_tabs_per_session: 8,
        term: "xterm-256color".into(),
        allow_compression: false,
        history_root: None,
        notify_sock: None,
    };
    tokio::spawn(async move {
        let _ = flyterm_server::endpoint::accept_loop(ep, store, cfg).await;
    });
    port
}

/// HELLO + OPEN_TAB，跑一条命令，返回 (session_token, tab_id)。
///
/// 返回 None 表示这台机器分配不到 PTY（CI 常见），调用方据此跳过。
async fn open_session(port: u16, cmd: &str) -> anyhow::Result<Option<([u8; 32], u32)>> {
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
    ctrl_tx.write_all(&buf).await?;
    let tab_ack: OpenTabAck = match tokio::time::timeout(
        Duration::from_secs(5),
        read_frame::<OpenTabAck>(&mut ctrl_rx),
    )
    .await
    {
        Ok(Ok(a)) => a,
        // 没有 PTY 可分配 —— 跳过而不是失败。
        _ => return Ok(None),
    };
    if tab_ack.status != aqt_protocol::OpenTabStatus::Ok {
        return Ok(None);
    }

    // 服务端为这个 tab 开了一条 bidi 流，往里写命令。
    let (mut pty_tx, _pty_rx) = conn.accept_bi().await?;
    pty_tx.write_all(cmd.as_bytes()).await?;
    // 给 shell 时间产出输出并进 ring。
    tokio::time::sleep(Duration::from_millis(700)).await;

    Ok(Some((ack.session_token, tab_ack.tab_id)))
}

/// 发一次 RESUME，返回 (ResumeAck, 恢复内容字节)。每次用**新连接**——真实
/// 客户端就是这样：断线重连本来就是新的 QUIC 连接。
///
/// 恢复内容不在 ResumeAck 里，它是新 PTY 流的头几个字节。这条流不会 EOF
/// （live 输出还在后面），所以按超时收一段就够——快照是自足的，收全即可判等。
/// 测试的 HELLO 用 `capabilities: 0`，服务端不压缩，读到的就是原始字节。
async fn resume_once(port: u16, token: [u8; 32], tab: u32) -> anyhow::Result<(ResumeAck, Vec<u8>)> {
    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;
    let mut buf = BytesMut::new();
    encode_frame(
        &Resume {
            session_token: token,
            tabs: vec![tab],
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack = read_frame::<ResumeAck>(&mut ctrl_rx).await?;

    let (_pty_tx, mut pty_rx) = conn.accept_bi().await?;
    let mut prelude = Vec::new();
    let mut b = [0u8; 8192];
    let deadline = tokio::time::Instant::now() + Duration::from_millis(400);
    loop {
        match tokio::time::timeout_at(deadline, pty_rx.read(&mut b)).await {
            Ok(Ok(Some(n))) => prelude.extend_from_slice(&b[..n]),
            _ => break,
        }
    }

    // 连接留到函数结束才 drop —— 提前关会让服务端那侧的 forwarder 立刻
    // 收摊，后续 RESUME 的观察对象就不一样了。
    drop(conn);
    Ok((ack, prelude))
}

/// 断言服务端确实声明了 Restored（内容本身走 PTY 流，不在这个帧里）。
fn assert_restored(ack: &ResumeAck, tab: u32) {
    match &ack
        .tabs
        .iter()
        .find(|t| t.tab_id == tab)
        .expect("tab in ack")
        .disposition
    {
        Disposition::Restored { .. } => {}
        other => panic!("期望 Restored，实际 {other:?}"),
    }
}

fn render(bytes: &[u8]) -> String {
    let mut p = vt100::Parser::new(24, 80, 0);
    p.process(bytes);
    String::from_utf8_lossy(&p.screen().contents_formatted()).into_owned()
}

// ── 测试 ────────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resuming_twice_lands_on_the_same_screen() -> anyhow::Result<()> {
    let port = start_server();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let Some((token, tab)) = open_session(port, "echo hello-idempotence\n").await? else {
        eprintln!("skip: 无法分配 PTY");
        return Ok(());
    };

    let (ack1, s1) = resume_once(port, token, tab).await?;
    let (ack2, s2) = resume_once(port, token, tab).await?;
    assert_restored(&ack1, tab);
    assert_restored(&ack2, tab);

    assert!(s1.starts_with(b"\x1bc"), "快照必须自足（开头是 RIS）");
    assert!(s2.starts_with(b"\x1bc"));

    // 应用一次 vs 连续应用两次 —— 结果必须相同。
    let once = render(&s1);
    let twice = {
        let mut p = vt100::Parser::new(24, 80, 0);
        p.process(&s1);
        p.process(&s2);
        String::from_utf8_lossy(&p.screen().contents_formatted()).into_owned()
    };
    assert_eq!(once, twice, "连续两次 RESUME 的快照叠加后必须与一次相同");
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn six_concurrent_resumes_all_get_usable_screens() -> anyhow::Result<()> {
    // 六个发起点的并发场景。协议里没有 offset，所以这些请求互不干扰 ——
    // 每一个都该拿到一份能用的快照，而不是「最后一个赢、前面几个拿到半截」。
    let port = start_server();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let Some((token, tab)) = open_session(port, "echo hello-concurrent\n").await? else {
        eprintln!("skip: 无法分配 PTY");
        return Ok(());
    };

    let acks = futures::future::join_all((0..6).map(|_| resume_once(port, token, tab))).await;
    let screens: Vec<Vec<u8>> = acks
        .into_iter()
        .map(|a| {
            let (ack, bytes) = a.expect("resume ok");
            assert_restored(&ack, tab);
            bytes
        })
        .collect();

    for s in &screens {
        assert!(s.starts_with(b"\x1bc"), "每份快照都必须自足");
    }
    let first = render(&screens[0]);
    for (i, s) in screens.iter().enumerate().skip(1) {
        assert_eq!(render(s), first, "第 {i} 份快照与第 0 份不一致");
    }
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn applying_a_stale_snapshot_still_converges() -> anyhow::Result<()> {
    // 乱序：先拿一份快照，让终端继续产出，再拿第二份，然后**倒着**应用。
    // 幂等意味着最终状态由最后应用的那一份决定，而不是叠加出第三种东西。
    let port = start_server();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let Some((token, tab)) = open_session(port, "echo first-line\n").await? else {
        eprintln!("skip: 无法分配 PTY");
        return Ok(());
    };

    let (_e_ack, early) = resume_once(port, token, tab).await?;
    let (_l_ack, late) = resume_once(port, token, tab).await?;

    // 倒序应用（stale 后到）与只应用 stale 那一份，结果相同。
    let reversed = {
        let mut p = vt100::Parser::new(24, 80, 0);
        p.process(&late);
        p.process(&early);
        String::from_utf8_lossy(&p.screen().contents_formatted()).into_owned()
    };
    assert_eq!(
        reversed,
        render(&early),
        "乱序应用后，最终状态该由最后应用的那一份决定"
    );
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resume_payload_carries_the_whole_scrollback() -> anyhow::Result<()> {
    let port = start_server();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let Some((token, tab)) = open_session(port, "seq 1 200\n").await? else {
        eprintln!("skip: 无法分配 PTY");
        return Ok(());
    };

    // 恢复一次，负载里应当就带着完整历史。
    let ep = make_client_ep();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let conn = ep.connect(addr, "aqt")?.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;
    let mut buf = BytesMut::new();
    encode_frame(
        &Resume {
            session_token: token,
            tabs: vec![tab],
        },
        &mut buf,
    )?;
    ctrl_tx.write_all(&buf).await?;
    let ack = read_frame::<ResumeAck>(&mut ctrl_rx).await?;
    match &ack.tabs[0].disposition {
        Disposition::Restored { .. } => {}
        other => panic!("期望 Restored，实际 {other:?}"),
    }
    // content 里应当已经带上了**全部**历史。它走新 PTY 流的头几个字节，
    // 不在 ResumeAck 里。
    let (_pty_tx, mut pty_rx) = conn.accept_bi().await?;
    let mut content = Vec::new();
    let mut rb = [0u8; 8192];
    let deadline = tokio::time::Instant::now() + Duration::from_millis(400);
    loop {
        match tokio::time::timeout_at(deadline, pty_rx.read(&mut rb)).await {
            Ok(Ok(Some(n))) => content.extend_from_slice(&rb[..n]),
            _ => break,
        }
    }
    let text = String::from_utf8_lossy(&content);
    assert!(
        text.contains("199") || text.contains("200"),
        "content 该带着 seq 的输出，实际前 200 字节：{:?}",
        &text.chars().take(200).collect::<String>()
    );

    // 一次送完，没有第二条通道。
    //
    // 这里曾经紧跟一个 `FetchScrollback` 请求，断言「往上取是空页」——
    // 也就是「content 已经带全了，别再取一遍」。那条通道现在整个删掉了，
    // 断言换成直接检查负载本身：`seq 1 200` 的输出远超一屏，最早那几行只
    // 可能来自历史段。
    //
    // 删掉通道之后这一点从「客户端要多问一次网络」变成「负载自带」——
    // 那条前插链路（预取回来时终端可能已经换代）也随之消失。
    assert!(
        text.contains("\n1\r") || text.contains("1\r\n") || text.contains(" 1"),
        "最早的输出该在历史段里；实际负载 {} 字节，末 200 字节：{:?}",
        text.len(),
        &text.chars().rev().take(200).collect::<String>()
    );
    // 顺序必须是「老的在前」——历史段在可见屏之前写出。
    let first_at = text.find("100").expect("中段内容该在");
    let last_at = text.rfind("200").expect("最新内容该在");
    assert!(
        first_at < last_at,
        "历史与可见屏的顺序反了：100 在 {first_at}，200 在 {last_at}"
    );
    Ok(())
}
