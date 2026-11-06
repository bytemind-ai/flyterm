// SPDX-License-Identifier: GPL-3.0-or-later
use crate::history::slug::slugify;
use crate::history::store::HistoryStore;
use anyhow::{Context, Result};
use aqt_protocol::frame::PreloadHistorySpec;
use std::path::PathBuf;

pub const MAX_SCROLLBACK_LINES: usize = 10_000;

pub struct ReplayResult {
    pub bytes: Vec<u8>,
    pub segments: Vec<(u64, u64, u64)>, // (history_id, started_at, ended_at)
}

pub fn replay_for(
    store: &HistoryStore,
    session_key: &str,
    rows: u16,
    cols: u16,
    spec: &PreloadHistorySpec,
) -> anyhow::Result<Option<ReplayResult>> {
    let segment = match spec {
        PreloadHistorySpec::LatestMatching { cmd } => {
            let slug = slugify(cmd);
            store.latest_for(session_key, &slug)?
        }
        PreloadHistorySpec::Explicit { history_id } => store
            .get_by_id(*history_id as i64)?
            .filter(|s| s.session_key == session_key),
    };

    let Some(seg) = segment else {
        return Ok(None);
    };

    let mut bytes = render_segments(
        &[PathBuf::from(&seg.path)],
        rows,
        cols,
        MAX_SCROLLBACK_LINES,
    )?;
    append_separator(&mut bytes);

    Ok(Some(ReplayResult {
        bytes,
        segments: vec![(
            seg.id as u64,
            seg.started_at,
            seg.ended_at.unwrap_or(seg.started_at),
        )],
    }))
}

/// Maximum raw log bytes to read per segment.  Reading the tail keeps the most
/// recent conversation while bounding the stripped output to ~400 KB, well within
/// xterm's scrollback budget.
const MAX_LOG_TAIL_BYTES: u64 = 1024 * 1024; // 1 MB raw → ~400 KB stripped

pub fn render_segments(
    paths: &[PathBuf],
    _rows: u16,
    _cols: u16,
    _scrollback: usize,
) -> Result<Vec<u8>> {
    // Strip ANSI escape sequences and return the full raw text.
    //
    // Only the tail of each log file is read (MAX_LOG_TAIL_BYTES) so the stripped
    // output stays well within xterm's maxLines budget.  Reading from the end keeps
    // the most recent (and most relevant) conversation content.
    let mut out = Vec::new();
    for path in paths {
        let bytes = read_tail(path, MAX_LOG_TAIL_BYTES)
            .with_context(|| format!("read history segment {}", path.display()))?;
        strip_ansi_into(&bytes, &mut out);
    }
    Ok(out)
}

fn read_tail(path: &PathBuf, max_bytes: u64) -> std::io::Result<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path)?;
    let file_len = f.metadata()?.len();
    if file_len <= max_bytes {
        let mut buf = Vec::new();
        f.read_to_end(&mut buf)?;
        return Ok(buf);
    }
    // Seek to max_bytes before EOF, then scan forward to the next line boundary
    // so we don't start in the middle of a multi-byte sequence.
    let start = file_len - max_bytes;
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::with_capacity(max_bytes as usize + 512);
    f.read_to_end(&mut buf)?;
    // Advance to first \n so we start on a clean line
    if let Some(nl) = buf.iter().position(|&b| b == b'\n') {
        Ok(buf[nl + 1..].to_vec())
    } else {
        Ok(buf)
    }
}

/// Strip ANSI/VT escape sequences, keeping printable bytes and CR/LF.
///
/// Lone \r (without following \n) is kept so xterm handles in-place rewrites
/// correctly — only the final state of each overwritten line shows in scrollback.
fn strip_ansi_into(input: &[u8], out: &mut Vec<u8>) {
    let mut i = 0;
    while i < input.len() {
        let b = input[i];
        if b == 0x1b {
            // Escape sequence
            i += 1;
            if i >= input.len() {
                break;
            }
            match input[i] {
                b'[' => {
                    // CSI: skip until final byte in 0x40–0x7e
                    i += 1;
                    while i < input.len() {
                        let c = input[i];
                        i += 1;
                        if c >= 0x40 {
                            break;
                        }
                    }
                }
                b']' => {
                    // OSC: skip until ST (ESC \) or BEL
                    i += 1;
                    loop {
                        if i >= input.len() {
                            break;
                        }
                        if input[i] == 0x07 {
                            i += 1;
                            break;
                        }
                        if input[i] == 0x1b && i + 1 < input.len() && input[i + 1] == b'\\' {
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                }
                b'(' | b')' | b'*' | b'+' => {
                    // Character set designation: ESC ( X — one more byte
                    i += 1;
                    if i < input.len() {
                        i += 1;
                    }
                }
                _ => {
                    i += 1;
                } // two-byte escape
            }
        } else if b == b'\r' {
            out.push(b'\r');
            // Normalize \r\n → single CRLF; lone \r stays as \r for xterm in-place
            if i + 1 < input.len() && input[i + 1] == b'\n' {
                out.push(b'\n');
                i += 2;
            } else {
                i += 1;
            }
        } else if b == b'\n' {
            // Bare LF → CRLF
            out.push(b'\r');
            out.push(b'\n');
            i += 1;
        } else if b >= 0x20 {
            // Printable ASCII or high byte (UTF-8 multibyte)
            out.push(b);
            i += 1;
        } else {
            // Other control chars (BEL, BS, etc.): skip
            i += 1;
        }
    }
}

pub fn append_separator(out: &mut Vec<u8>) {
    // UTF-8 bytes for "─── new session ───" with dim ANSI color
    out.extend_from_slice(
        b"\r\n\x1b[2m\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 new session \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\x1b[0m\r\n",
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::logger::HistoryLogger;
    use crate::history::store::HistoryStore;
    use aqt_protocol::frame::PreloadHistorySpec;
    use std::io::Write;
    use std::sync::Arc;
    use tempfile::NamedTempFile;

    #[test]
    fn replay_for_latest_matching_gets_most_recent() {
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());

        // Create two history segments with different content
        {
            let mut log = HistoryLogger::new(
                dir.path().to_path_buf(),
                store.clone(),
                "alice@host".into(),
                "claude".into(),
                1,
                1024 * 1024,
            )
            .unwrap();
            log.append(b"old-session-content\r\n").unwrap();
            log.flush_finalize().unwrap();
        }
        // Sleep 1s to ensure started_at differs
        std::thread::sleep(std::time::Duration::from_millis(1100));
        {
            let mut log = HistoryLogger::new(
                dir.path().to_path_buf(),
                store.clone(),
                "alice@host".into(),
                "claude".into(),
                2,
                1024 * 1024,
            )
            .unwrap();
            log.append(b"new-session-content\r\n").unwrap();
            log.flush_finalize().unwrap();
        }

        let result = replay_for(
            &store,
            "alice@host",
            24,
            80,
            &PreloadHistorySpec::LatestMatching {
                cmd: "claude".into(),
            },
        )
        .unwrap();
        assert!(result.is_some(), "should find a result");
        let r = result.unwrap();
        let s = String::from_utf8_lossy(&r.bytes);
        assert!(
            s.contains("new-session-content"),
            "should have new content, got: {:?}",
            s
        );
        // Separator should be present
        assert!(
            s.contains("new session"),
            "should have separator, got: {:?}",
            s
        );
    }

    #[test]
    fn replay_for_no_match_returns_none() {
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());
        let result = replay_for(
            &store,
            "alice@host",
            24,
            80,
            &PreloadHistorySpec::LatestMatching {
                cmd: "nonexistent".into(),
            },
        )
        .unwrap();
        assert!(result.is_none());
    }

    fn make_log(content: &[u8]) -> NamedTempFile {
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(content).unwrap();
        f
    }

    #[test]
    fn render_single_segment_plain_text() {
        let f = make_log(b"line1\r\nline2\r\nline3\r\n");
        let out = render_segments(&[f.path().to_path_buf()], 24, 80, 100).unwrap();
        let s = String::from_utf8_lossy(&out);
        assert!(s.contains("line1"), "output: {:?}", s);
        assert!(s.contains("line2"), "output: {:?}", s);
        assert!(s.contains("line3"), "output: {:?}", s);
    }

    #[test]
    fn render_concatenates_multiple_segments() {
        let f1 = make_log(b"first-segment-text\r\n");
        let f2 = make_log(b"second-segment-text\r\n");
        let out = render_segments(&[f1.path().into(), f2.path().into()], 24, 80, 100).unwrap();
        let s = String::from_utf8_lossy(&out);
        assert!(s.contains("first-segment-text"), "output: {:?}", s);
        assert!(s.contains("second-segment-text"), "output: {:?}", s);
    }

    #[test]
    fn render_strips_cursor_control() {
        // ANSI sequences are stripped; content is preserved regardless of clear-screen.
        // (vt100 viewport semantics no longer apply — we return the full text stream)
        let f = make_log(b"keep\r\n\x1b[H\x1b[2Jonly-this\r\n");
        let out = render_segments(&[f.path().into()], 24, 80, 100).unwrap();
        let s = String::from_utf8_lossy(&out);
        // Both lines should be present since ANSI strip retains all text
        assert!(s.contains("keep"), "keep should be in output: {:?}", s);
        assert!(
            s.contains("only-this"),
            "only-this should be in output: {:?}",
            s
        );
        // No raw CSI sequences should remain
        assert!(
            !out.windows(2).any(|w| w == b"\x1b["),
            "raw ESC[ should not be in output: {:?}",
            s
        );
    }

    #[test]
    fn vt100_basic_parse() {
        let mut p = vt100::Parser::new(24, 80, 100);
        p.process(b"hello\r\nworld\r\n");
        let contents = p.screen().contents();
        assert!(contents.contains("hello"), "contents: {:?}", contents);
        assert!(contents.contains("world"), "contents: {:?}", contents);
    }

    #[test]
    fn vt100_cursor_control_consumed() {
        // \x1b[H = cursor home, \x1b[2J = clear screen
        // After this sequence, "hello" should be cleared, only "world" remains
        let mut p = vt100::Parser::new(24, 80, 100);
        p.process(b"hello\r\n\x1b[H\x1b[2Jworld");
        let contents = p.screen().contents();
        let has_hello = contents.contains("hello");
        let has_world = contents.contains("world");
        assert!(
            !has_hello,
            "hello should be cleared by \\x1b[2J, contents: {:?}",
            contents
        );
        assert!(has_world, "world should remain, contents: {:?}", contents);
    }
}
