// SPDX-License-Identifier: GPL-3.0-or-later
use crate::history::store::HistoryStore;
use anyhow::Result;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub struct HistoryRoot {
    pub dir: PathBuf,
    pub store: Arc<HistoryStore>,
}

impl HistoryRoot {
    pub fn open(dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
        let store = Arc::new(HistoryStore::open(&dir.join("index.db"))?);
        Ok(Self { dir, store })
    }

    pub fn default_path() -> PathBuf {
        let home = std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"));
        home.join(".flyterm-server").join("history")
    }
}
