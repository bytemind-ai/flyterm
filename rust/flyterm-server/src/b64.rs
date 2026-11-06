// SPDX-License-Identifier: GPL-3.0-or-later
/// Minimal base64 encoder — STANDARD alphabet, no padding (RFC 4648 §3.2).
/// Replaces the `base64` crate for our two call sites (SPKI + token).
pub fn encode_no_pad(input: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let out_len = (input.len() * 4 + 2) / 3;
    let mut out = Vec::with_capacity(out_len);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 {
            chunk[1] as usize
        } else {
            0
        };
        let b2 = if chunk.len() > 2 {
            chunk[2] as usize
        } else {
            0
        };
        out.push(TABLE[b0 >> 2]);
        out.push(TABLE[((b0 << 4) | (b1 >> 4)) & 0x3f]);
        if chunk.len() > 1 {
            out.push(TABLE[((b1 << 2) | (b2 >> 6)) & 0x3f]);
        }
        if chunk.len() > 2 {
            out.push(TABLE[b2 & 0x3f]);
        }
    }
    String::from_utf8(out).expect("base64 chars are valid UTF-8")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn empty() {
        assert_eq!(encode_no_pad(b""), "");
    }
    #[test]
    fn one_byte() {
        assert_eq!(encode_no_pad(b"M"), "TQ");
    }
    #[test]
    fn two_bytes() {
        assert_eq!(encode_no_pad(b"Ma"), "TWE");
    }
    #[test]
    fn three_bytes() {
        assert_eq!(encode_no_pad(b"Man"), "TWFu");
    }
    #[test]
    fn no_padding() {
        assert!(!encode_no_pad(b"hello").contains('='));
    }
    #[test]
    fn known_vector() {
        // 32 zero bytes → well-known base64
        let zeros = [0u8; 32];
        let b64 = encode_no_pad(&zeros);
        assert_eq!(b64.len(), 43); // ceil(32*4/3) = 43 without padding
        assert!(!b64.contains('='));
    }
}
