// SPDX-License-Identifier: GPL-3.0-or-later
//! Simulates client+server session using in-memory buffers.
//! Tests: handshake → I/O → disconnect → resume → reconnect (no real QUIC).

use aqt_protocol::frame::*;
use aqt_protocol::session::{Event, InputReplayBuffer, Session, State, TabOffsetTracker};
use bytes::BytesMut;

fn encode_to_bytes<P: FramePayload>(p: &P) -> bytes::Bytes {
    let mut buf = BytesMut::new();
    encode_frame(p, &mut buf).unwrap();
    buf.freeze()
}

#[test]
fn handshake_then_resume_flow() {
    let mut client = Session::new();
    let mut server = Session::new();
    let mut client_in_buf = InputReplayBuffer::new(1024);
    let mut client_tracker = TabOffsetTracker::new();

    // Handshake
    let hello_bytes = encode_to_bytes(&Hello {
        version: 1,
        client_id: [0x11; 16],
        capabilities: 0,
    });
    client.apply(Event::SendHello).unwrap();
    assert_eq!(client.state(), State::Handshaking);

    let mut b = hello_bytes;
    let (op, _) = decode_frame_header(&mut b).unwrap();
    assert_eq!(op, Opcode::Hello);
    Hello::decode(&mut b).unwrap();

    let ack_bytes = encode_to_bytes(&HelloAck {
        server_caps: 0,
        session_token: [0x77; 32],
    });
    server.apply(Event::SendHello).unwrap();
    server.apply(Event::RecvHelloAck).unwrap();
    assert_eq!(server.state(), State::Connected);

    let mut b = ack_bytes;
    decode_frame_header(&mut b).unwrap();
    let ack_dec = HelloAck::decode(&mut b).unwrap();
    assert_eq!(ack_dec.session_token, [0x77; 32]);
    client.apply(Event::RecvHelloAck).unwrap();
    assert_eq!(client.state(), State::Connected);

    // I/O simulation
    let user_input = b"echo hi\n";
    client_in_buf.append(user_input);
    client_tracker.record_input_sent(1, user_input.len() as u64);
    let pty_output = b"hi\n";
    client_tracker.record_output_rendered(1, pty_output.len() as u64);

    // Disconnect
    client.apply(Event::Disconnect).unwrap();
    assert_eq!(client.state(), State::Resuming);

    // Resume —— 客户端只报「我是谁、我要哪些 tab」，不报任何位置。
    //
    // 这里曾经发 last_out_off / last_in_off / ring_tail_hash 三个字段，
    // 由客户端从自己的 tracker 里算出来。那正是「六个发起点各算一份、
    // 分裂成三个世代」的源头，整组删掉了。
    let snapshot = client_tracker.snapshot();
    let (tab_id, offsets) = snapshot[0].clone();
    // tracker 仍然记录输入位置 —— 重发未送达的按键要用（见下）。
    assert_eq!(offsets.in_off, 8); // "echo hi\n"

    let resume = Resume {
        session_token: [0x77; 32],
        tabs: vec![tab_id],
    };
    let resume_bytes = encode_to_bytes(&resume);

    let mut b = resume_bytes;
    decode_frame_header(&mut b).unwrap();
    let r = Resume::decode(&mut b).unwrap();
    assert_eq!(r.tabs, vec![tab_id]);

    // 服务端回一份自足的屏幕快照 + 它自己那侧的输入进度。
    let resume_ack = ResumeAck {
        tabs: vec![ResumeAckTab {
            tab_id,
            new_pty_stream_id: 4096,
            disposition: Disposition::Restored {
                server_in_seen_off: 8,
            },
        }],
        compression_enabled: false,
        session_ttl_secs: 604_800,
        prelude_lens: Vec::new(),
    };
    let ack_bytes = encode_to_bytes(&resume_ack);
    let mut b = ack_bytes;
    decode_frame_header(&mut b).unwrap();
    let ack_dec = ResumeAck::decode(&mut b).unwrap();

    let Disposition::Restored {
        server_in_seen_off, ..
    } = &ack_dec.tabs[0].disposition
    else {
        panic!("期望 Restored，实际 {:?}", ack_dec.tabs[0].disposition);
    };
    // 恢复内容不在这个帧里 —— 它是新 PTY 流的头几个字节，由
    // flyterm-server/tests/resume_idempotence_e2e.rs 端到端验证。
    assert_eq!(*server_in_seen_off, 8);

    // 输入方向的重放照常工作 —— 这一条是回归防线：输出 offset 删干净了，
    // 但用户敲下的键不能跟着一起丢。
    let to_resend = client_in_buf.replay_from(*server_in_seen_off).unwrap();
    assert_eq!(to_resend, b""); // 服务端已收全，没有要补的

    client.apply(Event::SendResume).unwrap();
    client.apply(Event::RecvResumeAck).unwrap();
    assert_eq!(client.state(), State::Connected);
}

#[test]
fn unacked_input_is_resent_after_resume() {
    // 断线瞬间敲的键：服务端只收到前 4 字节，重连后必须补发剩下的。
    let mut buf = InputReplayBuffer::new(1024);
    buf.append(b"echo hi\n");

    let ack = ResumeAck {
        tabs: vec![ResumeAckTab {
            tab_id: 1,
            new_pty_stream_id: 8,
            disposition: Disposition::Restored {
                server_in_seen_off: 4, // 只收到 "echo"
            },
        }],
        compression_enabled: false,
        session_ttl_secs: 60,
        prelude_lens: Vec::new(),
    };
    let Disposition::Restored {
        server_in_seen_off, ..
    } = &ack.tabs[0].disposition
    else {
        unreachable!()
    };
    assert_eq!(buf.replay_from(*server_in_seen_off).unwrap(), b" hi\n");
}

// `resume_with_lost_output_partial_slice` 随 byte-offset ring 一起删除：
// scrollback 改走 FetchScrollback 的行号通道，「offset 滚出窗口」这个
// 概念不再存在（请求已淘汰的行号返回空页，不是 Partial）。
