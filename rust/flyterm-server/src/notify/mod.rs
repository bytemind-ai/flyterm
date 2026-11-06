// SPDX-License-Identifier: GPL-3.0-or-later
pub mod listener;
pub mod queue;
pub mod text;

pub use queue::{NotifyQueue, MAX_QUEUED_EVENTS};
pub use text::sanitize_notify_text;
