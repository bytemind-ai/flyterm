// SPDX-License-Identifier: GPL-3.0-or-later
use bytes::Buf;
use bytes::BufMut;

pub fn encode_varint(value: u64, buf: &mut impl BufMut) -> Result<(), crate::error::DecodeError> {
    if value < 1 << 6 {
        buf.put_u8(value as u8);
    } else if value < 1 << 14 {
        buf.put_u16((value as u16) | 0x4000);
    } else if value < 1 << 30 {
        buf.put_u32((value as u32) | 0x8000_0000);
    } else if value < 1 << 62 {
        buf.put_u64(value | 0xC000_0000_0000_0000);
    } else {
        return Err(crate::error::DecodeError::VarintOverflow);
    }
    Ok(())
}

/// Decode one varint from the front of `buf`, consuming 1/2/4/8 bytes.
pub fn decode_varint(buf: &mut impl Buf) -> Result<u64, crate::error::DecodeError> {
    use crate::error::DecodeError;
    if buf.remaining() < 1 {
        return Err(DecodeError::Truncated { needed: 1, have: 0 });
    }
    let first = buf.chunk()[0];
    let len = 1 << (first >> 6); // 1, 2, 4, 8
    if buf.remaining() < len {
        return Err(DecodeError::Truncated {
            needed: len,
            have: buf.remaining(),
        });
    }
    let v = match len {
        1 => buf.get_u8() as u64 & 0x3F,
        2 => buf.get_u16() as u64 & 0x3FFF,
        4 => buf.get_u32() as u64 & 0x3FFF_FFFF,
        8 => buf.get_u64() & 0x3FFF_FFFF_FFFF_FFFF,
        _ => unreachable!(),
    };
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::BytesMut;

    #[test]
    fn encode_1byte() {
        let mut buf = BytesMut::new();
        encode_varint(37, &mut buf).unwrap();
        assert_eq!(buf.as_ref(), &[0x25]);
    }

    #[test]
    fn encode_2byte() {
        let mut buf = BytesMut::new();
        encode_varint(15293, &mut buf).unwrap();
        assert_eq!(buf.as_ref(), &[0x7B, 0xBD]);
    }

    #[test]
    fn encode_4byte() {
        let mut buf = BytesMut::new();
        encode_varint(494_878_333, &mut buf).unwrap();
        assert_eq!(buf.as_ref(), &[0x9D, 0x7F, 0x3E, 0x7D]);
    }

    #[test]
    fn encode_8byte() {
        let mut buf = BytesMut::new();
        encode_varint(151_288_809_941_952_652, &mut buf).unwrap();
        assert_eq!(
            buf.as_ref(),
            &[0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C]
        );
    }

    #[test]
    fn encode_overflow_rejected() {
        let mut buf = BytesMut::new();
        let r = encode_varint(1 << 62, &mut buf);
        assert!(matches!(r, Err(crate::error::DecodeError::VarintOverflow)));
    }
}

#[cfg(test)]
mod decode_tests {
    use super::*;
    use bytes::{Bytes, BytesMut};

    #[test]
    fn decode_1byte() {
        let mut b = Bytes::from_static(&[0x25]);
        assert_eq!(decode_varint(&mut b).unwrap(), 37);
        assert!(b.is_empty());
    }

    #[test]
    fn decode_2byte() {
        let mut b = Bytes::from_static(&[0x7B, 0xBD]);
        assert_eq!(decode_varint(&mut b).unwrap(), 15293);
    }

    #[test]
    fn decode_4byte() {
        let mut b = Bytes::from_static(&[0x9D, 0x7F, 0x3E, 0x7D]);
        assert_eq!(decode_varint(&mut b).unwrap(), 494_878_333);
    }

    #[test]
    fn decode_8byte() {
        let mut b = Bytes::from_static(&[0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C]);
        assert_eq!(decode_varint(&mut b).unwrap(), 151_288_809_941_952_652);
    }

    #[test]
    fn decode_truncated_2byte_header() {
        let mut b = Bytes::from_static(&[0x7B]);
        assert!(matches!(
            decode_varint(&mut b),
            Err(crate::error::DecodeError::Truncated { .. })
        ));
    }

    #[test]
    fn roundtrip_boundaries() {
        for v in [
            0_u64,
            1,
            63,
            64,
            16383,
            16384,
            (1u64 << 30) - 1,
            1u64 << 30,
            (1u64 << 62) - 1,
        ] {
            let mut buf = BytesMut::new();
            encode_varint(v, &mut buf).unwrap();
            let mut b = buf.freeze();
            assert_eq!(decode_varint(&mut b).unwrap(), v, "value {v}");
        }
    }
}

#[cfg(test)]
mod prop_tests {
    use super::*;
    use bytes::BytesMut;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn varint_roundtrip(v in 0u64..(1u64 << 62)) {
            let mut buf = BytesMut::new();
            encode_varint(v, &mut buf).unwrap();
            let mut b = buf.freeze();
            let decoded = decode_varint(&mut b).unwrap();
            prop_assert_eq!(decoded, v);
            prop_assert!(b.is_empty());
        }

        #[test]
        fn random_bytes_dont_panic(bytes in proptest::collection::vec(any::<u8>(), 0..16)) {
            let mut b: &[u8] = &bytes;
            let _ = decode_varint(&mut b);  // must not panic
        }
    }
}
