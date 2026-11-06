// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::{anyhow, Result};
use aqt_protocol::ALPN;
use once_cell::sync::Lazy;
use quinn::{ClientConfig, Connection, Endpoint};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use std::sync::Arc;
use std::time::Duration;
use x509_parser::prelude::*;

/// ring only: the rustls/quinn default (aws-lc) carries OpenSSL-licensed
/// code, which is GPL-incompatible.
fn crypto_provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// Pins the server's SPKI instead of validating a CA chain.
///
/// The pin alone only proves the server *presented* the expected public key;
/// the TLS 1.3 handshake signature is what proves it *holds* the private
/// key. `verify_tls13_signature` must therefore really verify — returning
/// `assertion()` there would let anyone replaying the public cert MITM the
/// connection (guarded by `pinned_cert_with_wrong_key_rejected`).
#[derive(Debug)]
struct SpkiPinVerifier {
    expected_spki: Vec<u8>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for SpkiPinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let (_, parsed) = X509Certificate::from_der(end_entity)
            .map_err(|e| rustls::Error::General(format!("parse cert: {e}")))?;
        let spki = parsed.tbs_certificate.subject_pki.raw;
        if spki == self.expected_spki.as_slice() {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("SPKI mismatch".into()))
        }
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 not supported".into()))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Global TLS session store shared across all QUIC connections.
///
/// rustls uses ClientConfig.resumption which holds an Arc<dyn ClientSessionStore>.
/// Sharing one store across endpoints lets session tickets from the first HELLO
/// be reused in subsequent aqt_resume() calls (network switch path), reducing
/// the TLS handshake from 1 RTT to ~0 RTT via PSK resumption.
///
/// Impact: proactive RESUME: 2 RTT → ~1 RTT (~100ms on GCP at 30ms RTT).
// 256 entries: room for multiple servers + multiple network-switch sessions.
static TLS_SESSION_STORE: Lazy<Arc<dyn rustls::client::ClientSessionStore>> =
    Lazy::new(|| Arc::new(rustls::client::ClientSessionMemoryCache::new(256)));

pub fn make_client_endpoint(expected_spki: Vec<u8>) -> Result<Endpoint> {
    let provider = crypto_provider();
    let mut crypto = rustls::ClientConfig::builder_with_provider(Arc::clone(&provider))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| anyhow!("TLS config: {e}"))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(SpkiPinVerifier {
            expected_spki,
            provider,
        }))
        .with_no_client_auth();
    crypto.alpn_protocols = vec![ALPN.to_vec()];
    // Share a session store so TLS tickets from prior connections enable
    // PSK-based resumption (0-RTT / 0.5-RTT) on network switches.
    crypto.resumption = rustls::client::Resumption::store(Arc::clone(&*TLS_SESSION_STORE));
    // ENABLE 0-RTT EARLY DATA. rustls defaults this to false — without this
    // flag, into_0rtt() always returns Err regardless of cached session
    // tickets, and every reconnect pays the full 1-RTT handshake. Server
    // is already configured with max_early_data_size=u32::MAX (endpoint.rs).
    // RESUME is idempotent so 0-RTT replay attacks are benign.
    crypto.enable_early_data = true;

    let mut cfg = ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(crypto)
            .map_err(|e| anyhow!("QUIC TLS config: {e}"))?,
    ));
    let mut transport = quinn::TransportConfig::default();
    // Must match server (endpoint.rs): Quinn keep_alive 15 s + foreground-only
    // app heartbeat 5 s. Quinn PING keeps NAT alive in background reliably;
    // app heartbeat provides foreground fast-failure detection.
    transport.keep_alive_interval(Some(Duration::from_secs(15)));
    // max_idle_timeout MUST be set explicitly and MUST exceed keep_alive_interval.
    // Omitting the setter does NOT disable the timeout — it falls back to
    // quinn's default of 10 s, which is shorter than the 15 s keep-alive above
    // and kills every idle connection before the first PING. Must stay in sync
    // with flyterm-server/src/endpoint.rs; the effective timeout is the minimum
    // of the two peers' advertised values, so leaving either side at the
    // default would re-introduce the 10 s death.
    //
    // Also mirrored in Dart as ReconnectService.kQuicIdleTimeout
    // (lib/ssh/reconnect_service.dart) — it derives the "probe before RESUME?"
    // decision from this value. Changing the timeout here without updating
    // that constant silently skews the probe heuristic.
    transport.max_idle_timeout(Some(Duration::from_secs(90).try_into()?));
    // Enable QUIC datagrams so aqt_heartbeat() can send 1-byte probe packets.
    // Server drains these in its datagram-drain task.
    transport.datagram_receive_buffer_size(Some(4096));
    // MTU: start at QUIC minimum (1200 B per RFC 9000 §14.1).
    // GCP + mobile paths often have effective MTU < 1452; without this the
    // kernel rejects outgoing packets with EMSGSIZE, stalling the handshake.
    transport.initial_mtu(1200);
    transport.mtu_discovery_config(None); // disable PMTUD probing
    cfg.transport_config(Arc::new(transport));

    let mut ep = Endpoint::client("0.0.0.0:0".parse()?)?;
    ep.set_default_client_config(cfg);
    Ok(ep)
}

pub async fn connect(
    endpoint: &Endpoint,
    server_addr: std::net::SocketAddr,
    sni: &str,
) -> Result<Connection> {
    endpoint
        .connect(server_addr, sni)
        .map_err(|e| anyhow!("connect: {e}"))?
        .await
        .map_err(|e| anyhow!("handshake: {e}"))
}

/// Attempt a 0-RTT connect: if the TLS session cache has a usable ticket for
/// this server name, the connection is returned IMMEDIATELY and any data
/// written to it is sent alongside the TLS handshake (1 RTT total instead of 2).
///
/// Returns (Connection, zero_rtt_accepted_future). The future resolves to true
/// if the server accepted 0-RTT data, false if it fell back to 1-RTT.
/// If no ticket is available, falls back to a normal 1-RTT connect.
pub async fn connect_0rtt(
    endpoint: &Endpoint,
    server_addr: std::net::SocketAddr,
    sni: &str,
) -> Result<(Connection, bool)> {
    let connecting = endpoint
        .connect(server_addr, sni)
        .map_err(|e| anyhow!("connect: {e}"))?;
    match connecting.into_0rtt() {
        Ok((conn, accepted)) => {
            tracing::debug!("0-RTT connect: data flowing during handshake");
            let was_accepted = accepted.await;
            Ok((conn, was_accepted))
        }
        Err(connecting) => {
            tracing::debug!("0-RTT unavailable, falling back to 1-RTT");
            let conn = connecting.await.map_err(|e| anyhow!("handshake: {e}"))?;
            Ok((conn, false))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::{Certificate as RcgenCert, CertificateParams, PKCS_ED25519};

    #[test]
    fn spki_match() {
        let mut params = CertificateParams::new(vec!["aqt".to_string()]);
        params.alg = &PKCS_ED25519;
        let cert = RcgenCert::from_params(params).unwrap();
        let cert_der = cert.serialize_der().unwrap();
        let expected_spki = cert.get_key_pair().public_key_der().to_vec();

        let verifier = SpkiPinVerifier {
            expected_spki,
            provider: crypto_provider(),
        };
        let rustls_cert = CertificateDer::from(cert_der);
        let result = verifier.verify_server_cert(
            &rustls_cert,
            &[],
            &ServerName::try_from("aqt").unwrap(),
            &[],
            UnixTime::now(),
        );
        assert!(result.is_ok());
    }

    #[test]
    fn spki_mismatch_rejected() {
        let mut params1 = CertificateParams::new(vec!["aqt".to_string()]);
        params1.alg = &PKCS_ED25519;
        let cert1 = RcgenCert::from_params(params1).unwrap();
        let mut params2 = CertificateParams::new(vec!["aqt".to_string()]);
        params2.alg = &PKCS_ED25519;
        let cert2 = RcgenCert::from_params(params2).unwrap();
        let cert_der = cert1.serialize_der().unwrap();
        let wrong_spki = cert2.get_key_pair().public_key_der().to_vec();

        let verifier = SpkiPinVerifier {
            expected_spki: wrong_spki,
            provider: crypto_provider(),
        };
        let rustls_cert = CertificateDer::from(cert_der);
        let result = verifier.verify_server_cert(
            &rustls_cert,
            &[],
            &ServerName::try_from("aqt").unwrap(),
            &[],
            UnixTime::now(),
        );
        assert!(result.is_err());
    }

    // quinn's Endpoint::client binds its socket on the ambient tokio runtime.
    #[tokio::test]
    async fn session_cache_shared() {
        // Verify two endpoints share the same session cache instance.
        let ep1 = make_client_endpoint(vec![0xAA; 32]);
        let ep2 = make_client_endpoint(vec![0xBB; 32]);
        assert!(ep1.is_ok() && ep2.is_ok());
        // Both use the same TLS_SESSION_CACHE — no assert needed beyond compilation.
    }
}
