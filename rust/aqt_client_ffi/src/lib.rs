// SPDX-License-Identifier: GPL-3.0-or-later
//! aqt_client_ffi: dart:ffi-compatible cdylib for FlyTerm QUIC client.
//!
//! All extern "C" entry points are panic-safe (catch_unwind) and return
//! i32 error codes. Pointer lifetimes documented per function.

pub mod client;
pub mod error;
#[allow(unsafe_code)]
pub mod ffi;
pub mod handle;
pub mod routed_socket;
pub mod runtime;
pub mod session;
