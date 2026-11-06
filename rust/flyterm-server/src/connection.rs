// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::{anyhow, Result};
use aqt_protocol::{
    decode_frame_header, encode_frame, CloseTab, Disposition, FramePayload, Hello, HelloAck,
    HistoryPreloadDone, HistorySegmentMeta, ListHistory, ListHistoryResp, Opcode, OpenTab,
    OpenTabAck, OpenTabStatus, Resize, Resume, ResumeAck, ResumeAckTab, Signal, CAP_LZ4,
    PROTOCOL_VERSION,
};
// NotifyAck isn't re-exported at the aqt_protocol crate root (only
// aqt_protocol::frame::*), so pull it in from its actual home. (Notify itself
// is only ever referenced through inference — `unread_since` already returns
// `Vec<Notify>` — so importing it by name here would be unused.)
use aqt_protocol::frame::NotifyAck;
use bytes::{Bytes, BytesMut};
use quinn::{Connection, RecvStream, SendStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::pty_task::{spawn_pty, PtyHandles, PtySpawnConfig};
use crate::session::{AqtTab, SessionStore, TOKEN_SIZE};

#[derive(Clone)]
pub struct ConnectionConfig {
    pub ring_size_bytes: usize,
    /// vt100 parser 每 tab 保留的 primary scrollback 行数 —— RESUME 负载的
    /// 历史段就是从这里读的。见 `cli.rs` 那个字段的内存说明。
    pub parser_scrollback_rows: usize,
    pub max_tabs_per_session: u32,
    pub term: String,
    /// Master switch: if false the server refuses to confirm CAP_ZSTD in
    /// HelloAck regardless of what the client advertises. Production sets it
    /// to false until the rendering-residue root cause is fixed; tests set
    /// it to true to exercise the compressed path.
    pub allow_compression: bool,
    /// Top-level handle for session history. None when history feature is
    /// disabled at compile time or directory is unwritable at startup.
    #[cfg(feature = "history")]
    pub history_root: Option<crate::history::root::HistoryRoot>,
    /// Placeholder type when history feature is off — keeps `history_root`
    /// field available so call-sites compile without cfg gates.
    #[cfg(not(feature = "history"))]
    pub history_root: Option<HistoryRootPlaceholder>,
    /// Path of the local `flyterm notify` unix socket, precomputed from
    /// `state_dir` in main.rs. Passed down into each spawned PTY's env
    /// (FLYTERM_NOTIFY_SOCK) so `flyterm notify` run inside a shell knows
    /// where to connect without guessing state_dir itself.
    ///
    /// `None` in Once mode: that mode never binds a listener (see main.rs),
    /// so injecting a path there would point at a socket nothing is ever
    /// listening on. Leaving the env vars unset instead lets `flyterm notify`
    /// fall back to its default `sock_path(&state_dir)` — which, if a
    /// long-running daemon happens to be up on the same machine, actually
    /// reaches it. Strictly better than pointing at a guaranteed-dead path.
    pub notify_sock: Option<std::path::PathBuf>,
}

/// Zero-size type used as `history_root` when the `history` feature is off.
#[cfg(not(feature = "history"))]
#[derive(Clone)]
pub struct HistoryRootPlaceholder;

pub async fn handle(conn: Connection, store: SessionStore, cfg: ConnectionConfig) -> Result<()> {
    let (mut tx, mut rx) = conn
        .accept_bi()
        .await
        .map_err(|e| anyhow!("accept control stream: {e:?}"))?;

    // Read first frame: HELLO or RESUME
    let mut buf = BytesMut::with_capacity(64);
    let token: [u8; TOKEN_SIZE] = loop {
        let mut tmp = [0u8; 256];
        let n = rx
            .read(&mut tmp)
            .await?
            .ok_or_else(|| anyhow!("eof in handshake"))?;
        buf.extend_from_slice(&tmp[..n]);
        let mut peek: &[u8] = &buf;
        let Ok((op, len)) = decode_frame_header(&mut peek) else {
            continue;
        };
        if peek.len() < len {
            continue;
        }
        let hlen = buf.len() - peek.len();
        let _ = buf.split_to(hlen);
        let payload = buf.split_to(len);

        match op {
            Opcode::Hello => {
                let mut p: &[u8] = &payload;
                let hello = Hello::decode(&mut p)?;
                if hello.version != PROTOCOL_VERSION {
                    return Err(anyhow!("unsupported version {}", hello.version));
                }
                let token = store.create().await
                    .ok_or_else(|| anyhow!("session quota exceeded (max_sessions limit); try --max-sessions or wait for old sessions to expire"))?;
                // Negotiate zstd compression: requires BOTH the client to
                // advertise CAP_ZSTD AND the server's master switch to be on.
                // The latter is gated to false in production (see main.rs)
                // until rendering-residue root cause is identified.
                let compression = (hello.capabilities & CAP_LZ4) != 0 && cfg.allow_compression;
                // Touch the new session immediately so its TTL starts from now,
                // and persist the compression flag for any later RESUME.
                store
                    .with_session(&token, |s| {
                        s.touch(crate::session::DEFAULT_SESSION_TTL);
                        s.compression_enabled = compression;
                    })
                    .await;
                let server_caps = if compression { CAP_LZ4 } else { 0 };
                log::info!("HELLO accepted; zstd={}", compression);
                write_frame(
                    &mut tx,
                    &HelloAck {
                        server_caps,
                        session_token: token,
                    },
                )
                .await?;
                break token;
            }
            Opcode::Resume => {
                let mut p: &[u8] = &payload;
                let resume = Resume::decode(&mut p)?;
                let token = resume.session_token;

                // 会话不存在 → **拒绝连接**，不发 ResumeAck。
                //
                // 一度改成「先回一份 NewSession 再断开」，想让客户端有个能
                // 分派的答案。但那是错的：write_frame 之后立刻关连接，客户端
                // 未必收得到那一帧，于是它既可能看到 NewSession、也可能只看到
                // 连接错误 —— 两条路都得处理，反而比单一的「被拒」更难判断。
                //
                // `Disposition::NewSession` 仍然有用，只是由**客户端**在这种
                // 情形下自己构造，用来驱动统一的分派入口（复位终端 + 走 HELLO
                // 建新会话）。服务端这边保持「无效 token = 连接被拒」这个既有
                // 契约，protocol_integration 里有一例锁着它。
                if store.with_session(&token, |_| ()).await.is_none() {
                    return Err(anyhow!("unknown or expired session token"));
                }

                // Parallel multi-tab RESUME：每个 tab 的 open_bi / 快照 /
                // 起转发任务互不依赖，try_join_all 让墙钟时间是 max 而不是
                // sum（3+ tab 时省 30-80 ms），且保持请求顺序。
                use futures::future::try_join_all;
                let conn_ref = &conn;
                let store_ref = &store;
                let tab_futures = resume.tabs.iter().map(|&tab_id| async move {
                    let info = store_ref
                        .with_session(&token, |s| {
                            s.tabs
                                .get(&tab_id)
                                .map(|t| (t.pty.clone(), t.last_in_off_acked))
                        })
                        .await
                        .flatten();

                    let Some((Some(pty), last_in_seen)) = info else {
                        return Ok::<(ResumeAckTab, u64), anyhow::Error>((
                            ResumeAckTab {
                                tab_id,
                                new_pty_stream_id: 0,
                                disposition: Disposition::TabGone { exit_status: None },
                            },
                            0, // 没开新流，没有 prelude 可数
                        ));
                    };

                    // 进程已经退出：报退出码，别再开流。客户端会显示状态但
                    // **不**复位终端 —— 用户还在看那些输出。
                    if let Some(code) = *pty.exit_rx.borrow() {
                        return Ok((
                            ResumeAckTab {
                                tab_id,
                                new_pty_stream_id: 0,
                                disposition: Disposition::TabGone {
                                    exit_status: Some(code),
                                },
                            },
                            0, // 同上：进程都退出了，不会有快照
                        ));
                    }

                    let (pty_send, pty_recv) = conn_ref
                        .open_bi()
                        .await
                        .map_err(|e| anyhow!("open pty bidi (resume): {e:?}"))?;
                    let new_stream_id = u64::from(pty_send.id());

                    // 恢复内容 = vt100 parser 的 primary 历史 + 可见屏
                    // （+ alt 屏快照，如果当前在 alt）。
                    //
                    // 这里曾经有约 200 行：按 last_out_off 判「续传还是重建」、
                    // 按 in_alt 决定发快照还是回放 ring、drop_leading_csi_tail
                    // 补救被 ring 旋转切断的 CSI。全部删掉了 ——
                    //
                    //   * 不看客户端 offset：Resume 帧里已经没有那个字段。它
                    //     在六个发起点之间无法维持单一真相，是全部 offset 类
                    //     bug 的载体。
                    //   * 不分 alt/primary：一条路径覆盖两者（alt 只是多叠一段）。
                    //   * 不碰任何 ring：历史直接来自 parser 的 scrollback，与
                    //     可见屏同源同单位。历史与屏幕之间**没有去重要做** ——
                    //     从字节流 ring 取历史再按行数剔重叠，那是四类「回放内容
                    //     重复」的共同根因，详见 `snapshot.rs` 头部。
                    //
                    // 只持 parser 的**读锁**：`primary_*` 那几个访问器是只读的，
                    // 不像 `set_scrollback` 那样需要改 parser 状态。
                    let screen = {
                        let parser = pty.parser.read().await;
                        crate::snapshot::serialize_resume(parser.screen(), RESUME_HISTORY_BYTES)
                    };

                    let (fwd_tx, fwd_rx) = tokio::sync::mpsc::channel::<Bytes>(
                        crate::pty_task::OUTPUT_CHANNEL_CAPACITY,
                    );
                    *pty.output_forwarder.lock().await = Some(fwd_tx);

                    let compression = store_ref
                        .with_session(&token, |s| s.compression_enabled)
                        .await
                        .unwrap_or(false);
                    // 恢复内容作为新 PTY 流的**头几个字节**送出，live 输出
                    // 接在后面。同一条有序流，客户端不需要为它做任何特殊处理。
                    //
                    // 这曾经走 ResumeAck 帧。改回来是因为把可达 256 KiB 的
                    // 载荷塞进控制帧要求客户端整帧收齐才能解码，再经 FFI
                    // 两阶段拷回、一次性 write —— 实测 113 KB 单次 write 就要
                    // 51ms，而控制帧这条路上还有更长的阻塞。
                    //
                    // 当年删掉 prelude 的理由**不在这里**：那时的问题是用
                    // byte offset 从 ring 切片（切片可能落在 CSI 中间、offset
                    // 在多个发起点之间分裂世代、replay_bytes 双重计数）。现在
                    // 历史按行号索引、客户端也不再数「前多少字节是回放」——
                    // 没有分派要做，字节写进去就行，那些坑没有回来的路径。
                    let resume_prelude_len = screen.len();
                    spawn_pty_forwarder(pty_send, fwd_rx, screen, compression);

                    let input_tx = pty.input_tx.clone();
                    let mut prx = pty_recv;
                    tokio::spawn(async move {
                        let mut b = [0u8; 4096];
                        loop {
                            match prx.read(&mut b).await {
                                Ok(Some(n)) => {
                                    if input_tx
                                        .send(Bytes::copy_from_slice(&b[..n]))
                                        .await
                                        .is_err()
                                    {
                                        break;
                                    }
                                }
                                Ok(None) | Err(_) => break,
                            }
                        }
                    });

                    log::info!(
                        "RESUME tab={} prelude={}B in_seen={}",
                        tab_id,
                        resume_prelude_len,
                        last_in_seen
                    );

                    Ok((
                        ResumeAckTab {
                            tab_id,
                            new_pty_stream_id: new_stream_id,
                            disposition: Disposition::Restored {
                                server_in_seen_off: last_in_seen,
                            },
                        },
                        resume_prelude_len as u64,
                    ))
                });

                let ack_pairs: Vec<(ResumeAckTab, u64)> = try_join_all(tab_futures).await?;
                // unzip 保证两个 Vec 长度相等、下标对齐，满足 ResumeAck::encode
                // 里 prelude_lens.len() == tabs.len() 的不变量。
                let (ack_tabs, prelude_lens): (Vec<_>, Vec<_>) = ack_pairs.into_iter().unzip();
                let session_compression = store
                    .with_session(&token, |s| s.compression_enabled)
                    .await
                    .unwrap_or(false);
                write_frame(
                    &mut tx,
                    &ResumeAck {
                        tabs: ack_tabs,
                        compression_enabled: session_compression,
                        session_ttl_secs: crate::session::DEFAULT_SESSION_TTL.as_secs(),
                        // 每个 tab 的 resume_prelude_len，随 try_join_all 保持
                        // 的请求顺序与 tabs 下标对齐；仅供客户端诊断/计时用，
                        // 不参与任何控制流分派。
                        prelude_lens,
                    },
                )
                .await?;
                // RESUME 成功：刷新 TTL，防止长时间运行的会话（含频繁断联）过期。
                store
                    .with_session(&token, |s| s.touch(crate::session::DEFAULT_SESSION_TTL))
                    .await;
                break token;
            }
            _ => return Err(anyhow!("expected HELLO or RESUME, got {op:?}")),
        }
    };

    // Heartbeat datagram pump.
    //
    // Client sends 1-byte QUIC datagrams every 5 s while the app is in
    // foreground (lib/ssh/aqt/aqt_transport.dart heartbeat timer). Each
    // arrival is a liveness signal — touch() the session to push its TTL
    // back so a long-lived foreground session never ages out.
    //
    // Previously we drained datagrams silently in a side task spawned
    // before HELLO; that task had no token reference and could not
    // touch(). With DEFAULT_SESSION_TTL=7d that was workable but still
    // wrong: any background process holding the connection open for >7d
    // (e.g. claude session left running over a long weekend) would still
    // expire on the dot, then RESUME would fail when the user came back.
    // Now the datagram pump runs after token is known and touches on
    // every datagram, so an actively-pinged session never expires.
    let conn_dg = conn.clone();
    let store_dg = store.clone();
    let token_dg = token;
    tokio::spawn(async move {
        loop {
            match conn_dg.read_datagram().await {
                Ok(_dg) => {
                    store_dg
                        .with_session(&token_dg, |s| {
                            s.touch(crate::session::DEFAULT_SESSION_TTL);
                        })
                        .await;
                }
                Err(_) => break,
            }
        }
    });

    // Route B：通知走一条独立的 QUIC uni 流，不再和控制流的请求/响应节奏
    // 耦合在一起。
    //
    // 起因：control_loop 原来用 tokio::select! 把 500ms 的 notify_tick 和
    // rx.read() 揉进同一个 loop，这个设计有两个问题——
    //   1. 插桩风险：一旦控制流上出现真正的异步推送，任何"读一次期望某个
    //      类型"的调用方（客户端 ffi.rs 的 read_frame_from）都可能在等
    //      HelloAck/OpenTabAck 之类响应时先读到一帧 Notify，类型不对直接
    //      decode 失败。
    //   2. 空闲期不投递：客户端建完 tab 之后，如果很长一段时间没有再发
    //      Resize/Signal 等控制流量，ffi.rs 里现存的三处 accept_bi() 调用
    //      点全都是一次性读取，没有常驻的控制流读循环——控制流一旦读完
    //      一次期望的响应就不会再被轮询，Notify 反而在最该工作的场景
    //      （手机睡着、网络抖动后又恢复）里根本送不到。
    // quinn 的 open_bi/accept_bi 与 open_uni/accept_uni 是两个完全独立的
    // 内部队列——给通知单开一条 uni 流之后，它的收发节奏与控制流的
    // 请求/响应节奏彻底解耦，客户端只需要另起一个常驻的 accept_uni() 循环
    // 专门等 Notify，不必碰任何一处现有的 accept_bi() 时序假设。
    //
    // last_acked 从 control_loop 内的局部变量提升为 Arc<AtomicU64>，因为
    // 现在有两个任务都要看到它：这里新起的推送任务只读它（决定这次要不要
    // 重投某个事件），真正的写入者仍然只有 control_loop 收到货真价实的
    // NotifyAck 帧那一刻——这个"只能被真实 ack 推进，绝不能在推送路径里
    // 乐观提前"的不变量原封不动地保留，只是从"同一个 loop 里的普通变量"
    // 变成"跨任务共享的原子变量"。
    let last_acked = Arc::new(AtomicU64::new(0));
    match conn.open_uni().await {
        Ok(uni_tx) => {
            spawn_notify_push_task(uni_tx, store.clone(), token, Arc::clone(&last_acked));
        }
        Err(e) => {
            // 通知是锦上添花的功能，不应该因为 uni 流开不出来就让整条连接
            // 失败——PTY 和控制流该怎么工作还怎么工作。理论上 open_uni 在
            // 一条已经建立好的 QUIC 连接上失败的概率极低（不像 accept_bi
            // 需要等对端主动发起）。
            log::warn!("failed to open notify push uni stream: {e:?}");
        }
    }

    control_loop(&mut rx, &mut tx, &conn, store, token, cfg, last_acked).await
}

/// 常驻任务：每 500ms 把该 session 队列里 last_acked 之后的未读事件推到
/// 专属的 Notify uni 流上。
///
/// 写失败即结束本任务（不影响连接的其余部分）：不同于旧版 control_loop
/// 里"写失败就让整个连接 `?` 传播出去"的策略——那是因为旧版通知和控制流
/// 共享同一条双向流，写方向坏了但读方向仍活会导致无限 warn 循环，必须
/// 靠终止连接止损。现在通知已经是完全独立的一条 uni 流，它的写失败只说明
/// "这条通知通道用不了了"，不该牵连 PTY 和控制流——按 Route B 的解耦
/// 精神，这里选择安静地停止推送，而不是让整条连接陪葬。
fn spawn_notify_push_task(
    mut uni_tx: SendStream,
    store: SessionStore,
    token: [u8; TOKEN_SIZE],
    last_acked: Arc<AtomicU64>,
) {
    tokio::spawn(async move {
        // 默认 Burst 行为会在 handle_open_tab 之类的同步阻塞（PTY spawn
        // 几百毫秒到几秒）期间攒下错过的 tick，恢复后背靠背连续触发，对
        // 同一批未 ack 事件重复推送好几轮。不丢数据（客户端按 event_id
        // 去重能兜住）但纯浪费，改成 Delay：错过的 tick 直接丢弃，下一个
        // tick 从"现在"重新起算。
        let mut notify_tick = tokio::time::interval(std::time::Duration::from_millis(500));
        notify_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            notify_tick.tick().await;
            let now_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            let acked = last_acked.load(Ordering::SeqCst);
            let pending = store
                .with_session(&token, |s| s.notify_queue.unread_since(acked, now_ms))
                .await
                .unwrap_or_default();
            for ev in pending {
                if let Err(e) = write_frame(&mut uni_tx, &ev).await {
                    log::warn!("failed to push Notify on uni stream, ending push task: {e:#}");
                    return;
                }
            }
        }
    });
}

async fn control_loop(
    rx: &mut RecvStream,
    tx: &mut SendStream,
    conn: &Connection,
    store: SessionStore,
    token: [u8; TOKEN_SIZE],
    cfg: ConnectionConfig,
    last_acked: Arc<AtomicU64>,
) -> Result<()> {
    let mut buf = BytesMut::with_capacity(4096);
    loop {
        let mut tmp = [0u8; 4096];
        let n = match rx.read(&mut tmp).await {
            Ok(Some(n)) => n,
            Ok(None) => break,
            Err(e) => return Err(anyhow!("control stream read: {e:?}")),
        };
        buf.extend_from_slice(&tmp[..n]);

        loop {
            let mut peek: &[u8] = &buf;
            let Ok((op, len)) = decode_frame_header(&mut peek) else {
                break;
            };
            let hlen = buf.len() - peek.len();
            if peek.len() < len {
                break;
            }
            let _ = buf.split_to(hlen);
            let payload = buf.split_to(len);

            log::info!("control_loop got opcode {:?}", op);
            match op {
                Opcode::OpenTab => {
                    let mut p: &[u8] = &payload;
                    let req = OpenTab::decode(&mut p)?;
                    log::info!(
                        "OPEN_TAB request cols={} rows={} cmd={:?}",
                        req.cols,
                        req.rows,
                        req.cmd
                    );
                    handle_open_tab(req, tx, conn, &store, &token, &cfg).await?;
                    log::info!("OPEN_TAB handled");
                }
                Opcode::Resize => {
                    let mut p: &[u8] = &payload;
                    let r = Resize::decode(&mut p)?;
                    if let Some(handles) = get_pty(&store, &token, r.tab_id).await {
                        let _ = handles.resize(r.cols, r.rows).await;
                    }
                }
                Opcode::Signal => {
                    let mut p: &[u8] = &payload;
                    let s = Signal::decode(&mut p)?;
                    if let Some(handles) = get_pty(&store, &token, s.tab_id).await {
                        let byte = match s.signum {
                            2 => Some(b'\x03'),
                            26 => Some(b'\x1A'),
                            _ => None,
                        };
                        if let Some(b) = byte {
                            let _ = handles.input_tx.send(Bytes::from(vec![b])).await;
                        }
                    }
                }
                Opcode::NotifyAck => {
                    // 这里是整个连接里唯一允许推进 last_acked 的地方——必须
                    // 是真正收到的一帧 NotifyAck，绝不能在推送任务里乐观
                    // 提前（见 spawn_notify_push_task 顶部注释）。
                    let mut p: &[u8] = &payload;
                    let ack = NotifyAck::decode(&mut p)?;
                    last_acked.fetch_max(ack.last_event_id, Ordering::SeqCst);
                    store
                        .with_session(&token, |s| s.notify_queue.ack(ack.last_event_id))
                        .await;
                }
                Opcode::CloseTab => {
                    let mut p: &[u8] = &payload;
                    let c = CloseTab::decode(&mut p)?;
                    store
                        .with_session(&token, |s| {
                            s.tabs.remove(&c.tab_id);
                        })
                        .await;
                }
                Opcode::ListHistory => {
                    #[cfg(feature = "history")]
                    {
                        let mut p: &[u8] = &payload;
                        let req = ListHistory::decode(&mut p)?;
                        let resp = if let Some(root) = &cfg.history_root {
                            let session_key = format!("peer-{}", conn.remote_address().ip());
                            let segs = root
                                .store
                                .list_for(
                                    &session_key,
                                    req.command_hint.as_deref(),
                                    req.limit as u32,
                                    req.before_ts,
                                )
                                .unwrap_or_default();
                            ListHistoryResp {
                                segments: segs
                                    .into_iter()
                                    .map(|s| HistorySegmentMeta {
                                        history_id: s.id as u64,
                                        command_hint: s.command_hint,
                                        started_at: s.started_at,
                                        ended_at: s.ended_at.unwrap_or(s.started_at),
                                        size_bytes: s.size_bytes,
                                        preview: String::new(),
                                    })
                                    .collect(),
                            }
                        } else {
                            ListHistoryResp { segments: vec![] }
                        };
                        write_frame(tx, &resp).await?;
                    }
                    #[cfg(not(feature = "history"))]
                    write_frame(tx, &ListHistoryResp { segments: vec![] }).await?;
                }
                _ => log::warn!("unhandled opcode {op:?}"),
            }
        }
    }
    Ok(())
}

async fn get_pty(
    store: &SessionStore,
    token: &[u8; TOKEN_SIZE],
    tab_id: u32,
) -> Option<Arc<PtyHandles>> {
    store
        .with_session(token, |s| s.tabs.get(&tab_id).and_then(|t| t.pty.clone()))
        .await
        .flatten()
}

async fn handle_open_tab(
    req: OpenTab,
    ctrl_tx: &mut SendStream,
    conn: &Connection,
    store: &SessionStore,
    token: &[u8; TOKEN_SIZE],
    cfg: &ConnectionConfig,
) -> Result<()> {
    let tab_count = store
        .with_session(token, |s| s.tabs.len() as u32)
        .await
        .unwrap_or(0);
    if tab_count >= cfg.max_tabs_per_session {
        return write_frame(
            ctrl_tx,
            &OpenTabAck {
                tab_id: 0,
                pty_stream_id: 0,
                status: OpenTabStatus::QuotaExceeded,
            },
        )
        .await;
    }

    // Allocate tab_id before spawning the PTY so the history logger can use it
    // for its segment filenames.
    let tab_id = store
        .with_session(token, |s| s.allocate_tab_id())
        .await
        .ok_or_else(|| anyhow!("session vanished before tab allocation"))?;

    // Create history logger if history_root is configured.
    // Write errors are silently ignored so history failure never affects the
    // live terminal experience.
    #[cfg(feature = "history")]
    let history_logger = if let Some(root) = &cfg.history_root {
        let session_key = format!("peer-{}", conn.remote_address().ip());
        match crate::history::logger::HistoryLogger::new(
            root.dir.clone(),
            root.store.clone(),
            session_key,
            req.cmd.clone(),
            tab_id,
            crate::history::logger::MAX_SEGMENT_BYTES,
        ) {
            Ok(logger) => {
                let l = Arc::new(std::sync::Mutex::new(logger));
                Some(l)
            }
            Err(e) => {
                log::warn!("history logger init failed: {}", e);
                None
            }
        }
    } else {
        None
    };
    #[cfg(not(feature = "history"))]
    let history_logger: Option<crate::pty_task::HistoryLoggerHandle> = None;

    let pty = match tokio::task::block_in_place(|| {
        spawn_pty(PtySpawnConfig {
            cols: req.cols,
            rows: req.rows,
            term: if req.term.is_empty() {
                cfg.term.clone()
            } else {
                req.term
            },
            cwd: if req.cwd.is_empty() {
                None
            } else {
                Some(req.cwd)
            },
            ring_size_bytes: cfg.ring_size_bytes,
            parser_scrollback_rows: cfg.parser_scrollback_rows,
            tab_id,
            notify_sock: cfg.notify_sock.clone(),
            history_logger: history_logger.clone(),
        })
    }) {
        Ok(p) => Arc::new(p),
        Err(e) => {
            log::warn!("spawn_pty failed: {e:#}");
            return write_frame(
                ctrl_tx,
                &OpenTabAck {
                    tab_id: 0,
                    pty_stream_id: 0,
                    status: OpenTabStatus::SpawnFailed,
                },
            )
            .await;
        }
    };

    let (pty_send, mut pty_recv) = conn
        .open_bi()
        .await
        .map_err(|e| anyhow!("open pty stream: {e:?}"))?;
    let pty_stream_id = u64::from(pty_send.id());

    store
        .with_session(token, |s| {
            s.tabs.insert(
                tab_id,
                AqtTab {
                    tab_id,
                    last_in_off_acked: 0,
                    last_out_off_acked: 0,
                    pty: Some(Arc::clone(&pty)),
                },
            );
        })
        .await
        .ok_or_else(|| anyhow!("session vanished"))?;

    // Spawn a background task that waits for PTY exit then flushes the logger.
    #[cfg(feature = "history")]
    if let Some(logger) = history_logger {
        let mut exit_rx = pty.exit_rx.clone();
        tokio::spawn(async move {
            let _ = exit_rx.wait_for(|v| v.is_some()).await;
            if let Ok(mut g) = logger.lock() {
                let _ = g.flush_finalize();
            }
        });
    }

    // Buffer upstream (client→server) keystrokes that arrive while we are busy
    // building the preload result. The QUIC receive buffer holds them safely for
    // a few seconds, but QUIC flow-control will eventually stall the sender once
    // the window fills. Draining the stream concurrently with the (potentially
    // 0.5-2 s) preload work keeps the flow-control window open and guarantees
    // every keystroke reaches the shell after it has spawned.
    //
    // Strategy: spawn a concurrent reader task that moves bytes from pty_recv
    // into an unbounded mpsc channel. The task returns the RecvStream through a
    // oneshot so we can resume normal forwarding after draining the buffer.
    let (upstream_buf_tx, upstream_buf_rx) = tokio::sync::mpsc::unbounded_channel::<Bytes>();
    let (stream_return_tx, stream_return_rx) = tokio::sync::oneshot::channel::<RecvStream>();

    // Buffer task: read whatever arrives during the preload window.
    // It runs until we signal it (by dropping stream_return_tx via the oneshot
    // "done" channel). We use a second oneshot as a stop signal.
    let (stop_buf_tx, mut stop_buf_rx) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn({
        let buf_tx = upstream_buf_tx;
        async move {
            let mut buf = [0u8; 4096];
            loop {
                tokio::select! {
                    biased;
                    _ = &mut stop_buf_rx => {
                        // Preload done. Return the stream to the caller.
                        let _ = stream_return_tx.send(pty_recv);
                        break;
                    }
                    res = pty_recv.read(&mut buf) => {
                        match res {
                            Ok(Some(n)) => {
                                let _ = buf_tx.send(Bytes::copy_from_slice(&buf[..n]));
                            }
                            Ok(None) | Err(_) => break,
                        }
                    }
                }
            }
        }
    });

    // Replay history bytes (if requested) before streaming live PTY output.
    #[cfg(feature = "history")]
    let preload_result: Option<crate::history::replay::ReplayResult> =
        if let (Some(spec), Some(root)) = (&req.preload_history, &cfg.history_root) {
            let session_key = format!("peer-{}", conn.remote_address().ip());
            match crate::history::replay::replay_for(
                &root.store,
                &session_key,
                req.rows,
                req.cols,
                spec,
            ) {
                Ok(Some(r)) => Some(r),
                Ok(None) => None,
                Err(e) => {
                    log::warn!("history replay failed: {e:#}");
                    None
                }
            }
        } else {
            None
        };
    #[cfg(not(feature = "history"))]
    let preload_result: Option<bytes::Bytes> = None;

    // Signal the buffer task to stop collecting and return the RecvStream.
    let _ = stop_buf_tx.send(());
    // Recover the RecvStream (may be Err if the buffer task exited early due to
    // stream EOF / error — treat that the same as a closed upstream).
    let recovered_recv = stream_return_rx.await.ok();

    // Snapshot ring AND wire forwarder under the same ring lock to avoid a
    // data-loss window: the PTY reader (pty_task.rs) takes the ring lock
    // first then the fwd lock; if we drop the ring lock before setting
    // fwd_tx, a chunk written in between is appended to the ring (NOT in
    // our snapshot) but its forward attempt sees fwd=None and is dropped.
    // Holding the ring lock until fwd_tx is set forces the PTY reader to
    // block on the ring lock, so any chunk it appends after our snapshot
    // also forwards through fwd_tx — no loss, no duplicate.
    let (fwd_tx, fwd_rx) =
        tokio::sync::mpsc::channel::<Bytes>(crate::pty_task::OUTPUT_CHANNEL_CAPACITY);
    let ring_bytes: Vec<u8> = {
        let ring = pty.ring.lock().await;
        let snapshot = ring.snapshot_all();
        *pty.output_forwarder.lock().await = Some(fwd_tx);
        // ring lock is held until this block ends; PTY reader is blocked
        // on its blocking_lock() at pty_task.rs:118 while we're here.
        snapshot
    };

    // Prepend history bytes to initial_bytes so they arrive before the shell
    // prompt.  Order: [history bytes] [separator] [ring snapshot].
    #[cfg(feature = "history")]
    let initial_bytes: Vec<u8> = if let Some(ref r) = preload_result {
        let mut combined = r.bytes.clone();
        combined.extend_from_slice(&ring_bytes);
        combined
    } else {
        ring_bytes
    };
    #[cfg(not(feature = "history"))]
    let initial_bytes: Vec<u8> = ring_bytes;
    // Look up the session's compression flag (negotiated at HELLO).
    let compression = store
        .with_session(token, |s| s.compression_enabled)
        .await
        .unwrap_or(false);
    spawn_pty_forwarder(pty_send, fwd_rx, initial_bytes, compression);
    {
        let itx = pty.input_tx.clone();
        let mut upstream_buf_rx = upstream_buf_rx;
        tokio::spawn(async move {
            // Phase 1: drain any keystrokes buffered during the preload window.
            // The buffer task has already stopped writing; close the sender side
            // by draining until the channel is empty (try_recv loop).
            loop {
                match upstream_buf_rx.try_recv() {
                    Ok(bytes) => {
                        if itx.send(bytes).await.is_err() {
                            return;
                        }
                    }
                    Err(_) => break, // empty or disconnected
                }
            }

            // Phase 2: forward live upstream bytes from the recovered RecvStream.
            let mut prx = match recovered_recv {
                Some(s) => s,
                None => return, // stream was already closed
            };
            let mut b = [0u8; 4096];
            loop {
                match prx.read(&mut b).await {
                    Ok(Some(n)) => {
                        if itx.send(Bytes::copy_from_slice(&b[..n])).await.is_err() {
                            break;
                        }
                    }
                    Ok(None) | Err(_) => break,
                }
            }
        });
    }

    // Send OpenTabAck first so the client can start reading the PTY stream.
    write_frame(
        ctrl_tx,
        &OpenTabAck {
            tab_id,
            pty_stream_id,
            status: OpenTabStatus::Ok,
        },
    )
    .await?;

    // Send HistoryPreloadDone on the control stream after OpenTabAck.
    #[cfg(feature = "history")]
    if let Some(r) = preload_result {
        let done = HistoryPreloadDone {
            tab_id: tab_id as u32,
            preloaded_bytes: r.bytes.len() as u64,
            segments: r.segments,
        };
        if let Err(e) = write_frame(ctrl_tx, &done).await {
            log::warn!("failed to send HistoryPreloadDone: {e:#}");
        }
    }

    Ok(())
}

async fn write_frame<P: FramePayload>(tx: &mut SendStream, payload: &P) -> Result<()> {
    let mut buf = BytesMut::with_capacity(64);
    encode_frame(payload, &mut buf)?;
    tx.write_all(&buf).await?;
    Ok(())
}

/// Write one logical PTY chunk to the QUIC stream.
///
/// LZ4 block framing (when `compression` is on):
///   [4 bytes BE: compressed_frame_len][lz4_flex::block::compress_prepend_size output]
/// The prepend_size output itself starts with [4 bytes LE: original_len].
/// Each chunk is an independent LZ4 block — no streaming state shared across calls.
async fn write_pty_chunk(
    writer: &mut SendStream,
    bytes: &[u8],
    compression: bool,
) -> Result<(), ()> {
    #[cfg(feature = "compression")]
    if compression && !bytes.is_empty() {
        // compress_prepend_size: [u32 LE orig_len][lz4 block bytes]
        let compressed = aqt_protocol::lz4block::compress_prepend_size(bytes);
        let frame_len = (compressed.len() as u32).to_be_bytes();
        writer.write_all(&frame_len).await.map_err(|_| ())?;
        return writer.write_all(&compressed).await.map_err(|_| ());
    }
    let _ = compression;
    if !bytes.is_empty() {
        writer.write_all(bytes).await.map_err(|_| ())
    } else {
        Ok(())
    }
}

/// Forwarder batching timeout. After the first chunk arrives we wait up to
/// this long for the PTY reader to produce more before calling write_all.
/// This amortises LZ4 frame header + quinn + Dart dispatch overhead across
/// more bytes per write call.
///
/// Latency budget: measured p99 echo latency ≈ 0.9 ms; with 1.5 ms added
/// worst-case becomes ≈ 2.4 ms, well within the ≤ 5 ms PTY latency target.
/// For interactive typing (chars arrive every ~100 ms) the wait is invisible.
const FORWARDER_BATCH_TIMEOUT: std::time::Duration = std::time::Duration::from_micros(1500);

/// PTY output forwarder task body. Reads coalesced chunks from `fwd_rx`, writes
/// each as a fully self-contained LZ4 frame (when `compression` is true) or
/// raw bytes. On end of stream sends QUIC FIN.
async fn drive_pty_forwarder(
    mut writer: SendStream,
    mut fwd_rx: tokio::sync::mpsc::Receiver<Bytes>,
    compression: bool,
) {
    while let Some(first) = fwd_rx.recv().await {
        let mut acc = BytesMut::from(first.as_ref());

        // Phase 1 — non-blocking drain: pick up whatever is already queued.
        // Handles burst scenarios (TUI full-screen refresh, ring replay) where
        // the PTY reader has already filled the mpsc queue.
        while acc.len() < 256 * 1024 {
            match fwd_rx.try_recv() {
                Ok(more) => acc.extend_from_slice(&more),
                Err(_) => break,
            }
        }

        // Phase 2 — timed wait: if the cap wasn't reached, wait briefly for
        // the PTY reader to deliver more. PTY OPOST/ONLCR processing produces
        // ~400-byte reads every ~0.7 ms; 1.5 ms captures ~2 additional chunks
        // on average, reducing per-burst frame count from ~19 000 to ~6 000
        // (3× fewer LZ4 headers, quinn writes, and Dart terminal.write() calls).
        if acc.len() < 256 * 1024 {
            let deadline = tokio::time::Instant::now() + FORWARDER_BATCH_TIMEOUT;
            loop {
                match tokio::time::timeout_at(deadline, fwd_rx.recv()).await {
                    Ok(Some(more)) => {
                        acc.extend_from_slice(&more);
                        if acc.len() >= 256 * 1024 {
                            break;
                        }
                    }
                    _ => break, // timeout or channel closed
                }
            }
        }

        // 取证埋点（2026-09-06「连着却收不到数据」）：客户端侧只能看到"PTY
        // 停流 N 秒"，分不清是远端真的没输出，还是这里的 write_all 被 QUIC
        // 流控/拥塞窗口挂住了。write_all 挂起时没有任何日志痕迹 —— 上面
        // spawn_pty_forwarder 里那条注释怀疑过同一件事，但当时没取到证。
        //
        // 只在超阈值时打，正常路径一个字节的日志都不产生。
        let write_started = std::time::Instant::now();
        let write_len = acc.len();
        let write_res = write_pty_chunk(&mut writer, &acc, compression).await;
        let write_took = write_started.elapsed();
        if write_took >= std::time::Duration::from_secs(5) {
            log::warn!(
                "pty write_all stalled {:?} for {} bytes (QUIC flow-control or \
                 congestion window; client would see this as a PTY stall)",
                write_took,
                write_len
            );
        }
        if write_res.is_err() {
            break;
        }
    }
    let _ = writer.finish();
}

/// RESUME 负载里带多少字节的 primary 历史。
///
/// 按字节而不是行数封顶：行长差异极大（`seq` 每行几字节，`cat` 一个
/// minified JS 每行几万字节），按行数封顶时后者会把首屏撑爆，弱网下恢复
/// 直接慢一个量级。
///
/// 256 KiB 与客户端 `Terminal(maxLines: 3000)` 的容量大致相当（3000 行 × 80
/// 列渲染后约 240 KB），也就是说负载一次就把客户端**能显示的全部**带过去了。
/// 曾经有一条 `FetchScrollback` 通道让客户端再按需往上取，删掉了：它取回的
/// 那部分客户端本来也放不下，而它带来的前插链路是一整类竞态的来源。
const RESUME_HISTORY_BYTES: usize = 256 * 1024;

/// Spawn the PTY output forwarder. Sends `initial_bytes` (replay + ESC[0m on
/// the RESUME path; nothing on OPEN_TAB) first, then loops on `fwd_rx`.
fn spawn_pty_forwarder(
    pty_send: SendStream,
    fwd_rx: tokio::sync::mpsc::Receiver<Bytes>,
    initial_bytes: Vec<u8>,
    compression: bool,
) {
    tokio::spawn(async move {
        let mut ps = pty_send;
        if !initial_bytes.is_empty() {
            // 诊断埋点（非修复）：排查冷 RESUME watchdog 误杀连接的假设时发现，
            // "RESUME tab N replay XXXB" 那行日志是在这里（spawn 之前）打的，
            // 代表"打算发送多少"，不代表"发出去多少/花了多久"——write_all 在
            // 流量控制/拥塞窗口受限时可能长时间挂起而没有任何日志痕迹。这里
            // 记录实际 flush 耗时，下次复现可直接对比 replay 声明 vs 实际写完
            // 时间，判断 prelude 传输是否才是 41s 超时的真正瓶颈。
            let prelude_started = std::time::Instant::now();
            let prelude_len = initial_bytes.len();
            // Split initial_bytes into 1 MB chunks. The client rejects any
            // single LZ4 frame larger than 2 MB; a full 8 MB ring buffer
            // replay would exceed that limit and cause an immediate disconnect.
            // 1 MB chunks compress to well under 2 MB in all practical cases.
            const CHUNK: usize = 1024 * 1024; // 1 MB
            for slice in initial_bytes.chunks(CHUNK) {
                if write_pty_chunk(&mut ps, slice, compression).await.is_err() {
                    log::warn!(
                        "prelude write failed after {:?} (wanted {} bytes)",
                        prelude_started.elapsed(),
                        prelude_len
                    );
                    return;
                }
            }
            log::info!(
                "prelude flushed: {} bytes in {:?}",
                prelude_len,
                prelude_started.elapsed()
            );
        }
        drive_pty_forwarder(ps, fwd_rx, compression).await;
    });
}
