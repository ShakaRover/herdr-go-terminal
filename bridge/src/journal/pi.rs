use std::collections::HashMap;
use std::path::PathBuf;
use regex::Regex;

use super::files::{contained_realpath, contained_realpath_in, read_tail, MAX_TRANSCRIPT_BYTES};
use super::text::{single_line, strip_ansi, truncate_chars, MAX_TEXT_CHARS, MAX_TOOL_RESULT_CHARS, MAX_TOOL_SUMMARY_CHARS};
use super::{AgentSessionRef, JournalAdapter, RefKind, ResolvedLog, ToolResult, TranscriptEntry, TranscriptPart};

/// pi 的 journal 适配器：读 `<root>/<dir>/<ISO-ts>_<session-uuid>.jsonl`。
/// root 默认 `$PI_CODING_AGENT_DIR/sessions`，缺省 `~/.pi/agent/sessions`。
pub struct PiAdapter {
    root: PathBuf,
}

fn uuid_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").unwrap()
    })
}

/// pi 的 content 列表摊平成文本：string 原样；数组取各 text block 以换行连接。
fn text_blocks(content: &serde_json::Value) -> String {
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

impl PiAdapter {
    pub fn new(root: Option<PathBuf>) -> Self {
        let root = root.unwrap_or_else(|| {
            std::env::var_os("PI_CODING_AGENT_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| crate::config::home_dir().join(".pi").join("agent"))
                .join("sessions")
        });
        PiAdapter { root }
    }

    /// 逐 root 一级子目录扫描 `*_<uuid小写>.jsonl` 后缀文件，找到后对该 root
    /// 做 containment；命中但逃逸（符号链接出 root）→ 跳过继续扫（pi.ts findUnder）。
    fn find_log(&self, session_id: &str) -> Option<PathBuf> {
        let suffix = format!("_{}.jsonl", session_id.to_ascii_lowercase());
        let rd = std::fs::read_dir(&self.root).ok()?; // 无 sessions root：本机没有 pi
        for dir in rd.flatten() {
            let names = match std::fs::read_dir(dir.path()) {
                Ok(n) => n,
                Err(_) => continue, // 一级条目不是目录
            };
            for f in names.flatten() {
                let name = f.file_name().to_string_lossy().to_ascii_lowercase();
                if name.ends_with(&suffix) {
                    if let Some(real) = contained_realpath(&f.path(), &self.root) {
                        return Some(real);
                    }
                }
            }
        }
        None
    }
}

impl JournalAdapter for PiAdapter {
    fn validate_ref(&self, r: &AgentSessionRef) -> bool {
        match &r.kind {
            // pi 的 hook 优先上报 session 文件绝对路径：自由路径无形状可校，
            // 绝对性之外全靠 resolve 的 containment 兜底
            RefKind::Path => std::path::Path::new(&r.value).is_absolute(),
            RefKind::Id => uuid_re().is_match(&r.value),
        }
    }

    fn resolve(&self, r: &AgentSessionRef) -> Option<ResolvedLog> {
        let real = match &r.kind {
            RefKind::Path => {
                // 自由路径视作敌意输入：非 .jsonl 一律拒绝，containment 即安全边界
                if !r.value.ends_with(".jsonl") {
                    return None;
                }
                contained_realpath_in(
                    std::path::Path::new(&r.value),
                    std::slice::from_ref(&self.root),
                )?
            }
            RefKind::Id => self.find_log(&r.value)?,
        };
        Some(ResolvedLog {
            cache_key: real.to_string_lossy().to_string(),
            path: Some(real),
        })
    }

    fn load(&self, resolved: &ResolvedLog) -> std::io::Result<(Vec<TranscriptEntry>, bool)> {
        let path = resolved.path.as_ref().expect("pi log path");
        let (text, truncated) = read_tail(path, MAX_TRANSCRIPT_BYTES)?;
        let mut entries: Vec<TranscriptEntry> = Vec::new();
        // toolCallId →(entry 下标, part 下标)：toolResult 是独立行，按 id 折叠回发出
        // 调用的那个 tool part（可能在早已 push 的前序 entry 里），不重排已产出条目。
        let mut pending: HashMap<String, (usize, usize)> = HashMap::new();
        for line in text.lines() {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
            // session / model_change / thinking_level_change 是簿记行，不渲染
            if v["type"].as_str() != Some("message") {
                continue;
            }
            let uuid = v["id"].as_str().unwrap_or("").to_string();
            let ts = match &v["timestamp"] {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Number(n) => n.to_string(), // epoch ms 数字 → 字符串
                _ => String::new(),
            };
            // role/content 载体：真实日志嵌在 `message` 对象里；扁平行（无 message
            // 键）以行自身为载体。message 存在但非对象 → 坏行跳过（pi.ts）。
            let host = match v.get("message") {
                Some(m) if m.is_object() => m,
                Some(_) => continue,
                None => &v,
            };
            if host["role"].as_str() == Some("toolResult") {
                let clean = strip_ansi(&text_blocks(&host["content"]));
                let (t, tr) = truncate_chars(&clean, MAX_TOOL_RESULT_CHARS);
                let tool_result = ToolResult {
                    text: t,
                    truncated: tr,
                    is_error: host["isError"].as_bool().unwrap_or(false),
                };
                let fold_target = host["toolCallId"]
                    .as_str()
                    .and_then(|id| pending.remove(id))
                    .and_then(|(ei, pi)| match entries.get_mut(ei)?.parts.get_mut(pi)? {
                        TranscriptPart::Tool { result, .. } => Some(result),
                        _ => None,
                    });
                match fold_target {
                    Some(result) => *result = Some(tool_result),
                    // 孤儿 result：调用落在尾部窗口外（或折叠不到），非空才保住输出
                    None => {
                        if !clean.trim().is_empty() {
                            entries.push(TranscriptEntry {
                                uuid,
                                ts,
                                role: "assistant".into(),
                                parts: vec![TranscriptPart::Tool {
                                    name: "result".into(),
                                    summary: String::new(),
                                    result: Some(tool_result),
                                }],
                            });
                        }
                    }
                }
                continue;
            }
            let role = if host["role"].as_str() == Some("assistant") { "assistant" } else { "user" };
            let mut parts: Vec<TranscriptPart> = Vec::new();
            for b in host["content"].as_array().cloned().unwrap_or_default() {
                match b["type"].as_str().unwrap_or("") {
                    "text" => {
                        let clean = strip_ansi(b["text"].as_str().unwrap_or(""));
                        if !clean.trim().is_empty() {
                            let (t, tr) = truncate_chars(&clean, MAX_TEXT_CHARS);
                            parts.push(TranscriptPart::Text { text: t, truncated: tr });
                        }
                    }
                    "thinking" => {
                        // pi 的 thinking 带真实文本（通常是加粗短标题），照常渲染
                        let clean = strip_ansi(b["thinking"].as_str().unwrap_or(""));
                        if !clean.trim().is_empty() {
                            let (t, tr) = truncate_chars(&clean, MAX_TEXT_CHARS);
                            parts.push(TranscriptPart::Thinking { text: t, truncated: tr });
                        }
                    }
                    "toolCall" => {
                        if let Some(id) = b["id"].as_str() {
                            pending.insert(id.to_string(), (entries.len(), parts.len()));
                        }
                        // pi 的 arguments 是真对象（codex 是 JSON 字符串），直接序列化
                        // 单行化；缺失/非对象 → 空摘要（summarizeToolInput 同语义）
                        let args = &b["arguments"];
                        let summary = if args.is_object() {
                            single_line(
                                &serde_json::to_string(args).unwrap_or_default(),
                                MAX_TOOL_SUMMARY_CHARS,
                            )
                        } else {
                            String::new()
                        };
                        parts.push(TranscriptPart::Tool {
                            name: b["name"].as_str().unwrap_or("tool").to_string(),
                            summary,
                            result: None, // toolResult 独立行稍后按 toolCallId 回填
                        });
                    }
                    _ => {}
                }
            }
            if parts.is_empty() {
                continue; // 没有可展示内容的行
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

    const UUID: &str = "123e4567-e89b-42d3-a456-426614174000";

    #[test]
    fn path_ref_contained_and_parsed() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("sessions");
        let sub = root.join("--tmp-project--");
        std::fs::create_dir_all(&sub).unwrap();
        let log = sub.join(format!("2026-01-01T00-00-00_{UUID}.jsonl"));
        std::fs::write(&log, [
            serde_json::json!({"type":"message","id":"m1","timestamp":"2026-01-01T00:00:00Z",
                "role":"user","content":[{"type":"text","text":"hi pi"}]}).to_string(),
            serde_json::json!({"type":"message","id":"m2","timestamp":"2026-01-01T00:00:01Z",
                "role":"assistant","content":[
                    {"type":"thinking","thinking":"hmm"},
                    {"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/x"}}
                ]}).to_string(),
            serde_json::json!({"type":"message","id":"m3","timestamp":"2026-01-01T00:00:02Z",
                "role":"toolResult","toolCallId":"c1","isError":false,
                "content":[{"type":"text","text":"file body"}]}).to_string(),
            serde_json::json!({"type":"other","id":"m4"}).to_string(),
        ].join("\n") + "\n").unwrap();
        let a = PiAdapter::new(Some(root.clone()));
        let r = AgentSessionRef { kind: RefKind::Path, value: log.to_string_lossy().to_string() };
        assert!(a.validate_ref(&r));
        let resolved = a.resolve(&r).unwrap();
        let (entries, _) = a.load(&resolved).unwrap();
        // toolResult 行按 toolCallId 折叠进 m2 的 tool part，不独立成条（pi.test.ts）
        assert_eq!(entries.len(), 2);
        match &entries[1].parts[1] {
            crate::journal::TranscriptPart::Tool { name, result, .. } => {
                assert_eq!(name, "read");
                assert_eq!(result.as_ref().unwrap().text, "file body");
            }
            _ => panic!("expected tool with folded result"),
        }
        // 逃逸路径被拒
        let evil = AgentSessionRef { kind: RefKind::Path, value: "/etc/passwd".into() };
        assert!(a.resolve(&evil).is_none());
    }

    #[test]
    fn id_ref_finds_suffix_match() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("sessions");
        let sub = root.join("d");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::write(sub.join(format!("2026-01-01T00-00-00_{UUID}.jsonl")),
            "{\"type\":\"message\",\"id\":\"m1\",\"role\":\"user\",\"content\":[]}\n").unwrap();
        let a = PiAdapter::new(Some(root));
        assert!(a.resolve(&AgentSessionRef { kind: RefKind::Id, value: UUID.into() }).is_some());
    }
}
