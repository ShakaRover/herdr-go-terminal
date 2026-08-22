use std::collections::HashMap;
use std::path::PathBuf;
use regex::Regex;

use super::files::{contained_realpath, read_tail, MAX_TRANSCRIPT_BYTES};
use super::text::{single_line, strip_ansi, truncate_chars, MAX_TEXT_CHARS, MAX_TOOL_RESULT_CHARS, MAX_TOOL_SUMMARY_CHARS};
use super::{AgentSessionRef, JournalAdapter, RefKind, ResolvedLog, TranscriptEntry, TranscriptPart, ToolResult};

pub struct CodexAdapter {
    root: PathBuf,
}

fn uuid_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(
        r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").unwrap())
}

fn djb2_base36(s: &str) -> String {
    let mut h: u64 = 5381;
    for b in s.as_bytes() {
        h = h.wrapping_mul(33).wrapping_add(*b as u64);
    }
    let mut out = String::new();
    let mut n = h;
    loop {
        out.push(char::from_digit((n % 36) as u32, 36).unwrap());
        n /= 36;
        if n == 0 { break; }
    }
    out.chars().rev().collect()
}

impl CodexAdapter {
    pub fn new(root: Option<PathBuf>) -> Self {
        let root = root.unwrap_or_else(|| {
            std::env::var_os("CODEX_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| crate::config::home_dir().join(".codex"))
                .join("sessions")
        });
        CodexAdapter { root }
    }
}

impl JournalAdapter for CodexAdapter {
    fn validate_ref(&self, r: &AgentSessionRef) -> bool {
        r.kind == RefKind::Id && uuid_re().is_match(&r.value)
    }

    fn resolve(&self, r: &AgentSessionRef) -> Option<ResolvedLog> {
        let suffix = format!("-{}.jsonl", r.value.to_ascii_lowercase());
        let mut days: Vec<PathBuf> = Vec::new();
        for y in std::fs::read_dir(&self.root).ok()?.flatten() {
            for m in std::fs::read_dir(y.path()).map(|r| r.flatten().collect::<Vec<_>>()).unwrap_or_default() {
                for d in std::fs::read_dir(m.path()).map(|r| r.flatten().collect::<Vec<_>>()).unwrap_or_default() {
                    days.push(d.path());
                }
            }
        }
        days.sort();
        days.reverse(); // YYYY/MM/DD 字典序 = 时间序，倒序扫最新
        for day in days {
            for f in std::fs::read_dir(&day).map(|r| r.flatten().collect::<Vec<_>>()).unwrap_or_default() {
                let name = f.file_name().to_string_lossy().to_string();
                if name.starts_with("rollout-") && name.ends_with(&suffix) {
                    if let Some(real) = contained_realpath(&f.path(), &self.root) {
                        return Some(ResolvedLog {
                            cache_key: real.to_string_lossy().to_string(),
                            path: Some(real),
                        });
                    }
                }
            }
        }
        None
    }

    fn load(&self, resolved: &ResolvedLog) -> std::io::Result<(Vec<TranscriptEntry>, bool)> {
        let path = resolved.path.as_ref().expect("codex log path");
        let (text, truncated) = read_tail(path, MAX_TRANSCRIPT_BYTES)?;
        let mut entries: Vec<TranscriptEntry> = Vec::new();
        let mut cursor_counts: HashMap<String, usize> = HashMap::new();
        for line in text.lines() {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
            if v["type"].as_str() != Some("response_item") { continue; }
            let payload = &v["payload"];
            let base = format!("cx-{}", djb2_base36(line));
            let n = cursor_counts.entry(base.clone()).or_insert(0);
            *n += 1;
            let uuid = if *n == 1 { base } else { format!("{base}-{n}") };
            let mut parts: Vec<TranscriptPart> = Vec::new();
            let role;
            match payload["type"].as_str().unwrap_or("") {
                "message" => {
                    role = match payload["role"].as_str() {
                        Some("user") => "user",
                        Some("assistant") => "assistant",
                        _ => continue,
                    };
                    let mut text = String::new();
                    for c in payload["content"].as_array().cloned().unwrap_or_default() {
                        match c["type"].as_str().unwrap_or("") {
                            "input_text" | "output_text" => {
                                if !text.is_empty() { text.push('\n'); }
                                text.push_str(c["text"].as_str().unwrap_or(""));
                            }
                            _ => {}
                        }
                    }
                    let t = text.trim();
                    if t.starts_with("<environment_context>") && t.ends_with("</environment_context>") {
                        continue;
                    }
                    let clean = strip_ansi(&text);
                    if clean.trim().is_empty() { continue; }
                    let (t2, tr) = truncate_chars(&clean, MAX_TEXT_CHARS);
                    parts.push(TranscriptPart::Text { text: t2, truncated: tr });
                }
                "reasoning" => {
                    role = "assistant";
                    let mut text = String::new();
                    for s in payload["summary"].as_array().cloned().unwrap_or_default() {
                        if !text.is_empty() { text.push('\n'); }
                        text.push_str(s["text"].as_str().unwrap_or(""));
                    }
                    if text.trim().is_empty() { continue; }
                    let (t, tr) = truncate_chars(&strip_ansi(&text), MAX_TEXT_CHARS);
                    parts.push(TranscriptPart::Thinking { text: t, truncated: tr });
                }
                "function_call" => {
                    role = "assistant";
                    parts.push(TranscriptPart::Tool {
                        name: payload["name"].as_str().unwrap_or("tool").to_string(),
                        summary: single_line(payload["arguments"].as_str().unwrap_or(""),
                            MAX_TOOL_SUMMARY_CHARS),
                        result: None,
                    });
                }
                "function_call_output" => {
                    role = "assistant";
                    let raw = payload["output"].as_str().unwrap_or("");
                    // output 是包了一层 JSON 的字符串：{"output": "..."}
                    let inner = serde_json::from_str::<serde_json::Value>(raw)
                        .ok()
                        .and_then(|v| v["output"].as_str().map(String::from))
                        .unwrap_or_else(|| raw.to_string());
                    let (t, tr) = truncate_chars(&strip_ansi(&inner), MAX_TOOL_RESULT_CHARS);
                    if let Some(TranscriptPart::Tool { result, .. }) =
                        entries.last_mut().and_then(|e| e.parts.iter_mut().rev()
                            .find(|p| matches!(p, TranscriptPart::Tool { result: None, .. })))
                    {
                        *result = Some(ToolResult { text: t, truncated: tr, is_error: false });
                        continue; // 不产生新条目
                    }
                    parts.push(TranscriptPart::Tool {
                        name: "result".into(), summary: String::new(),
                        result: Some(ToolResult { text: t, truncated: tr, is_error: false }),
                    });
                }
                _ => continue,
            }
            entries.push(TranscriptEntry { uuid, ts: String::new(), role: role.into(), parts });
        }
        Ok((entries, truncated))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::{AgentSessionRef, JournalAdapter, RefKind};

    const UUID: &str = "123e4567-e89b-42d3-a456-426614174000";

    fn rollout(dir: &std::path::Path, day: &str, uuid: &str, lines: &[&str]) {
        let d = dir.join(day);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join(format!("rollout-2026-01-01T00-00-00-{uuid}.jsonl")),
            lines.join("\n") + "\n").unwrap();
    }

    #[test]
    fn parses_response_items_and_synthesizes_cursors() {
        let dir = tempfile::tempdir().unwrap();
        rollout(dir.path(), "2026/01/01", UUID, &[
            &serde_json::json!({"type":"event_msg","payload":{"type":"user_message",
                "message":"duplicate bookkeeping"}}).to_string(),
            &serde_json::json!({"type":"response_item","payload":{"type":"message",
                "role":"user","content":[{"type":"input_text","text":"fix the bug"}]}}).to_string(),
            &serde_json::json!({"type":"response_item","payload":{"type":"reasoning",
                "summary":[{"type":"summary_text","text":"thinking hard"}]}}).to_string(),
            &serde_json::json!({"type":"response_item","payload":{"type":"function_call",
                "name":"shell","arguments":"{\"cmd\":\"ls\"}"}}).to_string(),
            &serde_json::json!({"type":"response_item","payload":{"type":"function_call_output",
                "output":"{\"output\":\"total 3\"}"}}).to_string(),
            &serde_json::json!({"type":"response_item","payload":{"type":"message",
                "role":"assistant","content":[{"type":"output_text","text":"done"}]}}).to_string(),
            &serde_json::json!({"type":"response_item","payload":{"type":"message",
                "role":"user","content":[{"type":"input_text",
                 "text":"<environment_context>cwd=/tmp</environment_context>"}]}}).to_string(),
        ]);
        let a = CodexAdapter::new(Some(dir.path().to_path_buf()));
        let resolved = a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).unwrap();
        let (entries, _) = a.load(&resolved).unwrap();
        assert_eq!(entries.len(), 4); // event_msg 与 environment_context 被丢弃
        assert_eq!(entries[0].role, "user");
        assert!(entries[0].uuid.starts_with("cx-"));
        match &entries[1].parts[0] {
            crate::journal::TranscriptPart::Thinking { text, .. } => assert_eq!(text, "thinking hard"),
            _ => panic!("expected thinking"),
        }
        match &entries[2].parts[0] {
            crate::journal::TranscriptPart::Tool { name, result, .. } => {
                assert_eq!(name, "shell");
                assert_eq!(result.as_ref().unwrap().text, "total 3");
            }
            _ => panic!("expected tool"),
        }
        assert_eq!(entries[3].role, "assistant");
        // 游标稳定：同输入同 uuid
        let (again, _) = a.load(&resolved).unwrap();
        assert_eq!(entries[0].uuid, again[0].uuid);
    }

    #[test]
    fn duplicate_lines_get_suffixed_cursors() {
        let dir = tempfile::tempdir().unwrap();
        let line = serde_json::json!({"type":"response_item","payload":{"type":"message",
            "role":"user","content":[{"type":"input_text","text":"same"}]}}).to_string();
        rollout(dir.path(), "2026/01/02", UUID, &[&line, &line]);
        let a = CodexAdapter::new(Some(dir.path().to_path_buf()));
        let resolved = a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).unwrap();
        let (entries, _) = a.load(&resolved).unwrap();
        assert_eq!(entries.len(), 2);
        assert_ne!(entries[0].uuid, entries[1].uuid);
        assert!(entries[1].uuid.ends_with("-2"));
    }

    #[test]
    fn finds_rollout_in_date_partitions_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        rollout(dir.path(), "2025/12/31", UUID, &[
            &serde_json::json!({"type":"response_item","payload":{"type":"message",
                "role":"user","content":[{"type":"input_text","text":"x"}]}}).to_string(),
        ]);
        let a = CodexAdapter::new(Some(dir.path().to_path_buf()));
        assert!(a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).is_some());
        assert!(a.resolve(&AgentSessionRef { kind: RefKind::Id,
            value: "00000000-0000-4000-8000-000000000000".into() }).is_none());
    }
}
