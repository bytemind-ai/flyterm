// SPDX-License-Identifier: GPL-3.0-or-later
//! PTY 启动窗口的字节缓冲。
//!
//! # 它不再是 scrollback
//!
//! 这个类型曾经承担 RESUME 的 scrollback 回放：客户端报一个 byte offset，
//! 服务端 `slice(from_off)` 切出增量。那套 offset 语义是全部恢复类 bug 的
//! 载体（见 2026-08-25 的会话恢复重新设计），已整体移除。
//!
//! 接替它的 `LineRing`（按逻辑行索引 + `FetchScrollback` 通道）也已经删掉：
//! 它存的是**原始字节流**，而屏幕是**求值后的状态**，两者之间按行数做算术
//! 是「回放内容重复」那一整类 bug 的根因。scrollback 现在直接来自服务端
//! vt100 parser 的 primary grid，见 `flyterm-server` 的 `snapshot.rs`。
//!
//! 剩下的唯一用途是 `OpenTab`：PTY 从 spawn 到 forwarder 装上之间会产生
//! 输出（shell 的初始 prompt 就在这个窗口里），那段字节必须补给客户端，
//! 否则新开的 tab 是空白的。调用方只取全部（[`ScrollbackRing::snapshot_all`]），
//! 不存在「从某个位置开始」的需求，所以 `slice` / `RingSlice` 一并删掉了。
//!
//! 容量满时丢弃最旧的字节，永不阻塞写入。

pub struct ScrollbackRing {
    buf: Box<[u8]>,
    head_off: u64,
    tail_off: u64,
    /// Tracks whether the running app is currently in alt-buffer mode by
    /// scanning every byte ever fed into `append` for `\x1b[?1049h` (enter)
    /// and `\x1b[?1049l` (exit). The most recent transition wins, even when
    /// the byte that carried it has long since been overwritten by the
    /// ring's overflow rotation. Used by RESUME prelude assembly to
    /// synthesise the correct buffer-mode escape when cold-start replay's
    /// 512 KB window doesn't reach far back enough to include the initial
    /// `?1049h` from a long-running TUI session.
    alt_match: AltMatcher,
}

/// Byte-by-byte matcher for `\x1b[?1049{h,l}` that survives `append`
/// boundaries. Sequences split across two writes still resolve correctly.
struct AltMatcher {
    /// Number of bytes of `\x1b[?1049` matched so far (0..PREFIX.len()).
    matched: usize,
    in_alt: bool,
}

const ALT_PREFIX: &[u8] = b"\x1b[?1049";

impl AltMatcher {
    const fn new() -> Self {
        Self {
            matched: 0,
            in_alt: false,
        }
    }

    fn feed(&mut self, data: &[u8]) {
        for &b in data {
            if self.matched < ALT_PREFIX.len() {
                if b == ALT_PREFIX[self.matched] {
                    self.matched += 1;
                } else if b == ALT_PREFIX[0] {
                    // Restart on the prefix's first byte even after a partial
                    // mismatch so back-to-back ESCs don't miss a sequence.
                    self.matched = 1;
                } else {
                    self.matched = 0;
                }
            } else {
                // Prefix complete; this byte is the mode terminator.
                match b {
                    b'h' => self.in_alt = true,
                    b'l' => self.in_alt = false,
                    _ => {} // not a recognised terminator → leave state alone
                }
                self.matched = 0;
            }
        }
    }
}

impl ScrollbackRing {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "capacity must be > 0");
        Self {
            buf: vec![0u8; capacity].into_boxed_slice(),
            head_off: 0,
            tail_off: 0,
            alt_match: AltMatcher::new(),
        }
    }

    pub fn capacity(&self) -> usize {
        self.buf.len()
    }
    pub fn head_off(&self) -> u64 {
        self.head_off
    }
    pub fn tail_off(&self) -> u64 {
        self.tail_off
    }
    pub fn len(&self) -> usize {
        (self.tail_off - self.head_off) as usize
    }
    pub fn is_empty(&self) -> bool {
        self.head_off == self.tail_off
    }

    /// Whether the running app's last alt-buffer transition was an ENTER
    /// (`\x1b[?1049h`). Tracks the full byte history fed into `append`,
    /// not just the bytes currently retained in the ring window.
    ///
    /// Superseded by vt100 parser authoritative state in flyterm-server.
    /// Kept for diagnostic/tests usage only.
    #[deprecated(
        note = "Alt-buffer state moved to vt100 parser in PtyHandles; this byte-stream heuristic is no longer load-bearing."
    )]
    pub fn is_alt_buffer(&self) -> bool {
        self.alt_match.in_alt
    }

    /// Append `data` to the ring tail.
    /// If data exceeds capacity, only the last `capacity` bytes are kept.
    /// If writing would overflow, head_off advances to make room first.
    pub fn append(&mut self, data: &[u8]) {
        // Feed the alt-buffer matcher with the FULL input — even bytes
        // that the overflow rotation is about to drop. Mode transitions
        // must survive ring rotation; only the latest h/l result matters.
        self.alt_match.feed(data);

        let cap = self.capacity();
        // new_tail is always advanced by the full original data length,
        // so global byte offsets are monotonic even when data is truncated.
        let new_tail = self.tail_off + data.len() as u64;

        let write_data = if data.len() > cap {
            &data[data.len() - cap..]
        } else {
            data
        };

        if new_tail - self.head_off > cap as u64 {
            self.head_off = new_tail - cap as u64;
        }

        // write_pos must be based on where write_data starts in the logical stream,
        // which is new_tail - write_data.len()
        let write_start = new_tail - write_data.len() as u64;
        let mut write_pos = (write_start % cap as u64) as usize;
        for &b in write_data {
            self.buf[write_pos] = b;
            write_pos = (write_pos + 1) % cap;
        }
        self.tail_off = new_tail;
    }
}

impl ScrollbackRing {
    /// 当前保留的全部字节，最旧的在前。
    ///
    /// `OpenTab` 用它把「forwarder 装上之前产生的输出」补给客户端。取全部
    /// 而不是从某个位置开始 —— 调用方没有位置可言，它才刚连上。
    pub fn snapshot_all(&self) -> Vec<u8> {
        let len = self.len();
        if len == 0 {
            return Vec::new();
        }
        let cap = self.capacity();
        let phys_start = (self.head_off % cap as u64) as usize;
        let mut out = Vec::with_capacity(len);
        if phys_start + len <= cap {
            out.extend_from_slice(&self.buf[phys_start..phys_start + len]);
        } else {
            let first = cap - phys_start;
            out.extend_from_slice(&self.buf[phys_start..]);
            out.extend_from_slice(&self.buf[..len - first]);
        }
        out
    }
}

#[cfg(test)]
#[allow(deprecated)] // tests exercise the deprecated is_alt_buffer() directly
mod tests {
    use super::*;

    #[test]
    fn new_is_empty() {
        let r = ScrollbackRing::new(64);
        assert!(r.is_empty());
        assert_eq!(r.head_off(), 0);
        assert_eq!(r.tail_off(), 0);
        assert_eq!(r.capacity(), 64);
    }

    #[test]
    fn append_within_capacity() {
        let mut r = ScrollbackRing::new(64);
        r.append(b"hello");
        assert_eq!(r.len(), 5);
        assert_eq!(r.head_off(), 0);
        assert_eq!(r.tail_off(), 5);
    }

    #[test]
    fn append_overflow_advances_head() {
        let mut r = ScrollbackRing::new(8);
        r.append(b"abcdefgh");
        assert_eq!(r.head_off(), 0);
        assert_eq!(r.tail_off(), 8);
        r.append(b"XYZ");
        assert_eq!(r.head_off(), 3);
        assert_eq!(r.tail_off(), 11);
        assert_eq!(r.len(), 8);
    }

    #[test]
    fn append_huge_data_truncated() {
        let mut r = ScrollbackRing::new(4);
        r.append(b"abcdefghij"); // 10 bytes into cap=4
        assert_eq!(r.head_off(), 6);
        assert_eq!(r.tail_off(), 10);
    }

    #[test]
    fn snapshot_all_on_empty_ring() {
        let r = ScrollbackRing::new(64);
        assert!(r.snapshot_all().is_empty());
    }

    #[test]
    fn snapshot_all_returns_everything_in_order() {
        let mut r = ScrollbackRing::new(64);
        r.append(b"hello world");
        assert_eq!(r.snapshot_all(), b"hello world");
    }

    #[test]
    fn snapshot_all_keeps_only_the_newest_after_overflow() {
        // 溢出时丢最旧的。OpenTab 拿到的是「最近这些字节」，够它把
        // shell 的初始 prompt 画出来。
        let mut r = ScrollbackRing::new(8);
        r.append(b"abcdefgh");
        r.append(b"XYZ"); // head=3, tail=11
        assert_eq!(r.snapshot_all(), b"defghXYZ");
    }

    #[test]
    fn snapshot_all_handles_wraparound() {
        // 物理写入位置绕回缓冲区头部时，拼接顺序不能错。
        let mut r = ScrollbackRing::new(8);
        r.append(b"abcdefgh"); // tail=8，物理位置正好绕满一圈
        r.append(b"ij"); // head=2, tail=10
        assert_eq!(r.snapshot_all(), b"cdefghij");
    }

    #[test]
    fn snapshot_all_after_single_oversized_write() {
        let mut r = ScrollbackRing::new(4);
        r.append(b"abcdefghij");
        assert_eq!(r.snapshot_all(), b"ghij", "只留得下最后 4 字节");
    }

    // ── Alt-buffer state tracking ─────────────────────────────────────

    #[test]
    fn alt_buffer_initially_off() {
        let r = ScrollbackRing::new(64);
        assert!(!r.is_alt_buffer());
    }

    #[test]
    fn alt_buffer_enter_then_exit() {
        let mut r = ScrollbackRing::new(64);
        r.append(b"normal output\x1b[?1049h");
        assert!(r.is_alt_buffer());
        r.append(b"\x1b[?1049l");
        assert!(!r.is_alt_buffer());
    }

    #[test]
    fn alt_buffer_repeated_enter() {
        let mut r = ScrollbackRing::new(64);
        r.append(b"\x1b[?1049h");
        assert!(r.is_alt_buffer());
        r.append(b"\x1b[?1049h"); // re-enter, still alt
        assert!(r.is_alt_buffer());
    }

    #[test]
    fn alt_buffer_survives_split_across_appends() {
        // Sequence split between two appends — matcher state must persist.
        let mut r = ScrollbackRing::new(64);
        r.append(b"\x1b[?10"); // first half
        assert!(!r.is_alt_buffer()); // not yet complete
        r.append(b"49h"); // second half
        assert!(r.is_alt_buffer());
    }

    #[test]
    fn alt_buffer_split_at_terminator() {
        // Prefix fully matched in first append, terminator in second.
        let mut r = ScrollbackRing::new(64);
        r.append(b"\x1b[?1049"); // prefix complete, awaiting h/l
        assert!(!r.is_alt_buffer());
        r.append(b"l"); // exit-alt
        assert!(!r.is_alt_buffer());
        r.append(b"\x1b[?1049");
        r.append(b"h"); // enter-alt
        assert!(r.is_alt_buffer());
    }

    #[test]
    fn alt_buffer_survives_ring_overflow() {
        // Once a transition is fed, it persists even after the carrying
        // byte is overwritten by ring overflow.
        let mut r = ScrollbackRing::new(8);
        r.append(b"\x1b[?1049h"); // 8 bytes exactly — fills ring
        assert!(r.is_alt_buffer());
        r.append(b"XYZ"); // pushes the enter sequence out of ring
        assert_eq!(r.head_off(), 3);
        // The bytes are gone from the buffer but the alt state remains.
        assert!(r.is_alt_buffer());
    }

    #[test]
    fn alt_buffer_unrelated_escapes_ignored() {
        let mut r = ScrollbackRing::new(64);
        // Other CSI sequences must not affect the alt-buffer matcher.
        r.append(b"\x1b[?25l\x1b[?2026h\x1b[H\x1b[2J");
        assert!(!r.is_alt_buffer());
        r.append(b"\x1b[?1049h");
        assert!(r.is_alt_buffer());
        r.append(b"\x1b[?25h\x1b[m");
        assert!(r.is_alt_buffer()); // still alt
    }

    #[test]
    fn alt_buffer_back_to_back_esc() {
        // \x1b followed by another \x1b (e.g. broken middle of one sequence
        // followed immediately by the start of the real one) should restart
        // the matcher correctly.
        let mut r = ScrollbackRing::new(64);
        r.append(b"\x1b\x1b[?1049h");
        assert!(r.is_alt_buffer());
    }
}

#[cfg(test)]
mod prop_tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn invariant_holds_after_random_appends(
            cap in 1usize..1024,
            writes in proptest::collection::vec(proptest::collection::vec(any::<u8>(), 0..2048), 0..50)
        ) {
            let mut r = ScrollbackRing::new(cap);
            for w in &writes {
                r.append(w);
                prop_assert!(r.tail_off() - r.head_off() <= cap as u64);
            }
        }

        #[test]
        fn snapshot_all_length_matches_len(
            cap in 1usize..256,
            data in proptest::collection::vec(any::<u8>(), 1..1024)
        ) {
            let mut r = ScrollbackRing::new(cap);
            r.append(&data);
            prop_assert_eq!(r.snapshot_all().len(), r.len());
        }

        #[test]
        fn snapshot_all_is_the_tail_of_what_was_written(
            cap in 1usize..128,
            data in proptest::collection::vec(any::<u8>(), 1..1024)
        ) {
            // ring 保留的永远是「最后写进去的那一段」，顺序不变。
            let mut r = ScrollbackRing::new(cap);
            r.append(&data);
            let got = r.snapshot_all();
            let want = &data[data.len() - got.len()..];
            prop_assert_eq!(got.as_slice(), want);
        }

    }
}
