// SPDX-License-Identifier: GPL-3.0-or-later
use crate::history::slug::slugify;
use crate::history::store::{HistoryStore, NewSegment};
use anyhow::{Context, Result};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_SEGMENT_BYTES: u64 = 256 * 1024 * 1024;

pub struct HistoryLogger {
    root: PathBuf,
    store: Arc<HistoryStore>,
    session_key: String,
    command_hint: String,
    tab_id: u32,
    rotate_at: u64,
    current_id: i64,
    current_seq: u32,
    current_file: File,
    current_path: PathBuf,
    current_size: u64,
}

impl HistoryLogger {
    pub fn new(
        root: PathBuf,
        store: Arc<HistoryStore>,
        session_key: String,
        command_hint: String,
        tab_id: u32,
        rotate_at: u64,
    ) -> Result<Self> {
        let cmd_slug = slugify(&command_hint);
        let dir = root.join(&session_key).join(&cmd_slug);
        std::fs::create_dir_all(&dir).context("create history dir")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }

        let seq = 0u32;
        let path = dir.join(format!("{}.{}.log", tab_id, seq));
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .context("open segment file")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
        }

        let started_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let id = store.insert_segment(NewSegment {
            session_key: &session_key,
            command_hint: &cmd_slug,
            tab_id,
            seq,
            started_at,
            path: path.to_str().unwrap_or(""),
        })?;

        Ok(Self {
            root,
            store,
            session_key,
            command_hint,
            tab_id,
            rotate_at,
            current_id: id,
            current_seq: seq,
            current_file: file,
            current_path: path,
            current_size: 0,
        })
    }

    pub fn append(&mut self, data: &[u8]) -> Result<()> {
        if self.current_size > 0 && self.current_size + data.len() as u64 > self.rotate_at {
            self.rotate()?;
        }
        match self.current_file.write_all(data) {
            Ok(()) => {
                self.current_size += data.len() as u64;
                Ok(())
            }
            Err(e) => {
                // Sync tracked size to actual file size so that rotation thresholds remain
                // accurate even after a partial write (O_APPEND may have advanced the position).
                if let Ok(meta) = self.current_file.metadata() {
                    self.current_size = meta.len();
                }
                Err(anyhow::Error::from(e).context("write history"))
            }
        }
    }

    fn rotate(&mut self) -> Result<()> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        self.store
            .finalize_segment(self.current_id, self.current_size, now)?;

        self.current_seq += 1;
        let cmd_slug = slugify(&self.command_hint);
        let dir = self.root.join(&self.session_key).join(&cmd_slug);
        let path = dir.join(format!("{}.{}.log", self.tab_id, self.current_seq));
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .context("open rotated segment")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
        }

        let id = self.store.insert_segment(NewSegment {
            session_key: &self.session_key,
            command_hint: &cmd_slug,
            tab_id: self.tab_id,
            seq: self.current_seq,
            started_at: now,
            path: path.to_str().unwrap_or(""),
        })?;

        self.current_id = id;
        self.current_file = file;
        self.current_path = path;
        self.current_size = 0;
        Ok(())
    }

    pub fn flush_finalize(&mut self) -> Result<()> {
        self.current_file.flush().context("flush history")?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        self.store
            .finalize_segment(self.current_id, self.current_size, now)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tempfile::TempDir;

    fn make_logger(rotate_at: u64) -> (TempDir, Arc<HistoryStore>, HistoryLogger) {
        let dir = TempDir::new().unwrap();
        let store = Arc::new(HistoryStore::open(&dir.path().join("h.db")).unwrap());
        let logger = HistoryLogger::new(
            dir.path().to_path_buf(),
            store.clone(),
            "alice@host".into(),
            "claude".into(),
            1, // tab_id
            rotate_at,
        )
        .unwrap();
        (dir, store, logger)
    }

    #[test]
    fn append_writes_to_file() {
        let (dir, _store, mut logger) = make_logger(1024 * 1024);
        logger.append(b"hello\n").unwrap();
        logger.append(b"world\n").unwrap();
        logger.flush_finalize().unwrap();
        let log_dir = dir.path().join("alice@host").join("claude");
        let entries: Vec<_> = std::fs::read_dir(&log_dir).unwrap().collect();
        assert_eq!(entries.len(), 1, "should have exactly 1 log file");
        let content = std::fs::read(entries[0].as_ref().unwrap().path()).unwrap();
        assert_eq!(content, b"hello\nworld\n");
    }

    #[test]
    fn rotation_creates_new_segment() {
        let (_dir, store, mut logger) = make_logger(10); // rotate after 10 bytes
        logger.append(b"0123456789AB").unwrap(); // 12 bytes, exceeds 10
        logger.append(b"second-file-data").unwrap();
        logger.flush_finalize().unwrap();

        // Check SQLite: should have 2 segments
        let seg1 = store.get_by_id(1).unwrap();
        assert!(seg1.is_some(), "first segment should exist");
        let seg2 = store.get_by_id(2).unwrap();
        assert!(seg2.is_some(), "second segment should exist");
    }
}
