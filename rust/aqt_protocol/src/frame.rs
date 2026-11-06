// SPDX-License-Identifier: GPL-3.0-or-later
use crate::error::DecodeError;
use crate::varint::{decode_varint, encode_varint};
use bytes::{Buf, BufMut, BytesMut};

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Opcode {
    Hello = 0x01,
    HelloAck = 0x02,
    OpenTab = 0x10,
    OpenTabAck = 0x11,
    Resize = 0x12,
    Signal = 0x13,
    CloseTab = 0x14,
    Resume = 0x20,
    ResumeAck = 0x21,
    OpenFile = 0x30,
    OpenFileAck = 0x31,
    FileProgress = 0x32,
    FileDone = 0x33,
    ListHistory = 0x40,
    ListHistoryResp = 0x41,
    HistoryPreloadDone = 0x42,
    Notify = 0x50,
    NotifyAck = 0x51,
    // 0x60 / 0x61 曾是 FetchScrollback / ScrollbackChunk。整条通道随
    // PROTOCOL_VERSION 2 删除（历史现在全在 RESUME 负载里），**不要复用这两个
    // 编号** —— 留空能让误连上来的旧客户端在 from_u8 处明确报 UnknownOpcode，
    // 而不是被解成别的帧。
}

impl Opcode {
    pub fn from_u8(v: u8) -> Result<Self, DecodeError> {
        match v {
            0x01 => Ok(Self::Hello),
            0x02 => Ok(Self::HelloAck),
            0x10 => Ok(Self::OpenTab),
            0x11 => Ok(Self::OpenTabAck),
            0x12 => Ok(Self::Resize),
            0x13 => Ok(Self::Signal),
            0x14 => Ok(Self::CloseTab),
            0x20 => Ok(Self::Resume),
            0x21 => Ok(Self::ResumeAck),
            0x30 => Ok(Self::OpenFile),
            0x31 => Ok(Self::OpenFileAck),
            0x32 => Ok(Self::FileProgress),
            0x33 => Ok(Self::FileDone),
            0x40 => Ok(Self::ListHistory),
            0x41 => Ok(Self::ListHistoryResp),
            0x42 => Ok(Self::HistoryPreloadDone),
            0x50 => Ok(Self::Notify),
            0x51 => Ok(Self::NotifyAck),
            other => Err(DecodeError::UnknownOpcode(other)),
        }
    }
}

impl TryFrom<u8> for Opcode {
    type Error = DecodeError;
    fn try_from(v: u8) -> Result<Self, Self::Error> {
        Self::from_u8(v)
    }
}

/// Trait implemented by all control frame payloads.
pub trait FramePayload: Sized {
    const OPCODE: Opcode;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError>;
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError>;
}

/// Encode a full frame (op byte + varint len + payload) into out.
pub fn encode_frame<P: FramePayload>(payload: &P, out: &mut BytesMut) -> Result<(), DecodeError> {
    let mut body = BytesMut::with_capacity(64);
    payload.encode(&mut body)?;
    out.put_u8(P::OPCODE as u8);
    encode_varint(body.len() as u64, out)?;
    out.extend_from_slice(&body);
    Ok(())
}

/// Decode frame header only: returns (opcode, payload_byte_length).
/// Caller is responsible for consuming exactly that many bytes of payload.
pub fn decode_frame_header(buf: &mut impl Buf) -> Result<(Opcode, usize), DecodeError> {
    if buf.remaining() < 1 {
        return Err(DecodeError::Truncated { needed: 1, have: 0 });
    }
    let op = Opcode::from_u8(buf.get_u8())?;
    let len = decode_varint(buf)? as usize;
    Ok((op, len))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opcode_roundtrip() {
        for &(byte, op) in &[(0x01u8, Opcode::Hello), (0x33u8, Opcode::FileDone)] {
            assert_eq!(op as u8, byte);
            assert_eq!(Opcode::from_u8(byte).unwrap(), op);
        }
    }

    #[test]
    fn opcode_unknown() {
        assert!(matches!(
            Opcode::from_u8(0xFF),
            Err(DecodeError::UnknownOpcode(0xFF))
        ));
    }
}

#[cfg(test)]
mod frame_wrapper_tests {
    use super::*;

    struct Dummy(Vec<u8>);
    impl FramePayload for Dummy {
        const OPCODE: Opcode = Opcode::Hello;
        fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
            buf.extend_from_slice(&self.0);
            Ok(())
        }
        fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
            let mut out = vec![0; buf.remaining()];
            buf.copy_to_slice(&mut out);
            Ok(Dummy(out))
        }
    }

    #[test]
    fn frame_wrapper_roundtrip() {
        let payload = Dummy(vec![0xDE, 0xAD, 0xBE, 0xEF]);
        let mut buf = BytesMut::new();
        encode_frame(&payload, &mut buf).unwrap();

        assert_eq!(buf[0], 0x01); // Hello opcode
        assert_eq!(buf[1], 0x04); // varint(4) = 1 byte
        assert_eq!(&buf[2..], &[0xDE, 0xAD, 0xBE, 0xEF]);

        let mut b = buf.freeze();
        let (op, len) = decode_frame_header(&mut b).unwrap();
        assert_eq!(op, Opcode::Hello);
        assert_eq!(len, 4);
        assert_eq!(b.remaining(), 4);
    }

    #[test]
    fn decode_unknown_opcode() {
        let mut b: &[u8] = &[0xFF, 0x00];
        assert!(matches!(
            decode_frame_header(&mut b),
            Err(DecodeError::UnknownOpcode(0xFF))
        ));
    }
}

// ===== Concrete Frame Types =====

use crate::codec::{get_fixed, get_string_lp, put_fixed, put_string_lp};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hello {
    pub version: u8,
    pub client_id: [u8; 16],
    pub capabilities: u32,
}

impl FramePayload for Hello {
    const OPCODE: Opcode = Opcode::Hello;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u8(self.version);
        put_fixed(&self.client_id, buf);
        buf.put_u32(self.capabilities);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 1 {
            return Err(DecodeError::Truncated { needed: 1, have: 0 });
        }
        let version = buf.get_u8();
        let client_id = get_fixed::<16>(buf)?;
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let capabilities = buf.get_u32();
        Ok(Self {
            version,
            client_id,
            capabilities,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelloAck {
    pub server_caps: u32,
    pub session_token: [u8; 32],
}

impl FramePayload for HelloAck {
    const OPCODE: Opcode = Opcode::HelloAck;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.server_caps);
        put_fixed(&self.session_token, buf);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let server_caps = buf.get_u32();
        let session_token = get_fixed::<32>(buf)?;
        Ok(Self {
            server_caps,
            session_token,
        })
    }
}

#[cfg(test)]
mod hello_tests {
    use super::*;

    #[test]
    fn hello_roundtrip() {
        let h = Hello {
            version: 1,
            client_id: [0x42; 16],
            capabilities: 0xDEAD_BEEF,
        };
        let mut buf = BytesMut::new();
        encode_frame(&h, &mut buf).unwrap();
        let mut b = buf.freeze();
        let (op, _) = decode_frame_header(&mut b).unwrap();
        assert_eq!(op, Opcode::Hello);
        assert_eq!(Hello::decode(&mut b).unwrap(), h);
    }

    #[test]
    fn hello_ack_roundtrip() {
        let ack = HelloAck {
            server_caps: 0x1234,
            session_token: [0xAB; 32],
        };
        let mut buf = BytesMut::new();
        encode_frame(&ack, &mut buf).unwrap();
        let mut b = buf.freeze();
        let (op, _) = decode_frame_header(&mut b).unwrap();
        assert_eq!(op, Opcode::HelloAck);
        assert_eq!(HelloAck::decode(&mut b).unwrap(), ack);
    }

    #[test]
    fn hello_truncated_payload() {
        let mut b: &[u8] = &[0x01]; // just version byte, no client_id
        assert!(matches!(
            Hello::decode(&mut b),
            Err(DecodeError::Truncated { .. })
        ));
    }
}

// ===== PreloadHistorySpec (used as optional field in OpenTab) =====

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreloadHistorySpec {
    LatestMatching { cmd: String },
    Explicit { history_id: u64 },
}

impl PreloadHistorySpec {
    pub fn encode(&self, buf: &mut bytes::BytesMut) {
        match self {
            Self::LatestMatching { cmd } => {
                buf.put_u8(0x01);
                crate::codec::put_string_lp(cmd, buf)
                    .expect("put_string_lp cannot fail on BytesMut");
            }
            Self::Explicit { history_id } => {
                buf.put_u8(0x02);
                buf.put_u64(*history_id);
            }
        }
    }

    pub fn decode(buf: &mut &[u8]) -> Result<Self, crate::error::DecodeError> {
        if buf.is_empty() {
            return Err(crate::error::DecodeError::Truncated { needed: 1, have: 0 });
        }
        let tag = buf.get_u8();
        match tag {
            0x01 => {
                let cmd = crate::codec::get_string_lp(buf)?;
                Ok(Self::LatestMatching { cmd })
            }
            0x02 => {
                if buf.remaining() < 8 {
                    return Err(crate::error::DecodeError::Truncated {
                        needed: 8,
                        have: buf.remaining(),
                    });
                }
                Ok(Self::Explicit {
                    history_id: buf.get_u64(),
                })
            }
            _ => Err(crate::error::DecodeError::InvalidField(
                "PreloadHistorySpec tag",
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenTab {
    pub cols: u16,
    pub rows: u16,
    pub term: String,
    pub cwd: String, // empty = not specified
    pub cmd: String, // MVP: ignored by server, kept for wire compat
    /// Optional: request historical session content to be preloaded into the
    /// PTY stream before live output begins. Absent in old clients; new servers
    /// that receive an old frame (without this field) will decode it as `None`.
    pub preload_history: Option<PreloadHistorySpec>,
}

impl FramePayload for OpenTab {
    const OPCODE: Opcode = Opcode::OpenTab;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u16(self.cols);
        buf.put_u16(self.rows);
        put_string_lp(&self.term, buf)?;
        put_string_lp(&self.cwd, buf)?;
        put_string_lp(&self.cmd, buf)?;
        // Optional field: only written when present.
        // Old decoders that stop after cmd will simply ignore the extra bytes
        // (they are isolated by the transport-layer length prefix).
        if let Some(spec) = &self.preload_history {
            spec.encode(buf);
        }
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let cols = buf.get_u16();
        let rows = buf.get_u16();
        let term = get_string_lp(buf)?;
        let cwd = get_string_lp(buf)?;
        let cmd = get_string_lp(buf)?;
        // Backward compatible: only decode the optional field if bytes remain.
        // Old clients that do not send this field will have an empty buffer here,
        // so preload_history will be None.
        //
        // PreloadHistorySpec::decode takes &mut &[u8], so we collect the remaining
        // bytes into a local slice, decode from it, then advance `buf` by the
        // number of bytes consumed.
        let preload_history = if buf.has_remaining() {
            let remaining = buf.remaining();
            // Copy remaining bytes into a Vec so we can hold a &[u8] reference.
            let mut tmp = vec![0u8; remaining];
            buf.copy_to_slice(&mut tmp);
            let mut slice: &[u8] = &tmp;
            let spec = PreloadHistorySpec::decode(&mut slice)?;
            // `slice` has been advanced past the consumed bytes by decode().
            // Any leftover bytes in `slice` were part of the frame payload that
            // a future field extension might use; for now they are simply dropped
            // (the transport length prefix already bounds the payload window).
            Some(spec)
        } else {
            None
        };
        Ok(Self {
            cols,
            rows,
            term,
            cwd,
            cmd,
            preload_history,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenTabStatus {
    Ok = 0,
    QuotaExceeded = 1,
    SpawnFailed = 2,
    SessionInvalid = 3,
}

impl OpenTabStatus {
    pub fn from_u8(v: u8) -> Result<Self, DecodeError> {
        match v {
            0 => Ok(Self::Ok),
            1 => Ok(Self::QuotaExceeded),
            2 => Ok(Self::SpawnFailed),
            3 => Ok(Self::SessionInvalid),
            _ => Err(DecodeError::InvalidField("OpenTabStatus")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenTabAck {
    pub tab_id: u32,
    pub pty_stream_id: u64,
    pub status: OpenTabStatus,
}

impl FramePayload for OpenTabAck {
    const OPCODE: Opcode = Opcode::OpenTabAck;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.tab_id);
        encode_varint(self.pty_stream_id, buf)?;
        buf.put_u8(self.status as u8);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let tab_id = buf.get_u32();
        let pty_stream_id = decode_varint(buf)?;
        if buf.remaining() < 1 {
            return Err(DecodeError::Truncated { needed: 1, have: 0 });
        }
        Ok(Self {
            tab_id,
            pty_stream_id,
            status: OpenTabStatus::from_u8(buf.get_u8())?,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Resize {
    pub tab_id: u32,
    pub cols: u16,
    pub rows: u16,
}

impl FramePayload for Resize {
    const OPCODE: Opcode = Opcode::Resize;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.tab_id);
        buf.put_u16(self.cols);
        buf.put_u16(self.rows);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 8 {
            return Err(DecodeError::Truncated {
                needed: 8,
                have: buf.remaining(),
            });
        }
        Ok(Self {
            tab_id: buf.get_u32(),
            cols: buf.get_u16(),
            rows: buf.get_u16(),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Signal {
    pub tab_id: u32,
    pub signum: u8,
}

impl FramePayload for Signal {
    const OPCODE: Opcode = Opcode::Signal;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.tab_id);
        buf.put_u8(self.signum);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 5 {
            return Err(DecodeError::Truncated {
                needed: 5,
                have: buf.remaining(),
            });
        }
        Ok(Self {
            tab_id: buf.get_u32(),
            signum: buf.get_u8(),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CloseTab {
    pub tab_id: u32,
}

impl FramePayload for CloseTab {
    const OPCODE: Opcode = Opcode::CloseTab;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.tab_id);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        Ok(Self {
            tab_id: buf.get_u32(),
        })
    }
}

#[cfg(test)]
mod tab_frame_tests {
    use super::*;

    macro_rules! rt_test {
        ($name:ident, $ty:ty, $value:expr) => {
            #[test]
            fn $name() {
                let v: $ty = $value;
                let mut buf = BytesMut::new();
                encode_frame(&v, &mut buf).unwrap();
                let mut b = buf.freeze();
                let (op, _) = decode_frame_header(&mut b).unwrap();
                assert_eq!(op, <$ty as FramePayload>::OPCODE);
                let decoded = <$ty>::decode(&mut b).unwrap();
                assert_eq!(decoded, v);
            }
        };
    }

    rt_test!(
        open_tab_rt,
        OpenTab,
        OpenTab {
            cols: 80,
            rows: 24,
            term: "xterm-256color".into(),
            cwd: "/home/user".into(),
            cmd: "".into(),
            preload_history: None,
        }
    );
    rt_test!(
        open_tab_ack_rt,
        OpenTabAck,
        OpenTabAck {
            tab_id: 7,
            pty_stream_id: 1024,
            status: OpenTabStatus::Ok
        }
    );
    rt_test!(
        resize_rt,
        Resize,
        Resize {
            tab_id: 7,
            cols: 200,
            rows: 50
        }
    );
    rt_test!(
        signal_rt,
        Signal,
        Signal {
            tab_id: 7,
            signum: 15
        }
    );
    rt_test!(close_tab_rt, CloseTab, CloseTab { tab_id: 7 });
}

// ===== Resume + ResumeAck（2026-08-25 重新设计）=====
//
// Resume 不携带任何位置信息 —— 没有 last_out_off / last_in_off /
// ring_tail_hash。恢复传的是幂等的屏幕快照，不是字节增量，所以客户端不需要
// （也不应该）告诉服务端「我读到哪了」：那个状态在六个发起点之间无法维持
// 单一真相，是全部 offset 类 bug 的载体。
//
// ResumeAck 用 Disposition **显式声明**服务端做了什么，客户端按枚举分派。
// 旧协议让客户端用 `server_out_off - replay_bytes` 的算术去逆推「续传还是
// 重建」，于是服务端一改语义客户端判据就失效（见 e382759）。

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resume {
    pub session_token: [u8; 32],
    pub tabs: Vec<u32>,
}

impl FramePayload for Resume {
    const OPCODE: Opcode = Opcode::Resume;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        put_fixed(&self.session_token, buf);
        encode_varint(self.tabs.len() as u64, buf)?;
        for &t in &self.tabs {
            buf.put_u32(t);
        }
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        let session_token = get_fixed::<32>(buf)?;
        let count = decode_varint(buf)? as usize;
        let mut tabs = Vec::with_capacity(count.min(1024));
        for _ in 0..count {
            if buf.remaining() < 4 {
                return Err(DecodeError::Truncated {
                    needed: 4,
                    have: buf.remaining(),
                });
            }
            tabs.push(buf.get_u32());
        }
        Ok(Self {
            session_token,
            tabs,
        })
    }
}

/// 服务端对一个 tab 的处置。客户端**按枚举分派，不做任何算术推断**。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Disposition {
    /// 会话与 PTY 都在。
    ///
    /// 恢复内容**不在这个帧里** —— 它作为新 PTY 流的头几个字节送出（见
    /// `spawn_pty_forwarder` 的 `initial_bytes`）。这样客户端无需为它做任何
    /// 特殊处理：字节自然流进终端，与后续 live 输出同属一条有序流。
    ///
    /// 曾经有一个 `screen: Vec<u8>` 字段走这里。它把一段可达 256 KiB 的
    /// 载荷塞进控制帧，客户端必须整帧收齐才能解码，再经 FFI 两阶段拷回、
    /// 一次性 write。改回 PTY 流后这些都不需要了。
    Restored {
        /// 服务端已经收到的**输入**字节数。客户端据此从
        /// `InputReplayBuffer` 重发断线瞬间没送达的按键。
        ///
        /// ## 为什么输出方向的 offset 全删了，这个却留着
        ///
        /// 两者性质不同，不是一回事：
        ///
        /// * 输出 offset（`last_out_off` 等，已删）是**客户端的状态**——
        ///   「我读到哪了」。六个发起点各自计算它，谁都不是权威，于是同一
        ///   个 tab 能同时存在三个世代的值。那是无法修的，只能取消。
        /// * 输入 offset 是**服务端的状态**——「我收到了多少」。只有一个
        ///   来源，客户端照做即可，不存在世代分裂。
        ///
        /// 而且它承担的是正确性：没有它，用户在断线那一刻敲下的键会静默
        /// 丢失，而键盘输入丢字比画面短暂不一致严重得多。
        server_in_seen_off: u64,
    },
    /// 会话不存在或已过期。客户端复位终端、开新 shell。
    ///
    /// 这是**唯一**该复位终端的路径：旧实现在 QUIC 续传上也做那段复位，
    /// 把 TUI 那一屏丢掉而服务端只发 delta，于是黑屏且自愈不了。
    NewSession,
    /// token 有效但这个 tab 的进程已退出。客户端显示退出状态，**不**复位
    /// 终端 —— 用户还在看那些输出。
    TabGone { exit_status: Option<i32> },
}

const DISP_RESTORED: u8 = 1;
const DISP_NEW_SESSION: u8 = 2;
const DISP_TAB_GONE: u8 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeAckTab {
    pub tab_id: u32,
    pub new_pty_stream_id: u64,
    pub disposition: Disposition,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeAck {
    pub tabs: Vec<ResumeAckTab>,
    /// 这条已恢复会话的 server→client PTY 流是否启用了 zstd（原始 HELLO
    /// 时按 CAP_ZSTD 协商）。客户端据此接上解码器。
    pub compression_enabled: bool,
    /// 服务端的 session TTL。客户端存下来用它判过期 —— 常量在两侧各写一份
    /// 正是「服务端 7 天 vs 客户端 110 分钟」那个 bug 的根源。
    pub session_ttl_secs: u64,
    /// 每个 tab 的 RESUME 快照字节数，下标与 [`tabs`] 对齐。空 vec = 对端是
    /// 旧版本、没发这个字段。
    ///
    /// **只喂诊断，永远不得参与任何控制流分派。**
    ///
    /// 当年删掉 offset 语义，是因为「客户端按字节数决定这段数据该走哪条路」
    /// 引出了整类竞态（六个 RESUME 发起点各持一代 offset）。加一个长度字段
    /// 本身不重建那套语义 —— 前提是它只被用来打时间戳。客户端拿它算的是
    /// 「快照流完了没有」这个**时刻**，不是「这段字节属于谁」这个**归属**。
    /// 一旦有人用它做分派，那条竞态链就会整条回来。
    ///
    /// 编码位置在 payload 最外层尾部，不在 [`ResumeAckTab`] 内部：后者是
    /// 数组元素，其尾部紧跟下一个元素，「有剩余字节才读」在那里不成立。
    pub prelude_lens: Vec<u64>,
}

impl FramePayload for ResumeAck {
    const OPCODE: Opcode = Opcode::ResumeAck;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        encode_varint(self.tabs.len() as u64, buf)?;
        for t in &self.tabs {
            buf.put_u32(t.tab_id);
            encode_varint(t.new_pty_stream_id, buf)?;
            match &t.disposition {
                Disposition::Restored { server_in_seen_off } => {
                    buf.put_u8(DISP_RESTORED);
                    buf.put_u64(*server_in_seen_off);
                }
                Disposition::NewSession => buf.put_u8(DISP_NEW_SESSION),
                Disposition::TabGone { exit_status } => {
                    buf.put_u8(DISP_TAB_GONE);
                    match exit_status {
                        Some(c) => {
                            buf.put_u8(1);
                            buf.put_i32(*c);
                        }
                        None => buf.put_u8(0),
                    }
                }
            }
        }
        buf.put_u8(if self.compression_enabled { 1 } else { 0 });
        buf.put_u64(self.session_ttl_secs);
        // 长度契约：prelude_lens 要么为空（不发这个字段），要么与 tabs 等长。
        //
        // 解码侧按 tabs.len() 读，所以不一致时行为不对称：「少」会读到一半
        // buf 空、报 Truncated（能发现）；「多」只读前 tabs.len() 个，多余的
        // 字节被静默丢弃 —— 帧读取层不检查 payload 是否耗尽。tabs 为空时更
        // 极端：整段 prelude_lens 被吞掉，连 Truncated 都不会有。
        //
        // 不为此引入新的 error variant：这个字段只喂诊断，静默丢弃不影响
        // 正确性，不值得让正常路径背上一个分支。但也不能让服务端的计数 bug
        // 永远不可见 —— debug_assert 在开发/测试期立刻炸出来，release 构建
        // 下被裁掉，生产零成本。
        debug_assert!(
            self.prelude_lens.is_empty() || self.prelude_lens.len() == self.tabs.len(),
            "prelude_lens 长度必须为 0 或与 tabs 等长，实际 {} vs {}",
            self.prelude_lens.len(),
            self.tabs.len()
        );
        // 可选字段：只在非空时写。旧解码器读完 session_ttl_secs 就停，
        // 多出来的字节被帧头长度隔离，会被安全忽略。
        for len in &self.prelude_lens {
            encode_varint(*len, buf)?;
        }
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        let count = decode_varint(buf)? as usize;
        let mut tabs = Vec::with_capacity(count.min(1024));
        for _ in 0..count {
            if buf.remaining() < 4 {
                return Err(DecodeError::Truncated {
                    needed: 4,
                    have: buf.remaining(),
                });
            }
            let tab_id = buf.get_u32();
            let new_pty_stream_id = decode_varint(buf)?;
            if buf.remaining() < 1 {
                return Err(DecodeError::Truncated { needed: 1, have: 0 });
            }
            let disposition = match buf.get_u8() {
                DISP_RESTORED => {
                    if buf.remaining() < 8 {
                        return Err(DecodeError::Truncated {
                            needed: 8,
                            have: buf.remaining(),
                        });
                    }
                    Disposition::Restored {
                        server_in_seen_off: buf.get_u64(),
                    }
                }
                DISP_NEW_SESSION => Disposition::NewSession,
                DISP_TAB_GONE => {
                    if buf.remaining() < 1 {
                        return Err(DecodeError::Truncated { needed: 1, have: 0 });
                    }
                    let exit_status = if buf.get_u8() == 1 {
                        if buf.remaining() < 4 {
                            return Err(DecodeError::Truncated {
                                needed: 4,
                                have: buf.remaining(),
                            });
                        }
                        Some(buf.get_i32())
                    } else {
                        None
                    };
                    Disposition::TabGone { exit_status }
                }
                // 未知 tag 报错而不是猜 —— 猜出来的 disposition 会让客户端
                // 走错分支，正是这次重新设计要消除的那类问题。
                _ => return Err(DecodeError::InvalidField("Disposition")),
            };
            tabs.push(ResumeAckTab {
                tab_id,
                new_pty_stream_id,
                disposition,
            });
        }
        if buf.remaining() < 1 {
            return Err(DecodeError::Truncated { needed: 1, have: 0 });
        }
        let compression_enabled = buf.get_u8() != 0;
        if buf.remaining() < 8 {
            return Err(DecodeError::Truncated {
                needed: 8,
                have: buf.remaining(),
            });
        }
        let session_ttl_secs = buf.get_u64();
        // 向后兼容：只在还有剩余字节时读。旧服务端不发这个字段，
        // 此处 buf 已空 → prelude_lens 为空 vec。
        //
        // 读就必须读满 tabs.len() 个 —— 读到一半的数组会让下标与 tabs
        // 错位，而错位的诊断数据比没有数据更糟（它看起来是对的）。
        let prelude_lens = if buf.has_remaining() {
            let mut v = Vec::with_capacity(tabs.len());
            for _ in 0..tabs.len() {
                v.push(decode_varint(buf)?);
            }
            v
        } else {
            Vec::new()
        };
        Ok(Self {
            tabs,
            compression_enabled,
            session_ttl_secs,
            prelude_lens,
        })
    }
}

#[cfg(test)]
mod resume_ack_prelude_tests {
    use super::*;
    use bytes::BytesMut;

    fn sample_ack(prelude_lens: Vec<u64>) -> ResumeAck {
        ResumeAck {
            tabs: vec![
                ResumeAckTab {
                    tab_id: 7,
                    new_pty_stream_id: 42,
                    disposition: Disposition::Restored {
                        server_in_seen_off: 100,
                    },
                },
                ResumeAckTab {
                    tab_id: 8,
                    new_pty_stream_id: 43,
                    disposition: Disposition::NewSession,
                },
            ],
            compression_enabled: true,
            session_ttl_secs: 604800,
            prelude_lens,
        }
    }

    #[test]
    fn prelude_lens_roundtrip() {
        let ack = sample_ack(vec![4096, 0]);
        let mut buf = BytesMut::new();
        ack.encode(&mut buf).unwrap();
        let mut slice: &[u8] = &buf;
        let decoded = ResumeAck::decode(&mut slice).unwrap();
        assert_eq!(decoded, ack);
        assert_eq!(decoded.prelude_lens, vec![4096, 0]);
    }

    /// 旧服务端不发这个字段：解码后应得到空 vec，而不是报错。
    #[test]
    fn missing_prelude_lens_decodes_as_empty() {
        let ack = sample_ack(vec![]);
        let mut buf = BytesMut::new();
        ack.encode(&mut buf).unwrap();
        let mut slice: &[u8] = &buf;
        let decoded = ResumeAck::decode(&mut slice).unwrap();
        assert!(decoded.prelude_lens.is_empty());
    }

    /// 合法编码之后被**传输截断**：数组读到一半 buf 就空了，必须报错，
    /// 不能返回一个短数组 —— 短数组会让下标与 tabs 错位，而错位的诊断
    /// 数据比没有数据更糟，它看起来是对的。
    ///
    /// 注意这测的**不是**「编码器产出的计数与 tabs 不一致」，那是另一回事，
    /// 由 encode 里的 debug_assert 兜（"多"的情形解码侧不会报错）。
    #[test]
    fn truncated_prelude_lens_is_an_error() {
        let ack = sample_ack(vec![4096, 0]);
        let mut buf = BytesMut::new();
        ack.encode(&mut buf).unwrap();
        // 砍掉最后一个 varint（值 0，单字节）
        let truncated = &buf[..buf.len() - 1];
        let mut slice: &[u8] = truncated;
        assert!(ResumeAck::decode(&mut slice).is_err());
    }
}

// ===== OpenFile + OpenFileAck + FileProgress + FileDone =====

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FileMode {
    Upload = 1,
    Download = 2,
    UploadResume = 3,
    DownloadResume = 4,
}

impl FileMode {
    pub fn from_u8(v: u8) -> Result<Self, DecodeError> {
        match v {
            1 => Ok(Self::Upload),
            2 => Ok(Self::Download),
            3 => Ok(Self::UploadResume),
            4 => Ok(Self::DownloadResume),
            _ => Err(DecodeError::InvalidField("FileMode")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum OpenFileStatus {
    Ok = 0,
    PathInvalid = 1,
    PermissionDenied = 2,
    DiskFull = 3,
    AlreadyExists = 4,
    ResumeMismatch = 5,
    QuotaExceeded = 6,
}

impl OpenFileStatus {
    pub fn from_u8(v: u8) -> Result<Self, DecodeError> {
        match v {
            0 => Ok(Self::Ok),
            1 => Ok(Self::PathInvalid),
            2 => Ok(Self::PermissionDenied),
            3 => Ok(Self::DiskFull),
            4 => Ok(Self::AlreadyExists),
            5 => Ok(Self::ResumeMismatch),
            6 => Ok(Self::QuotaExceeded),
            _ => Err(DecodeError::InvalidField("OpenFileStatus")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FileDoneStatus {
    Ok = 0,
    HashMismatch = 1,
    Aborted = 2,
    DiskFull = 3,
}

impl FileDoneStatus {
    pub fn from_u8(v: u8) -> Result<Self, DecodeError> {
        match v {
            0 => Ok(Self::Ok),
            1 => Ok(Self::HashMismatch),
            2 => Ok(Self::Aborted),
            3 => Ok(Self::DiskFull),
            _ => Err(DecodeError::InvalidField("FileDoneStatus")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenFile {
    pub request_id: u32,
    pub mode: FileMode,
    pub path: String,
    pub size: u64,
    pub perms: u32,
    pub resume_offset: u64,
    pub sha256_full: [u8; 32],
}

impl FramePayload for OpenFile {
    const OPCODE: Opcode = Opcode::OpenFile;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.request_id);
        buf.put_u8(self.mode as u8);
        put_string_lp(&self.path, buf)?;
        buf.put_u64(self.size);
        buf.put_u32(self.perms);
        buf.put_u64(self.resume_offset);
        put_fixed(&self.sha256_full, buf);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 5 {
            return Err(DecodeError::Truncated {
                needed: 5,
                have: buf.remaining(),
            });
        }
        let request_id = buf.get_u32();
        let mode = FileMode::from_u8(buf.get_u8())?;
        let path = get_string_lp(buf)?;
        if buf.remaining() < 20 {
            return Err(DecodeError::Truncated {
                needed: 20,
                have: buf.remaining(),
            });
        }
        let size = buf.get_u64();
        let perms = buf.get_u32();
        let resume_offset = buf.get_u64();
        let sha256_full = get_fixed::<32>(buf)?;
        Ok(Self {
            request_id,
            mode,
            path,
            size,
            perms,
            resume_offset,
            sha256_full,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenFileAck {
    pub request_id: u32,
    pub file_stream_id: u64,
    pub status: OpenFileStatus,
    pub existing_size: u64,
    pub existing_sha256: [u8; 32],
}

impl FramePayload for OpenFileAck {
    const OPCODE: Opcode = Opcode::OpenFileAck;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.request_id);
        encode_varint(self.file_stream_id, buf)?;
        buf.put_u8(self.status as u8);
        buf.put_u64(self.existing_size);
        put_fixed(&self.existing_sha256, buf);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let request_id = buf.get_u32();
        let file_stream_id = decode_varint(buf)?;
        if buf.remaining() < 9 {
            return Err(DecodeError::Truncated {
                needed: 9,
                have: buf.remaining(),
            });
        }
        let status = OpenFileStatus::from_u8(buf.get_u8())?;
        let existing_size = buf.get_u64();
        let existing_sha256 = get_fixed::<32>(buf)?;
        Ok(Self {
            request_id,
            file_stream_id,
            status,
            existing_size,
            existing_sha256,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileProgress {
    pub request_id: u32,
    pub bytes_done: u64,
    pub throughput_bps: u32,
}

impl FramePayload for FileProgress {
    const OPCODE: Opcode = Opcode::FileProgress;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.request_id);
        buf.put_u64(self.bytes_done);
        buf.put_u32(self.throughput_bps);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 16 {
            return Err(DecodeError::Truncated {
                needed: 16,
                have: buf.remaining(),
            });
        }
        Ok(Self {
            request_id: buf.get_u32(),
            bytes_done: buf.get_u64(),
            throughput_bps: buf.get_u32(),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileDone {
    pub request_id: u32,
    pub sha256: [u8; 32],
    pub status: FileDoneStatus,
}

impl FramePayload for FileDone {
    const OPCODE: Opcode = Opcode::FileDone;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.request_id);
        put_fixed(&self.sha256, buf);
        buf.put_u8(self.status as u8);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let request_id = buf.get_u32();
        let sha256 = get_fixed::<32>(buf)?;
        if buf.remaining() < 1 {
            return Err(DecodeError::Truncated { needed: 1, have: 0 });
        }
        Ok(Self {
            request_id,
            sha256,
            status: FileDoneStatus::from_u8(buf.get_u8())?,
        })
    }
}

#[cfg(test)]
mod file_frame_tests {
    use super::*;

    #[test]
    fn open_file_upload_roundtrip() {
        let v = OpenFile {
            request_id: 42,
            mode: FileMode::Upload,
            path: "/tmp/foo.tar.gz".into(),
            size: 1_048_576,
            perms: 0o644,
            resume_offset: 0,
            sha256_full: [0xAB; 32],
        };
        let mut buf = BytesMut::new();
        encode_frame(&v, &mut buf).unwrap();
        let mut b = buf.freeze();
        decode_frame_header(&mut b).unwrap();
        assert_eq!(OpenFile::decode(&mut b).unwrap(), v);
    }

    #[test]
    fn open_file_ack_roundtrip() {
        let v = OpenFileAck {
            request_id: 42,
            file_stream_id: 8192,
            status: OpenFileStatus::Ok,
            existing_size: 0,
            existing_sha256: [0; 32],
        };
        let mut buf = BytesMut::new();
        encode_frame(&v, &mut buf).unwrap();
        let mut b = buf.freeze();
        decode_frame_header(&mut b).unwrap();
        assert_eq!(OpenFileAck::decode(&mut b).unwrap(), v);
    }

    #[test]
    fn file_progress_roundtrip() {
        let v = FileProgress {
            request_id: 42,
            bytes_done: 524_288,
            throughput_bps: 1_000_000,
        };
        let mut buf = BytesMut::new();
        encode_frame(&v, &mut buf).unwrap();
        let mut b = buf.freeze();
        decode_frame_header(&mut b).unwrap();
        assert_eq!(FileProgress::decode(&mut b).unwrap(), v);
    }

    #[test]
    fn file_done_roundtrip() {
        let v = FileDone {
            request_id: 42,
            sha256: [0xCD; 32],
            status: FileDoneStatus::Ok,
        };
        let mut buf = BytesMut::new();
        encode_frame(&v, &mut buf).unwrap();
        let mut b = buf.freeze();
        decode_frame_header(&mut b).unwrap();
        assert_eq!(FileDone::decode(&mut b).unwrap(), v);
    }

    #[test]
    fn invalid_file_mode_rejected() {
        let mut b: &[u8] = &[0, 0, 0, 1, 99]; // request_id u32 + invalid mode byte
        assert!(matches!(
            OpenFile::decode(&mut b),
            Err(DecodeError::InvalidField("FileMode"))
        ));
    }
}

// ===== ListHistory + ListHistoryResp + HistoryPreloadDone =====

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListHistory {
    pub command_hint: Option<String>,
    pub limit: u16,
    pub before_ts: Option<u64>,
}

impl FramePayload for ListHistory {
    const OPCODE: Opcode = Opcode::ListHistory;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        match &self.command_hint {
            Some(s) => {
                buf.put_u8(1);
                put_string_lp(s, buf)?;
            }
            None => {
                buf.put_u8(0);
            }
        }
        buf.put_u16(self.limit);
        match self.before_ts {
            Some(t) => {
                buf.put_u8(1);
                buf.put_u64(t);
            }
            None => {
                buf.put_u8(0);
            }
        }
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 1 {
            return Err(DecodeError::Truncated { needed: 1, have: 0 });
        }
        let has_cmd = buf.get_u8();
        let command_hint = match has_cmd {
            0 => None,
            1 => Some(get_string_lp(buf)?),
            _ => return Err(DecodeError::InvalidField("command_hint presence")),
        };
        if buf.remaining() < 2 {
            return Err(DecodeError::Truncated {
                needed: 2,
                have: buf.remaining(),
            });
        }
        let limit = buf.get_u16();
        if buf.remaining() < 1 {
            return Err(DecodeError::Truncated { needed: 1, have: 0 });
        }
        let has_ts = buf.get_u8();
        let before_ts = match has_ts {
            0 => None,
            1 => {
                if buf.remaining() < 8 {
                    return Err(DecodeError::Truncated {
                        needed: 8,
                        have: buf.remaining(),
                    });
                }
                Some(buf.get_u64())
            }
            _ => return Err(DecodeError::InvalidField("before_ts presence")),
        };
        Ok(Self {
            command_hint,
            limit,
            before_ts,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistorySegmentMeta {
    pub history_id: u64,
    pub command_hint: String,
    pub started_at: u64,
    pub ended_at: u64,
    pub size_bytes: u64,
    pub preview: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListHistoryResp {
    pub segments: Vec<HistorySegmentMeta>,
}

impl FramePayload for ListHistoryResp {
    const OPCODE: Opcode = Opcode::ListHistoryResp;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.segments.len() as u32);
        for s in &self.segments {
            buf.put_u64(s.history_id);
            put_string_lp(&s.command_hint, buf)?;
            buf.put_u64(s.started_at);
            buf.put_u64(s.ended_at);
            buf.put_u64(s.size_bytes);
            put_string_lp(&s.preview, buf)?;
        }
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let n = buf.get_u32() as usize;
        if n > 1_000 {
            return Err(DecodeError::InvalidField("too many segments"));
        }
        let mut segments = Vec::with_capacity(n);
        for _ in 0..n {
            if buf.remaining() < 8 {
                return Err(DecodeError::Truncated {
                    needed: 8,
                    have: buf.remaining(),
                });
            }
            let history_id = buf.get_u64();
            let command_hint = get_string_lp(buf)?;
            if buf.remaining() < 24 {
                return Err(DecodeError::Truncated {
                    needed: 24,
                    have: buf.remaining(),
                });
            }
            let started_at = buf.get_u64();
            let ended_at = buf.get_u64();
            let size_bytes = buf.get_u64();
            let preview = get_string_lp(buf)?;
            segments.push(HistorySegmentMeta {
                history_id,
                command_hint,
                started_at,
                ended_at,
                size_bytes,
                preview,
            });
        }
        Ok(Self { segments })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPreloadDone {
    pub tab_id: u32,
    pub preloaded_bytes: u64,
    pub segments: Vec<(u64, u64, u64)>, // (history_id, started_at, ended_at)
}

impl FramePayload for HistoryPreloadDone {
    const OPCODE: Opcode = Opcode::HistoryPreloadDone;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u32(self.tab_id);
        buf.put_u64(self.preloaded_bytes);
        buf.put_u32(self.segments.len() as u32);
        for (id, s, e) in &self.segments {
            buf.put_u64(*id);
            buf.put_u64(*s);
            buf.put_u64(*e);
        }
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 16 {
            return Err(DecodeError::Truncated {
                needed: 16,
                have: buf.remaining(),
            });
        }
        let tab_id = buf.get_u32();
        let preloaded_bytes = buf.get_u64();
        if buf.remaining() < 4 {
            return Err(DecodeError::Truncated {
                needed: 4,
                have: buf.remaining(),
            });
        }
        let n = buf.get_u32() as usize;
        if n > 1_000 {
            return Err(DecodeError::InvalidField("too many segments"));
        }
        let mut segments = Vec::with_capacity(n);
        for _ in 0..n {
            if buf.remaining() < 24 {
                return Err(DecodeError::Truncated {
                    needed: 24,
                    have: buf.remaining(),
                });
            }
            segments.push((buf.get_u64(), buf.get_u64(), buf.get_u64()));
        }
        Ok(Self {
            tab_id,
            preloaded_bytes,
            segments,
        })
    }
}

// ===== 自托管通知：Notify + NotifyAck =====

/// 服务端主动推给客户端的一条通知事件。
///
/// `ts_unix_ms` 是事件**发生**时刻而非投递时刻 —— 断连期间排队的事件在
/// RESUME 时补投，必须显示原始时间，否则一批旧事件会全部显示成"刚刚"。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notify {
    pub event_id: u64,
    pub ts_unix_ms: u64,
    pub text: String,
    /// 事件来源 tab。tmux pane 继承了过期的 FLYTERM_TAB_ID 时降级为 None，
    /// 客户端此时把通知深链到服务器而非具体 tab。
    pub tab_id: Option<u32>,
}

impl FramePayload for Notify {
    const OPCODE: Opcode = Opcode::Notify;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u64(self.event_id);
        buf.put_u64(self.ts_unix_ms);
        put_string_lp(&self.text, buf)?;
        match self.tab_id {
            Some(t) => {
                buf.put_u8(1);
                buf.put_u32(t);
            }
            None => buf.put_u8(0),
        }
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 16 {
            return Err(DecodeError::Truncated {
                needed: 16,
                have: buf.remaining(),
            });
        }
        let event_id = buf.get_u64();
        let ts_unix_ms = buf.get_u64();
        let text = get_string_lp(buf)?;
        if buf.remaining() < 1 {
            return Err(DecodeError::Truncated { needed: 1, have: 0 });
        }
        let tab_id = match buf.get_u8() {
            0 => None,
            1 => {
                if buf.remaining() < 4 {
                    return Err(DecodeError::Truncated {
                        needed: 4,
                        have: buf.remaining(),
                    });
                }
                Some(buf.get_u32())
            }
            _ => return Err(DecodeError::InvalidField("tab_id presence")),
        };
        Ok(Self {
            event_id,
            ts_unix_ms,
            text,
            tab_id,
        })
    }
}

/// 客户端已消费位置。服务端据此裁剪队列，语义与 RESUME 的 last_out_off 同构。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotifyAck {
    pub last_event_id: u64,
}

impl FramePayload for NotifyAck {
    const OPCODE: Opcode = Opcode::NotifyAck;
    fn encode(&self, buf: &mut BytesMut) -> Result<(), DecodeError> {
        buf.put_u64(self.last_event_id);
        Ok(())
    }
    fn decode(buf: &mut impl Buf) -> Result<Self, DecodeError> {
        if buf.remaining() < 8 {
            return Err(DecodeError::Truncated {
                needed: 8,
                have: buf.remaining(),
            });
        }
        Ok(Self {
            last_event_id: buf.get_u64(),
        })
    }
}

#[cfg(test)]
mod notify_tests {
    use super::*;

    #[test]
    fn notify_roundtrip_with_tab() {
        let v = Notify {
            event_id: 7,
            ts_unix_ms: 1_755_300_000_000,
            text: "构建完成".into(),
            tab_id: Some(3),
        };
        let mut buf = BytesMut::new();
        encode_frame(&v, &mut buf).unwrap();
        let mut b = buf.freeze();
        decode_frame_header(&mut b).unwrap();
        assert_eq!(Notify::decode(&mut b).unwrap(), v);
    }

    #[test]
    fn notify_roundtrip_without_tab() {
        // tab_id=None 是真实路径：tmux pane 继承了过期环境变量时降级如此。
        let v = Notify {
            event_id: 1,
            ts_unix_ms: 0,
            text: String::new(),
            tab_id: None,
        };
        let mut buf = BytesMut::new();
        encode_frame(&v, &mut buf).unwrap();
        let mut b = buf.freeze();
        decode_frame_header(&mut b).unwrap();
        assert_eq!(Notify::decode(&mut b).unwrap(), v);
    }

    #[test]
    fn notify_ack_roundtrip() {
        let v = NotifyAck { last_event_id: 42 };
        let mut buf = BytesMut::new();
        encode_frame(&v, &mut buf).unwrap();
        let mut b = buf.freeze();
        decode_frame_header(&mut b).unwrap();
        assert_eq!(NotifyAck::decode(&mut b).unwrap(), v);
    }

    #[test]
    fn notify_rejects_bad_tab_presence_byte() {
        // presence 字节只允许 0/1；其他值必须报错而不是静默当成 None。
        let mut b: &[u8] = &[
            0, 0, 0, 0, 0, 0, 0, 1, // event_id
            0, 0, 0, 0, 0, 0, 0, 0, // ts
            0, // 空字符串 (varint len = 0)
            9, // 非法 presence
        ];
        assert!(Notify::decode(&mut b).is_err());
    }
}
