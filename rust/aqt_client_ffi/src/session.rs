// SPDX-License-Identifier: GPL-3.0-or-later
use crate::handle::{AqtEvent, ConnState};
use aqt_protocol::InputReplayBuffer;
use std::collections::HashMap;
use std::net::SocketAddr;
use tokio::sync::mpsc;

pub const INPUT_BUFFER_SIZE: usize = 64 * 1024;

pub struct SessionState {
    pub conn: Option<quinn::Connection>,
    pub server_addr: SocketAddr,
    pub expected_spki: Vec<u8>,
    pub session_token: [u8; 32],
    pub sni: String,
    pub tabs: HashMap<u32, TabState>,
    pub event_tx: mpsc::UnboundedSender<AqtEvent>,
    pub conn_state: ConnState,
}

pub struct TabState {
    pub tab_id: u32,
    pub input_buf: InputReplayBuffer,
    pub out_offset_rendered: u64,
}

impl TabState {
    pub fn new(tab_id: u32) -> Self {
        Self {
            tab_id,
            input_buf: InputReplayBuffer::new(INPUT_BUFFER_SIZE),
            out_offset_rendered: 0,
        }
    }
}
