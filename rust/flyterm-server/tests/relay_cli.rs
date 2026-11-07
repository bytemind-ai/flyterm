// SPDX-License-Identifier: GPL-3.0-or-later
//! The real binary's `--relay` wiring (main.rs): frames in on stdin come
//! back from a UDP echo on stdout, and closing stdin ends the process.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use flyterm_server::relay::{encode_frame, FrameDecoder};

#[test]
fn relay_binary_smoke() {
    let echo = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let port = echo.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let mut buf = [0u8; 2048];
        while let Ok((n, from)) = echo.recv_from(&mut buf) {
            let _ = echo.send_to(&buf[..n], from);
        }
    });

    let mut child = Command::new(env!("CARGO_BIN_EXE_flyterm-server"))
        .args(["--relay", &port.to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();

    stdin
        .write_all(&encode_frame(b"ping-through-relay"))
        .unwrap();
    stdin.flush().unwrap();
    let mut d = FrameDecoder::new();
    let mut buf = [0u8; 256];
    let mut got = Vec::new();
    while got.is_empty() {
        let n = stdout.read(&mut buf).unwrap();
        assert!(n > 0, "relay closed stdout before echoing");
        got.extend(d.push(&buf[..n]).unwrap());
    }
    assert_eq!(got, vec![b"ping-through-relay".to_vec()]);

    drop(stdin); // SSH channel closed
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "{status:?}");
            break;
        }
        assert!(Instant::now() < deadline, "relay did not exit on stdin EOF");
        std::thread::sleep(Duration::from_millis(20));
    }
}
