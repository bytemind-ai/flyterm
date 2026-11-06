// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::Mutex;

pub struct HistoryStore {
    conn: Mutex<Connection>,
}

pub struct NewSegment<'a> {
    pub session_key: &'a str,
    pub command_hint: &'a str,
    pub tab_id: u32,
    pub seq: u32,
    pub started_at: u64,
    pub path: &'a str,
}

#[derive(Debug, Clone)]
pub struct Segment {
    pub id: i64,
    pub session_key: String,
    pub command_hint: String,
    pub tab_id: u32,
    pub seq: u32,
    pub started_at: u64,
    pub ended_at: Option<u64>,
    pub size_bytes: u64,
    pub path: String,
}

impl HistoryStore {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(path).context("open history db")?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS history_segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_key TEXT NOT NULL,
                command_hint TEXT NOT NULL,
                tab_id INTEGER NOT NULL,
                seq INTEGER NOT NULL,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                path TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_session_cmd_time
                ON history_segments(session_key, command_hint, started_at DESC);
            "#,
        )?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn insert_segment(&self, s: NewSegment) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO history_segments (session_key, command_hint, tab_id, seq, started_at, path)
             VALUES (?, ?, ?, ?, ?, ?)",
            params![s.session_key, s.command_hint, s.tab_id, s.seq, s.started_at as i64, s.path],
        )?;
        Ok(conn.last_insert_rowid())
    }

    pub fn finalize_segment(&self, id: i64, size_bytes: u64, ended_at: u64) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE history_segments SET size_bytes = ?, ended_at = ? WHERE id = ?",
            params![size_bytes as i64, ended_at as i64, id],
        )?;
        Ok(())
    }

    pub fn latest_for(&self, session_key: &str, command_hint: &str) -> Result<Option<Segment>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, session_key, command_hint, tab_id, seq, started_at, ended_at, size_bytes, path
             FROM history_segments
             WHERE session_key = ? AND command_hint = ?
             ORDER BY started_at DESC LIMIT 1",
        )?;
        let row = stmt
            .query_row(params![session_key, command_hint], Self::row_to_segment)
            .optional()?;
        Ok(row)
    }

    pub fn get_by_id(&self, id: i64) -> Result<Option<Segment>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, session_key, command_hint, tab_id, seq, started_at, ended_at, size_bytes, path
             FROM history_segments WHERE id = ?",
        )?;
        Ok(stmt
            .query_row(params![id], Self::row_to_segment)
            .optional()?)
    }

    pub fn list_for(
        &self,
        session_key: &str,
        command_hint: Option<&str>,
        limit: u32,
        before_ts: Option<u64>,
    ) -> anyhow::Result<Vec<Segment>> {
        let conn = self.conn.lock().unwrap();
        let limit_i = limit.min(200) as i64;

        let segments = match (command_hint, before_ts) {
            (Some(cmd), Some(ts)) => {
                let sql = "SELECT id, session_key, command_hint, tab_id, seq, started_at, ended_at, size_bytes, path \
                           FROM history_segments WHERE session_key = ?1 AND command_hint = ?2 AND started_at < ?3 \
                           ORDER BY started_at DESC LIMIT ?4";
                let mut stmt = conn.prepare(sql)?;
                let rows = stmt
                    .query_map(
                        params![session_key, cmd, ts as i64, limit_i],
                        Self::row_to_segment,
                    )?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                rows
            }
            (Some(cmd), None) => {
                let sql = "SELECT id, session_key, command_hint, tab_id, seq, started_at, ended_at, size_bytes, path \
                           FROM history_segments WHERE session_key = ?1 AND command_hint = ?2 \
                           ORDER BY started_at DESC LIMIT ?3";
                let mut stmt = conn.prepare(sql)?;
                let rows = stmt
                    .query_map(params![session_key, cmd, limit_i], Self::row_to_segment)?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                rows
            }
            (None, Some(ts)) => {
                let sql = "SELECT id, session_key, command_hint, tab_id, seq, started_at, ended_at, size_bytes, path \
                           FROM history_segments WHERE session_key = ?1 AND started_at < ?2 \
                           ORDER BY started_at DESC LIMIT ?3";
                let mut stmt = conn.prepare(sql)?;
                let rows = stmt
                    .query_map(
                        params![session_key, ts as i64, limit_i],
                        Self::row_to_segment,
                    )?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                rows
            }
            (None, None) => {
                let sql = "SELECT id, session_key, command_hint, tab_id, seq, started_at, ended_at, size_bytes, path \
                           FROM history_segments WHERE session_key = ?1 \
                           ORDER BY started_at DESC LIMIT ?2";
                let mut stmt = conn.prepare(sql)?;
                let rows = stmt
                    .query_map(params![session_key, limit_i], Self::row_to_segment)?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                rows
            }
        };
        Ok(segments)
    }

    fn row_to_segment(row: &rusqlite::Row) -> rusqlite::Result<Segment> {
        Ok(Segment {
            id: row.get(0)?,
            session_key: row.get(1)?,
            command_hint: row.get(2)?,
            tab_id: row.get::<_, i64>(3)? as u32,
            seq: row.get::<_, i64>(4)? as u32,
            started_at: row.get::<_, i64>(5)? as u64,
            ended_at: row.get::<_, Option<i64>>(6)?.map(|v| v as u64),
            size_bytes: row.get::<_, i64>(7)? as u64,
            path: row.get(8)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_store() -> (TempDir, HistoryStore) {
        let dir = TempDir::new().unwrap();
        let store = HistoryStore::open(&dir.path().join("test.db")).unwrap();
        (dir, store)
    }

    #[test]
    fn insert_and_query_latest() {
        let (_dir, store) = make_store();
        let id1 = store
            .insert_segment(NewSegment {
                session_key: "alice@host",
                command_hint: "claude",
                tab_id: 1,
                seq: 0,
                started_at: 1_700_000_000,
                path: "/tmp/a.log",
            })
            .unwrap();
        let id2 = store
            .insert_segment(NewSegment {
                session_key: "alice@host",
                command_hint: "claude",
                tab_id: 2,
                seq: 0,
                started_at: 1_700_001_000,
                path: "/tmp/b.log",
            })
            .unwrap();
        assert!(id2 > id1);
        let latest = store.latest_for("alice@host", "claude").unwrap();
        assert_eq!(latest.unwrap().path, "/tmp/b.log");
    }

    #[test]
    fn latest_no_match_returns_none() {
        let (_dir, store) = make_store();
        assert!(store.latest_for("alice@host", "claude").unwrap().is_none());
    }

    #[test]
    fn finalize_updates_size_and_ended_at() {
        let (_dir, store) = make_store();
        let id = store
            .insert_segment(NewSegment {
                session_key: "u",
                command_hint: "c",
                tab_id: 1,
                seq: 0,
                started_at: 1_700_000_000,
                path: "/tmp/x.log",
            })
            .unwrap();
        store.finalize_segment(id, 4096, 1_700_001_000).unwrap();
        let seg = store.get_by_id(id).unwrap().unwrap();
        assert_eq!(seg.size_bytes, 4096);
        assert_eq!(seg.ended_at, Some(1_700_001_000));
    }

    #[test]
    fn isolation_across_session_keys() {
        let (_dir, store) = make_store();
        store
            .insert_segment(NewSegment {
                session_key: "alice@host",
                command_hint: "claude",
                tab_id: 1,
                seq: 0,
                started_at: 1_700_000_000,
                path: "/tmp/a.log",
            })
            .unwrap();
        store
            .insert_segment(NewSegment {
                session_key: "bob@host",
                command_hint: "claude",
                tab_id: 2,
                seq: 0,
                started_at: 1_700_001_000,
                path: "/tmp/b.log",
            })
            .unwrap();
        let alice = store.latest_for("alice@host", "claude").unwrap().unwrap();
        assert_eq!(alice.path, "/tmp/a.log");
    }

    #[test]
    fn list_for_returns_most_recent_first() {
        let (_dir, store) = make_store();
        for i in 0..3u64 {
            store
                .insert_segment(NewSegment {
                    session_key: "u",
                    command_hint: "claude",
                    tab_id: i as u32,
                    seq: 0,
                    started_at: 1_700_000_000 + i,
                    path: "/tmp/x",
                })
                .unwrap();
        }
        let list = store.list_for("u", Some("claude"), 10, None).unwrap();
        assert_eq!(list.len(), 3);
        assert!(list[0].started_at > list[1].started_at, "should be DESC");
    }

    #[test]
    fn list_for_filters_by_session_key() {
        let (_dir, store) = make_store();
        store
            .insert_segment(NewSegment {
                session_key: "alice",
                command_hint: "c",
                tab_id: 1,
                seq: 0,
                started_at: 100,
                path: "/a",
            })
            .unwrap();
        store
            .insert_segment(NewSegment {
                session_key: "bob",
                command_hint: "c",
                tab_id: 2,
                seq: 0,
                started_at: 200,
                path: "/b",
            })
            .unwrap();
        let list = store.list_for("alice", None, 10, None).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].session_key, "alice");
    }
}
