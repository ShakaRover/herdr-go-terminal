use std::path::PathBuf;

use regex::Regex;

use super::files::{contained_realpath_in, read_tail, MAX_TRANSCRIPT_BYTES};
use super::text::{
    single_line, strip_ansi, truncate_chars, MAX_TEXT_CHARS, MAX_TOOL_RESULT_CHARS,
    MAX_TOOL_SUMMARY_CHARS,
};
use super::{
    AgentSessionRef, JournalAdapter, RefKind, ResolvedLog, ToolResult, TranscriptEntry,
    TranscriptPart,
};

/// claude 的 journal 适配器：读 `~/.claude/projects/<dir>/<uuid>.jsonl`。
pub struct ClaudeAdapter {
    roots: Vec<PathBuf>,
}

fn uuid_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").unwrap()
    })
}

impl ClaudeAdapter {
    pub fn new(roots: Vec<PathBuf>) -> Self {
        ClaudeAdapter { roots }
    }

    /// 逐 root 一级子目录扫描 `<dir>/<uuid>.jsonl`，找到后对该 root 做
    /// containment。命中但不属于该 root（符号链接逃逸）→ 跳过继续扫，
    /// 不能让一个 profile 里的植入链接弄瞎其它 root 的历史（claude.ts）。
    /// 返回 (realpath, 命中的 root)——后续 containment 都以它为准。
    fn find_log(&self, uuid: &str) -> Option<(PathBuf, PathBuf)> {
        let name = format!("{uuid}.jsonl");
        for root in &self.roots {
            let rd = match std::fs::read_dir(root) {
                Ok(rd) => rd,
                Err(_) => continue, // 该 root 不存在：本机没有这个 profile
            };
            for entry in rd.flatten() {
                let candidate = entry.path().join(&name);
                if !candidate.is_file() {
                    continue;
                }
                if let Some(real) = contained_realpath_in(&candidate, std::slice::from_ref(root)) {
                    return Some((real, root.clone()));
                }
            }
        }
        None
    }
}

/// continuation-following：同目录兄弟文件首行 uuid（conversationRoot）相同、
/// size 不更小、`(mtime, size)` 序更新则跟随（mtime 相同时 size 决胜，
/// 保证测试确定性）。兄弟文件同样对命中 root 过 containment。
fn follow_continuation(path: PathBuf, root: &PathBuf) -> PathBuf {
    let Some(root_uuid) = first_line_uuid(&path) else { return path };
    let Ok(meta) = std::fs::metadata(&path) else { return path };
    let mut best = path.clone();
    let mut best_key = (meta.modified().ok(), meta.len(), path.clone());
    let Some(parent) = path.parent() else { return best };
    let Ok(rd) = std::fs::read_dir(parent) else { return best };
    for entry in rd.flatten() {
        let p = entry.path();
        if p == path || p.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(m) = std::fs::metadata(&p) else { continue };
        if m.len() < meta.len() {
            continue; // 跟随永远不能看到更少的历史
        }
        let Some(real) = contained_realpath_in(&p, std::slice::from_ref(root)) else { continue };
        if first_line_uuid(&real).as_deref() != Some(root_uuid.as_str()) {
            continue;
        }
        let key = (m.modified().ok(), m.len(), p.clone());
        if key > best_key {
            best_key = key;
            best = real;
        }
    }
    best
}

/// 首行 JSON 的 `uuid` 字段：日志的 conversation root；读不到/解析失败 → None。
fn first_line_uuid(path: &std::path::Path) -> Option<String> {
    use std::io::BufRead;
    let f = std::fs::File::open(path).ok()?;
    let mut line = String::new();
    let mut r = std::io::BufReader::new(f);
    r.read_line(&mut line).ok()?;
    serde_json::from_str::<serde_json::Value>(&line)
        .ok()?
        .get("uuid")?
        .as_str()
        .map(String::from)
}

/// collie classifyUserText：None = 丢弃该行；Some((role, text)) 保留。
fn classify_user_text(text: &str) -> Option<(&'static str, String)> {
    let t = strip_ansi(text);
    let t = t.trim();
    if (t.starts_with("<system-reminder>") && t.ends_with("</system-reminder>"))
        || (t.starts_with("<local-command-caveat>") && t.ends_with("</local-command-caveat>"))
    {
        return None;
    }
    for (tag, role) in [
        ("local-command-stdout", "note"),
        ("task-notification", "note"),
        ("command-name", "user"),
    ] {
        let open = format!("<{tag}>");
        let close = format!("</{tag}>");
        if t.starts_with(&open) && t.ends_with(&close) {
            return Some((role, t[open.len()..t.len() - close.len()].trim().to_string()));
        }
    }
    Some(("user", text.to_string()))
}

fn text_part(text: &str) -> Option<TranscriptPart> {
    let clean = strip_ansi(text);
    if clean.trim().is_empty() {
        return None;
    }
    let (t, truncated) = truncate_chars(&clean, MAX_TEXT_CHARS);
    Some(TranscriptPart::Text { text: t, truncated })
}

/// claude.ts 的 toolResultText：content 为 string 原样；为 text block 数组时
/// 取各 block 的 `text` 以换行连接；其余（null 等）为空串。
fn tool_result_text(content: &serde_json::Value) -> String {
    match content {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

impl JournalAdapter for ClaudeAdapter {
    fn validate_ref(&self, r: &AgentSessionRef) -> bool {
        r.kind == RefKind::Id && uuid_re().is_match(&r.value)
    }

    fn resolve(&self, r: &AgentSessionRef) -> Option<ResolvedLog> {
        let (found, root) = self.find_log(&r.value)?;
        let followed = follow_continuation(found, &root);
        Some(ResolvedLog {
            cache_key: followed.to_string_lossy().to_string(),
            path: Some(followed),
        })
    }

    fn load(&self, resolved: &ResolvedLog) -> std::io::Result<(Vec<TranscriptEntry>, bool)> {
        let path = resolved
            .path
            .as_ref()
            .expect("claude logs always resolve to a path");
        let (text, truncated) = read_tail(path, MAX_TRANSCRIPT_BYTES)?;
        let mut entries: Vec<TranscriptEntry> = Vec::new();
        // tool_use id →(entry 下标, part 下标)：tool_result 行折叠回发出调用的那个 part
        //（可能在早已 push 的前序 entry 里），不重排任何已产出条目。
        let mut pending: std::collections::HashMap<String, (usize, usize)> =
            std::collections::HashMap::new();
        for line in text.lines() {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
            let typ = v["type"].as_str().unwrap_or("");
            let compact = v["isCompactSummary"].as_bool().unwrap_or(false);
            if typ != "user" && typ != "assistant" && !compact {
                continue;
            }
            if v["isSidechain"].as_bool().unwrap_or(false) {
                continue;
            }
            let uuid = v["uuid"].as_str().unwrap_or("").to_string();
            if uuid.is_empty() {
                continue;
            }
            let ts = v["timestamp"].as_str().unwrap_or("").to_string();
            if compact {
                let summary = v["summary"].as_str().unwrap_or("").to_string();
                entries.push(TranscriptEntry {
                    uuid,
                    ts,
                    role: "summary".into(),
                    parts: text_part(&summary).into_iter().collect(),
                });
                continue;
            }
            let content = &v["message"]["content"];
            let mut parts: Vec<TranscriptPart> = Vec::new();
            let mut role = if typ == "user" { "user" } else { "assistant" };
            match content {
                serde_json::Value::String(s) => {
                    if typ == "user" {
                        match classify_user_text(s) {
                            None => continue,
                            Some((r, t)) => {
                                role = r;
                                if let Some(p) = text_part(&t) {
                                    parts.push(p);
                                }
                            }
                        }
                    } else if let Some(p) = text_part(s) {
                        parts.push(p);
                    }
                }
                serde_json::Value::Array(blocks) => {
                    for b in blocks {
                        match b["type"].as_str().unwrap_or("") {
                            "text" => {
                                if let Some(p) = text_part(b["text"].as_str().unwrap_or("")) {
                                    parts.push(p);
                                }
                            }
                            "thinking" => {
                                let clean = strip_ansi(b["thinking"].as_str().unwrap_or(""));
                                if !clean.trim().is_empty() {
                                    let (t, tr) = truncate_chars(&clean, MAX_TEXT_CHARS);
                                    parts.push(TranscriptPart::Thinking { text: t, truncated: tr });
                                }
                            }
                            "tool_use" => {
                                let name = b["name"].as_str().unwrap_or("tool").to_string();
                                let summary = single_line(
                                    &serde_json::to_string(&b["input"]).unwrap_or_default(),
                                    MAX_TOOL_SUMMARY_CHARS,
                                );
                                if let Some(id) = b["id"].as_str() {
                                    pending.insert(id.to_string(), (entries.len(), parts.len()));
                                }
                                parts.push(TranscriptPart::Tool {
                                    name,
                                    summary,
                                    result: None, // tool_result 行稍后按 id 回填
                                });
                            }
                            "tool_result" => {
                                let clean = strip_ansi(&tool_result_text(&b["content"]));
                                let (t, tr) = truncate_chars(&clean, MAX_TOOL_RESULT_CHARS);
                                let is_error = b["is_error"].as_bool().unwrap_or(false);
                                let tool_result =
                                    ToolResult { text: t, truncated: tr, is_error };
                                // 折叠回发出调用的 tool part（可能在之前的 entry 里）；
                                // 载体行不再成为独立 user 条目。折叠目标不在已 push 的
                                // entries 里（同一 content 数组内 tool_use 后跟
                                // tool_result，真实日志不产生此形状）→ 按「折叠不到」
                                // 处理，不能让坏行崩进程
                                let fold_target = b["tool_use_id"]
                                    .as_str()
                                    .and_then(|id| pending.remove(id))
                                    .and_then(|(ei, pi)| {
                                        match entries.get_mut(ei)?.parts.get_mut(pi)? {
                                            TranscriptPart::Tool { result, .. } => Some(result),
                                            _ => None,
                                        }
                                    });
                                match fold_target {
                                    Some(result) => *result = Some(tool_result),
                                    // 孤儿 result：调用落在尾部窗口外（或折叠不到），
                                    // 保住输出不静默丢弃（空输出除外）
                                    None => {
                                        if !clean.trim().is_empty() {
                                            parts.push(TranscriptPart::Tool {
                                                name: "result".into(),
                                                summary: String::new(),
                                                result: Some(tool_result),
                                            });
                                        }
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
            if parts.is_empty() {
                continue; // 没有可展示内容的簿记行
            }
            entries.push(TranscriptEntry { uuid, ts, role: role.into(), parts });
        }
        Ok((entries, truncated))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::{AgentSessionRef, JournalAdapter, RefKind};

    fn write_jsonl(dir: &std::path::Path, name: &str, lines: &[&str]) -> std::path::PathBuf {
        let p = dir.join(name);
        std::fs::write(&p, lines.join("\n") + "\n").unwrap();
        p
    }

    const UUID: &str = "123e4567-e89b-42d3-a456-426614174000";

    #[test]
    fn validate_ref_shape() {
        let a = ClaudeAdapter::new(vec![]);
        assert!(a.validate_ref(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }));
        assert!(!a.validate_ref(&AgentSessionRef {
            kind: RefKind::Id,
            value: "../../etc/passwd".into()
        }));
        assert!(!a.validate_ref(&AgentSessionRef { kind: RefKind::Path, value: "/tmp/x".into() }));
    }

    #[test]
    fn parses_user_assistant_and_tool_fold() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        let sub = root.join("proj");
        std::fs::create_dir_all(&sub).unwrap();
        write_jsonl(&sub, &format!("{UUID}.jsonl"), &[
            &serde_json::json!({"uuid":"u1","type":"user","timestamp":"2026-01-01T00:00:00Z",
                "message":{"content":"hello there"}}).to_string(),
            &serde_json::json!({"uuid":"u2","type":"assistant","timestamp":"2026-01-01T00:00:01Z",
                "message":{"content":[
                    {"type":"thinking","thinking":"let me think"},
                    {"type":"text","text":"hi back"},
                    {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}
                ]}}).to_string(),
            &serde_json::json!({"uuid":"u3","type":"user","timestamp":"2026-01-01T00:00:02Z",
                "message":{"content":[
                    {"type":"tool_result","tool_use_id":"t1","content":"file1\nfile2"}
                ]}}).to_string(),
            &serde_json::json!({"uuid":"u4","type":"assistant","isSidechain":true,
                "message":{"content":[{"type":"text","text":"sidechain noise"}]}}).to_string(),
            &serde_json::json!({"uuid":"u5","type":"summary","isCompactSummary":true,
                "summary":"we did stuff","message":{"content":[]}}).to_string(),
        ]);
        let a = ClaudeAdapter::new(vec![root]);
        let resolved =
            a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).unwrap();
        let (entries, truncated) = a.load(&resolved).unwrap();
        assert!(!truncated);
        // sidechain 过滤 + tool_result 载体行（u3）折叠进 u2 后不再独立成条
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].role, "user");
        assert_eq!(entries[1].role, "assistant");
        match &entries[1].parts[0] {
            crate::journal::TranscriptPart::Thinking { text, .. } => assert_eq!(text, "let me think"),
            _ => panic!("expected thinking part"),
        }
        match &entries[1].parts[2] {
            crate::journal::TranscriptPart::Tool { name, summary, result } => {
                assert_eq!(name, "Bash");
                assert!(summary.contains("ls -la"));
                assert_eq!(result.as_ref().unwrap().text, "file1\nfile2");
            }
            _ => panic!("expected tool part"),
        }
        assert_eq!(entries[2].role, "summary");
    }

    #[test]
    fn system_reminder_dropped_command_note_kept() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("r");
        let sub = root.join("p");
        std::fs::create_dir_all(&sub).unwrap();
        write_jsonl(&sub, &format!("{UUID}.jsonl"), &[
            &serde_json::json!({"uuid":"a","type":"user","message":{"content":
                "<system-reminder>secret instr</system-reminder>"}}).to_string(),
            &serde_json::json!({"uuid":"b","type":"user","message":{"content":
                "<local-command-stdout>ok output</local-command-stdout>"}}).to_string(),
        ]);
        let a = ClaudeAdapter::new(vec![root]);
        let resolved =
            a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).unwrap();
        let (entries, _) = a.load(&resolved).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].role, "note");
        assert_eq!(entries[0].uuid, "b");
    }

    #[test]
    fn same_line_tool_use_and_result_folds_to_orphan() {
        // 坏行形状：同一 content 数组内 tool_use 后跟同 id 的 tool_result。
        // 折叠目标 entry 尚未 push，下标越界——按孤儿 result 处理，不能 panic。
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("r");
        let sub = root.join("p");
        std::fs::create_dir_all(&sub).unwrap();
        write_jsonl(&sub, &format!("{UUID}.jsonl"), &[
            &serde_json::json!({"uuid":"u1","type":"assistant",
                "timestamp":"2026-01-01T00:00:00Z","message":{"content":[
                    {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},
                    {"type":"tool_result","tool_use_id":"t1","content":"file1"}
                ]}}).to_string(),
        ]);
        let a = ClaudeAdapter::new(vec![root]);
        let resolved =
            a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).unwrap();
        let (entries, _) = a.load(&resolved).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].parts.len(), 2);
        match &entries[0].parts[0] {
            crate::journal::TranscriptPart::Tool { name, result, .. } => {
                assert_eq!(name, "Bash");
                assert!(result.is_none());
            }
            _ => panic!("expected tool part"),
        }
        match &entries[0].parts[1] {
            crate::journal::TranscriptPart::Tool { name, result, .. } => {
                assert_eq!(name, "result");
                assert_eq!(result.as_ref().unwrap().text, "file1");
            }
            _ => panic!("expected orphan result part"),
        }
    }

    #[test]
    fn continuation_following_picks_newest_sibling() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("r");
        let sub = root.join("p");
        std::fs::create_dir_all(&sub).unwrap();
        let first_line = serde_json::json!({"uuid":"root-uuid","type":"user",
            "message":{"content":"root"}}).to_string();
        write_jsonl(&sub, &format!("{UUID}.jsonl"), &[&first_line]);
        let newer = "123e4567-e89b-42d3-a456-426614174001";
        write_jsonl(&sub, &format!("{newer}.jsonl"), &[&first_line,
            &serde_json::json!({"uuid":"u2","type":"user","message":{"content":"continued"}}).to_string()]);
        // 两文件几乎同时创建（mtime 可能相同）：按「首行 uuid 相同 + (mtime, size)
        // 序、size 更大或相等」决胜，保证测试确定性
        let a = ClaudeAdapter::new(vec![root]);
        let resolved =
            a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).unwrap();
        // continuation 目标应为后者（首行 uuid 相同且 mtime 更新/大小不更小）
        assert!(resolved.cache_key.ends_with(&format!("{newer}.jsonl")));
        let (entries, _) = a.load(&resolved).unwrap();
        assert!(entries.iter().any(|e| e.uuid == "u2"));
    }
}
