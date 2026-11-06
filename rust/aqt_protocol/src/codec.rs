// SPDX-License-Identifier: GPL-3.0-or-later
use crate::error::DecodeError;
use crate::varint::{decode_varint, encode_varint};
use bytes::{Buf, BufMut};

/// 写入 [varint len][bytes]
pub fn put_bytes_lp(value: &[u8], buf: &mut impl BufMut) -> Result<(), DecodeError> {
    encode_varint(value.len() as u64, buf)?;
    buf.put_slice(value);
    Ok(())
}

/// 读取 [varint len][bytes]，返回 owned Vec
pub fn get_bytes_lp(buf: &mut impl Buf) -> Result<Vec<u8>, DecodeError> {
    let len = decode_varint(buf)? as usize;
    if buf.remaining() < len {
        return Err(DecodeError::Truncated {
            needed: len,
            have: buf.remaining(),
        });
    }
    let mut out = vec![0u8; len];
    buf.copy_to_slice(&mut out);
    Ok(out)
}

/// 写入 [varint len][utf8 bytes]
pub fn put_string_lp(value: &str, buf: &mut impl BufMut) -> Result<(), DecodeError> {
    put_bytes_lp(value.as_bytes(), buf)
}

/// 读取 [varint len][utf8 bytes]，验证 utf8 合法
pub fn get_string_lp(buf: &mut impl Buf) -> Result<String, DecodeError> {
    let raw = get_bytes_lp(buf)?;
    String::from_utf8(raw).map_err(|_| DecodeError::InvalidUtf8)
}

/// 写入定长字节
pub fn put_fixed<const N: usize>(value: &[u8; N], buf: &mut impl BufMut) {
    buf.put_slice(value);
}

/// 读取定长字节
pub fn get_fixed<const N: usize>(buf: &mut impl Buf) -> Result<[u8; N], DecodeError> {
    if buf.remaining() < N {
        return Err(DecodeError::Truncated {
            needed: N,
            have: buf.remaining(),
        });
    }
    let mut out = [0u8; N];
    buf.copy_to_slice(&mut out);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::BytesMut;

    #[test]
    fn string_lp_roundtrip() {
        let mut buf = BytesMut::new();
        put_string_lp("hello, 世界", &mut buf).unwrap();
        let mut b = buf.freeze();
        let s = get_string_lp(&mut b).unwrap();
        assert_eq!(s, "hello, 世界");
        assert!(b.is_empty());
    }

    #[test]
    fn fixed_roundtrip() {
        let mut buf = BytesMut::new();
        let token: [u8; 32] = [0xAB; 32];
        put_fixed(&token, &mut buf);
        let mut b = buf.freeze();
        let out: [u8; 32] = get_fixed(&mut b).unwrap();
        assert_eq!(out, token);
    }

    #[test]
    fn truncated_string_errors() {
        let mut buf = BytesMut::new();
        crate::varint::encode_varint(100, &mut buf).unwrap();
        buf.extend_from_slice(b"abc");
        let mut b = buf.freeze();
        assert!(matches!(
            get_string_lp(&mut b),
            Err(DecodeError::Truncated { .. })
        ));
    }

    #[test]
    fn invalid_utf8_errors() {
        let mut buf = BytesMut::new();
        put_bytes_lp(&[0xFF, 0xFE], &mut buf).unwrap();
        let mut b = buf.freeze();
        assert!(matches!(
            get_string_lp(&mut b),
            Err(DecodeError::InvalidUtf8)
        ));
    }
}
