// SPDX-License-Identifier: GPL-3.0-or-later
//! Integration tests for the AI history preload feature.
//!
//! Tests verify: log history -> call replay_for -> bytes contain content + separator.
//! The full network-level wiring (open_tab with preload) is covered by T25.
//!
//! **整文件挂在 `history` feature 下**：`flyterm_server::history` 模块本身就在
//! `#[cfg(feature = "history")]` 里，feature 关掉时这些 `use` 直接解析不到，
//! 编译失败。而 feature 默认是关的（APK 分发的 binary 不带它），于是这个
//! 测试文件曾经让 `cargo test` 在默认配置下根本跑不起来 —— 连带把同一次
//! 编译里的其它集成测试也拖下水。
//!
//! gate 在**模块级**而不是每个 `#[test]` 上：整文件的依赖面完全落在 feature
//! 内，逐个标注只会重复二十遍同一个条件。
#![cfg(feature = "history")]

#[cfg(test)]
mod tests {
    use aqt_protocol::frame::PreloadHistorySpec;
    use flyterm_server::history::{
        logger::HistoryLogger,
        replay::{replay_for, ReplayResult},
        store::HistoryStore,
    };
    use std::sync::Arc;

    #[test]
    fn replay_for_returns_bytes_with_separator() {
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());

        let mut log = HistoryLogger::new(
            dir.path().to_path_buf(),
            store.clone(),
            "test-user".into(),
            "claude".into(),
            1,
            1024 * 1024,
        )
        .unwrap();
        log.append(b"AI-OUTPUT-MARKER\r\n").unwrap();
        log.flush_finalize().unwrap();

        let result = replay_for(
            &store,
            "test-user",
            24,
            80,
            &PreloadHistorySpec::LatestMatching {
                cmd: "claude".into(),
            },
        )
        .unwrap();

        assert!(result.is_some(), "should find a matching session");
        let r: ReplayResult = result.unwrap();
        let s = String::from_utf8_lossy(&r.bytes);
        assert!(
            s.contains("AI-OUTPUT-MARKER"),
            "expected AI-OUTPUT-MARKER in bytes: {:?}",
            s
        );
        assert!(
            s.contains("new session"),
            "expected separator in bytes: {:?}",
            s
        );
        assert!(!r.segments.is_empty(), "segments should be non-empty");
    }

    #[test]
    fn replay_for_no_match_returns_none() {
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());

        let result = replay_for(
            &store,
            "test-user",
            24,
            80,
            &PreloadHistorySpec::LatestMatching {
                cmd: "nonexistent-cmd".into(),
            },
        )
        .unwrap();
        assert!(result.is_none(), "should return None for unknown cmd");
    }

    /// Verify that the unbounded mpsc channel used as the upstream keystroke
    /// buffer accumulates bytes sent before the consumer starts and delivers
    /// them in order.  This is a unit-level proof-of-mechanism for the
    /// buffering approach in `handle_open_tab`.
    #[test]
    fn upstream_bytes_buffered_during_preload_get_forwarded() {
        use tokio::sync::mpsc;

        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (buf_tx, mut buf_rx) = mpsc::unbounded_channel::<Vec<u8>>();

            // Simulate upstream bytes arriving during the preload window.
            buf_tx.send(b"ls\n".to_vec()).unwrap();
            buf_tx.send(b"pwd\n".to_vec()).unwrap();

            // Signal end-of-preload by dropping the sender.
            drop(buf_tx);

            // Drain the buffer — must deliver all bytes in order.
            let mut collected = Vec::new();
            while let Some(chunk) = buf_rx.recv().await {
                collected.extend_from_slice(&chunk);
            }

            assert_eq!(collected, b"ls\npwd\n");
        });
    }

    #[test]
    fn replay_result_segments_have_correct_shape() {
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());

        let mut log = HistoryLogger::new(
            dir.path().to_path_buf(),
            store.clone(),
            "user2".into(),
            "htop".into(),
            42,
            1024 * 1024,
        )
        .unwrap();
        log.append(b"htop-output\r\n").unwrap();
        log.flush_finalize().unwrap();

        let r = replay_for(
            &store,
            "user2",
            24,
            80,
            &PreloadHistorySpec::LatestMatching { cmd: "htop".into() },
        )
        .unwrap()
        .unwrap();

        // Each segment is (history_id, started_at, ended_at)
        assert_eq!(r.segments.len(), 1);
        let (id, started, ended) = r.segments[0];
        assert!(id > 0, "history_id should be > 0");
        assert!(started > 0, "started_at should be a unix timestamp");
        assert!(ended >= started, "ended_at should be >= started_at");
    }

    #[test]
    fn replay_includes_separator_line_bytes() {
        // The separator "─── new session ───" must appear in replay output
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());

        let mut log = HistoryLogger::new(
            dir.path().to_path_buf(),
            store.clone(),
            "user".into(),
            "claude".into(),
            1,
            1024 * 1024,
        )
        .unwrap();
        log.append(b"session content\r\n").unwrap();
        log.flush_finalize().unwrap();

        let result = replay_for(
            &store,
            "user",
            24,
            80,
            &PreloadHistorySpec::LatestMatching {
                cmd: "claude".into(),
            },
        )
        .unwrap()
        .unwrap();

        let s = String::from_utf8_lossy(&result.bytes);
        // Separator bytes: "─── new session ───" (UTF-8 box drawing chars)
        assert!(
            s.contains("new session"),
            "separator missing in output: {:?}",
            s
        );
        // Output should NOT contain raw cursor-control escape sequences
        assert!(
            !result.bytes.windows(4).any(|w| w == b"\x1b[2J"),
            "raw clear-screen should not appear in rendered output"
        );
    }

    #[test]
    fn replay_isolates_by_session_key() {
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());

        // Write history for two different users
        for (user, content, tab_id) in [
            ("alice", b"alice-content\r\n" as &[u8], 1u32),
            ("bob", b"bob-content\r\n", 2),
        ] {
            let mut log = HistoryLogger::new(
                dir.path().to_path_buf(),
                store.clone(),
                user.into(),
                "claude".into(),
                tab_id,
                1024 * 1024,
            )
            .unwrap();
            log.append(content).unwrap();
            log.flush_finalize().unwrap();
        }

        // Alice should only see her content
        let alice_result = replay_for(
            &store,
            "alice",
            24,
            80,
            &PreloadHistorySpec::LatestMatching {
                cmd: "claude".into(),
            },
        )
        .unwrap()
        .unwrap();
        let alice_s = String::from_utf8_lossy(&alice_result.bytes);
        assert!(
            alice_s.contains("alice-content"),
            "alice missing: {:?}",
            alice_s
        );
        assert!(
            !alice_s.contains("bob-content"),
            "alice should not see bob: {:?}",
            alice_s
        );
    }

    #[test]
    fn replay_explicit_history_id_returns_specific_segment() {
        let dir = tempfile::TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());

        // Create two segments
        for (content, tab_id) in [
            (b"first-segment\r\n" as &[u8], 1u32),
            (b"second-segment\r\n", 2),
        ] {
            let mut log = HistoryLogger::new(
                dir.path().to_path_buf(),
                store.clone(),
                "user".into(),
                "claude".into(),
                tab_id,
                1024 * 1024,
            )
            .unwrap();
            log.append(content).unwrap();
            log.flush_finalize().unwrap();
        }
        std::thread::sleep(std::time::Duration::from_millis(50));

        // Get first segment ID via list_for
        let segs = store.list_for("user", Some("claude"), 10, None).unwrap();
        assert_eq!(segs.len(), 2, "expected 2 segments");
        let first_id = segs.iter().min_by_key(|s| s.started_at).unwrap().id;

        // Fetch first segment explicitly
        let result = replay_for(
            &store,
            "user",
            24,
            80,
            &PreloadHistorySpec::Explicit {
                history_id: first_id as u64,
            },
        )
        .unwrap()
        .unwrap();

        let s = String::from_utf8_lossy(&result.bytes);
        assert!(
            s.contains("first-segment"),
            "expected first-segment: {:?}",
            s
        );
    }
}
