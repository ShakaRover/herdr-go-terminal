use std::path::PathBuf;
use regex::Regex;
use rusqlite::{Connection, OpenFlags};

use super::text::{single_line, strip_ansi, truncate_chars, MAX_TEXT_CHARS, MAX_TOOL_RESULT_CHARS, MAX_TOOL_SUMMARY_CHARS};
use super::{AgentSessionRef, JournalAdapter, RefKind, ResolvedLog, TranscriptEntry, TranscriptPart, ToolResult};

pub struct OpencodeAdapter { root: PathBuf }

fn ses_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^ses_[A-Za-z0-9]{8,64}$").unwrap())
}

impl OpencodeAdapter {
    pub fn new(root: Option<PathBuf>) -> Self {
        let root = root.unwrap_or_else(|| {
            std::env::var_os("XDG_DATA_HOME").map(PathBuf::from)
                .unwrap_or_else(|| crate::config::home_dir().join(".local").join("share"))
                .join("opencode")
        });
        OpencodeAdapter { root }
    }

    fn db_path(&self) -> PathBuf { self.root.join("opencode.db") }

    fn open(&self) -> Option<Connection> {
        Connection::open_with_flags(self.db_path(), OpenFlags::SQLITE_OPEN_READ_ONLY).ok()
    }
}

impl JournalAdapter for OpencodeAdapter {
    fn validate_ref(&self, r: &AgentSessionRef) -> bool {
        r.kind == RefKind::Id && ses_re().is_match(&r.value)
    }

    fn resolve(&self, r: &AgentSessionRef) -> Option<ResolvedLog> {
        let conn = self.open()?;
        let exists: bool = conn
            .query_row("SELECT 1 FROM session WHERE id = ?1", [&r.value], |_| Ok(true))
            .unwrap_or(false);
        exists.then(|| ResolvedLog {
            cache_key: format!("{}#{}", self.db_path().display(), r.value),
            path: None,
        })
    }

    fn load(&self, resolved: &ResolvedLog) -> std::io::Result<(Vec<TranscriptEntry>, bool)> {
        let session_id = resolved.cache_key.rsplit('#').next().unwrap_or("").to_string();
        let conn = self.open().ok_or_else(|| std::io::Error::new(
            std::io::ErrorKind::NotFound, "opencode.db not openable"))?;
        // 真实 opencode.db（drizzle schema）的载荷在 data JSON 列，
        // message/part 表没有扁平的 role/type/text 列。
        let mut stmt = conn.prepare(
            "SELECT id, data FROM message WHERE session_id = ?1
             ORDER BY time_created, id").map_err(io_err)?;
        let messages = stmt.query_map([&session_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).map_err(io_err)?.collect::<Result<Vec<_>, _>>().map_err(io_err)?;
        let mut part_stmt = conn.prepare(
            "SELECT data FROM part WHERE message_id = ?1
             ORDER BY id").map_err(io_err)?;
        let mut entries = Vec::new();
        for (mid, mdata) in messages {
            let Ok(mv) = serde_json::from_str::<serde_json::Value>(&mdata) else { continue };
            let role = mv["role"].as_str().unwrap_or("");
            if role != "user" && role != "assistant" { continue; }
            let ts = mv["time"]["created"].as_i64()
                .map(epoch_ms_to_iso).unwrap_or_default();
            let mut parts = Vec::new();
            let rows = part_stmt.query_map([&mid], |row| row.get::<_, String>(0))
                .map_err(io_err)?;
            for row in rows {
                let pdata = row.map_err(io_err)?;
                let Ok(pv) = serde_json::from_str::<serde_json::Value>(&pdata)
                    else { continue };
                match pv["type"].as_str().unwrap_or("") {
                    "text" => {
                        if let Some(t) = pv["text"].as_str() {
                            let (t2, tr) = truncate_chars(&strip_ansi(t), MAX_TEXT_CHARS);
                            parts.push(TranscriptPart::Text { text: t2, truncated: tr });
                        }
                    }
                    "reasoning" => {
                        if let Some(t) = pv["text"].as_str() {
                            let (t2, tr) = truncate_chars(&strip_ansi(t), MAX_TEXT_CHARS);
                            parts.push(TranscriptPart::Thinking { text: t2, truncated: tr });
                        }
                    }
                    "tool" => {
                        let st = &pv["state"];
                        let name = pv["tool"].as_str().unwrap_or("tool").to_string();
                        let summary = if st["input"].is_null() {
                            String::new()
                        } else {
                            single_line(
                                &serde_json::to_string(&st["input"]).unwrap_or_default(),
                                MAX_TOOL_SUMMARY_CHARS)
                        };
                        let result = match st["status"].as_str() {
                            Some("completed") | Some("error") => {
                                let is_error = st["status"] == "error";
                                // error 态正文在 state.error，completed 在 state.output。
                                let out = if is_error {
                                    st["error"].as_str()
                                        .or_else(|| st["output"].as_str())
                                        .unwrap_or("")
                                } else {
                                    st["output"].as_str().unwrap_or("")
                                };
                                let (t, tr) = truncate_chars(&strip_ansi(out),
                                    MAX_TOOL_RESULT_CHARS);
                                Some(ToolResult { text: t, truncated: tr, is_error })
                            }
                            _ => None,
                        };
                        parts.push(TranscriptPart::Tool { name, summary, result });
                    }
                    _ => {} // step-start/step-finish/patch/subtask 等不渲染
                }
            }
            if parts.is_empty() { continue; }
            entries.push(TranscriptEntry {
                uuid: mid,
                ts,
                role: role.to_string(),
                parts,
            });
        }
        Ok((entries, false))
    }
}

/// epoch ms → `YYYY-MM-DDTHH:MM:SSZ`（UTC）。civil-from-days 算法，
/// 避免仅为格式化引入 chrono/time 依赖。
fn epoch_ms_to_iso(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86400);
    let sod = secs.rem_euclid(86400);
    let (h, mi, s) = (sod / 3600, sod % 3600 / 60, sod % 60);
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn io_err(e: rusqlite::Error) -> std::io::Error {
    std::io::Error::other(e)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::{AgentSessionRef, JournalAdapter, RefKind};
    use rusqlite::Connection;

    // 与真实 opencode.db 同形：载荷全在 data JSON 列。
    fn make_db(root: &std::path::Path) {
        let conn = Connection::open(root.join("opencode.db")).unwrap();
        conn.execute_batch(r#"
            CREATE TABLE session (id TEXT PRIMARY KEY);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
                data TEXT NOT NULL);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL,
                session_id TEXT NOT NULL, time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            INSERT INTO session VALUES ('ses_abc123xyz');
            INSERT INTO message VALUES ('m1', 'ses_abc123xyz', 1700000000000, 1700000000000,
                '{"role":"user","time":{"created":1700000000000}}');
            INSERT INTO message VALUES ('m2', 'ses_abc123xyz', 1700000001000, 1700000001000,
                '{"role":"assistant","time":{"created":1700000001000}}');
            INSERT INTO message VALUES ('m3', 'ses_abc123xyz', 1700000002000, 1700000002000,
                '{"time":{"created":1700000002000}}');
            INSERT INTO part VALUES ('p1', 'm1', 'ses_abc123xyz', 1700000000000, 1700000000000,
                '{"type":"text","text":"hello opencode"}');
            INSERT INTO part VALUES ('p2', 'm2', 'ses_abc123xyz', 1700000001000, 1700000001000,
                '{"type":"reasoning","text":"thinking..."}');
            INSERT INTO part VALUES ('p3', 'm2', 'ses_abc123xyz', 1700000001001, 1700000001001,
                '{"type":"tool","tool":"bash","state":{"status":"completed",
                  "input":{"cmd":"ls"},"output":"files"}}');
            INSERT INTO part VALUES ('p4', 'm2', 'ses_abc123xyz', 1700000001002, 1700000001002,
                '{"type":"tool","tool":"read","state":{"status":"error",
                  "input":{"filePath":"/x"},"error":"Error: File not found: /x"}}');
            INSERT INTO part VALUES ('p5', 'm2', 'ses_abc123xyz', 1700000001003, 1700000001003,
                '{"type":"tool","tool":"noop","state":{"status":"running"}}');
            INSERT INTO part VALUES ('p6', 'm2', 'ses_abc123xyz', 1700000001004, 1700000001004,
                '{"type":"step-start","snapshot":"abc"}');
            INSERT INTO part VALUES ('p7', 'm3', 'ses_abc123xyz', 1700000002000, 1700000002000,
                '{"type":"text","text":"orphan"}');
        "#).unwrap();
    }

    #[test]
    fn reads_session_from_sqlite() {
        let dir = tempfile::tempdir().unwrap();
        make_db(dir.path());
        let a = OpencodeAdapter::new(Some(dir.path().to_path_buf()));
        let r = AgentSessionRef { kind: RefKind::Id, value: "ses_abc123xyz".into() };
        assert!(a.validate_ref(&r));
        let resolved = a.resolve(&r).unwrap();
        assert!(resolved.cache_key.ends_with("#ses_abc123xyz"));
        let (entries, truncated) = a.load(&resolved).unwrap();
        assert!(!truncated);
        // m3 无 role，被过滤
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].role, "user");
        assert_eq!(entries[0].uuid, "m1");
        assert_eq!(entries[0].ts, "2023-11-14T22:13:20Z");
        // reasoning + 三个 tool（running 的也有 part），step-start 不渲染
        assert_eq!(entries[1].parts.len(), 4);
        match &entries[1].parts[1] {
            crate::journal::TranscriptPart::Tool { name, summary, result } => {
                assert_eq!(name, "bash");
                assert!(summary.contains("ls"));
                let r = result.as_ref().unwrap();
                assert_eq!(r.text, "files");
                assert!(!r.is_error);
            }
            _ => panic!("expected tool part"),
        }
        match &entries[1].parts[2] {
            crate::journal::TranscriptPart::Tool { name, result, .. } => {
                assert_eq!(name, "read");
                let r = result.as_ref().unwrap();
                assert!(r.is_error);
                assert!(r.text.contains("File not found"));
            }
            _ => panic!("expected tool part"),
        }
        // running 态 tool 有 part 但无 result
        match &entries[1].parts[3] {
            crate::journal::TranscriptPart::Tool { name, result, .. } => {
                assert_eq!(name, "noop");
                assert!(result.is_none());
            }
            _ => panic!("expected tool part"),
        }
        // 未知 session → None
        assert!(a.resolve(&AgentSessionRef { kind: RefKind::Id,
            value: "ses_unknown99".into() }).is_none());
        // 形状非法 → validate 拒
        assert!(!a.validate_ref(&AgentSessionRef { kind: RefKind::Id,
            value: "../../etc/passwd".into() }));
    }
}
