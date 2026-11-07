// SPDX-License-Identifier: GPL-3.0-or-later
//! `flyterm-server --relay PORT`: QUIC over an SSH channel.
//!
//! When UDP to the daemon is blocked (only port 22 open, or the phone's
//! network drops UDP), the App runs this over an SSH exec channel and
//! tunnels the QUIC packets through it. Each packet travels as one frame,
//! `u16 big-endian length + bytes`; this process forwards frames from stdin
//! to the daemon at `127.0.0.1:PORT` and the daemon's replies back to
//! stdout. It is stateless: QUIC (TLS, streams, RESUME, Notify) runs end to
//! end through it, and the daemon just sees a local UDP peer.
//!
//! Exits when stdin reaches EOF, i.e. when the SSH channel closes.

use anyhow::Result;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::UdpSocket;

/// Largest packet a frame can carry (the `u16` length field).
pub const MAX_PACKET: usize = u16::MAX as usize;

/// Frames one packet. Callers never pass an empty or oversized packet: UDP
/// datagrams from quinn are 1..=MTU bytes.
pub fn encode_frame(packet: &[u8]) -> Vec<u8> {
    debug_assert!(!packet.is_empty() && packet.len() <= MAX_PACKET);
    let mut out = Vec::with_capacity(2 + packet.len());
    out.extend_from_slice(&(packet.len() as u16).to_be_bytes());
    out.extend_from_slice(packet);
    out
}

#[derive(Debug)]
pub struct FrameError(&'static str);

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "relay frame error: {}", self.0)
    }
}

impl std::error::Error for FrameError {}

/// Reassembles frames from arbitrarily split / coalesced byte chunks.
#[derive(Default)]
pub struct FrameDecoder {
    buf: Vec<u8>,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<Vec<u8>>, FrameError> {
        self.buf.extend_from_slice(chunk);
        let mut out = Vec::new();
        let mut at = 0;
        while self.buf.len() - at >= 2 {
            let len = u16::from_be_bytes([self.buf[at], self.buf[at + 1]]) as usize;
            if len == 0 {
                return Err(FrameError("zero-length frame"));
            }
            if self.buf.len() - at - 2 < len {
                break;
            }
            out.push(self.buf[at + 2..at + 2 + len].to_vec());
            at += 2 + len;
        }
        self.buf.drain(..at);
        Ok(out)
    }
}

/// Relays between [input]/[output] (the SSH channel) and the daemon's UDP
/// port. Returns `Ok` on input EOF, `Err` on a framing or I/O error.
pub async fn run<R, W>(daemon_port: u16, mut input: R, mut output: W) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let sock = UdpSocket::bind("127.0.0.1:0").await?;
    sock.connect(("127.0.0.1", daemon_port)).await?;
    let mut decoder = FrameDecoder::new();
    let mut inbuf = vec![0u8; 64 * 1024];
    let mut pkt = vec![0u8; MAX_PACKET];
    loop {
        tokio::select! {
            r = input.read(&mut inbuf) => {
                let n = r?;
                if n == 0 {
                    return Ok(());
                }
                for p in decoder.push(&inbuf[..n])? {
                    // A daemon that is down shows up as ECONNREFUSED here or
                    // on the next recv; QUIC on the App side times out and
                    // reconnects, so the relay just keeps going.
                    let _ = sock.send(&p).await;
                }
            }
            r = sock.recv(&mut pkt) => {
                match r {
                    Ok(0) => {}
                    Ok(n) => {
                        output.write_all(&encode_frame(&pkt[..n])).await?;
                        output.flush().await?;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {}
                    Err(e) => return Err(e.into()),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn frame_roundtrip() {
        assert_eq!(encode_frame(b"abc"), vec![0, 3, b'a', b'b', b'c']);
        let mut d = FrameDecoder::new();
        assert_eq!(
            d.push(&encode_frame(b"abc")).unwrap(),
            vec![b"abc".to_vec()]
        );
    }

    #[test]
    fn decoder_handles_split_and_coalesced() {
        let mut both = encode_frame(b"first");
        both.extend(encode_frame(b"second-packet"));
        for cut in 0..=both.len() {
            let mut d = FrameDecoder::new();
            let mut got = d.push(&both[..cut]).unwrap();
            got.extend(d.push(&both[cut..]).unwrap());
            assert_eq!(
                got,
                vec![b"first".to_vec(), b"second-packet".to_vec()],
                "cut={cut}"
            );
        }
    }

    #[test]
    fn decoder_rejects_zero_length() {
        assert!(FrameDecoder::new().push(&[0, 0]).is_err());
    }

    /// stdin 写两帧后关闭：两帧都被转发到 UDP 对端并原样回显到 stdout，
    /// 然后 `run` 因 stdin EOF 返回 Ok —— SSH 通道关闭时 relay 必须退出。
    #[tokio::test]
    async fn relay_exits_on_stdin_eof() {
        let echo = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = echo.local_addr().unwrap().port();
        tokio::spawn(async move {
            let mut buf = [0u8; 2048];
            loop {
                let (n, from) = echo.recv_from(&mut buf).await.unwrap();
                echo.send_to(&buf[..n], from).await.unwrap();
            }
        });

        let (mut feed, input) = tokio::io::duplex(4096);
        let (output, mut sink) = tokio::io::duplex(4096);
        let relay = tokio::spawn(run(port, input, output));

        feed.write_all(&encode_frame(b"one")).await.unwrap();
        feed.write_all(&encode_frame(b"two")).await.unwrap();
        let mut d = FrameDecoder::new();
        let mut got = Vec::new();
        let mut buf = [0u8; 256];
        while got.len() < 2 {
            let n = tokio::time::timeout(std::time::Duration::from_secs(2), sink.read(&mut buf))
                .await
                .expect("echo frames")
                .unwrap();
            got.extend(d.push(&buf[..n]).unwrap());
        }
        assert_eq!(got, vec![b"one".to_vec(), b"two".to_vec()]);

        drop(feed); // stdin EOF
        let res = tokio::time::timeout(std::time::Duration::from_secs(2), relay)
            .await
            .expect("relay must exit on stdin EOF")
            .unwrap();
        assert!(res.is_ok(), "{res:?}");
    }
}
