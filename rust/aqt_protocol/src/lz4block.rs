// SPDX-License-Identifier: GPL-3.0-or-later
/// Minimal LZ4 **block** compressor and decompressor (no frame format).
///
/// Compatible with the LZ4 Block Specification:
///   <https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md>
///
/// Also implements the `compress_prepend_size` / `decompress_size_prepended`
/// convention used by lz4_flex: the compressed payload is prefixed with a
/// 4-byte little-endian original size so the decompressor can pre-allocate.
///
/// Wire format used by the AQT compression feature:
///   [u32 BE: frame_length][u32 LE: original_length][lz4 block bytes]
///
/// The helpers `compress_prepend_size` and `decompress_size_prepended` operate
/// on the inner [u32 LE orig_len][block bytes] slice, matching lz4_flex's API.
use std::fmt;

// ── Error ─────────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq, Eq)]
pub enum Lz4Error {
    /// Compressed data ended prematurely.
    UnexpectedEof,
    /// Match offset points before the start of the output buffer.
    InvalidOffset,
    /// Decompressed size exceeds the declared original size.
    OutputOverflow,
    /// The prepended size is implausibly large (> 64 MiB).
    InvalidPrependedSize,
}

impl fmt::Display for Lz4Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnexpectedEof => write!(f, "lz4: unexpected end of compressed data"),
            Self::InvalidOffset => write!(f, "lz4: match offset out of range"),
            Self::OutputOverflow => write!(f, "lz4: output exceeds declared size"),
            Self::InvalidPrependedSize => write!(f, "lz4: prepended size too large"),
        }
    }
}

// ── Constants ─────────────────────────────────────────────────────────────

const MIN_MATCH: usize = 4;
const LAST_LITS: usize = 5; // last 5 source bytes must always be literals
const HASH_LOG: usize = 16;
const HASH_SIZE: usize = 1 << HASH_LOG;
const MAX_DISTANCE: usize = 0xFFFF; // 16-bit offset

// ── Compressor ────────────────────────────────────────────────────────────

#[inline]
fn hash4(src: &[u8], pos: usize) -> usize {
    let v = u32::from_le_bytes(src[pos..pos + 4].try_into().unwrap());
    (v.wrapping_mul(0x9E37_79B1) >> (32 - HASH_LOG)) as usize
}

/// Compress `input` using LZ4 block format. Returns the compressed bytes.
pub fn compress(input: &[u8]) -> Vec<u8> {
    if input.is_empty() {
        return vec![0x00];
    } // empty block: token 0, no literals

    // If input is too short to contain a MIN_MATCH sequence + LAST_LITS guard,
    // skip match search and emit everything as literals.
    if input.len() < MIN_MATCH + LAST_LITS {
        return literals_only(input);
    }

    let mut out: Vec<u8> = Vec::with_capacity(input.len() / 2 + 32);
    // Hash table: maps hash → last seen position with that hash.
    let mut table = vec![0u32; HASH_SIZE];

    let limit = input.len() - LAST_LITS; // last safe position to start a match
    let mut anchor = 0usize; // start of pending literals
    let mut pos = 0usize;

    while pos + MIN_MATCH <= limit {
        let h = hash4(input, pos);
        let cand = table[h] as usize;
        table[h] = pos as u32;

        // Is there a valid match at `cand`?
        let match_len = if cand < pos
            && pos - cand <= MAX_DISTANCE
            && input[cand..cand + MIN_MATCH] == input[pos..pos + MIN_MATCH]
        {
            // Extend greedily, but never past `limit`
            let max_ml = limit - pos;
            let mut ml = MIN_MATCH;
            while ml < max_ml && input[cand + ml] == input[pos + ml] {
                ml += 1;
            }
            ml
        } else {
            0
        };

        if match_len < MIN_MATCH {
            pos += 1;
            continue;
        }

        // Emit one full sequence: [literals] then [match]
        let lit_len = pos - anchor;
        let match_offset = pos - cand;
        let enc_match = match_len - MIN_MATCH; // stored value = actual - 4

        // Token
        out.push(((lit_len.min(15) as u8) << 4) | enc_match.min(15) as u8);

        // Extra literal-length bytes (if lit_len >= 15)
        append_extra(&mut out, lit_len, 15);

        // Literal data
        out.extend_from_slice(&input[anchor..pos]);

        // 16-bit LE match offset
        out.push((match_offset & 0xFF) as u8);
        out.push((match_offset >> 8) as u8);

        // Extra match-length bytes (if enc_match >= 15)
        append_extra(&mut out, enc_match, 15);

        pos += match_len;
        anchor = pos;

        // Update hash for the position just after the match (improves ratio slightly)
        if pos + MIN_MATCH <= limit {
            table[hash4(input, pos - 1)] = (pos - 1) as u32;
        }
    }

    // Final (mandatory) literal-only sequence
    emit_end_literals(&mut out, &input[anchor..]);
    out
}

/// Compress `input` and prepend the original length as a 4-byte LE u32.
/// Format: [u32 LE orig_len][compressed block bytes].
/// Compatible with lz4_flex::block::compress_prepend_size.
pub fn compress_prepend_size(input: &[u8]) -> Vec<u8> {
    let orig_len = input.len() as u32;
    let compressed = compress(input);
    let mut out = Vec::with_capacity(4 + compressed.len());
    out.extend_from_slice(&orig_len.to_le_bytes());
    out.extend_from_slice(&compressed);
    out
}

// Emit `len - threshold` extra bytes in the LZ4 extra-length encoding.
fn append_extra(out: &mut Vec<u8>, len: usize, threshold: usize) {
    if len >= threshold {
        let mut rem = len - threshold;
        while rem >= 255 {
            out.push(255);
            rem -= 255;
        }
        out.push(rem as u8);
    }
}

// Emit the mandatory end-of-block literal-only sequence.
fn emit_end_literals(out: &mut Vec<u8>, lits: &[u8]) {
    let n = lits.len();
    out.push((n.min(15) as u8) << 4); // token: match nibble = 0
    append_extra(out, n, 15);
    out.extend_from_slice(lits);
    // No offset or match-length follows: this terminates the block.
}

// When input is too short for matches, emit everything as one literal run.
fn literals_only(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len() + 5);
    emit_end_literals(&mut out, input);
    out
}

// ── Decompressor ─────────────────────────────────────────────────────────

/// Decompress a raw LZ4 block. `max_output` caps the output size.
pub fn decompress(input: &[u8], max_output: usize) -> Result<Vec<u8>, Lz4Error> {
    let mut out = Vec::with_capacity(input.len().min(max_output));
    let mut src = 0usize;

    loop {
        if src >= input.len() {
            break;
        }
        let token = input[src];
        src += 1;

        // ── Literal run ──────────────────────────────────────────────────
        let mut lit_len = (token >> 4) as usize;
        if lit_len == 15 {
            lit_len += read_extra(input, &mut src)?;
        }
        if src + lit_len > input.len() {
            return Err(Lz4Error::UnexpectedEof);
        }
        if out.len() + lit_len > max_output {
            return Err(Lz4Error::OutputOverflow);
        }
        out.extend_from_slice(&input[src..src + lit_len]);
        src += lit_len;

        // End of block: the last sequence has no match part.
        if src >= input.len() {
            break;
        }

        // ── Match copy ───────────────────────────────────────────────────
        if src + 2 > input.len() {
            return Err(Lz4Error::UnexpectedEof);
        }
        let offset = (input[src] as usize) | ((input[src + 1] as usize) << 8);
        src += 2;
        if offset == 0 || offset > out.len() {
            return Err(Lz4Error::InvalidOffset);
        }

        let mut match_len = (token & 0x0F) as usize + MIN_MATCH;
        if (token & 0x0F) == 15 {
            match_len += read_extra(input, &mut src)?;
        }
        if out.len() + match_len > max_output {
            return Err(Lz4Error::OutputOverflow);
        }

        // Byte-by-byte copy supports overlapping matches (offset < match_len)
        let match_start = out.len() - offset;
        for i in 0..match_len {
            let b = out[match_start + i];
            out.push(b);
        }
    }

    Ok(out)
}

/// Read the "extra length" encoding: sum bytes until one is < 255.
fn read_extra(input: &[u8], src: &mut usize) -> Result<usize, Lz4Error> {
    let mut total = 0usize;
    loop {
        if *src >= input.len() {
            return Err(Lz4Error::UnexpectedEof);
        }
        let b = input[*src] as usize;
        *src += 1;
        total += b;
        if b < 255 {
            break;
        }
    }
    Ok(total)
}

/// Decompress a payload that starts with a 4-byte LE original size.
/// Compatible with lz4_flex::block::decompress_size_prepended.
pub fn decompress_size_prepended(data: &[u8]) -> Result<Vec<u8>, Lz4Error> {
    if data.len() < 4 {
        return Err(Lz4Error::UnexpectedEof);
    }
    let orig_size = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
    if orig_size > 64 * 1024 * 1024 {
        return Err(Lz4Error::InvalidPrependedSize);
    }
    let result = decompress(&data[4..], orig_size)?;
    if result.len() != orig_size {
        return Err(Lz4Error::OutputOverflow);
    }
    Ok(result)
}

// ── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(input: &[u8]) {
        let compressed = compress(input);
        let decompressed = decompress(&compressed, input.len() * 2 + 16).unwrap();
        assert_eq!(
            decompressed,
            input,
            "roundtrip failed for input len={}",
            input.len()
        );
    }

    fn roundtrip_prepend(input: &[u8]) {
        let compressed = compress_prepend_size(input);
        let decompressed = decompress_size_prepended(&compressed).unwrap();
        assert_eq!(decompressed, input);
    }

    #[test]
    fn empty_input() {
        roundtrip(b"");
        roundtrip_prepend(b"");
    }

    #[test]
    fn single_byte() {
        roundtrip(b"A");
    }

    #[test]
    fn short_no_match() {
        roundtrip(b"hello");
    }

    #[test]
    fn all_same_byte() {
        let input = vec![0x41u8; 256];
        let c = compress(&input);
        assert!(c.len() < input.len(), "should compress repetitions");
        let d = decompress(&c, 512).unwrap();
        assert_eq!(d, input);
    }

    #[test]
    fn ansi_sequence() {
        // Typical PTY output: ANSI color codes + text
        let input = b"\x1b[32mHello, world!\x1b[0m\r\n\x1b[32mHello, world!\x1b[0m\r\n";
        roundtrip(input);
    }

    #[test]
    fn random_looking_bytes() {
        // Worst case: incompressible data
        let input: Vec<u8> = (0u8..=255).cycle().take(1000).collect();
        roundtrip(&input);
    }

    #[test]
    fn repeated_line_pattern() {
        // Typical terminal: same prompt repeated many times
        let line = b"user@host:~$ ls -la\r\n";
        let input: Vec<u8> = line.iter().cloned().cycle().take(4096).collect();
        let c = compress(&input);
        assert!(
            c.len() < input.len() / 2,
            "should achieve >50% compression on repeated text"
        );
        let d = decompress(&c, input.len() + 1).unwrap();
        assert_eq!(d, input);
    }

    #[test]
    fn exactly_4kb() {
        // Typical PTY chunk size
        let input: Vec<u8> = b"The quick brown fox jumps over the lazy dog\r\n"
            .iter()
            .cloned()
            .cycle()
            .take(4096)
            .collect();
        roundtrip(&input);
    }

    #[test]
    fn overlapping_match() {
        // offset < match_len → "run-length" copy — e.g., "AAAA..."
        let input = vec![b'A'; 100];
        roundtrip(&input);
    }

    #[test]
    fn prepend_roundtrip_large() {
        let input: Vec<u8> = b"lorem ipsum dolor sit amet\r\n"
            .iter()
            .cloned()
            .cycle()
            .take(8192)
            .collect();
        roundtrip_prepend(&input);
    }

    #[test]
    fn decompressor_invalid_offset() {
        // Hand-craft a block with offset=0 (invalid)
        // Token: 0 literals, 4-byte match. Offset: 0x0000
        let bad = vec![0x00u8, 0x00, 0x00];
        assert_eq!(decompress(&bad, 1024), Err(Lz4Error::InvalidOffset));
    }

    #[test]
    fn decompressor_unexpected_eof_in_literals() {
        // Token says 10 literals but block ends immediately
        let bad = vec![0xA0u8]; // lit_len=10, no extra, then 0 bytes of literals
        assert_eq!(decompress(&bad, 1024), Err(Lz4Error::UnexpectedEof));
    }
}
