// SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::VecDeque;

use aqt_protocol::frame::Notify;

use super::sanitize_notify_text;

/// 队列上限。满了丢最旧的——最新事件比最旧的更相关。
pub const MAX_QUEUED_EVENTS: usize = 50;

/// 事件保活时长。超过这个时间还没投出去的，投出去也没意义了。
pub const EVENT_TTL_MS: u64 = 24 * 3600 * 1000;

/// 单个 session 的待投递通知队列。
///
/// 存在的理由是"app 没连着的时候恰恰最该通知"（手机睡着、网断了）。
/// 事件在这里排队，客户端 RESUME 时按 last_event_id 补发。
///
/// # 不变式：必须与 session 同生共死
///
/// 一个 `NotifyQueue` 实例必须与它所属的 session 同生共死——绝不可在会话
/// 存活期内被重建，也不可跨 session 复用。`ack()` 收到一个超出队列范围的
/// `last_event_id` 会直接清空整个队列（见 `ack_beyond_head_is_harmless`），
/// 这条行为的安全性完全建立在"进程重启后 `next_id` 会连同 session_token
/// 一起归零，客户端此时必然走冷启动 HELLO 而非带着旧 `last_event_id` 的
/// RESUME"这个前提上。一旦这个前提被破坏——队列在同一 session 存活期内被
/// 重建，或者被另一个 session 复用——`next_id` 会重置回 0，但客户端手里
/// 还攥着上一代队列分配的高位 `last_event_id`；它下一次发来的那个本该
/// 过期的 NotifyAck 会被当成合法 ack 收下，把新队列里刚产生、客户端还
/// 没读到的事件一次性清空，通知就这样在客户端毫无察觉的情况下丢了。
#[derive(Debug, Default)]
pub struct NotifyQueue {
    events: VecDeque<Notify>,
    next_id: u64,
}

impl NotifyQueue {
    pub fn new() -> Self {
        Self {
            events: VecDeque::new(),
            next_id: 0,
        }
    }

    /// 入队一条事件，返回分配的 event_id。文本在这里消毒，调用方不必先处理。
    pub fn push(&mut self, text: String, tab_id: Option<u32>, now_ms: u64) -> u64 {
        self.drop_expired(now_ms);
        self.next_id += 1;
        let id = self.next_id;
        self.events.push_back(Notify {
            event_id: id,
            ts_unix_ms: now_ms,
            text: sanitize_notify_text(&text),
            tab_id,
        });
        while self.events.len() > MAX_QUEUED_EVENTS {
            self.events.pop_front();
        }
        id
    }

    /// 客户端 last_event_id 之后、且尚未过期的未读事件。
    ///
    /// 只读不删：过期事件在被真正 push 或 ack 触发清理之前会一直滞留在
    /// 内存里（队列上限只有 50 条，这点内存不值一提），但绝不会被这个
    /// 方法投递出去——纯读不写的 session（一整夜没有新事件）同样要遵守
    /// 24h TTL 的承诺，不能只指望下一次 push 来清理。
    pub fn unread_since(&self, last_event_id: u64, now_ms: u64) -> Vec<Notify> {
        self.events
            .iter()
            .filter(|e| e.event_id > last_event_id && !Self::is_expired(e.ts_unix_ms, now_ms))
            .cloned()
            .collect()
    }

    /// 客户端确认已消费到 last_event_id，裁掉这之前的。
    pub fn ack(&mut self, last_event_id: u64) {
        self.events.retain(|e| e.event_id > last_event_id);
    }

    /// 队列里的**物理**条数，不是"还会投递多少条"。
    ///
    /// `unread_since` 只过滤过期事件、不删除它们，所以逻辑上已过期但还没被
    /// 下一次 `push`/`ack` 物理清掉的条目仍然计入。这个不一致只朝一个方向
    /// 说谎：可能多算，绝不会少算。因此拿 `is_empty()` 当"跳过本次轮询"的
    /// 快速判断是安全的（最坏多跑一次空的 `unread_since`），但别拿 `len()`
    /// 当待投递计数去做别的决策。
    pub fn len(&self) -> usize {
        self.events.len()
    }

    /// 见 [`Self::len`]：同样是物理判断，可能把已过期未清理的条目算进去。
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    /// 单一事实来源：`push` 的主动清理和 `unread_since` 的读路径过滤必须
    /// 用同一条判定规则，否则两处的 TTL 语义迟早会飘。
    fn is_expired(ts_unix_ms: u64, now_ms: u64) -> bool {
        ts_unix_ms < now_ms.saturating_sub(EVENT_TTL_MS)
    }

    fn drop_expired(&mut self, now_ms: u64) {
        self.events
            .retain(|e| !Self::is_expired(e.ts_unix_ms, now_ms));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: u64 = 1_755_300_000_000;

    #[test]
    fn push_assigns_monotonic_ids_starting_at_1() {
        let mut q = NotifyQueue::new();
        assert_eq!(q.push("a".into(), None, T0), 1);
        assert_eq!(q.push("b".into(), None, T0), 2);
    }

    #[test]
    fn unread_since_returns_only_newer_events() {
        let mut q = NotifyQueue::new();
        q.push("a".into(), None, T0);
        q.push("b".into(), Some(3), T0);
        let unread = q.unread_since(1, T0);
        assert_eq!(unread.len(), 1);
        assert_eq!(unread[0].event_id, 2);
        assert_eq!(unread[0].tab_id, Some(3));
    }

    #[test]
    fn unread_since_zero_returns_everything() {
        let mut q = NotifyQueue::new();
        q.push("a".into(), None, T0);
        q.push("b".into(), None, T0);
        assert_eq!(q.unread_since(0, T0).len(), 2);
    }

    #[test]
    fn ack_trims_consumed_events() {
        let mut q = NotifyQueue::new();
        q.push("a".into(), None, T0);
        q.push("b".into(), None, T0);
        q.ack(1);
        assert_eq!(q.len(), 1);
        assert_eq!(q.unread_since(0, T0).len(), 1, "被 ack 的不该再补投");
    }

    #[test]
    fn ack_beyond_head_is_harmless() {
        // 客户端可能 ack 一个比队列里最大 id 还大的值（服务端重启后 id 重置）。
        let mut q = NotifyQueue::new();
        q.push("a".into(), None, T0);
        q.ack(999);
        assert_eq!(q.len(), 0);
    }

    #[test]
    fn ack_zero_retains_everything() {
        // 边界：last_event_id=0 意味着"什么都还没确认"，不该裁掉任何事件。
        let mut q = NotifyQueue::new();
        q.push("a".into(), None, T0);
        q.push("b".into(), None, T0);
        q.ack(0);
        assert_eq!(q.len(), 2);
    }

    #[test]
    fn evicts_oldest_when_full() {
        let mut q = NotifyQueue::new();
        for i in 0..(MAX_QUEUED_EVENTS + 10) {
            q.push(format!("e{i}"), None, T0);
        }
        assert_eq!(q.len(), MAX_QUEUED_EVENTS);
        // 最新的必须还在——最新事件比最旧的更相关。
        let all = q.unread_since(0, T0);
        assert_eq!(
            all.last().unwrap().text,
            format!("e{}", MAX_QUEUED_EVENTS + 9)
        );
    }

    #[test]
    fn drops_events_older_than_ttl() {
        let mut q = NotifyQueue::new();
        q.push("old".into(), None, T0);
        // 25 小时后再 push，触发写路径的 TTL 清理。
        let later = T0 + 25 * 3600 * 1000;
        q.push("new".into(), None, later);
        let all = q.unread_since(0, later);
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].text, "new");
    }

    #[test]
    fn unread_since_filters_stale_events_without_any_new_push() {
        // 回归护栏：纯读不写的 session（一整夜没有新事件，用户睡了一觉）
        // 同样要遵守 TTL——不能只指望"下一次 push"来触发清理。
        let mut q = NotifyQueue::new();
        q.push("stale".into(), None, T0);
        let later = T0 + 25 * 3600 * 1000;
        assert_eq!(q.unread_since(0, later).len(), 0);
    }

    #[test]
    fn text_is_sanitized_on_push() {
        let mut q = NotifyQueue::new();
        q.push("a\x1bb".into(), None, T0);
        assert_eq!(q.unread_since(0, T0)[0].text, "a b");
    }
}
