// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::Result;
use rusqlite::{params, Connection};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

pub struct PersistentStore {
    conn: Arc<Mutex<Connection>>,
}

impl PersistentStore {
    pub async fn open(state_dir: PathBuf) -> Result<Self> {
        tokio::fs::create_dir_all(&state_dir).await.ok();
        let db_path = state_dir.join("sessions.db");
        let conn = tokio::task::spawn_blocking(move || -> Result<Connection> {
            let c = Connection::open(&db_path)?;
            c.execute_batch(
                "CREATE TABLE IF NOT EXISTS sessions (
                    token        BLOB PRIMARY KEY,
                    expires_unix INTEGER NOT NULL,
                    created_unix INTEGER NOT NULL
                );",
            )?;
            Ok(c)
        })
        .await??;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    pub async fn insert(&self, token: &[u8; 32], expires_unix: i64) -> Result<()> {
        let token_vec = token.to_vec();
        let conn = Arc::clone(&self.conn);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        tokio::task::spawn_blocking(move || -> Result<()> {
            let c = conn.blocking_lock();
            c.execute(
                "INSERT OR REPLACE INTO sessions(token, expires_unix, created_unix) VALUES (?1, ?2, ?3)",
                params![token_vec, expires_unix, now],
            )?;
            Ok(())
        }).await??;
        Ok(())
    }

    pub async fn load_all_valid(&self) -> Result<Vec<([u8; 32], Duration)>> {
        let conn = Arc::clone(&self.conn);
        let now_unix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        let rows = tokio::task::spawn_blocking(move || -> Result<Vec<([u8; 32], i64)>> {
            let c = conn.blocking_lock();
            let mut stmt =
                c.prepare("SELECT token, expires_unix FROM sessions WHERE expires_unix > ?1")?;
            let rows: Vec<([u8; 32], i64)> = stmt
                .query_map(params![now_unix], |row| {
                    let token_vec: Vec<u8> = row.get(0)?;
                    let mut tok = [0u8; 32];
                    if token_vec.len() == 32 {
                        tok.copy_from_slice(&token_vec);
                    }
                    Ok((tok, row.get::<_, i64>(1)?))
                })?
                .filter_map(|r| r.ok())
                .collect();
            Ok(rows)
        })
        .await??;
        Ok(rows
            .into_iter()
            .map(|(tok, exp)| {
                let secs = (exp - now_unix).max(0) as u64;
                (tok, Duration::from_secs(secs))
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn persist_and_reload() {
        let tmp = TempDir::new().unwrap();
        let store = PersistentStore::open(tmp.path().to_path_buf())
            .await
            .unwrap();
        let token = [0x77u8; 32];
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        store.insert(&token, now + 3600).await.unwrap();
        let loaded = store.load_all_valid().await.unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].0, token);
    }

    #[tokio::test]
    async fn expired_not_loaded() {
        let tmp = TempDir::new().unwrap();
        let store = PersistentStore::open(tmp.path().to_path_buf())
            .await
            .unwrap();
        let token = [0x88u8; 32];
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        store.insert(&token, now - 1).await.unwrap();
        assert!(store.load_all_valid().await.unwrap().is_empty());
    }
}
