// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::{Context, Result};
use quinn::{Endpoint, ServerConfig};
use rustls::ServerConfig as RustlsServerConfig;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Notify;

use crate::cli::{CongestionKind, PortSpec};
use crate::connection::ConnectionConfig;
use crate::session::SessionStore;
use crate::tls::ServerTlsMaterial;

pub struct EndpointHandle {
    pub endpoint: Endpoint,
    pub local_addr: SocketAddr,
    pub shutdown: Arc<Notify>,
}

/// 在 [ports] 指定的端口段里绑定：依次尝试段内各端口，被占用的跳过。
///
/// 只有「端口已被占用」会换下一个；其他绑定错误（地址不存在、权限不足等）
/// 换端口也不会好，直接返回。整段都被占用时报错并带上端口段。
pub fn build_endpoint_in(
    bind_ip: &str,
    ports: PortSpec,
    tls: &ServerTlsMaterial,
    congestion: CongestionKind,
) -> Result<EndpointHandle> {
    build_endpoint_from(bind_ip, &ports.candidates(), tls, congestion)
        .map_err(|e| e.context(format!("no free UDP port in {ports}")))
}

/// [build_endpoint_in] 的确定性内核：按给定顺序尝试 [candidates]。
fn build_endpoint_from(
    bind_ip: &str,
    candidates: &[u16],
    tls: &ServerTlsMaterial,
    congestion: CongestionKind,
) -> Result<EndpointHandle> {
    for &port in candidates {
        let addr: SocketAddr = format!("{bind_ip}:{port}")
            .parse()
            .with_context(|| format!("invalid bind address {bind_ip}:{port}"))?;
        match build_endpoint(addr, tls, congestion) {
            Ok(h) => return Ok(h),
            Err(e) if is_addr_in_use(&e) => continue,
            Err(e) => return Err(e),
        }
    }
    Err(anyhow::anyhow!("every candidate port is in use"))
}

fn is_addr_in_use(e: &anyhow::Error) -> bool {
    e.chain().any(|c| {
        c.downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::AddrInUse)
    })
}

pub fn build_endpoint(
    bind_addr: SocketAddr,
    tls: &ServerTlsMaterial,
    congestion: CongestionKind,
) -> Result<EndpointHandle> {
    let mut server_crypto = RustlsServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_no_client_auth()
    .with_single_cert(tls.cert_chain.clone(), tls.private_key.clone_key())?;
    server_crypto.alpn_protocols = vec![aqt_protocol::ALPN.to_vec()];
    // Enable 0-RTT early data: client can send RESUME frame in the initial
    // packet alongside the TLS ClientHello, saving 1 RTT. RESUME carries a
    // session_token that the server validates — replay attacks are benign
    // (idempotent: server just re-binds the PTY forwarder to the new stream).
    server_crypto.max_early_data_size = u32::MAX;

    let mut server_config = ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(server_crypto)?,
    ));
    let mut transport = quinn::TransportConfig::default();
    transport.max_concurrent_bidi_streams(64u32.into());
    transport.max_concurrent_uni_streams(8u32.into());
    // Enable QUIC datagram reception so client heartbeat probes (1-byte datagrams)
    // are accepted. Datagrams are drained by the connection handler; if the buffer
    // fills up quinn silently drops new datagrams — correct behaviour for heartbeats.
    transport.datagram_receive_buffer_size(Some(4096));
    // Quinn keep_alive_interval: 15 s PING frames keep NAT mapping alive across
    // carrier UDP NAT timeouts (typical 30-60 s). Restored after the brief
    // "disable to save bandwidth" experiment showed that pure datagram-based
    // heartbeat cannot reliably keep mobile UDP paths alive — Mosh sustains
    // adaptive 3 s probes precisely because UDP NAT timeouts are aggressive.
    // PINGs are sent only when idle (no other traffic), and the QUIC frame is
    // <10 bytes — negligible cost compared to RESUME+1MB-prelude cycles.
    transport.keep_alive_interval(Some(std::time::Duration::from_secs(15)));
    // max_idle_timeout MUST be set explicitly and MUST exceed keep_alive_interval.
    //
    // This was previously commented out with a note claiming that removing it
    // made the connection "survive indefinitely". That is wrong: omitting the
    // setter does not disable the timeout, it falls back to quinn's DEFAULT of
    // 10 s (quinn-proto TransportConfig::default → max_idle_timeout:
    // Some(VarInt(10_000))). So the "fix" silently shortened the timeout from
    // the intended 90 s to 10 s — SHORTER than the 15 s keep-alive above, which
    // meant an idle connection always died at 10 s before the first keep-alive
    // PING could refresh it.
    //
    // Observed effect: the app cancels its 3 s foreground heartbeat when
    // backgrounded, leaving quinn's 15 s PING as the only traffic; every
    // connection therefore died ~10 s after the screen went off, and the
    // server logged a stream of `ConnectionLost(TimedOut)`.
    //
    // 90 s gives 6× headroom over the 15 s keep-alive, so a path only times out
    // when PINGs genuinely stop arriving.
    //
    // Also mirrored in Dart as ReconnectService.kQuicIdleTimeout
    // (lib/ssh/reconnect_service.dart) — it derives the "probe before RESUME?"
    // decision from this value. Changing the timeout here without updating
    // that constant silently skews the probe heuristic.
    transport.max_idle_timeout(Some(std::time::Duration::from_secs(90).try_into()?));
    // MTU: use QUIC minimum (1200 B per RFC 9000 §14.1) as the initial value.
    // GCP VMs sit behind Google's Andromeda SDN overlay which adds encapsulation;
    // the effective path MTU to mobile clients is often well below the Ethernet
    // default of 1472 (1500 - 28). Without this, quinn tries 1452-byte packets
    // that the kernel rejects with EMSGSIZE (errno 90), stalling the handshake.
    // quinn's PMTUD will probe upward from 1200 once the connection is alive.
    transport.initial_mtu(1200);
    // Disable MTU discovery to prevent quinn from probing larger packet sizes.
    // On GCP the effective path MTU to mobile clients is often < 1452; probing
    // at 1452 generates kernel EMSGSIZE (errno 90) which is benign but noisy
    // in logs and wastes cycles. Staying at 1200 (QUIC minimum) works on all
    // network paths.
    transport.mtu_discovery_config(None);
    // 拥塞控制。默认 CUBIC，`--congestion bbr` 切到 BBR —— 为什么这是个开关
    // 而不是直接换掉默认值，见 [`CongestionKind`] 的文档。
    //
    // 只装在服务端：拥塞控制在**发送端**生效，而恢复快照（现场 268 KB）是
    // server→client 的，客户端上行只有按键。
    //
    // 日志必须打：整个 flag 的用途是真机 A/B，而「以为开了、其实没开」会让
    // 结论整个反过来。这一行是现场唯一能确认它真的生效的凭据。
    match congestion {
        CongestionKind::Cubic => {
            transport
                .congestion_controller_factory(Arc::new(quinn::congestion::CubicConfig::default()));
        }
        CongestionKind::Bbr => {
            transport
                .congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
        }
    }
    log::info!("congestion control: {}", congestion.as_str());
    server_config.transport = Arc::new(transport);

    let endpoint = Endpoint::server(server_config, bind_addr)
        .with_context(|| format!("bind quinn endpoint to {bind_addr}"))?;
    let local_addr = endpoint.local_addr()?;
    Ok(EndpointHandle {
        endpoint,
        local_addr,
        shutdown: Arc::new(Notify::new()),
    })
}

pub async fn accept_loop(
    handle: EndpointHandle,
    store: SessionStore,
    cfg: ConnectionConfig,
) -> Result<()> {
    loop {
        tokio::select! {
            _ = handle.shutdown.notified() => {
                log::info!("endpoint shutdown requested");
                handle.endpoint.close(0u32.into(), b"shutdown");
                handle.endpoint.wait_idle().await;
                return Ok(());
            }
            incoming = handle.endpoint.accept() => {
                let Some(incoming) = incoming else { return Ok(()); };
                let store_c = store.clone();
                let cfg_c = cfg.clone();
                tokio::spawn(async move {
                    let connecting = match incoming.accept() {
                        Ok(c) => c,
                        Err(e) => {
                            log::warn!("incoming rejected: {e:#}");
                            return;
                        }
                    };
                    match connecting.await {
                        Ok(connection) => {
                            let peer = connection.remote_address();
                            log::info!("connection established (peer={peer})");
                            if let Err(e) = crate::connection::handle(connection, store_c, cfg_c).await {
                                log::warn!("connection error (peer={peer}): {e:#}");
                            }
                        }
                        Err(e) => log::warn!("handshake failed: {e:#}"),
                    }
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 段内有端口被占用时跳过它、绑到段内另一个空闲端口。
    #[tokio::test]
    async fn port_range_skips_occupied_port() -> Result<()> {
        let tls = crate::tls::generate_ephemeral()?;
        let squatter = std::net::UdpSocket::bind("127.0.0.1:0")?;
        let taken = squatter.local_addr()?.port();
        let free_neighbour = std::net::UdpSocket::bind(("127.0.0.1", taken + 1)).is_ok();
        if !free_neighbour {
            return Ok(()); // 相邻端口恰好被别人占着，构造不出这个场景
        }
        // 被占的排在前面，确定性地走「跳过、换下一个」这条路径。
        let h = build_endpoint_from(
            "127.0.0.1",
            &[taken, taken + 1],
            &tls,
            CongestionKind::Cubic,
        )?;
        assert_eq!(h.local_addr.port(), taken + 1);
        h.endpoint.close(0u32.into(), b"test");
        drop(squatter);
        Ok(())
    }

    /// 整段都被占用时报错，错误信息里带上端口段，方便用户对照安全组。
    #[tokio::test]
    async fn port_range_all_occupied_reports_range() -> Result<()> {
        let tls = crate::tls::generate_ephemeral()?;
        let squatter = std::net::UdpSocket::bind("127.0.0.1:0")?;
        let taken = squatter.local_addr()?.port();
        let ports = PortSpec {
            start: taken,
            end: taken,
        };
        let err = build_endpoint_in("127.0.0.1", ports, &tls, CongestionKind::Cubic)
            .err()
            .expect("all ports occupied must fail");
        assert!(
            format!("{err:#}").contains(&format!("no free UDP port in {taken}")),
            "{err:#}"
        );
        Ok(())
    }

    #[tokio::test]
    async fn port_spec_any_binds_random_port() -> Result<()> {
        let tls = crate::tls::generate_ephemeral()?;
        let h = build_endpoint_in("127.0.0.1", PortSpec::ANY, &tls, CongestionKind::Cubic)?;
        assert!(h.local_addr.port() != 0);
        h.endpoint.close(0u32.into(), b"test");
        Ok(())
    }

    #[tokio::test]
    async fn endpoint_binds_random_port() -> Result<()> {
        let tls = crate::tls::generate_ephemeral()?;
        let h = build_endpoint("127.0.0.1:0".parse()?, &tls, CongestionKind::Cubic)?;
        assert!(h.local_addr.port() != 0);
        h.endpoint.close(0u32.into(), b"test");
        Ok(())
    }

    /// 只证明 BBR 那条分支能装配起来（quinn 的 `ControllerFactory` 是
    /// `Box<dyn>`，装错类型是编译期错误，装配阶段 panic 才是运行期风险）。
    ///
    /// **它证明不了 BBR 真的在跑** —— quinn 不暴露当前的 controller，没有任何
    /// 进程内断言能验证这件事。生效与否只能看启动日志那行 `congestion
    /// control: bbr`，收益与否只能靠真机对拍 `resume-samples.txt`。
    #[tokio::test]
    async fn endpoint_builds_with_bbr() -> Result<()> {
        let tls = crate::tls::generate_ephemeral()?;
        let h = build_endpoint("127.0.0.1:0".parse()?, &tls, CongestionKind::Bbr)?;
        assert!(h.local_addr.port() != 0);
        h.endpoint.close(0u32.into(), b"test");
        Ok(())
    }
}
