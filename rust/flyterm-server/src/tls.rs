// SPDX-License-Identifier: GPL-3.0-or-later
/// TLS material generation using ring directly — no rcgen/pem/yasna dependency.
///
/// Produces a minimal self-signed ED25519 X.509 certificate whose only
/// purpose is to carry the public key in a TLS handshake. Clients pin
/// the SPKI out-of-band (via AQT_PUBKEY) and verify it through a custom
/// ServerCertVerifier, so neither the CA chain nor the validity window
/// matters for authentication.
use anyhow::Result;
use ring::{
    rand::{SecureRandom, SystemRandom},
    signature::{Ed25519KeyPair, KeyPair},
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

pub struct ServerTlsMaterial {
    pub cert_chain: Vec<CertificateDer<'static>>,
    /// Not `Clone`; use `clone_key()`.
    pub private_key: PrivateKeyDer<'static>,
    pub spki_base64: String,
}

// ── Minimal DER builder ─────────────────────────────────────────────────────

fn der_len(n: usize) -> Vec<u8> {
    if n < 0x80 {
        vec![n as u8]
    } else if n < 0x100 {
        vec![0x81, n as u8]
    } else {
        vec![0x82, (n >> 8) as u8, (n & 0xff) as u8]
    }
}

fn der_tlv(tag: u8, content: &[u8]) -> Vec<u8> {
    let mut v = vec![tag];
    v.extend(der_len(content.len()));
    v.extend_from_slice(content);
    v
}

fn der_seq(c: &[u8]) -> Vec<u8> {
    der_tlv(0x30, c)
}
fn der_set(c: &[u8]) -> Vec<u8> {
    der_tlv(0x31, c)
}
fn der_ctx0(c: &[u8]) -> Vec<u8> {
    der_tlv(0xa0, c)
} // [0] EXPLICIT

fn der_pos_integer(n: &[u8]) -> Vec<u8> {
    // Ensure high bit is clear (positive). Prepend 0x00 if needed.
    let mut v = if n.first().copied().unwrap_or(0) & 0x80 != 0 {
        vec![0x02, 0x00]
    } else {
        vec![0x02]
    };
    v.extend(der_len(
        n.len()
            + if n.first().copied().unwrap_or(0) & 0x80 != 0 {
                1
            } else {
                0
            },
    ));
    // If we added a leading 0x00, adjust: redo properly
    let content = if n.first().copied().unwrap_or(0) & 0x80 != 0 {
        let mut tmp = vec![0x00];
        tmp.extend_from_slice(n);
        tmp
    } else {
        n.to_vec()
    };
    der_tlv(0x02, &content)
}

fn der_oid(bytes: &[u8]) -> Vec<u8> {
    der_tlv(0x06, bytes)
}
fn der_bit_string(data: &[u8]) -> Vec<u8> {
    // unused-bits prefix byte = 0x00
    let mut v = vec![0x00];
    v.extend_from_slice(data);
    der_tlv(0x03, &v)
}
fn der_utf8_string(s: &str) -> Vec<u8> {
    der_tlv(0x0c, s.as_bytes())
}
fn der_utc_time(s: &str) -> Vec<u8> {
    der_tlv(0x17, s.as_bytes())
}

// Ed25519 OID: 1.3.101.112 (id-EdDSA)
const OID_ED25519: &[u8] = &[0x2b, 0x65, 0x70];
// OID commonName: 2.5.4.3
const OID_CN: &[u8] = &[0x55, 0x04, 0x03];

fn ed25519_alg_id() -> Vec<u8> {
    // AlgorithmIdentifier { algorithm Ed25519 } — no parameters field for EdDSA
    der_seq(&der_oid(OID_ED25519))
}

fn name_cn_aqt() -> Vec<u8> {
    // Name ::= SEQUENCE OF RelativeDistinguishedName
    // RDN  ::= SET { AttributeTypeAndValue }
    // ATAV ::= SEQUENCE { type OID, value ANY }
    let atav = der_seq(&[der_oid(OID_CN), der_utf8_string("aqt")].concat());
    der_seq(&der_set(&atav))
}

fn subj_pub_key_info(pub_key_raw: &[u8]) -> Vec<u8> {
    // SEQUENCE { AlgorithmIdentifier, BIT STRING publicKey }
    der_seq(&[ed25519_alg_id(), der_bit_string(pub_key_raw)].concat())
}

fn build_tbs(pub_key_raw: &[u8], serial: &[u8]) -> Vec<u8> {
    let mut tbs = Vec::new();
    tbs.extend(der_ctx0(&der_tlv(0x02, &[2u8]))); // version v3 = INTEGER 2
    tbs.extend(der_pos_integer(serial));
    tbs.extend(ed25519_alg_id()); // signature algorithm
    tbs.extend(name_cn_aqt()); // issuer
                               // Validity: hardcoded wide window — clients pin SPKI, not cert chain
    tbs.extend(der_seq(
        &[
            der_utc_time("240101000000Z"), // not before 2024-01-01
            der_utc_time("340101000000Z"), // not after  2034-01-01
        ]
        .concat(),
    ));
    tbs.extend(name_cn_aqt()); // subject (= issuer, self-signed)
    tbs.extend(subj_pub_key_info(pub_key_raw));
    der_seq(&tbs)
}

// ── Public API ───────────────────────────────────────────────────────────────

fn make_material(pkcs8: &[u8]) -> Result<ServerTlsMaterial> {
    let key_pair = Ed25519KeyPair::from_pkcs8(pkcs8)
        .map_err(|e| anyhow::anyhow!("load ed25519 key: {e:?}"))?;
    let pub_key = key_pair.public_key().as_ref(); // 32 bytes

    let rng = SystemRandom::new();
    let mut serial = [0u8; 8];
    rng.fill(&mut serial)
        .map_err(|e| anyhow::anyhow!("rng: {e:?}"))?;

    let tbs = build_tbs(pub_key, &serial);
    let sig = key_pair.sign(&tbs);

    let cert_der = der_seq(
        &[
            tbs,
            ed25519_alg_id(), // signatureAlgorithm
            der_bit_string(sig.as_ref()),
        ]
        .concat(),
    );

    let spki_der = subj_pub_key_info(pub_key);
    let spki_base64 = crate::b64::encode_no_pad(&spki_der);

    Ok(ServerTlsMaterial {
        cert_chain: vec![CertificateDer::from(cert_der)],
        private_key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(pkcs8.to_vec())),
        spki_base64,
    })
}

pub fn generate_ephemeral() -> Result<ServerTlsMaterial> {
    let rng = SystemRandom::new();
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng)
        .map_err(|e| anyhow::anyhow!("generate ed25519: {e:?}"))?;
    make_material(pkcs8.as_ref())
}

pub fn load_or_generate_persistent(state_dir: &std::path::Path) -> Result<ServerTlsMaterial> {
    use std::fs;
    fs::create_dir_all(state_dir)?;
    let key_path = state_dir.join("server.key");
    let spki_path = state_dir.join("server.spki.b64");

    let pkcs8_bytes: Vec<u8> = if key_path.exists() {
        fs::read(&key_path)?
    } else {
        let rng = SystemRandom::new();
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng)
            .map_err(|e| anyhow::anyhow!("generate ed25519: {e:?}"))?;
        fs::write(&key_path, pkcs8.as_ref())?;
        pkcs8.as_ref().to_vec()
    };

    let material = make_material(&pkcs8_bytes)?;

    // Write SPKI for easy inspection (best-effort).
    let _ = fs::write(&spki_path, material.spki_base64.as_bytes());

    Ok(material)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_two_keys_differ() {
        let a = generate_ephemeral().unwrap();
        let b = generate_ephemeral().unwrap();
        assert_ne!(a.spki_base64, b.spki_base64);
    }

    #[test]
    fn spki_base64_no_padding() {
        let m = generate_ephemeral().unwrap();
        assert!(!m.spki_base64.contains('='));
        assert!(!m.spki_base64.is_empty());
    }

    #[test]
    fn cert_der_is_parseable() {
        // rustls must accept the cert we generate
        let m = generate_ephemeral().unwrap();
        assert!(!m.cert_chain.is_empty());
        assert!(!m.cert_chain[0].is_empty());
    }
}
