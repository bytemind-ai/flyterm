// SPDX-License-Identifier: GPL-3.0-or-later
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AqtError {
    Ok = 0,
    InvalidArg = -1,
    HandshakeFailed = -2,
    SpkiMismatch = -3,
    TokenInvalid = -4,
    NotConnected = -5,
    StreamClosed = -6,
    Panic = -7,
    Unknown = -99,
}

impl AqtError {
    pub fn as_i32(self) -> i32 {
        self as i32
    }
}
