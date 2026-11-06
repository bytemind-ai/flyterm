// SPDX-License-Identifier: GPL-3.0-or-later
use aqt_protocol::{
    encode_frame, Event, Hello, ScrollbackRing, Session, State, ALPN, PROTOCOL_VERSION,
};
use bytes::BytesMut;

#[test]
fn top_level_api_compiles_and_works() {
    assert_eq!(PROTOCOL_VERSION, 2);
    // ALPN 必须与 PROTOCOL_VERSION 同步 —— 它是唯一在 prewarm 直连 RESUME
    // 这条路上也生效的版本闸门（Resume 帧不带版本字段）。见 lib.rs 的说明。
    assert_eq!(ALPN, b"aqt/2");

    let mut buf = BytesMut::new();
    encode_frame(
        &Hello {
            version: PROTOCOL_VERSION,
            client_id: [0; 16],
            capabilities: 0,
        },
        &mut buf,
    )
    .unwrap();
    assert!(!buf.is_empty());

    let mut s = Session::new();
    s.apply(Event::SendHello).unwrap();
    assert_eq!(s.state(), State::Handshaking);

    let r = ScrollbackRing::new(64);
    assert_eq!(r.capacity(), 64);
}
