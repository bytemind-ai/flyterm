// SPDX-License-Identifier: GPL-3.0-or-later
use aqt_protocol::frame::*;
use bytes::{Buf, BytesMut};

#[test]
fn preload_history_spec_roundtrip_latest() {
    let spec = PreloadHistorySpec::LatestMatching {
        cmd: "claude code".into(),
    };
    let mut buf = BytesMut::new();
    spec.encode(&mut buf);
    let mut cursor = &buf[..];
    let decoded = PreloadHistorySpec::decode(&mut cursor).unwrap();
    assert_eq!(decoded, spec);
    assert!(cursor.is_empty());
}

#[test]
fn preload_history_spec_roundtrip_explicit() {
    let spec = PreloadHistorySpec::Explicit { history_id: 42 };
    let mut buf = BytesMut::new();
    spec.encode(&mut buf);
    let mut cursor = &buf[..];
    let decoded = PreloadHistorySpec::decode(&mut cursor).unwrap();
    assert_eq!(decoded, spec);
}

#[test]
fn preload_history_spec_unknown_tag_errors() {
    let buf = [0x99u8];
    let mut cursor = &buf[..];
    assert!(PreloadHistorySpec::decode(&mut cursor).is_err());
}

#[test]
fn multi_frame_stream() {
    let mut buf = BytesMut::new();

    encode_frame(
        &Hello {
            version: 1,
            client_id: [0x11; 16],
            capabilities: 0,
        },
        &mut buf,
    )
    .unwrap();
    encode_frame(
        &HelloAck {
            server_caps: 0,
            session_token: [0x22; 32],
        },
        &mut buf,
    )
    .unwrap();
    encode_frame(
        &OpenTab {
            cols: 80,
            rows: 24,
            term: "xterm".into(),
            cwd: "".into(),
            cmd: "".into(),
            preload_history: None,
        },
        &mut buf,
    )
    .unwrap();

    let mut b = buf.freeze();
    let mut opcodes = Vec::new();
    while b.remaining() > 0 {
        let (op, len) = decode_frame_header(&mut b).unwrap();
        let mut payload = b.split_to(len);
        opcodes.push(op);
        match op {
            Opcode::Hello => {
                Hello::decode(&mut payload).unwrap();
            }
            Opcode::HelloAck => {
                HelloAck::decode(&mut payload).unwrap();
            }
            Opcode::OpenTab => {
                OpenTab::decode(&mut payload).unwrap();
            }
            _ => panic!("unexpected opcode {op:?}"),
        }
    }
    assert_eq!(
        opcodes,
        vec![Opcode::Hello, Opcode::HelloAck, Opcode::OpenTab]
    );
}

#[test]
fn opcode_new_variants_roundtrip() {
    use aqt_protocol::frame::Opcode;
    assert_eq!(Opcode::try_from(0x40u8).unwrap(), Opcode::ListHistory);
    assert_eq!(Opcode::try_from(0x41u8).unwrap(), Opcode::ListHistoryResp);
    assert_eq!(
        Opcode::try_from(0x42u8).unwrap(),
        Opcode::HistoryPreloadDone
    );
    assert_eq!(Opcode::ListHistory as u8, 0x40);
    assert_eq!(Opcode::ListHistoryResp as u8, 0x41);
    assert_eq!(Opcode::HistoryPreloadDone as u8, 0x42);
}

#[test]
fn open_tab_roundtrip_with_preload() {
    use aqt_protocol::frame::{OpenTab, PreloadHistorySpec};
    let original = OpenTab {
        cols: 80,
        rows: 24,
        term: "xterm-256color".into(),
        cwd: "/home/user".into(),
        cmd: "claude code".into(),
        preload_history: Some(PreloadHistorySpec::LatestMatching {
            cmd: "claude code".into(),
        }),
    };
    let mut buf = bytes::BytesMut::new();
    original.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    let decoded = OpenTab::decode(&mut cursor).unwrap();
    assert_eq!(decoded, original);
}

#[test]
fn open_tab_roundtrip_without_preload_backcompat() {
    use aqt_protocol::frame::OpenTab;
    let original = OpenTab {
        cols: 80,
        rows: 24,
        term: "xterm-256color".into(),
        cwd: "/home/user".into(),
        cmd: "bash".into(),
        preload_history: None,
    };
    let mut buf = bytes::BytesMut::new();
    original.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    let decoded = OpenTab::decode(&mut cursor).unwrap();
    assert_eq!(decoded.preload_history, None);
    assert!(cursor.is_empty());
}

use aqt_protocol::frame::{HistoryPreloadDone, HistorySegmentMeta, ListHistory, ListHistoryResp};

#[test]
fn list_history_roundtrip() {
    let frame = ListHistory {
        command_hint: Some("claude".into()),
        limit: 50,
        before_ts: Some(1_700_000_000),
    };
    let mut buf = bytes::BytesMut::new();
    frame.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(ListHistory::decode(&mut cursor).unwrap(), frame);
}

#[test]
fn list_history_resp_roundtrip() {
    let frame = ListHistoryResp {
        segments: vec![HistorySegmentMeta {
            history_id: 1,
            command_hint: "claude".into(),
            started_at: 1_700_000_000,
            ended_at: 1_700_001_000,
            size_bytes: 4096,
            preview: "Human: hello".into(),
        }],
    };
    let mut buf = bytes::BytesMut::new();
    frame.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(ListHistoryResp::decode(&mut cursor).unwrap(), frame);
}

#[test]
fn history_preload_done_roundtrip() {
    let frame = HistoryPreloadDone {
        tab_id: 7,
        preloaded_bytes: 1_234_567,
        segments: vec![(42u64, 1_700_000_000u64, 1_700_001_000u64)],
    };
    let mut buf = bytes::BytesMut::new();
    frame.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(HistoryPreloadDone::decode(&mut cursor).unwrap(), frame);
}

// ===== Resume / ResumeAck 重新设计（2026-08-25）=====

#[test]
fn resume_carries_no_position_information() {
    // 这个测试的存在本身就是规格：Resume 里**没有** offset 字段。
    // 「六个发起点各算一份 offset、分裂成三个世代」那类 bug，靠的是
    // 「没有东西可分裂」来消除，而不是靠调用方自律。
    let f = Resume {
        session_token: [7u8; 32],
        tabs: vec![1, 2, 42],
    };
    let mut buf = BytesMut::new();
    f.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(Resume::decode(&mut cursor).unwrap(), f);
    assert!(cursor.is_empty());
}

#[test]
fn resume_ack_restored_roundtrip() {
    let f = ResumeAck {
        session_ttl_secs: 604_800,
        compression_enabled: true,
        tabs: vec![ResumeAckTab {
            tab_id: 3,
            new_pty_stream_id: 12,
            disposition: Disposition::Restored {
                server_in_seen_off: 4096,
            },
        }],
        prelude_lens: Vec::new(),
    };
    let mut buf = BytesMut::new();
    f.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(ResumeAck::decode(&mut cursor).unwrap(), f);
    assert!(cursor.is_empty());
}

#[test]
fn resume_ack_new_session_and_tab_gone_roundtrip() {
    let f = ResumeAck {
        session_ttl_secs: 3600,
        compression_enabled: false,
        tabs: vec![
            ResumeAckTab {
                tab_id: 1,
                new_pty_stream_id: 0,
                disposition: Disposition::NewSession,
            },
            ResumeAckTab {
                tab_id: 2,
                new_pty_stream_id: 0,
                disposition: Disposition::TabGone {
                    exit_status: Some(130),
                },
            },
            ResumeAckTab {
                tab_id: 3,
                new_pty_stream_id: 0,
                disposition: Disposition::TabGone { exit_status: None },
            },
        ],
        prelude_lens: Vec::new(),
    };
    let mut buf = BytesMut::new();
    f.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(ResumeAck::decode(&mut cursor).unwrap(), f);
    assert!(cursor.is_empty());
}

#[test]
fn resume_ack_handles_negative_exit_status() {
    // 被信号杀掉时退出码按惯例是负数或 128+n，i32 必须能原样往返。
    let f = ResumeAck {
        session_ttl_secs: 1,
        compression_enabled: false,
        tabs: vec![ResumeAckTab {
            tab_id: 1,
            new_pty_stream_id: 0,
            disposition: Disposition::TabGone {
                exit_status: Some(-9),
            },
        }],
        prelude_lens: Vec::new(),
    };
    let mut buf = BytesMut::new();
    f.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(ResumeAck::decode(&mut cursor).unwrap(), f);
}

#[test]
fn resume_ack_rejects_unknown_disposition_tag() {
    // 未知 tag 必须报错而不是猜 —— 猜出来的 disposition 会让客户端走错
    // 分支，而那正是这次重新设计要消除的那类问题（见 e382759）。
    use aqt_protocol::varint::encode_varint;
    use bytes::BufMut;
    let mut buf = BytesMut::new();
    encode_varint(1, &mut buf).unwrap(); // tabs.len()
    buf.put_u32(1); // tab_id
    encode_varint(0, &mut buf).unwrap(); // new_pty_stream_id
    buf.put_u8(0xEE); // 未知 disposition tag
    let mut cursor = &buf[..];
    assert!(ResumeAck::decode(&mut cursor).is_err());
}

#[test]
fn resume_ack_restored_with_zero_offsets_is_legal() {
    // 刚开的 tab 还没有任何输出 —— 各偏移为 0 不是错误。
    let f = ResumeAck {
        session_ttl_secs: 100,
        compression_enabled: false,
        tabs: vec![ResumeAckTab {
            tab_id: 1,
            new_pty_stream_id: 4,
            disposition: Disposition::Restored {
                server_in_seen_off: 0,
            },
        }],
        prelude_lens: Vec::new(),
    };
    let mut buf = BytesMut::new();
    f.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    assert_eq!(ResumeAck::decode(&mut cursor).unwrap(), f);
}

#[test]
fn restored_still_carries_input_side_offset() {
    // 输出方向的 offset 全删了，输入方向的**必须**留着。
    //
    // 两者性质不同：输出 offset 是客户端状态（「我读到哪了」，六个发起点
    // 各自算、无法单一真相）；输入 offset 是服务端状态（「我收到了多少」，
    // 只有一个来源）。删掉后者会让用户在断线那一刻敲的键静默丢失，而
    // InputReplayBuffer 正是靠它决定从哪里重发。
    let f = ResumeAck {
        session_ttl_secs: 604_800,
        compression_enabled: false,
        tabs: vec![ResumeAckTab {
            tab_id: 1,
            new_pty_stream_id: 9,
            disposition: Disposition::Restored {
                server_in_seen_off: 12_345,
            },
        }],
        prelude_lens: Vec::new(),
    };
    let mut buf = BytesMut::new();
    f.encode(&mut buf).unwrap();
    let mut cursor = &buf[..];
    let got = ResumeAck::decode(&mut cursor).unwrap();
    match &got.tabs[0].disposition {
        Disposition::Restored {
            server_in_seen_off, ..
        } => {
            assert_eq!(*server_in_seen_off, 12_345);
        }
        other => panic!("期望 Restored，实际 {other:?}"),
    }
}

/// 0x60 / 0x61 是删掉的 FetchScrollback / ScrollbackChunk。协议版本 2 起它们
/// 不再是合法 opcode —— 误连上来的旧客户端必须在这里就被明确拒掉，而不是被
/// 解成别的帧。
#[test]
fn retired_scrollback_opcodes_are_rejected() {
    assert!(Opcode::from_u8(0x60).is_err(), "0x60 不该再被接受");
    assert!(Opcode::from_u8(0x61).is_err(), "0x61 不该再被接受");
}

/// 版本必须是 2。锁住它是因为 `Disposition` 的线格式是位置式的：旧服务端会在
/// DISP_RESTORED 之后多发一个 u64（那是被删掉的 scrollback_head_line），新客户端
/// 会把它当 server_in_seen_off 静默读走。版本检查是唯一能挡住这个错解析的地方。
#[test]
fn protocol_version_is_two() {
    assert_eq!(aqt_protocol::PROTOCOL_VERSION, 2);
}
