// SPDX-License-Identifier: GPL-3.0-or-later
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DecodeError {
    #[error("buffer too short: need {needed} bytes, have {have}")]
    Truncated { needed: usize, have: usize },
    #[error("invalid varint: value exceeds 62 bits")]
    VarintOverflow,
    #[error("invalid utf-8 in string field")]
    InvalidUtf8,
    #[error("unknown frame opcode: {0:#x}")]
    UnknownOpcode(u8),
    #[error("frame payload mismatch: declared len {declared} != actual {actual}")]
    LengthMismatch { declared: usize, actual: usize },
    #[error("invalid frame field: {0}")]
    InvalidField(&'static str),
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("invalid transition: state={state} cannot handle event={event}")]
    InvalidTransition {
        state: &'static str,
        event: &'static str,
    },
    #[error("session token mismatch")]
    SessionTokenMismatch,
    #[error("session expired")]
    SessionExpired,
}
