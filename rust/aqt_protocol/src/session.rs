// SPDX-License-Identifier: GPL-3.0-or-later
use crate::error::ProtocolError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Initial,
    Handshaking,
    Connected,
    Resuming,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    SendHello,
    RecvHelloAck,
    Disconnect,
    SendResume,
    RecvResumeAck,
    Close,
}

pub struct Session {
    state: State,
}

impl Session {
    pub fn new() -> Self {
        Self {
            state: State::Initial,
        }
    }
    pub fn state(&self) -> State {
        self.state
    }

    pub fn apply(&mut self, event: Event) -> Result<State, ProtocolError> {
        let next = match (self.state, event) {
            (State::Initial, Event::SendHello) => State::Handshaking,
            (State::Handshaking, Event::RecvHelloAck) => State::Connected,
            (State::Connected, Event::Disconnect) => State::Resuming,
            (State::Resuming, Event::SendResume) => State::Resuming, // idempotent
            (State::Resuming, Event::RecvResumeAck) => State::Connected,
            (_, Event::Close) => State::Closed,
            (state, event) => {
                return Err(ProtocolError::InvalidTransition {
                    state: state_name(state),
                    event: event_name(event),
                });
            }
        };
        self.state = next;
        Ok(next)
    }
}

impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}

fn state_name(s: State) -> &'static str {
    match s {
        State::Initial => "Initial",
        State::Handshaking => "Handshaking",
        State::Connected => "Connected",
        State::Resuming => "Resuming",
        State::Closed => "Closed",
    }
}

fn event_name(e: Event) -> &'static str {
    match e {
        Event::SendHello => "SendHello",
        Event::RecvHelloAck => "RecvHelloAck",
        Event::Disconnect => "Disconnect",
        Event::SendResume => "SendResume",
        Event::RecvResumeAck => "RecvResumeAck",
        Event::Close => "Close",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path() {
        let mut s = Session::new();
        assert_eq!(s.state(), State::Initial);
        s.apply(Event::SendHello).unwrap();
        assert_eq!(s.state(), State::Handshaking);
        s.apply(Event::RecvHelloAck).unwrap();
        assert_eq!(s.state(), State::Connected);
    }

    #[test]
    fn reconnect_path() {
        let mut s = Session::new();
        s.apply(Event::SendHello).unwrap();
        s.apply(Event::RecvHelloAck).unwrap();
        s.apply(Event::Disconnect).unwrap();
        assert_eq!(s.state(), State::Resuming);
        s.apply(Event::SendResume).unwrap(); // idempotent
        s.apply(Event::RecvResumeAck).unwrap();
        assert_eq!(s.state(), State::Connected);
    }

    #[test]
    fn close_from_any_state() {
        let mut s = Session::new();
        s.apply(Event::SendHello).unwrap();
        s.apply(Event::Close).unwrap();
        assert_eq!(s.state(), State::Closed);
    }

    #[test]
    fn invalid_transition_rejected() {
        let mut s = Session::new();
        assert!(matches!(
            s.apply(Event::Disconnect),
            Err(ProtocolError::InvalidTransition { .. })
        ));
        assert_eq!(s.state(), State::Initial);
    }

    #[test]
    fn cant_resurrect_from_closed() {
        let mut s = Session::new();
        s.apply(Event::Close).unwrap();
        assert!(matches!(
            s.apply(Event::SendHello),
            Err(ProtocolError::InvalidTransition { .. })
        ));
    }
}

// ===== TabOffsetTracker =====

use std::collections::HashMap;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TabOffsets {
    pub in_off: u64,
    pub out_off_rendered: u64,
}

#[derive(Debug, Default)]
pub struct TabOffsetTracker {
    tabs: HashMap<u32, TabOffsets>,
}

impl TabOffsetTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get_or_init(&mut self, tab_id: u32) -> &mut TabOffsets {
        self.tabs.entry(tab_id).or_default()
    }

    pub fn record_input_sent(&mut self, tab_id: u32, bytes: u64) {
        self.get_or_init(tab_id).in_off += bytes;
    }

    pub fn record_output_rendered(&mut self, tab_id: u32, bytes: u64) {
        self.get_or_init(tab_id).out_off_rendered += bytes;
    }

    pub fn snapshot(&self) -> Vec<(u32, TabOffsets)> {
        let mut v: Vec<_> = self.tabs.iter().map(|(k, v)| (*k, v.clone())).collect();
        v.sort_by_key(|(k, _)| *k);
        v
    }
}

#[cfg(test)]
mod tracker_tests {
    use super::*;

    #[test]
    fn record_and_snapshot() {
        let mut t = TabOffsetTracker::new();
        t.record_input_sent(1, 100);
        t.record_output_rendered(1, 4096);
        t.record_input_sent(2, 50);
        let snap = t.snapshot();
        assert_eq!(snap.len(), 2);
        assert_eq!(
            snap[0],
            (
                1,
                TabOffsets {
                    in_off: 100,
                    out_off_rendered: 4096
                }
            )
        );
        assert_eq!(
            snap[1],
            (
                2,
                TabOffsets {
                    in_off: 50,
                    out_off_rendered: 0
                }
            )
        );
    }

    #[test]
    fn incremental_recording() {
        let mut t = TabOffsetTracker::new();
        for _ in 0..5 {
            t.record_input_sent(1, 10);
        }
        assert_eq!(t.tabs[&1].in_off, 50);
    }
}

// ===== InputReplayBuffer =====

pub struct InputReplayBuffer {
    buf: Box<[u8]>,
    head_off: u64,
    tail_off: u64,
}

impl InputReplayBuffer {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0);
        Self {
            buf: vec![0u8; capacity].into_boxed_slice(),
            head_off: 0,
            tail_off: 0,
        }
    }

    pub fn append(&mut self, data: &[u8]) {
        let cap = self.buf.len();
        let data = if data.len() > cap {
            &data[data.len() - cap..]
        } else {
            data
        };
        let new_tail = self.tail_off + data.len() as u64;
        if new_tail - self.head_off > cap as u64 {
            self.head_off = new_tail - cap as u64;
        }
        let mut wpos = (self.tail_off % cap as u64) as usize;
        for &b in data {
            self.buf[wpos] = b;
            wpos = (wpos + 1) % cap;
        }
        self.tail_off = new_tail;
    }

    pub fn replay_from(&self, from_off: u64) -> Option<Vec<u8>> {
        if from_off < self.head_off {
            return None;
        }
        if from_off >= self.tail_off {
            return Some(Vec::new());
        }
        let cap = self.buf.len();
        let len = (self.tail_off - from_off) as usize;
        let phys_start = (from_off % cap as u64) as usize;
        let mut out = Vec::with_capacity(len);
        if phys_start + len <= cap {
            out.extend_from_slice(&self.buf[phys_start..phys_start + len]);
        } else {
            let first_chunk = cap - phys_start;
            out.extend_from_slice(&self.buf[phys_start..]);
            out.extend_from_slice(&self.buf[..len - first_chunk]);
        }
        Some(out)
    }
}

#[cfg(test)]
mod input_buffer_tests {
    use super::*;

    #[test]
    fn replay_full() {
        let mut b = InputReplayBuffer::new(1024);
        b.append(b"ls -la\n");
        b.append(b"echo hi\n");
        assert_eq!(b.replay_from(0).unwrap(), b"ls -la\necho hi\n");
    }

    #[test]
    fn replay_partial_from_offset() {
        let mut b = InputReplayBuffer::new(1024);
        b.append(b"abcdef");
        assert_eq!(b.replay_from(3).unwrap(), b"def");
    }

    #[test]
    fn replay_lost_when_overflowed() {
        let mut b = InputReplayBuffer::new(4);
        b.append(b"abcd");
        b.append(b"efgh"); // head=4
        assert!(b.replay_from(0).is_none());
        assert_eq!(b.replay_from(4).unwrap(), b"efgh");
    }

    #[test]
    fn replay_empty_when_caught_up() {
        let mut b = InputReplayBuffer::new(1024);
        b.append(b"hello");
        assert_eq!(b.replay_from(5).unwrap(), b"");
    }
}
