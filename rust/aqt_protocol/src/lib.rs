// SPDX-License-Identifier: GPL-3.0-or-later
#![forbid(unsafe_code)]
#![warn(clippy::all)]

//! FlyTerm QUIC Transport — protocol crate
//!
//! Sans-IO protocol layer: frame codec, session state machine, ScrollbackRing.
//! No I/O or async runtime — caller drives all I/O.

pub mod codec;
pub mod error;
pub mod frame;
pub mod lz4block;
pub mod ring;
pub mod session;
pub mod varint;

pub use error::{DecodeError, ProtocolError};
pub use frame::Disposition;
pub use frame::{
    decode_frame_header, encode_frame, CloseTab, FileDone, FileDoneStatus, FileMode, FileProgress,
    FramePayload, Hello, HelloAck, HistoryPreloadDone, HistorySegmentMeta, ListHistory,
    ListHistoryResp, Opcode, OpenFile, OpenFileAck, OpenFileStatus, OpenTab, OpenTabAck,
    OpenTabStatus, PreloadHistorySpec, Resize, Resume, ResumeAck, ResumeAckTab, Signal,
};
pub use ring::ScrollbackRing;
pub use session::{Event, InputReplayBuffer, Session, State, TabOffsetTracker, TabOffsets};

/// 协议版本。
///
/// 1 → 2：删掉了 `FetchScrollback` / `ScrollbackChunk` 两个帧（opcode 0x60/0x61）
/// 以及 `Disposition::Restored.scrollback_head_line` 字段。历史现在整段随 RESUME
/// 负载送达，不再有按需取历史的通道。
///
/// **这次必须 bump**：Disposition 的线格式是位置式的（`put_u64` 挨着写），旧服务端
/// 会在 `DISP_RESTORED` 后多发一个 u64，新客户端把它当成 `server_in_seen_off` 读
/// —— 那是个静默错解析，不会报错，只会让输入重放从一个荒谬的 offset 开始，后面的
/// `compression_enabled` / `session_ttl_secs` 也跟着整体错位。
pub const PROTOCOL_VERSION: u8 = 2;

/// ALPN identifier for QUIC handshake.
///
/// 跟着 [`PROTOCOL_VERSION`] 一起从 1 走到 2。**必须一起改**，因为
/// [`PROTOCOL_VERSION`] 一个人挡不住上面那个错解析：
///
/// 版本检查只在 HELLO 分支里（见 `connection.rs`），而 `Resume` 帧不带版本字段。
/// 而 prewarm 路径正是拿磁盘上持久化的 token **直接 RESUME**、不走 SSH 引导的
/// —— 那条路上没有任何一处会比对版本，旧服务端会照常回一份多 8 字节的
/// ResumeAck。
///
/// ALPN 是唯一在**每一条**连接上、且先于任何帧交换生效的闸门：不匹配则 QUIC
/// 握手直接失败，客户端把它当「路径还没通」重试，最终回落到 SSH 引导那条路，
/// 那里会做版本比对并把服务端二进制升上来（见
/// `aqt_transport_factory.dart` 的 `_serverVersionSufficient`）。
pub const ALPN: &[u8] = b"aqt/2";

/// Capability bit — zstd compression (deprecated, kept for wire compatibility).
pub const CAP_ZSTD: u32 = 0x01;

/// Capability bit — LZ4 block compression (replaces CAP_ZSTD).
/// When both client and server set this bit, every server→client PTY bidi stream
/// is compressed with LZ4 block format: [u32 BE frame_len][lz4_flex compressed block].
/// PTY input direction is NOT compressed (volume too small).
pub const CAP_LZ4: u32 = 0x02;
