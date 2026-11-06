// SPDX-License-Identifier: GPL-3.0-or-later
#![allow(unsafe_code)]

use std::ffi::{c_char, c_int, c_void, CStr};
use std::net::SocketAddr;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;

use bytes::{Buf, BytesMut};

use aqt_protocol::frame::{HistoryPreloadDone, NotifyAck, PreloadHistorySpec};
use aqt_protocol::{
    decode_frame_header, encode_frame, FramePayload, Hello, HelloAck, OpenTab, OpenTabAck,
    OpenTabStatus, Resize, Resume, ResumeAck, CAP_LZ4, PROTOCOL_VERSION,
};
// Notify itself is only ever referenced through inference (notify_accept_loop's
// read_frame_from::<Notify>() infers P from context) — importing it by name
// here would be unused, same reasoning as connection.rs's NotifyAck-only import.

use crate::client::{connect, make_client_endpoint};
use crate::error::AqtError;
use crate::handle::{AqtEvent, AqtEventKind, ConnState, SessionHandle, TabHandle};
use crate::runtime::RUNTIME;

/// Connection parameters struct passed from Dart.
#[repr(C)]
pub struct AqtConnectParams {
    /// null-terminated UTF-8 host string
    pub host: *const c_char,
    pub port: u16,
    /// raw SPKI bytes (decoded from base64 by Dart side)
    pub spki_ptr: *const u8,
    pub spki_len: usize,
    /// 32-byte session token
    pub token_ptr: *const u8,
    /// null-terminated SNI (often = base64 of token)
    pub sni: *const c_char,
}

// ──────────────────────────────────────────────
// Internal helpers
// ──────────────────────────────────────────────

/// Read one framed message from a RecvStream, returning the decoded payload.
async fn read_frame_from<P: FramePayload>(rx: &mut quinn::RecvStream) -> anyhow::Result<P> {
    let mut rbuf = BytesMut::new();
    loop {
        let mut tmp = [0u8; 512];
        let n = rx
            .read(&mut tmp)
            .await?
            .ok_or_else(|| anyhow::anyhow!("eof while reading frame"))?;
        rbuf.extend_from_slice(&tmp[..n]);

        // Try to parse header from current buffer
        let mut peek: &[u8] = &rbuf;
        match decode_frame_header(&mut peek) {
            Ok((_op, payload_len)) => {
                let header_len = rbuf.len() - peek.len();
                if peek.len() >= payload_len {
                    // Discard header bytes
                    rbuf.advance(header_len);
                    let payload_bytes = rbuf.split_to(payload_len);
                    let mut pb: &[u8] = &payload_bytes;
                    let frame =
                        P::decode(&mut pb).map_err(|e| anyhow::anyhow!("decode frame: {e:?}"))?;
                    return Ok(frame);
                }
                // else: need more bytes — keep looping
            }
            Err(_) => {
                // Truncated header — need more bytes
            }
        }
    }
}

/// Persistent-stream frame reader for uni streams that may carry more than
/// one frame per physical `rx.read()` (e.g. the Notify push stream: the
/// server's 500ms tick writes several queued events back-to-back in one
/// `for ev in pending { write_frame(...).await }` burst — see
/// `spawn_notify_push_task` in `connection.rs`).
///
/// `read_frame_from` above is **not** safe to reuse here: it allocates a
/// fresh `BytesMut` on every call and returns as soon as the FIRST frame
/// decodes, silently dropping whatever trailing bytes of the NEXT frame
/// happened to already be sitting in that same physical read. On the four
/// existing `read_frame_from` call sites (HelloAck / OpenTabAck / ResumeAck /
/// HistoryPreloadDone) that's harmless dead-code risk — those are strict
/// one-shot request/response exchanges, so the stream never has a second
/// frame queued up behind the one being read. On a persistent stream that
/// gets read in a `loop` — like Notify's — it is not harmless: confirmed by
/// reproduction, broadcasting two events back-to-back before the client
/// even accepts the stream causes the SECOND read to return the FIRST
/// event again (the tick's redelivery of the still-unacked first event),
/// while the second event is never observed. It doesn't eventually recover
/// either — every subsequent read keeps re-decoding whatever the first
/// complete frame in the (never-persisted) buffer is, so events other than
/// the first one in a coalesced batch are dropped for good. That is exactly
/// the scenario the whole feature exists for: notifications piling up while
/// the phone was asleep/offline and arriving in a burst once it reconnects.
///
/// The fix is for the buffer to outlive a single call: `FrameReader` owns a
/// `BytesMut` across the whole lifetime of the stream, and `read_frames`
/// drains and returns *every* complete frame already sitting in it before
/// touching the network again, leaving only a genuinely incomplete tail
/// buffered for the next physical `read()` to complete.
struct FrameReader {
    buf: BytesMut,
}

impl FrameReader {
    fn new() -> Self {
        Self {
            buf: BytesMut::new(),
        }
    }

    /// Reads from `rx` until at least one frame can be decoded, then
    /// returns every complete frame currently sitting in the buffer (there
    /// may be more than one if a physical read coalesced several writes).
    ///
    /// Opcode is validated against `P::OPCODE` (unlike `read_frame_from`,
    /// which discards it and decodes unconditionally). On this stream that
    /// "safety" today rests entirely on the structural fact that the server
    /// only ever writes Notify frames here — not on anything the code
    /// enforces. A mismatched opcode is logged and its payload skipped
    /// (advancing past exactly `payload_len` bytes) rather than treated as
    /// a hard decode error, so a single unexpected frame can't permanently
    /// kill notification delivery for the rest of the connection's life —
    /// which is what happened before: `P::decode` failing on a wrong-typed
    /// payload propagated an `Err` all the way out of `notify_accept_loop`,
    /// ending the loop's `return` for good.
    async fn read_frames<P: FramePayload>(
        &mut self,
        rx: &mut quinn::RecvStream,
    ) -> anyhow::Result<Vec<P>> {
        loop {
            let mut out = Vec::new();
            loop {
                let mut peek: &[u8] = &self.buf;
                match decode_frame_header(&mut peek) {
                    Ok((op, payload_len)) => {
                        let header_len = self.buf.len() - peek.len();
                        if peek.len() < payload_len {
                            break; // header complete, payload still incomplete — need more bytes
                        }
                        self.buf.advance(header_len);
                        let payload_bytes = self.buf.split_to(payload_len);
                        if op != P::OPCODE {
                            tracing::warn!(
                                "FrameReader: unexpected opcode {op:?} (want {:?}), skipping {payload_len}B",
                                P::OPCODE
                            );
                            continue;
                        }
                        let mut pb: &[u8] = &payload_bytes;
                        match P::decode(&mut pb) {
                            Ok(frame) => out.push(frame),
                            Err(e) => {
                                tracing::warn!("FrameReader: decode failed, skipping frame: {e:?}");
                            }
                        }
                    }
                    Err(_) => break, // header itself incomplete — need more bytes
                }
            }
            if !out.is_empty() {
                return Ok(out);
            }
            let mut tmp = [0u8; 1024];
            let n = rx
                .read(&mut tmp)
                .await?
                .ok_or_else(|| anyhow::anyhow!("eof while reading frame"))?;
            self.buf.extend_from_slice(&tmp[..n]);
        }
    }
}

/// Spawn a task that reads bytes from `pty_recv`, optionally decompressing
/// them with zstd, and emits `PtyOutput` events. When `compression` is true,
/// LZ4 block framing: server sends [u32 BE frame_len][lz4_flex compressed block].
/// Client reads the length header, reads exactly that many bytes, then
/// calls lz4_flex::block::decompress_size_prepended() on the block.
/// Each chunk is an independent LZ4 block — no streaming state.
fn spawn_pty_reader(
    pty_recv: quinn::RecvStream,
    evt_tx: tokio::sync::mpsc::UnboundedSender<AqtEvent>,
    tab_id: u32,
    compression: bool,
) {
    tokio::spawn(async move {
        macro_rules! send_closed {
            () => {
                let _ = evt_tx.send(AqtEvent {
                    kind: AqtEventKind::TabClosed,
                    tab_id,
                    data: vec![],
                    preloaded_bytes: 0,
                });
            };
        }
        if compression {
            let mut prx = pty_recv;
            loop {
                // Read 4-byte big-endian frame length
                let mut len_buf = [0u8; 4];
                let mut got = 0usize;
                loop {
                    match prx.read(&mut len_buf[got..]).await {
                        Ok(Some(n)) if n > 0 => {
                            got += n;
                            if got == 4 {
                                break;
                            }
                        }
                        Ok(Some(_)) => {}
                        Ok(None) | Err(_) => {
                            send_closed!();
                            return;
                        }
                    }
                }
                let frame_len = u32::from_be_bytes(len_buf) as usize;
                if frame_len > 2 * 1024 * 1024 {
                    tracing::warn!("lz4 frame too large: {} bytes (max 2 MB)", frame_len);
                    let _ = evt_tx.send(AqtEvent {
                        kind: AqtEventKind::TabClosed,
                        tab_id,
                        data: b"lz4_frame_too_large".to_vec(),
                        preloaded_bytes: 0,
                    });
                    return;
                }
                // Read the compressed block
                let mut compressed = vec![0u8; frame_len];
                let mut got = 0usize;
                while got < frame_len {
                    match prx.read(&mut compressed[got..]).await {
                        Ok(Some(n)) if n > 0 => got += n,
                        Ok(Some(_)) => {}
                        Ok(None) | Err(_) => {
                            send_closed!();
                            return;
                        }
                    }
                }
                // Decompress (block includes prepended original size)
                match aqt_protocol::lz4block::decompress_size_prepended(&compressed) {
                    Ok(data) => {
                        let _ = evt_tx.send(AqtEvent {
                            kind: AqtEventKind::PtyOutput,
                            tab_id,
                            data,
                            preloaded_bytes: 0,
                        });
                    }
                    Err(e) => {
                        tracing::warn!(
                            "lz4 decompression error: {:?} (frame_len={})",
                            e,
                            frame_len
                        );
                        let _ = evt_tx.send(AqtEvent {
                            kind: AqtEventKind::TabClosed,
                            tab_id,
                            data: format!("lz4_error:{:?}", e).into_bytes(),
                            preloaded_bytes: 0,
                        });
                        return;
                    }
                }
            }
        } else {
            let mut prx = pty_recv;
            let mut buf = [0u8; 4096];
            loop {
                match prx.read(&mut buf).await {
                    Ok(Some(n)) if n > 0 => {
                        let _ = evt_tx.send(AqtEvent {
                            kind: AqtEventKind::PtyOutput,
                            tab_id,
                            data: buf[..n].to_vec(),
                            preloaded_bytes: 0,
                        });
                    }
                    Ok(Some(_)) => {} // n == 0, ignore
                    Ok(None) | Err(_) => {
                        let _ = evt_tx.send(AqtEvent {
                            kind: AqtEventKind::TabClosed,
                            tab_id,
                            data: vec![],
                            preloaded_bytes: 0,
                        });
                        break;
                    }
                }
            }
        }
    });
}

/// Perform HELLO handshake on the control bidi stream.
/// Stores ctrl_tx and ctrl_rx in the handle on success.
async fn do_hello_handshake(h: &SessionHandle, conn: quinn::Connection) -> anyhow::Result<()> {
    let (mut tx, mut rx) = conn.open_bi().await?;

    // Send HELLO. Always advertise CAP_ZSTD — server confirms via server_caps.
    let hello = Hello {
        version: PROTOCOL_VERSION,
        client_id: [0x42; 16],
        capabilities: CAP_LZ4,
    };
    let mut buf = BytesMut::new();
    encode_frame(&hello, &mut buf).map_err(|e| anyhow::anyhow!("encode HELLO: {e:?}"))?;
    tx.write_all(&buf).await?;

    // Read HELLO_ACK
    let ack: HelloAck = read_frame_from(&mut rx).await?;
    let compression = (ack.server_caps & CAP_LZ4) != 0;
    tracing::info!("HELLO_ACK received; lz4={}", compression);

    // Store session token for 0-RTT RESUME and the negotiated compression flag.
    *h.session_token.lock().await = Some(ack.session_token);
    *h.compression_enabled.lock().await = compression;

    // Store control stream halves
    *h.ctrl_tx.lock().await = Some(tx);
    *h.ctrl_rx.lock().await = Some(rx);

    Ok(())
}

/// Persistent Notify dispatch loop (Route B).
///
/// 为什么通知走一条独立的 uni 流，而不是在控制流的 read_frame_from 调用点
/// 之间插一个共享的 opcode 分发器：控制流上现有的三处 accept_bi()
/// （do_open_tab / do_open_tab_v2 / do_quic_resume）以及 HelloAck/OpenTabAck/
/// ResumeAck/HistoryPreloadDone 的读取，全部是"发一次请求、读一次期望类型
/// 的响应"这种一次性调用，中间没有常驻的控制流读循环——tab 打开之后如果
/// 长时间没有新的 Resize/Signal 等控制流量，控制流根本不会被轮询，服务端
/// 这段时间推的 Notify 帧就会淤积在 QUIC 层，客户端却感知不到。
///
/// quinn 的 open_bi/accept_bi 与 open_uni/accept_uni 是两个完全独立的内部
/// 队列，给通知单开一条 uni 流之后，这里只需要一次 accept_uni()（服务端在
/// HELLO/RESUME 成功后就会主动开好这条流，见 connection.rs 的
/// `handle()`），后续在同一条流上持续读，不用碰前面提到的任何一处
/// accept_bi() 调用点或它们的时序假设。
///
/// 旧服务端永远不会调用 open_uni()：这里的 accept_uni() 会一直挂起，直到
/// 连接关闭才返回 Err——不影响 PTY/控制流的其余功能，只是白占一个任务。
async fn notify_accept_loop(
    conn: quinn::Connection,
    evt_tx: tokio::sync::mpsc::UnboundedSender<AqtEvent>,
) {
    let mut rx = match conn.accept_uni().await {
        Ok(rx) => rx,
        Err(e) => {
            tracing::info!("notify uni stream never opened by peer (old server?): {e:?}");
            return;
        }
    };
    // Persistent buffer across the whole life of the stream — see
    // `FrameReader`'s doc comment for why `read_frame_from` (fresh local
    // buffer per call) is unsafe to use on a stream read in a loop.
    let mut reader = FrameReader::new();
    loop {
        match reader
            .read_frames::<aqt_protocol::frame::Notify>(&mut rx)
            .await
        {
            Ok(notifies) => {
                for notify in notifies {
                    let _ = evt_tx.send(AqtEvent {
                        kind: AqtEventKind::Notify,
                        tab_id: notify.tab_id.unwrap_or(0),
                        data: encode_notify_payload(&notify),
                        preloaded_bytes: 0,
                    });
                }
            }
            Err(e) => {
                tracing::info!("notify uni stream ended: {e:#}");
                return;
            }
        }
    }
}

/// Pack a `Notify` frame into the self-describing byte layout carried in
/// `AqtEvent.data` (see that field's doc comment in handle.rs):
///
/// ```text
/// [0..8)   event_id     u64 LE
/// [8..16)  ts_unix_ms   u64 LE
/// [16..24) tab_id       i64 LE  — widened from Option<u32>; -1 means None.
///                                 (u64::MAX → -1 signedness precedent: see
///                                 aqt_get_last_recv_age_ms /
///                                 kNeverReceivedAgeMs on the Dart side. -1
///                                 cannot collide with any real u32 tab_id
///                                 once widened to i64, same reasoning.)
/// [24..)   text         UTF-8, unprefixed — data_len (from aqt_poll_event)
///                                 already tells the reader where it ends.
/// ```
fn encode_notify_payload(n: &aqt_protocol::frame::Notify) -> Vec<u8> {
    let mut buf = Vec::with_capacity(24 + n.text.len());
    buf.extend_from_slice(&n.event_id.to_le_bytes());
    buf.extend_from_slice(&n.ts_unix_ms.to_le_bytes());
    let tab_id: i64 = n.tab_id.map(|t| t as i64).unwrap_or(-1);
    buf.extend_from_slice(&tab_id.to_le_bytes());
    buf.extend_from_slice(n.text.as_bytes());
    buf
}

// ──────────────────────────────────────────────
// FFI: aqt_connect
// ──────────────────────────────────────────────

/// Connect to server asynchronously. Returns 0 on success; fills *out_handle.
/// Status arrives via aqt_poll_event (kind=0=Connected or kind=2=Failed).
///
/// # Safety
/// All pointers must be valid for the duration of this call. Content is copied.
#[no_mangle]
pub unsafe extern "C" fn aqt_connect(
    params: *const AqtConnectParams,
    out_handle: *mut *mut c_void,
) -> c_int {
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| -> i32 {
        if params.is_null() || out_handle.is_null() {
            return AqtError::InvalidArg.as_i32();
        }
        let p = &*params;
        let host = match CStr::from_ptr(p.host).to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => return AqtError::InvalidArg.as_i32(),
        };
        let sni = match CStr::from_ptr(p.sni).to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => return AqtError::InvalidArg.as_i32(),
        };
        let spki = std::slice::from_raw_parts(p.spki_ptr, p.spki_len).to_vec();
        let token_slice = std::slice::from_raw_parts(p.token_ptr, 32);
        let mut token = [0u8; 32];
        token.copy_from_slice(token_slice);

        let addr: SocketAddr = match format!("{host}:{}", p.port).parse() {
            Ok(a) => a,
            Err(_) => return AqtError::InvalidArg.as_i32(),
        };

        let (handle, _evt_tx) = SessionHandle::new();
        // raw holds refcount=1; this is the Dart-side "ownership" ref.
        let raw = Arc::into_raw(handle) as *mut c_void;
        let handle_ptr = raw as usize;

        // Increment refcount for the async task (refcount becomes 2).
        Arc::increment_strong_count(raw as *const SessionHandle);

        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                // This Arc owns the incremented refcount; drops at end of scope.
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                match make_client_endpoint(spki) {
                    Err(e) => {
                        tracing::warn!("make_endpoint: {e:#}");
                        let _ = h.event_tx.send(AqtEvent {
                            kind: AqtEventKind::Failed,
                            tab_id: 0,
                            data: e.to_string().into_bytes(),
                            preloaded_bytes: 0,
                        });
                        *h.conn_state.lock().await = ConnState::Failed;
                        // h drops here, decrementing refcount back to 1
                    }
                    Ok(ep) => match connect(&ep, addr, &sni).await {
                        Err(e) => {
                            tracing::warn!("connect: {e:#}");
                            *h.conn_state.lock().await = ConnState::Failed;
                            let _ = h.event_tx.send(AqtEvent {
                                kind: AqtEventKind::Failed,
                                tab_id: 0,
                                data: e.to_string().into_bytes(),
                                preloaded_bytes: 0,
                            });
                            // h drops here, decrementing refcount back to 1
                        }
                        Ok(conn) => {
                            // Store endpoint + connection. Endpoint must
                            // outlive any aqt_rebind() call (migration).
                            *h.endpoint.write().await = Some(ep.clone());
                            *h.conn.write().await = Some(conn.clone());
                            *h.conn_state.lock().await = ConnState::Connected;

                            // C1: 1Hz recv_bytes poll. quinn updates conn.stats().udp_rx.bytes
                            // on every inbound UDP datagram — ACKs, datagrams, PATH_RESPONSE,
                            // PtyOutput. The poll task bumps SessionHandle.last_recv_at_ms
                            // whenever udp_rx.bytes increases since the last sample. This is the
                            // data source for the Dart foreground watchdog.
                            {
                                let h_poll = h.clone();
                                tokio::spawn(async move {
                                    let mut last_recv: u64 = 0;
                                    let mut tick = tokio::time::interval(
                                        std::time::Duration::from_millis(1000),
                                    );
                                    tick.set_missed_tick_behavior(
                                        tokio::time::MissedTickBehavior::Skip,
                                    );
                                    // Drop the first immediate-fire tick — give the connection a
                                    // tick worth of time to observe its first ACK.
                                    tick.tick().await;
                                    loop {
                                        tick.tick().await;
                                        let conn_guard = h_poll.conn.read().await;
                                        let Some(conn_ref) = conn_guard.as_ref() else {
                                            break;
                                        };
                                        // Exit cleanly once quinn has closed the connection — otherwise
                                        // the task spins forever, leaks the SessionHandle Arc, and
                                        // accumulates one zombie task per reconnect.
                                        if conn_ref.close_reason().is_some() {
                                            break;
                                        }
                                        let recv = conn_ref.stats().udp_rx.bytes;
                                        if recv != last_recv {
                                            let now_ms = crate::handle::monotonic_ms();
                                            // Clamp to ≥ 1 — sentinel 0 means "never received".
                                            h_poll.last_recv_at_ms.store(
                                                now_ms.max(1),
                                                std::sync::atomic::Ordering::Relaxed,
                                            );
                                            last_recv = recv;
                                        }
                                        drop(conn_guard);
                                    }
                                });
                            }

                            // Run HELLO handshake
                            match do_hello_handshake(&h, conn).await {
                                Ok(()) => {
                                    let _ = h.event_tx.send(AqtEvent {
                                        kind: AqtEventKind::Connected,
                                        tab_id: 0,
                                        data: vec![],
                                        preloaded_bytes: 0,
                                    });
                                    // Monitor connection: send Disconnected when QUIC path dies.
                                    // Fires within 2-4 s (2s keepalive) after network switch —
                                    // much faster than the previous 10s idle timeout.
                                    if let Some(conn) = h.conn.read().await.clone() {
                                        let evt_tx = h.event_tx.clone();
                                        tokio::spawn(async move {
                                            let _ = conn.closed().await;
                                            let _ = evt_tx.send(AqtEvent {
                                                kind: AqtEventKind::Disconnected,
                                                tab_id: 0,
                                                data: vec![],
                                                preloaded_bytes: 0,
                                            });
                                        });
                                    }
                                    // Route B: persistent Notify dispatch loop on its own
                                    // dedicated uni stream (see notify_accept_loop's doc
                                    // comment for why this is independent of the control
                                    // stream / existing accept_bi() call sites).
                                    if let Some(conn) = h.conn.read().await.clone() {
                                        let evt_tx = h.event_tx.clone();
                                        tokio::spawn(notify_accept_loop(conn, evt_tx));
                                    }
                                }
                                Err(e) => {
                                    tracing::warn!("HELLO handshake failed: {e:#}");
                                    *h.conn_state.lock().await = ConnState::Failed;
                                    let _ = h.event_tx.send(AqtEvent {
                                        kind: AqtEventKind::Failed,
                                        tab_id: 0,
                                        data: e.to_string().into_bytes(),
                                        preloaded_bytes: 0,
                                    });
                                }
                            }
                            // h drops here, decrementing refcount back to 1
                        }
                    },
                }
            });
        });

        *out_handle = raw;
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: aqt_close
// ──────────────────────────────────────────────

/// Close and free the session handle.
///
/// # Safety
/// handle must be a valid pointer returned by aqt_connect, called exactly once.
#[no_mangle]
pub unsafe extern "C" fn aqt_close(handle: *mut c_void) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        // Reconstitute Arc and drop it (refcount was 1 from Dart side)
        let _ = Arc::from_raw(handle as *const SessionHandle);
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: aqt_poll_event
// ──────────────────────────────────────────────

/// Poll for the next event. Returns 0 if event available; -1 if no event.
/// event_kind: 0=Connected, 1=Disconnected, 2=Failed, 3=PtyOutput, 4=TabOpened, 5=TabClosed
/// data_ptr / data_len: caller-allocated buffer; filled if available.
/// tab_id_out: tab id for per-tab events.
///
/// # Safety
/// handle must be valid. data_ptr must point to a buffer of at least data_cap bytes.
#[no_mangle]
pub unsafe extern "C" fn aqt_poll_event(
    handle: *mut c_void,
    event_kind_out: *mut u8,
    tab_id_out: *mut u32,
    data_ptr: *mut u8,
    data_cap: usize,
    data_len_out: *mut usize,
) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        let mut rx = match h.event_rx.try_lock() {
            Ok(g) => g,
            Err(_) => return -1, // lock contention — no event available
        };
        match rx.try_recv() {
            Ok(evt) => {
                *event_kind_out = evt.kind as u8;
                *tab_id_out = evt.tab_id;
                let copy_len = evt.data.len().min(data_cap);
                if copy_len > 0 {
                    std::ptr::copy_nonoverlapping(evt.data.as_ptr(), data_ptr, copy_len);
                }
                *data_len_out = copy_len;
                0
            }
            Err(_) => -1, // no event available
        }
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: aqt_state
// ──────────────────────────────────────────────

/// Get current connection state.
/// 0=Connecting, 1=Connected, 2=Reconnecting, 3=Closed, 4=Failed
#[no_mangle]
pub unsafe extern "C" fn aqt_state(handle: *const c_void) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        // blocking_lock is OK — state updates are fast and non-contended
        let state = h.conn_state.blocking_lock();
        *state as i32
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: aqt_open_tab
// ──────────────────────────────────────────────

/// Open a new PTY tab. Sends OPEN_TAB on the control stream; server replies
/// with OPEN_TAB_ACK and opens a bidi PTY stream. Result arrives via
/// aqt_poll_event (kind=4=TabOpened or kind=2=Failed).
///
/// # Safety
/// handle must be valid. term may be null (defaults to "xterm-256color").
#[no_mangle]
pub unsafe extern "C" fn aqt_open_tab(
    handle: *mut c_void,
    cols: u16,
    rows: u16,
    term: *const c_char,
) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let term_str = if term.is_null() {
            "xterm-256color".to_string()
        } else {
            match CStr::from_ptr(term).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => "xterm-256color".to_string(),
            }
        };

        // Borrow the handle without taking Arc ownership (handle stays alive
        // as long as Dart holds it; the async task borrows via raw ptr).
        let handle_ptr = handle as usize;
        // Increment refcount so the async task can hold the Arc safely.
        Arc::increment_strong_count(handle as *const SessionHandle);

        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                // This Arc owns the incremented refcount.
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                if let Err(e) = do_open_tab(&h, cols, rows, &term_str).await {
                    tracing::warn!("open_tab failed: {e:#}");
                    let _ = h.event_tx.send(AqtEvent {
                        kind: AqtEventKind::Failed,
                        tab_id: 0,
                        data: e.to_string().into_bytes(),
                        preloaded_bytes: 0,
                    });
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

/// Internal: send OPEN_TAB, receive OPEN_TAB_ACK, accept PTY bidi stream,
/// wire input channel and output reader task.
async fn do_open_tab(
    h: &Arc<SessionHandle>,
    cols: u16,
    rows: u16,
    term: &str,
) -> anyhow::Result<()> {
    // ── 1. Send OPEN_TAB on control stream ──────────────────────────────
    let open = OpenTab {
        cols,
        rows,
        term: term.to_string(),
        cwd: String::new(),
        cmd: String::new(),
        preload_history: None,
    };
    let mut frame_buf = BytesMut::new();
    encode_frame(&open, &mut frame_buf).map_err(|e| anyhow::anyhow!("encode OPEN_TAB: {e:?}"))?;
    {
        let mut ctrl = h.ctrl_tx.lock().await;
        let tx = ctrl
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("ctrl_tx not ready"))?;
        tx.write_all(&frame_buf).await?;
    }

    // ── 2. Read OPEN_TAB_ACK from control stream ─────────────────────────
    let ack: OpenTabAck = {
        let mut ctrl = h.ctrl_rx.lock().await;
        let rx = ctrl
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("ctrl_rx not ready"))?;
        read_frame_from(rx).await?
    };
    if !matches!(ack.status, OpenTabStatus::Ok) {
        return Err(anyhow::anyhow!("OPEN_TAB_ACK status: {:?}", ack.status));
    }
    let tab_id = ack.tab_id;

    // ── 3. Accept server-initiated PTY bidi stream ───────────────────────
    let conn_guard = h.conn.read().await;
    let conn = conn_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("not connected"))?;
    let (mut pty_send, pty_recv) = conn.accept_bi().await?;
    drop(conn_guard);

    // ── 4. Wire client → PTY send channel ────────────────────────────────
    let (pty_tx, mut pty_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    h.tabs.write().await.insert(tab_id, TabHandle { pty_tx });

    // Forwarder: client input mpsc → QUIC PTY send stream
    tokio::spawn(async move {
        while let Some(data) = pty_rx.recv().await {
            if pty_send.write_all(&data).await.is_err() {
                break;
            }
        }
    });

    // ── 5. Reader: QUIC PTY recv stream → events (zstd-decoded if negotiated)
    let evt_tx = h.event_tx.clone();
    let compression = *h.compression_enabled.lock().await;
    spawn_pty_reader(pty_recv, evt_tx, tab_id, compression);

    // ── 6. Notify caller ──────────────────────────────────────────────────
    let _ = h.event_tx.send(AqtEvent {
        kind: AqtEventKind::TabOpened,
        tab_id,
        data: vec![],
        preloaded_bytes: 0,
    });
    Ok(())
}

// ──────────────────────────────────────────────
// FFI: aqt_open_tab_v2  (with optional history preload)
// ──────────────────────────────────────────────

/// Open a new PTY tab with optional history preload.
/// Sends OPEN_TAB (with preload_history set) on the control stream.
/// Result arrives via aqt_poll_event:
///   - kind=4=TabOpened on success
///   - kind=6=HistoryPreloadDone when history bytes are fully written (only
///     emitted if preload_kind != 0)
///   - kind=2=Failed on error
///
/// preload_kind:
///   0 = no preload (same as aqt_open_tab)
///   1 = LatestMatching { cmd: preload_cmd }
///   2 = Explicit { history_id: preload_history_id }
///
/// # Safety
/// handle must be valid. term/cmd/preload_cmd may be null.
/// preload_cmd is only read when preload_kind == 1.
#[no_mangle]
pub unsafe extern "C" fn aqt_open_tab_v2(
    handle: *mut c_void,
    cols: u16,
    rows: u16,
    term: *const c_char,
    cmd: *const c_char,
    preload_kind: u8,
    preload_cmd: *const c_char,
    preload_history_id: u64,
    _out_tab_id: *mut u32,
) -> i32 {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let term_str = if term.is_null() {
            "xterm-256color".to_string()
        } else {
            match CStr::from_ptr(term).to_str() {
                Ok(s) => s.to_string(),
                Err(_) => "xterm-256color".to_string(),
            }
        };
        let cmd_str = if cmd.is_null() {
            String::new()
        } else {
            CStr::from_ptr(cmd).to_string_lossy().into_owned()
        };
        let preload_history: Option<PreloadHistorySpec> = match preload_kind {
            0 => None,
            1 => {
                let pc = if preload_cmd.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr(preload_cmd).to_string_lossy().into_owned()
                };
                Some(PreloadHistorySpec::LatestMatching { cmd: pc })
            }
            2 => Some(PreloadHistorySpec::Explicit {
                history_id: preload_history_id,
            }),
            _ => None,
        };

        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);

        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                if let Err(e) =
                    do_open_tab_v2(&h, cols, rows, &term_str, &cmd_str, preload_history).await
                {
                    tracing::warn!("open_tab_v2 failed: {e:#}");
                    let _ = h.event_tx.send(AqtEvent {
                        kind: AqtEventKind::Failed,
                        tab_id: 0,
                        data: e.to_string().into_bytes(),
                        preloaded_bytes: 0,
                    });
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

/// Internal: send OPEN_TAB (with optional preload_history), receive OPEN_TAB_ACK,
/// accept PTY bidi stream, wire I/O channels, and (when preload requested) start
/// a control-reader task that waits for the HistoryPreloadDone frame.
async fn do_open_tab_v2(
    h: &Arc<SessionHandle>,
    cols: u16,
    rows: u16,
    term: &str,
    cmd: &str,
    preload_history: Option<PreloadHistorySpec>,
) -> anyhow::Result<()> {
    let has_preload = preload_history.is_some();

    // ── 1. Send OPEN_TAB on control stream ──────────────────────────────
    let open = OpenTab {
        cols,
        rows,
        term: term.to_string(),
        cwd: String::new(),
        cmd: cmd.to_string(),
        preload_history,
    };
    let mut frame_buf = BytesMut::new();
    encode_frame(&open, &mut frame_buf).map_err(|e| anyhow::anyhow!("encode OPEN_TAB: {e:?}"))?;
    {
        let mut ctrl = h.ctrl_tx.lock().await;
        let tx = ctrl
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("ctrl_tx not ready"))?;
        tx.write_all(&frame_buf).await?;
    }

    // ── 2. Read OPEN_TAB_ACK from control stream ─────────────────────────
    let ack: OpenTabAck = {
        let mut ctrl = h.ctrl_rx.lock().await;
        let rx = ctrl
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("ctrl_rx not ready"))?;
        read_frame_from(rx).await?
    };
    if !matches!(ack.status, OpenTabStatus::Ok) {
        return Err(anyhow::anyhow!("OPEN_TAB_ACK status: {:?}", ack.status));
    }
    let tab_id = ack.tab_id;

    // ── 3. Accept server-initiated PTY bidi stream ───────────────────────
    let conn_guard = h.conn.read().await;
    let conn = conn_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("not connected"))?;
    let (mut pty_send, pty_recv) = conn.accept_bi().await?;
    drop(conn_guard);

    // ── 4. Wire client → PTY send channel ────────────────────────────────
    let (pty_tx, mut pty_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    h.tabs.write().await.insert(tab_id, TabHandle { pty_tx });

    tokio::spawn(async move {
        while let Some(data) = pty_rx.recv().await {
            if pty_send.write_all(&data).await.is_err() {
                break;
            }
        }
    });

    // ── 5. Reader: QUIC PTY recv stream → events (zstd-decoded if negotiated)
    let evt_tx = h.event_tx.clone();
    let compression = *h.compression_enabled.lock().await;
    spawn_pty_reader(pty_recv, evt_tx, tab_id, compression);

    // ── 6. Notify caller ──────────────────────────────────────────────────
    let _ = h.event_tx.send(AqtEvent {
        kind: AqtEventKind::TabOpened,
        tab_id,
        data: vec![],
        preloaded_bytes: 0,
    });

    // ── 7. If preload was requested, spawn a control-reader task that waits
    //       for the HistoryPreloadDone frame and surfaces it as an event.
    if has_preload {
        let evt_tx2 = h.event_tx.clone();
        let ctrl_rx_arc = Arc::clone(&h.ctrl_rx);
        tokio::spawn(async move {
            let done: HistoryPreloadDone = {
                let mut ctrl = ctrl_rx_arc.lock().await;
                match ctrl.as_mut() {
                    Some(rx) => match read_frame_from::<HistoryPreloadDone>(rx).await {
                        Ok(d) => d,
                        Err(e) => {
                            tracing::warn!("reading HistoryPreloadDone failed: {e:#}");
                            return;
                        }
                    },
                    None => {
                        tracing::warn!("ctrl_rx gone when waiting for HistoryPreloadDone");
                        return;
                    }
                }
            };
            // Encode preloaded_bytes as 8 LE bytes in data so Dart can read
            // it through the existing aqt_poll_event data buffer (no ABI change needed).
            let _ = evt_tx2.send(AqtEvent {
                kind: AqtEventKind::HistoryPreloadDone,
                tab_id: done.tab_id,
                data: done.preloaded_bytes.to_le_bytes().to_vec(),
                preloaded_bytes: done.preloaded_bytes,
            });
        });
    }

    Ok(())
}

// ──────────────────────────────────────────────
// FFI: aqt_write_pty
// ──────────────────────────────────────────────

/// Write PTY input bytes to the specified tab.
///
/// # Safety
/// handle must be valid. data_ptr must point to data_len readable bytes.
#[no_mangle]
pub unsafe extern "C" fn aqt_write_pty(
    handle: *mut c_void,
    tab_id: u32,
    data_ptr: *const u8,
    data_len: usize,
) -> c_int {
    if handle.is_null() || data_ptr.is_null() || data_len == 0 {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let data = std::slice::from_raw_parts(data_ptr, data_len).to_vec();

        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);

        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                let tabs = h.tabs.read().await;
                if let Some(tab) = tabs.get(&tab_id) {
                    let _ = tab.pty_tx.send(data).await;
                } else {
                    tracing::warn!("aqt_write_pty: unknown tab_id={tab_id}");
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: aqt_resize_tab
// ──────────────────────────────────────────────

/// Send a RESIZE frame for the specified tab.
///
/// # Safety
/// handle must be valid.
#[no_mangle]
pub unsafe extern "C" fn aqt_resize_tab(
    handle: *mut c_void,
    tab_id: u32,
    cols: u16,
    rows: u16,
) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);

        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                let resize = Resize { tab_id, cols, rows };
                let mut buf = BytesMut::new();
                match encode_frame(&resize, &mut buf) {
                    Ok(()) => {
                        let mut ctrl = h.ctrl_tx.lock().await;
                        if let Some(tx) = ctrl.as_mut() {
                            if let Err(e) = tx.write_all(&buf).await {
                                tracing::warn!("aqt_resize_tab write: {e:#}");
                            }
                        } else {
                            tracing::warn!("aqt_resize_tab: ctrl_tx not ready");
                        }
                    }
                    Err(e) => {
                        tracing::warn!("aqt_resize_tab encode: {e:?}");
                    }
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: aqt_notify_ack
// ──────────────────────────────────────────────

/// Acknowledge notifications up to and including `last_event_id`. Writes a
/// NotifyAck frame on the CONTROL stream (not the Notify uni stream — Route B
/// only made the server→client push direction independent; the client→server
/// ack keeps riding the existing control bi-stream, same as Resize/Signal/
/// CloseTab, because control_loop's `Opcode::NotifyAck` arm already reads
/// from there and there is no reason to open a second stream for a single
/// small, infrequent frame).
///
/// # Safety
/// handle must be valid.
#[no_mangle]
pub unsafe extern "C" fn aqt_notify_ack(handle: *mut c_void, last_event_id: u64) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);

        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                let ack = NotifyAck { last_event_id };
                let mut buf = BytesMut::new();
                match encode_frame(&ack, &mut buf) {
                    Ok(()) => {
                        let mut ctrl = h.ctrl_tx.lock().await;
                        if let Some(tx) = ctrl.as_mut() {
                            if let Err(e) = tx.write_all(&buf).await {
                                tracing::warn!("aqt_notify_ack write: {e:#}");
                            }
                        } else {
                            tracing::warn!("aqt_notify_ack: ctrl_tx not ready");
                        }
                    }
                    Err(e) => {
                        tracing::warn!("aqt_notify_ack encode: {e:?}");
                    }
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: misc stubs
// ──────────────────────────────────────────────

/// Send a 1-byte QUIC datagram as a liveness probe.
///
/// Why datagram instead of a stream:
///   - Fire-and-forget: no waiting for ACK or stream credits.
///   - If `send_datagram` returns ConnectionError, the QUIC connection is
///     definitively dead (path was stuck without quinn detecting it via the
///     normal idle-timeout path, e.g. after NAT rebind or `sendmsg EMSGSIZE`).
///   - On failure we explicitly close the connection so `conn.closed()` fires
///     and Dart receives a `Disconnected` event, triggering RESUME / reconnect.
///
/// Both sides must enable datagram support (datagram_receive_buffer_size > 0).
#[no_mangle]
pub unsafe extern "C" fn aqt_heartbeat(handle: *mut c_void) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);
        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                let conn = h.conn.read().await.clone();
                if let Some(conn) = conn {
                    // Send a 1-byte QUIC datagram. This exercises the actual UDP
                    // send path — the same path that keepalive PINGs use.
                    let probe = bytes::Bytes::from_static(b"\x00");
                    let is_fg = h.is_foreground
                        .load(std::sync::atomic::Ordering::Relaxed);
                    if let Err(e) = conn.send_datagram(probe) {
                        // Require HB_CLOSE_THRESHOLD consecutive failures before closing.
                        // Background: NEVER close — Doze/sleep blocks network at OS
                        // level; closing would force a useless RESUME + replay cycle
                        // the user can't see. Foreground transition's immediate
                        // probe (kImmediateForegroundProbe) handles real recovery.
                        const HB_CLOSE_THRESHOLD: u32 = 3;
                        let prev = h.hb_consecutive_failures
                            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        if is_fg && prev + 1 >= HB_CLOSE_THRESHOLD {
                            tracing::warn!(
                                "heartbeat probe failed {} consecutive times (foreground): {e} — closing",
                                prev + 1
                            );
                            h.hb_consecutive_failures
                                .store(0, std::sync::atomic::Ordering::Relaxed);
                            conn.close(quinn::VarInt::from_u32(0), b"heartbeat-failed");
                        } else {
                            tracing::debug!(
                                "heartbeat probe failed (attempt {}/{}, fg={}): {e}",
                                prev + 1, HB_CLOSE_THRESHOLD, is_fg
                            );
                        }
                    } else {
                        // Reset consecutive failure counter on any success.
                        h.hb_consecutive_failures
                            .store(0, std::sync::atomic::Ordering::Relaxed);
                    }
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or(AqtError::Panic.as_i32())
}

/// Hint that the network path has changed (WiFi ↔ 4G etc.).
///
/// Sends a 1-byte datagram to stimulate quinn into sending a packet from
/// the current network interface, which lets the server observe the new
/// source address and initiate a PATH_CHALLENGE/PATH_RESPONSE exchange
/// (RFC 9000 §9 Connection Migration).
///
/// Key difference from aqt_heartbeat:
///   - Send failure is NOT treated as a dead connection — during a network
///     switch the old path is momentarily down (expected), and the new path
///     may not be validated yet.  Closing here would prevent transparent
///     QUIC migration and force an unnecessary RESUME.
///   - The periodic aqt_heartbeat (every 5 s) acts as the fallback: if the
///     migration fails and the connection is truly dead, heartbeat will
///     detect it and trigger RESUME.
#[no_mangle]
pub unsafe extern "C" fn aqt_roam(handle: *mut c_void) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);
        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                let conn = h.conn.read().await.clone();
                if let Some(conn) = conn {
                    // Fire-and-forget: stimulate traffic on the new path.
                    // Failure is ignored — the connection may be mid-migration.
                    let _ = conn.send_datagram(bytes::Bytes::from_static(b"\x00"));
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or(AqtError::Panic.as_i32())
}

/// True RFC 9000 §9 connection migration: rebind the Quinn endpoint to a
/// fresh UDP socket on the current default route. The QUIC connection
/// keeps its connection ID; outgoing packets now leave from the new socket
/// (possibly a different network interface, e.g. cellular instead of Wi-Fi).
/// On the server side, the receive address changes, which triggers
/// PATH_CHALLENGE / PATH_RESPONSE validation and migration of the
/// connection state to the new four-tuple.
///
/// **MUST only be called when the network interface has positively
/// changed.** Calling from periodic stale-probe loops produced packet
/// reordering between PATH_CHALLENGE retransmissions and live streams
/// (xterm parser drifted out of sync, mouse events leaked to bash —
/// see a9.jpg and the commit that introduced this guardrail).
///
/// Returns:
///   0   — success (rebound; server-side validation happens async)
///   <0  — error (socket alloc / no active endpoint / etc.)
#[no_mangle]
pub unsafe extern "C" fn aqt_rebind(handle: *mut c_void) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);
        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                let ep_opt = h.endpoint.read().await.clone();
                let Some(ep) = ep_opt else {
                    tracing::warn!("aqt_rebind: no endpoint stored — skipping");
                    return;
                };
                // Bind a fresh UDP socket on the OS's current default route.
                // "0.0.0.0:0" lets the kernel pick interface + ephemeral port.
                let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::warn!("aqt_rebind: socket bind failed: {e}");
                        return;
                    }
                };
                if let Err(e) = socket.set_nonblocking(true) {
                    tracing::warn!("aqt_rebind: set_nonblocking failed: {e}");
                    return;
                }
                if let Err(e) = ep.rebind(socket) {
                    tracing::warn!("aqt_rebind: endpoint.rebind failed: {e}");
                    return;
                }
                tracing::info!("aqt_rebind: endpoint rebound to fresh socket");
                // Wake the new path: send a probe datagram so the server
                // observes the new four-tuple and emits PATH_CHALLENGE.
                let conn_opt = h.conn.read().await.clone();
                if let Some(conn) = conn_opt {
                    let _ = conn.send_datagram(bytes::Bytes::from_static(b"\x00"));
                }
            });
        });
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or(AqtError::Panic.as_i32())
}

/// Update foreground/background state.
///
/// In foreground: heartbeat failures (3 consecutive) close the connection
/// to trigger fast RESUME recovery.
/// In background: heartbeat failures are logged but do NOT close the
/// connection — Doze/sleep mode blocks network I/O at the OS level, and a
/// closed-and-reconnected QUIC connection in background just wastes a full
/// RESUME + scrollback-replay cycle the user can't see. The Dart-side
/// kImmediateForegroundProbe re-tests the path the moment user returns.
#[no_mangle]
pub unsafe extern "C" fn aqt_set_foreground(handle: *mut c_void, active: u8) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let handle_ptr = handle as usize;
        Arc::increment_strong_count(handle as *const SessionHandle);
        let h = Arc::from_raw(handle_ptr as *const SessionHandle);
        h.is_foreground
            .store(active != 0, std::sync::atomic::Ordering::Relaxed);
        // On foreground transition, reset the consecutive-failure counter so
        // a single foreground probe failure doesn't immediately close.
        if active != 0 {
            h.hb_consecutive_failures
                .store(0, std::sync::atomic::Ordering::Relaxed);
        }
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or(AqtError::Panic.as_i32())
}

/// Start a file upload. Returns request_id (> 0) on success, or negative error code.
#[no_mangle]
pub unsafe extern "C" fn aqt_file_upload_start(
    handle: *mut c_void,
    local_path: *const c_char,
    remote_path: *const c_char,
    size: u64,
    perms: u32,
    sha256_ptr: *const u8,
) -> i32 {
    if handle.is_null() || local_path.is_null() || remote_path.is_null() || sha256_ptr.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let _ = size;
        let _ = perms;
        // MVP stub: returns a fixed request_id
        1i32
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

/// Start a file download.
#[no_mangle]
pub unsafe extern "C" fn aqt_file_download_start(
    handle: *mut c_void,
    remote_path: *const c_char,
    local_path: *const c_char,
    resume_offset: u64,
) -> i32 {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let _ = remote_path;
    let _ = local_path;
    let _ = resume_offset;
    1i32
}

/// Cancel a file transfer.
#[no_mangle]
pub unsafe extern "C" fn aqt_file_cancel(handle: *mut c_void, request_id: u32) -> c_int {
    if handle.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let _ = request_id;
    AqtError::Ok.as_i32()
}

// ──────────────────────────────────────────────
// FFI: aqt_get_session_token
// ──────────────────────────────────────────────

/// Returns the 32-byte session token from the last successful HELLO_ACK.
/// Fills token_out (caller-allocated, must be 32 bytes).
/// Returns 0 on success, AqtError::NotConnected if no token yet.
///
/// # Safety
/// handle must be valid. token_out must point to 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn aqt_get_session_token(handle: *const c_void, token_out: *mut u8) -> c_int {
    if handle.is_null() || token_out.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        let token = h.session_token.blocking_lock();
        match *token {
            Some(t) => {
                std::ptr::copy_nonoverlapping(t.as_ptr(), token_out, 32);
                AqtError::Ok.as_i32()
            }
            None => AqtError::NotConnected.as_i32(),
        }
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

// ──────────────────────────────────────────────
// FFI: RESUME 处置查询
// ──────────────────────────────────────────────
//
// 这里曾经是 aqt_get_last_resume_server_out_off / _replay_bytes 两个 getter，
// 存在的唯一目的是让 Dart 侧算 `server_out_off - replay_bytes` 去反推「服务端
// 是续传还是重建」。删掉它们，让「诱使客户端重建那个推断」在 API 层面不可能。
//
// 现在服务端直接声明处置，这几个 getter 只是把它读出来。

pub const DISPOSITION_NONE: i32 = 0;
pub const DISPOSITION_RESTORED: i32 = 1;
pub const DISPOSITION_NEW_SESSION: i32 = 2;
pub const DISPOSITION_TAB_GONE: i32 = 3;

/// 最近一次 RESUME 的处置码，见 `DISPOSITION_*`。没有记录时返回 0。
///
/// # Safety
/// handle 必须有效。
#[no_mangle]
pub unsafe extern "C" fn aqt_get_resume_disposition(handle: *const c_void) -> i32 {
    if handle.is_null() {
        return DISPOSITION_NONE;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        // blocking_lock 与其它同步 getter 一致：FFI 调用来自 Dart 线程，
        // 不在 tokio 上下文里；这个锁只在 RESUME 落地时被写一次，无竞争。
        let guard = h.last_resume_disposition.blocking_lock();
        match guard.as_ref() {
            Some(aqt_protocol::Disposition::Restored { .. }) => DISPOSITION_RESTORED,
            Some(aqt_protocol::Disposition::NewSession) => DISPOSITION_NEW_SESSION,
            Some(aqt_protocol::Disposition::TabGone { .. }) => DISPOSITION_TAB_GONE,
            None => DISPOSITION_NONE,
        }
    }));
    result.unwrap_or(DISPOSITION_NONE)
}

/// 服务端在最近一次 RESUME_ACK 里下发的 session TTL（秒）。0 = 还没拿到，
/// 调用方该用自己的兜底值。
///
/// 让服务端下发而不是两侧各写一个常量 —— 后者正是「服务端 7 天 vs 客户端
/// 110 分钟」那个 bug 的根源。
///
/// # Safety
/// handle 必须有效。
#[no_mangle]
pub unsafe extern "C" fn aqt_get_resume_ttl_secs(handle: *const c_void) -> u64 {
    if handle.is_null() {
        return 0;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        h.last_resume_ttl_secs
            .load(std::sync::atomic::Ordering::Relaxed)
    }));
    result.unwrap_or(0)
}

/// 服务端在最近一次 RESUME_ACK 里下发的快照字节数。0 = 没拿到
/// （旧服务端、非 Restored 处置，或还没 RESUME 过）。
///
/// **只喂诊断。** 客户端用它判断「快照流完了没有」以打上 replayComplete
/// 时间戳，不做任何数据分派 —— 见 aqt_protocol 里该字段的文档。
///
/// # Safety
/// handle 必须有效。
#[no_mangle]
pub unsafe extern "C" fn aqt_get_resume_prelude_len(handle: *const c_void) -> u64 {
    if handle.is_null() {
        return 0;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        h.last_resume_prelude_len
            .load(std::sync::atomic::Ordering::Relaxed)
    }));
    result.unwrap_or(0)
}

/// `Restored.server_in_seen_off` —— 服务端已收到的输入字节数，客户端据此
/// 从重放缓冲补发断线瞬间没送达的按键。非 Restored 时返回 0。
///
/// # Safety
/// handle 必须有效。
#[no_mangle]
pub unsafe extern "C" fn aqt_get_resume_in_seen_off(handle: *const c_void) -> u64 {
    if handle.is_null() {
        return 0;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        // blocking_lock 与其它同步 getter 一致：FFI 调用来自 Dart 线程，
        // 不在 tokio 上下文里；这个锁只在 RESUME 落地时被写一次，无竞争。
        let guard = h.last_resume_disposition.blocking_lock();
        match guard.as_ref() {
            Some(aqt_protocol::Disposition::Restored {
                server_in_seen_off, ..
            }) => *server_in_seen_off,
            _ => 0,
        }
    }));
    result.unwrap_or(0)
}

/// `TabGone.exit_status`。`has_status` 写 1 表示有退出码，0 表示没有。
///
/// # Safety
/// handle 必须有效；has_status 若非空必须可写。
#[no_mangle]
pub unsafe extern "C" fn aqt_get_resume_exit_status(
    handle: *const c_void,
    has_status: *mut u8,
) -> i32 {
    if !has_status.is_null() {
        *has_status = 0;
    }
    if handle.is_null() {
        return 0;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let h = &*(handle as *const SessionHandle);
        // blocking_lock 与其它同步 getter 一致：FFI 调用来自 Dart 线程，
        // 不在 tokio 上下文里；这个锁只在 RESUME 落地时被写一次，无竞争。
        let guard = h.last_resume_disposition.blocking_lock();
        match guard.as_ref() {
            Some(aqt_protocol::Disposition::TabGone {
                exit_status: Some(code),
            }) => (1u8, *code),
            _ => (0u8, 0),
        }
    }));
    let (has, code) = result.unwrap_or((0, 0));
    if !has_status.is_null() {
        *has_status = has;
    }
    code
}

// ──────────────────────────────────────────────
// FFI: aqt_get_path_stats  (debug overlay path stats)
// ──────────────────────────────────────────────

/// Packed C-ABI struct mirroring quinn's path-level connection stats
/// plus our own migration / rebinding counters. Dart side reads this
/// via `AqtFfi.getPathStats(handle)` and surfaces it as the `path` row
/// in the debug overlay.
///
/// Reserved 24 bytes for forward compat — new fields can be appended
/// without rebuilding the Dart binary if Dart only reads the prefix it
/// knows about. Current layout: 8+8+8+4+4+8 + 24 reserved = 64 bytes.
#[repr(C)]
pub struct AqtPathStats {
    pub rtt_us: u64, // smoothed RTT, microseconds
    pub lost_packets: u64,
    pub sent_packets: u64,
    pub migration_count: u32,
    pub rebinding_count: u32,
    pub cwnd_bytes: u64,
    pub _reserved: [u8; 24],
}

/// Fill `*out` with current path stats. Returns 0 on success, -1 if the
/// handle is null or the underlying QUIC connection is gone.
///
/// # Safety
/// `handle` must be a valid `SessionHandle` pointer (or null — handled);
/// `out` must point to writable space for `AqtPathStats`.
#[no_mangle]
pub unsafe extern "C" fn aqt_get_path_stats(
    handle: *const c_void,
    out: *mut AqtPathStats,
) -> c_int {
    if handle.is_null() || out.is_null() {
        return -1;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| -> i32 {
        let h = &*(handle as *const SessionHandle);
        // try_read is non-blocking — if a writer holds the lock (rare,
        // only during connection setup/teardown), report -1 so Dart can
        // keep its cached last-known value.
        let conn_guard = match h.conn.try_read() {
            Ok(g) => g,
            Err(_) => return -1,
        };
        let Some(conn) = conn_guard.as_ref() else {
            return -1;
        };

        // Migration detection: compare current remote_address with
        // last recorded; bump counter on mismatch. try_lock to avoid
        // blocking on the rare case where another task holds the mutex.
        let remote = conn.remote_address();
        if let Ok(mut last) = h.last_observed_addr.try_lock() {
            match *last {
                Some(prev) if prev != remote => {
                    h.migration_count
                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                _ => {}
            }
            *last = Some(remote);
        }

        let stats = conn.stats();
        let path = stats.path;
        let out_ref = &mut *out;
        out_ref.rtt_us = path.rtt.as_micros() as u64;
        out_ref.lost_packets = path.lost_packets;
        out_ref.sent_packets = path.sent_packets;
        out_ref.migration_count = h.migration_count.load(std::sync::atomic::Ordering::Relaxed);
        out_ref.rebinding_count = h.rebinding_count.load(std::sync::atomic::Ordering::Relaxed);
        out_ref.cwnd_bytes = path.cwnd;
        out_ref._reserved = [0u8; 24];
        0
    }));
    result.unwrap_or(-1)
}

// ──────────────────────────────────────────────
// FFI: aqt_get_last_recv_age_ms  (foreground watchdog)
// ──────────────────────────────────────────────

/// Returns milliseconds since the last observed inbound packet (PtyOutput,
/// ACK, datagram, PATH_RESPONSE). Returns u64::MAX when:
///   - handle is null
///   - SessionHandle has never observed inbound (sentinel 0)
///
/// Cheap: atomic load + monotonic clock read. Safe to call ~1Hz from Dart.
/// Used by the foreground watchdog to detect silent path death
/// within ~7s instead of the 15-30s quinn keep_alive cycle.
///
/// # Safety
/// `handle` must be a valid `SessionHandle` pointer (or null — handled).
#[no_mangle]
pub unsafe extern "C" fn aqt_get_last_recv_age_ms(handle: *const c_void) -> u64 {
    if handle.is_null() {
        return u64::MAX;
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| -> u64 {
        let h = &*(handle as *const SessionHandle);
        let last = h.last_recv_at_ms.load(std::sync::atomic::Ordering::Relaxed);
        if last == 0 {
            return u64::MAX;
        }
        let now = crate::handle::monotonic_ms();
        now.saturating_sub(last)
    }));
    result.unwrap_or(u64::MAX)
}

// ──────────────────────────────────────────────
// FFI: aqt_resume
// ──────────────────────────────────────────────

/// Attempt 0-RTT session resume. Creates a new handle and connects to the same
/// server endpoint, sending RESUME instead of HELLO.
/// Returns 0 on success; fills *out_handle.
/// Status arrives via aqt_poll_event (Connected+TabOpened on success, Failed on error).
///
/// # Safety
/// All pointers must be valid for the duration of this call. Content is copied.
#[no_mangle]
pub unsafe extern "C" fn aqt_resume(
    out_handle: *mut *mut c_void, // OUTPUT — new handle (not existing)
    host: *const c_char,
    port: u16,
    spki_ptr: *const u8,
    spki_len: usize,
    session_token: *const u8, // 32-byte session token from previous HELLO_ACK
    tab_id: u32,
    last_out_off: u64,
    last_in_off: u64,
    ring_tail_hash: u64, // FNV-1a of last 8 raw bytes at last_out_off; 0 = no hash
) -> c_int {
    if out_handle.is_null() || host.is_null() || spki_ptr.is_null() || session_token.is_null() {
        return AqtError::InvalidArg.as_i32();
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| -> i32 {
        let host_str = match CStr::from_ptr(host).to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => return AqtError::InvalidArg.as_i32(),
        };
        let spki = std::slice::from_raw_parts(spki_ptr, spki_len).to_vec();
        let mut token = [0u8; 32];
        token.copy_from_slice(std::slice::from_raw_parts(session_token, 32));

        let addr: std::net::SocketAddr = match format!("{host_str}:{port}").parse() {
            Ok(a) => a,
            Err(_) => return AqtError::InvalidArg.as_i32(),
        };

        // Create a FRESH handle — no HELLO handshake (that's what aqt_connect does).
        let (handle, _evt_tx) = SessionHandle::new();
        // raw holds refcount=1; this is the Dart-side "ownership" ref.
        let raw = Arc::into_raw(handle) as *mut c_void;
        let handle_ptr = raw as usize;

        // Increment refcount for the async task (refcount becomes 2).
        Arc::increment_strong_count(raw as *const SessionHandle);

        RUNTIME.dispatch(move |rt| {
            rt.spawn(async move {
                // This Arc owns the incremented refcount; drops at end of scope.
                let h = Arc::from_raw(handle_ptr as *const SessionHandle);
                match do_quic_resume(
                    &h,
                    addr,
                    spki,
                    token,
                    tab_id,
                    last_out_off,
                    last_in_off,
                    ring_tail_hash,
                )
                .await
                {
                    Ok(()) => {}
                    Err(e) => {
                        tracing::warn!("aqt_resume failed: {e:#}");
                        *h.conn_state.lock().await = ConnState::Failed;
                        let _ = h.event_tx.send(AqtEvent {
                            kind: AqtEventKind::Failed,
                            tab_id: 0,
                            data: e.to_string().into_bytes(),
                            preloaded_bytes: 0,
                        });
                    }
                }
            });
        });

        *out_handle = raw;
        AqtError::Ok.as_i32()
    }));
    result.unwrap_or_else(|_| AqtError::Panic.as_i32())
}

async fn do_quic_resume(
    h: &Arc<SessionHandle>,
    addr: std::net::SocketAddr,
    spki: Vec<u8>,
    session_token: [u8; 32],
    tab_id: u32,
    last_out_off: u64,
    last_in_off: u64,
    ring_tail_hash: u64,
) -> anyhow::Result<()> {
    let ep = make_client_endpoint(spki)?;
    // 0-RTT RESUME: send the RESUME frame in the initial packet alongside
    // TLS ClientHello. Saves 1 RTT vs awaiting full handshake first.
    // RESUME is idempotent (session_token validated server-side, replay benign).
    let (conn, zero_rtt_accepted) = crate::client::connect_0rtt(&ep, addr, "aqt").await?;
    tracing::debug!("aqt_resume: 0-RTT accepted={}", zero_rtt_accepted);

    // Store endpoint + connection. Endpoint must outlive aqt_rebind().
    *h.endpoint.write().await = Some(ep.clone());
    *h.conn.write().await = Some(conn.clone());
    *h.conn_state.lock().await = ConnState::Connected;

    // C1: 1Hz udp_rx.bytes poll (same as aqt_connect path). Bumps
    // SessionHandle.last_recv_at_ms whenever inbound UDP activity is observed,
    // giving the Dart foreground watchdog a sub-7s silent-path-death signal.
    {
        let h_poll = h.clone();
        tokio::spawn(async move {
            let mut last_recv: u64 = 0;
            let mut tick = tokio::time::interval(std::time::Duration::from_millis(1000));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            // Drop the first immediate-fire tick.
            tick.tick().await;
            loop {
                tick.tick().await;
                let conn_guard = h_poll.conn.read().await;
                let Some(conn_ref) = conn_guard.as_ref() else {
                    break;
                };
                // Exit cleanly once quinn has closed the connection — otherwise
                // the task spins forever, leaks the SessionHandle Arc, and
                // accumulates one zombie task per reconnect.
                if conn_ref.close_reason().is_some() {
                    break;
                }
                let recv = conn_ref.stats().udp_rx.bytes;
                if recv != last_recv {
                    let now_ms = crate::handle::monotonic_ms();
                    // Clamp to ≥ 1 — sentinel 0 means "never received".
                    h_poll
                        .last_recv_at_ms
                        .store(now_ms.max(1), std::sync::atomic::Ordering::Relaxed);
                    last_recv = recv;
                }
                drop(conn_guard);
            }
        });
    }

    // Open control stream — works on 0-RTT (queued) or 1-RTT (synchronous).
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;

    // Send RESUME frame with ring hash for server-side sync verification.
    // ring_tail_hash=0 means "no hash" — server uses last_out_off as-is (backwards compat).
    // RESUME 不再携带任何位置信息 —— 客户端只说「我是谁、我要哪个 tab」。
    // last_out_off / last_in_off / ring_tail_hash 三个参数在签名里还留着
    // （Dart 侧的调用点尚未清理），这里显式忽略，等 Dart 侧清理时一并去掉。
    let _ = (last_out_off, last_in_off, ring_tail_hash);
    let resume = Resume {
        session_token,
        tabs: vec![tab_id],
    };
    let mut buf = bytes::BytesMut::new();
    encode_frame(&resume, &mut buf).map_err(|e| anyhow::anyhow!("encode RESUME: {e:?}"))?;
    ctrl_tx.write_all(&buf).await?;

    // Read RESUME_ACK
    let ack: ResumeAck = read_frame_from(&mut ctrl_rx).await?;
    // Inherit compression flag from the server's ack (sticky on the session).
    *h.compression_enabled.lock().await = ack.compression_enabled;
    h.last_resume_ttl_secs
        .store(ack.session_ttl_secs, std::sync::atomic::Ordering::Relaxed);
    h.last_resume_prelude_len.store(
        ack.prelude_lens.first().copied().unwrap_or(0),
        std::sync::atomic::Ordering::Relaxed,
    );
    tracing::info!("RESUME_ACK received; lz4={}", ack.compression_enabled);
    let tab_entry = ack
        .tabs
        .first()
        .ok_or_else(|| anyhow::anyhow!("RESUME_ACK has no tab entries"))?;

    // 把处置存起来供 Dart 查询。**先存再判断** —— TabGone 那条路要提前
    // 返回 Err，但 Dart 侧仍需读到退出码才能显示「进程已退出（code）」。
    let new_tab_id = tab_entry.tab_id;
    *h.last_resume_disposition.lock().await = Some(tab_entry.disposition.clone());

    // 非 Restored → 服务端不会打开 bidi 流，若不提前返回则 accept_bi()
    // 会一直阻塞到超时。
    //
    // 前缀 "AQT_ERR_SNF:" (Session Not Found) 让 Dart 侧用 startsWith 做
    // 结构化识别，避免文案改一改 contains 匹配就失效。保留它是因为现有
    // Dart 识别路径（contains("not found on server")）还在用。
    match &tab_entry.disposition {
        aqt_protocol::Disposition::Restored { .. } => {}
        aqt_protocol::Disposition::TabGone { exit_status } => {
            return Err(anyhow::anyhow!(
                "AQT_ERR_SNF: RESUME tab {} not found on server (exited{})",
                new_tab_id,
                match exit_status {
                    Some(c) => format!(" with status {c}"),
                    None => String::new(),
                }
            ));
        }
        aqt_protocol::Disposition::NewSession => {
            return Err(anyhow::anyhow!(
                "AQT_ERR_SNF: RESUME tab {} not found on server (session gone)",
                new_tab_id
            ));
        }
    }

    // Store control streams
    *h.ctrl_tx.lock().await = Some(ctrl_tx);
    *h.ctrl_rx.lock().await = Some(ctrl_rx);

    // Accept server-initiated PTY bidi stream
    let (mut pty_send, pty_recv) = conn.accept_bi().await?;

    // Wire client → PTY send channel
    let (fwd_tx, mut fwd_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    h.tabs
        .write()
        .await
        .insert(new_tab_id, TabHandle { pty_tx: fwd_tx });

    // PTY output reader: QUIC PTY recv stream → events (zstd-aware)
    let evt_tx = h.event_tx.clone();
    let compression = *h.compression_enabled.lock().await;
    spawn_pty_reader(pty_recv, evt_tx, new_tab_id, compression);

    // PTY input forwarder: fwd_rx → QUIC PTY send stream
    tokio::spawn(async move {
        while let Some(chunk) = fwd_rx.recv().await {
            if pty_send.write_all(&chunk).await.is_err() {
                break;
            }
        }
    });

    // Store session token (refreshed from the resumed session)
    *h.session_token.lock().await = Some(session_token);

    let _ = h.event_tx.send(AqtEvent {
        kind: AqtEventKind::Connected,
        tab_id: 0,
        data: vec![],
        preloaded_bytes: 0,
    });
    let _ = h.event_tx.send(AqtEvent {
        kind: AqtEventKind::TabOpened,
        tab_id: new_tab_id,
        data: vec![],
        preloaded_bytes: 0,
    });

    // Monitor connection: send Disconnected when QUIC path dies (same as aqt_connect).
    if let Some(conn_ref) = h.conn.read().await.clone() {
        let evt_tx = h.event_tx.clone();
        tokio::spawn(async move {
            let _ = conn_ref.closed().await;
            let _ = evt_tx.send(AqtEvent {
                kind: AqtEventKind::Disconnected,
                tab_id: 0,
                data: vec![],
                preloaded_bytes: 0,
            });
        });
    }
    // Route B: RESUME goes through the same server-side `handle()` path as
    // HELLO, which opens the Notify uni stream right after the ACK — so the
    // dispatch loop needs wiring here too, not just in aqt_connect's success
    // path.
    if let Some(conn_ref) = h.conn.read().await.clone() {
        let evt_tx = h.event_tx.clone();
        tokio::spawn(notify_accept_loop(conn_ref, evt_tx));
    }

    Ok(())
}

// ──────────────────────────────────────────────
// Tests: FrameReader backlog-delivery regression
// ──────────────────────────────────────────────
//
// Spins up a real `flyterm-server` (in-process, via the `flyterm-server` dev-
// dependency — see Cargo.toml) and exercises `FrameReader` exactly the way
// `notify_accept_loop` does, but against the scenario `read_frame_from`
// gets wrong: several Notify frames queued up *before* the client even
// accepts the uni stream, so the very first physical `rx.read()` is likely
// to already contain more than one complete frame. `FrameReader` lives as a
// private item in this module, so this test has to live inside `ffi.rs`
// itself (an external `tests/` file in this crate would only see the public
// API and couldn't reach it) — mirrors `flyterm-server/tests/protocol_integration.rs`'s
// `start_server`/`make_client_ep`/`read_frame` helpers, adapted to call
// `FrameReader::read_frames` instead.
#[cfg(test)]
mod tests {
    use super::*;
    use aqt_protocol::frame::Notify;
    use std::net::SocketAddr;
    use std::sync::Arc;
    use std::time::Duration;

    /// Accepts any server, including any handshake signature: these tests
    /// exercise the FFI session logic, not TLS. Never use outside tests.
    #[derive(Debug)]
    struct SkipVerification;
    impl rustls::client::danger::ServerCertVerifier for SkipVerification {
        fn verify_server_cert(
            &self,
            _end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp_response: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }
        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }
        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            rustls::crypto::ring::default_provider()
                .signature_verification_algorithms
                .supported_schemes()
        }
    }

    fn make_test_client_ep() -> quinn::Endpoint {
        let mut crypto = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(SkipVerification))
        .with_no_client_auth();
        crypto.alpn_protocols = vec![aqt_protocol::ALPN.to_vec()];
        let mut cfg = quinn::ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(crypto).unwrap(),
        ));
        let mut transport = quinn::TransportConfig::default();
        transport.keep_alive_interval(Some(Duration::from_secs(5)));
        cfg.transport_config(Arc::new(transport));
        let mut ep = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        ep.set_default_client_config(cfg);
        ep
    }

    fn start_test_server(max_sessions: u32) -> (u16, flyterm_server::session::SessionStore) {
        let tls = flyterm_server::tls::generate_ephemeral().expect("ephemeral tls");
        let ep = flyterm_server::endpoint::build_endpoint(
            "127.0.0.1:0".parse().unwrap(),
            &tls,
            flyterm_server::cli::CongestionKind::Cubic,
        )
        .expect("build endpoint");
        let port = ep.local_addr.port();
        let store = flyterm_server::session::SessionStore::new(
            max_sessions,
            flyterm_server::session::DEFAULT_SESSION_TTL,
        );
        let cfg = flyterm_server::connection::ConnectionConfig {
            ring_size_bytes: 64 * 1024,
            parser_scrollback_rows: 1000,
            max_tabs_per_session: 8,
            term: "xterm-256color".into(),
            allow_compression: false,
            history_root: None,
            notify_sock: Some(std::path::PathBuf::from(
                "/tmp/flyterm-test-notify-ffi.sock",
            )),
        };
        let store_for_loop = store.clone();
        tokio::spawn(async move {
            let _ = flyterm_server::endpoint::accept_loop(ep, store_for_loop, cfg).await;
        });
        (port, store)
    }

    /// The regression test mandated by review: broadcast TWO events before
    /// the client ever calls `accept_uni()`, so the push task's very first
    /// tick writes both frames back-to-back in one `for ev in pending { ... }`
    /// burst (see `spawn_notify_push_task` in `connection.rs`). If the
    /// client's physical `rx.read()` coalesces both frames' bytes into one
    /// buffer — which is exactly what the reviewer's scratch reproduction
    /// observed — a reader that returns after the first decoded frame and
    /// throws its buffer away on the next call (the `read_frame_from`
    /// pattern) permanently loses the second event. `FrameReader::read_frames`
    /// must return both, in order, from calls that together drain the buffer
    /// fully before doing another physical read.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn backlog_of_multiple_notify_events_all_arrive() -> anyhow::Result<()> {
        let (port, store) = start_test_server(10);
        tokio::time::sleep(Duration::from_millis(50)).await;

        let ep = make_test_client_ep();
        let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
        let conn = ep.connect(addr, "aqt")?.await?;
        let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;

        // HELLO: give the server exactly one active session to broadcast
        // into. This is a legitimate one-shot exchange, so reusing the
        // existing (unmodified) `read_frame_from` here is correct — it's
        // only unsafe on streams read in a loop, which this one isn't.
        let mut buf = BytesMut::new();
        encode_frame(
            &Hello {
                version: PROTOCOL_VERSION,
                client_id: [0x42; 16],
                capabilities: 0,
            },
            &mut buf,
        )
        .map_err(|e| anyhow::anyhow!("encode HELLO: {e:?}"))?;
        ctrl_tx.write_all(&buf).await?;
        let _ack: HelloAck = read_frame_from(&mut ctrl_rx).await?;

        // Broadcast TWO events BEFORE accept_uni(). Same ordering rationale
        // as protocol_integration.rs's notify tests: quinn only surfaces an
        // opened uni stream to the peer once the first byte actually hits
        // the wire, and the push task only writes once it has pending
        // events — awaiting accept_uni() first would deadlock.
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        store
            .broadcast_notify(Some(1), "first".into(), now_ms)
            .await;
        store
            .broadcast_notify(Some(2), "second".into(), now_ms + 1)
            .await;

        let mut notify_rx = tokio::time::timeout(Duration::from_secs(2), conn.accept_uni())
            .await
            .map_err(|_| {
                anyhow::anyhow!("server never opened the notify uni stream within 2s")
            })??;

        // Collect via FrameReader exactly as notify_accept_loop does, until
        // both events have arrived (a single read_frames() call may return
        // one or both, depending on how the physical read chunked things —
        // the point of the test is that neither one is ever lost). Never
        // ack, so — same as `unacked_notify_is_redelivered_until_client_confirms`
        // — the server keeps redelivering both on every subsequent tick.
        // Dedup by event_id, keeping first-seen order, so a slow test
        // scheduler letting a second tick's redelivery land in the same
        // physical read doesn't turn into a spurious "got 3/4 events"
        // failure — the thing under test is only that neither original
        // event is ever lost or reordered, not the total frame count.
        let mut reader = FrameReader::new();
        let mut got: Vec<Notify> = Vec::new();
        let mut seen_ids = std::collections::HashSet::new();
        while got.len() < 2 {
            let batch: Vec<Notify> = tokio::time::timeout(
                Duration::from_secs(2),
                reader.read_frames::<Notify>(&mut notify_rx),
            )
            .await
            .map_err(|_| {
                anyhow::anyhow!(
                    "timed out waiting for backlog delivery, got {} so far",
                    got.len()
                )
            })??;
            for n in batch {
                if seen_ids.insert(n.event_id) {
                    got.push(n);
                }
            }
        }

        assert_eq!(got[0].text, "first");
        assert_eq!(got[0].tab_id, Some(1));
        assert_eq!(got[1].text, "second");
        assert_eq!(got[1].tab_id, Some(2));
        assert_ne!(
            got[0].event_id, got[1].event_id,
            "the two events must be distinct"
        );

        Ok(())
    }
}
