// SPDX-License-Identifier: GPL-3.0-or-later
//! `RoutedSocket`: a quinn `AsyncUdpSocket` that keeps QUIC pointed at one
//! fixed *virtual* peer (`127.0.0.2:<daemon_port>`) while the real UDP
//! destination can be switched at runtime (server UDP port <-> local
//! SSH-relay port). Outgoing datagrams addressed to the virtual peer are sent
//! to the current target; incoming datagrams from the current or previous
//! target are reported as coming from the virtual peer, anything else is
//! neutralised (`meta.len = 0`).

use std::fmt;
use std::io::{self, IoSliceMut};
use std::net::{Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use quinn::udp::{RecvMeta, Transmit};
use quinn::{AsyncUdpSocket, UdpPoller};

#[derive(Debug, Clone, Copy)]
struct Route {
    current: SocketAddr,
    previous: Option<SocketAddr>,
    /// Datagrams received from `current` since the last `set_target`.
    /// Packets from `previous` are accepted but not counted, so a switch is
    /// only confirmed by traffic that really came over the new route.
    rx_current: u64,
}

pub struct RoutedSocket {
    inner: Arc<dyn AsyncUdpSocket>,
    route: Mutex<Route>,
    virtual_peer: SocketAddr,
}

impl fmt::Debug for RoutedSocket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RoutedSocket")
            .field("route", &self.route)
            .field("virtual_peer", &self.virtual_peer)
            .finish()
    }
}

/// Map a datagram's real source to the virtual peer. `None` = stranger.
pub(crate) fn map_source(
    from: SocketAddr,
    current: SocketAddr,
    previous: Option<SocketAddr>,
    virtual_peer: SocketAddr,
) -> Option<SocketAddr> {
    if from == current || previous == Some(from) {
        Some(virtual_peer)
    } else {
        None
    }
}

impl RoutedSocket {
    pub fn new(
        socket: std::net::UdpSocket,
        target: SocketAddr,
        daemon_port: u16,
    ) -> io::Result<Arc<RoutedSocket>> {
        Self::wrap(
            socket,
            Route {
                current: target,
                previous: None,
                rx_current: 0,
            },
            daemon_port,
        )
    }

    fn wrap(
        socket: std::net::UdpSocket,
        route: Route,
        daemon_port: u16,
    ) -> io::Result<Arc<RoutedSocket>> {
        let runtime =
            quinn::default_runtime().ok_or_else(|| io::Error::other("no async runtime found"))?;
        Ok(Arc::new(RoutedSocket {
            inner: runtime.wrap_udp_socket(socket)?,
            route: Mutex::new(route),
            virtual_peer: SocketAddr::new(Ipv4Addr::new(127, 0, 0, 2).into(), daemon_port),
        }))
    }

    pub fn virtual_peer(&self) -> SocketAddr {
        self.virtual_peer
    }

    pub fn set_target(&self, addr: SocketAddr) {
        let mut r = self.route.lock().unwrap();
        r.previous = Some(r.current);
        r.current = addr;
        r.rx_current = 0;
    }

    /// Datagrams received from the current target since the last
    /// [`set_target`](Self::set_target).
    pub fn rx_from_current(&self) -> u64 {
        self.route.lock().unwrap().rx_current
    }

    pub fn target(&self) -> SocketAddr {
        self.route.lock().unwrap().current
    }

    /// New socket bound to `0.0.0.0:0` inheriting the current route (rebind).
    pub fn with_fresh_socket(&self) -> io::Result<Arc<RoutedSocket>> {
        let socket = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
        let route = *self.route.lock().unwrap();
        Self::wrap(socket, route, self.virtual_peer.port())
    }
}

impl AsyncUdpSocket for RoutedSocket {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        self.inner.clone().create_io_poller()
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        if transmit.destination != self.virtual_peer {
            return self.inner.try_send(transmit);
        }
        let routed = Transmit {
            destination: self.target(),
            ecn: transmit.ecn,
            contents: transmit.contents,
            segment_size: transmit.segment_size,
            src_ip: transmit.src_ip,
        };
        self.inner.try_send(&routed)
    }

    fn poll_recv(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        let n = match self.inner.poll_recv(cx, bufs, meta) {
            Poll::Ready(Ok(n)) => n,
            other => return other,
        };
        // Classify and count under the lock so a concurrent set_target
        // cannot reset the counter between the two.
        let mut route = self.route.lock().unwrap();
        for m in meta.iter_mut().take(n) {
            let from_current = m.addr == route.current;
            match map_source(m.addr, route.current, route.previous, self.virtual_peer) {
                Some(vp) => {
                    if from_current && m.len > 0 {
                        route.rx_current += 1;
                    }
                    m.addr = vp;
                }
                None => m.len = 0,
            }
        }
        drop(route);
        Poll::Ready(Ok(n))
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner.local_addr()
    }

    fn max_transmit_segments(&self) -> usize {
        self.inner.max_transmit_segments()
    }

    fn max_receive_segments(&self) -> usize {
        self.inner.max_receive_segments()
    }

    fn may_fragment(&self) -> bool {
        self.inner.may_fragment()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::UdpSocket;
    use std::time::Duration;

    fn sa(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    fn peer() -> (UdpSocket, SocketAddr) {
        let s = UdpSocket::bind("127.0.0.1:0").unwrap();
        s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let a = s.local_addr().unwrap();
        (s, a)
    }

    fn routed(target: SocketAddr) -> (Arc<RoutedSocket>, SocketAddr) {
        let s = UdpSocket::bind("127.0.0.1:0").unwrap();
        let addr = s.local_addr().unwrap();
        (RoutedSocket::new(s, target, 4433).unwrap(), addr)
    }

    /// Collect `want` entries from poll_recv as (addr, len).
    async fn recv_entries(r: &RoutedSocket, want: usize) -> Vec<(SocketAddr, usize)> {
        let mut out = Vec::new();
        let mut storage = vec![[0u8; 2048]; 8];
        while out.len() < want {
            let mut bufs: Vec<IoSliceMut<'_>> =
                storage.iter_mut().map(|b| IoSliceMut::new(b)).collect();
            let mut meta = vec![RecvMeta::default(); 8];
            let n = tokio::time::timeout(
                Duration::from_secs(2),
                std::future::poll_fn(|cx| r.poll_recv(cx, &mut bufs, &mut meta)),
            )
            .await
            .expect("recv timed out")
            .unwrap();
            out.extend(meta.iter().take(n).map(|m| (m.addr, m.len)));
        }
        out
    }

    #[test]
    fn map_source_rewrites_current_and_previous() {
        let (cur, prev, stranger, vp) = (
            sa("10.0.0.1:1000"),
            sa("10.0.0.2:2000"),
            sa("10.0.0.3:3000"),
            sa("127.0.0.2:4433"),
        );
        assert_eq!(map_source(cur, cur, Some(prev), vp), Some(vp));
        assert_eq!(map_source(prev, cur, Some(prev), vp), Some(vp));
        assert_eq!(map_source(stranger, cur, Some(prev), vp), None);
    }

    #[tokio::test]
    async fn routed_accepts_previous_target_after_switch() {
        let (a, a_addr) = peer();
        let (b, b_addr) = peer();
        let (r, r_addr) = routed(a_addr);
        r.set_target(b_addr);
        a.send_to(b"a", r_addr).unwrap();
        b.send_to(b"b", r_addr).unwrap();
        let got = recv_entries(&r, 2).await;
        assert_eq!(got.len(), 2);
        for (addr, len) in got {
            assert_eq!(addr, r.virtual_peer());
            assert_eq!(addr, sa("127.0.0.2:4433"));
            assert_eq!(len, 1);
        }
    }

    #[tokio::test]
    async fn routed_send_goes_to_current_target() {
        let (a, a_addr) = peer();
        let (b, b_addr) = peer();
        let (r, _) = routed(a_addr);
        // tokio's try_send needs writable readiness to have been polled first.
        let mut poller = r.clone().create_io_poller();
        let send = |payload: &'static [u8]| {
            r.try_send(&Transmit {
                destination: r.virtual_peer(),
                ecn: None,
                contents: payload,
                segment_size: None,
                src_ip: None,
            })
            .unwrap()
        };
        let mut buf = [0u8; 16];
        std::future::poll_fn(|cx| poller.as_mut().poll_writable(cx))
            .await
            .unwrap();
        send(b"one");
        let n = a.recv(&mut buf).unwrap();
        assert_eq!(&buf[..n], b"one");
        r.set_target(b_addr);
        std::future::poll_fn(|cx| poller.as_mut().poll_writable(cx))
            .await
            .unwrap();
        send(b"two");
        let n = b.recv(&mut buf).unwrap();
        assert_eq!(&buf[..n], b"two");
    }

    #[tokio::test]
    async fn routed_drops_stranger() {
        let (_a, a_addr) = peer();
        let (c, _) = peer();
        let (r, r_addr) = routed(a_addr);
        c.send_to(b"x", r_addr).unwrap();
        let got = recv_entries(&r, 1).await;
        assert_eq!(got[0].1, 0);
    }

    #[tokio::test]
    async fn rx_from_current_counts_only_current_and_resets_on_switch() {
        let (a, a_addr) = peer();
        let (b, b_addr) = peer();
        let (r, r_addr) = routed(a_addr);
        a.send_to(b"a", r_addr).unwrap();
        recv_entries(&r, 1).await;
        assert_eq!(r.rx_from_current(), 1);

        r.set_target(b_addr);
        assert_eq!(r.rx_from_current(), 0, "set_target resets the counter");
        // A is now `previous`: still accepted, but not counted.
        a.send_to(b"a", r_addr).unwrap();
        recv_entries(&r, 1).await;
        assert_eq!(r.rx_from_current(), 0);
        b.send_to(b"b", r_addr).unwrap();
        recv_entries(&r, 1).await;
        assert_eq!(r.rx_from_current(), 1);

        r.set_target(a_addr);
        assert_eq!(r.rx_from_current(), 0, "reset again on the next switch");
    }
}
