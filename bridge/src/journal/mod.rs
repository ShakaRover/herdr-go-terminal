pub mod claude;
pub mod codex;
pub mod files;
pub mod omp;
pub mod opencode;
pub mod pi;
pub mod text;

use serde::Serialize;
use std::path::PathBuf;

use crate::config::Config;

#[derive(Debug, Clone, PartialEq)]
pub enum RefKind { Id, Path }

#[derive(Debug, Clone)]
pub struct AgentSessionRef {
    pub kind: RefKind,
    pub value: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct TranscriptEntry {
    pub uuid: String,
    pub ts: String,
    pub role: String, // user | assistant | summary | note
    pub parts: Vec<TranscriptPart>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum TranscriptPart {
    Text { text: String, #[serde(skip_serializing_if = "std::ops::Not::not")] truncated: bool },
    Thinking { text: String, #[serde(skip_serializing_if = "std::ops::Not::not")] truncated: bool },
    Tool { name: String, summary: String,
           #[serde(skip_serializing_if = "Option::is_none")] result: Option<ToolResult> },
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolResult {
    pub text: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not", rename = "isError")]
    pub is_error: bool,
}

#[derive(Debug)]
pub struct Page {
    pub entries: Vec<TranscriptEntry>,
    pub has_more: bool,
    pub total: usize,
    pub file_truncated: bool,
}

pub fn paginate(
    entries: Vec<TranscriptEntry>, limit: usize, before: Option<&str>, file_truncated: bool,
) -> Page {
    let total = entries.len();
    let limit = limit.max(1);
    let end = before
        .and_then(|b| entries.iter().position(|e| e.uuid == b))
        .unwrap_or(total); // 未知游标 → 最新页
    let start = end.saturating_sub(limit);
    let has_more = start > 0 || (file_truncated && start == 0 && total > 0);
    Page { entries: entries[start..end].to_vec(), has_more, total, file_truncated }
}

pub struct ResolvedLog {
    pub cache_key: String,
    pub path: Option<PathBuf>,
}

pub trait JournalAdapter: Send + Sync {
    fn validate_ref(&self, r: &AgentSessionRef) -> bool;
    fn resolve(&self, r: &AgentSessionRef) -> Option<ResolvedLog>;
    fn load(&self, resolved: &ResolvedLog) -> std::io::Result<(Vec<TranscriptEntry>, bool)>;
}

pub enum HistoryOutcome {
    Disabled,
    NoSession,
    NoLog,
    Ok(Page),
}

pub struct JournalRegistry {
    claude: claude::ClaudeAdapter,
    codex: codex::CodexAdapter,
    pi: pi::PiAdapter,
    omp: omp::OmpAdapter,
    opencode: opencode::OpencodeAdapter,
    enabled: bool,
}

impl JournalRegistry {
    pub fn new(cfg: &Config) -> Self {
        JournalRegistry {
            claude: claude::ClaudeAdapter::new(cfg.transcript_roots.clone()),
            codex: codex::CodexAdapter::new(cfg.codex_root.clone()),
            pi: pi::PiAdapter::new(cfg.pi_root.clone()),
            omp: omp::OmpAdapter::new(cfg.omp_root.clone()),
            opencode: opencode::OpencodeAdapter::new(cfg.opencode_root.clone()),
            enabled: cfg.transcript,
        }
    }

    pub fn has_adapter(&self, agent: &str) -> bool {
        matches!(agent, "claude" | "codex" | "pi" | "omp" | "opencode")
    }

    /// 解析 pane 的历史会话引用。herdr 对 omp 不上报 agent_session，
    /// 回退到 pane cwd 下最新的 OMP 会话文件。
    pub fn pane_session(
        &self, pane: &crate::herdr::types::PaneInfo,
    ) -> Option<AgentSessionRef> {
        let agent = pane.agent.as_deref().unwrap_or("");
        if !self.has_adapter(agent) {
            return None;
        }
        if let Some(session) = &pane.agent_session {
            if session.agent.as_deref().is_some_and(|a| a != agent) {
                return None;
            }
            let kind = match session.kind.as_str() {
                "id" => RefKind::Id,
                "path" => RefKind::Path,
                _ => return None,
            };
            return Some(AgentSessionRef { kind, value: session.value.clone() });
        }
        if agent == "omp" {
            let cwd = pane.cwd.as_deref()?;
            let path = self.omp.find_for_cwd(cwd)?;
            return Some(AgentSessionRef {
                kind: RefKind::Path,
                value: path.to_string_lossy().to_string(),
            });
        }
        None
    }

    /// 该 pane 是否有可尝试的历史（与 history 端点的可用性保持一致）。
    pub fn pane_has_session(&self, pane: &crate::herdr::types::PaneInfo) -> bool {
        self.pane_session(pane).is_some()
    }

    fn adapter(&self, agent: &str) -> Option<&dyn JournalAdapter> {
        match agent {
            "claude" => Some(&self.claude),
            "codex" => Some(&self.codex),
            "pi" => Some(&self.pi),
            "omp" => Some(&self.omp),
            "opencode" => Some(&self.opencode),
            _ => None,
        }
    }

    pub fn history(
        &self, agent: &str, r: &AgentSessionRef, limit: usize, before: Option<&str>,
    ) -> std::io::Result<HistoryOutcome> {
        if !self.enabled { return Ok(HistoryOutcome::Disabled); }
        let Some(adapter) = self.adapter(agent) else { return Ok(HistoryOutcome::NoSession) };
        if !adapter.validate_ref(r) { return Ok(HistoryOutcome::NoLog); }
        let Some(resolved) = adapter.resolve(r) else { return Ok(HistoryOutcome::NoLog) };
        let (entries, file_truncated) = adapter.load(&resolved)?;
        Ok(HistoryOutcome::Ok(paginate(entries, limit, before, file_truncated)))
    }
}

#[cfg(test)]
mod page_tests {
    use super::*;

    fn entries(n: usize) -> Vec<TranscriptEntry> {
        (0..n).map(|i| TranscriptEntry {
            uuid: format!("u{i}"), ts: String::new(), role: "user".into(), parts: vec![],
        }).collect()
    }

    #[test]
    fn newest_page_by_default() {
        let p = paginate(entries(10), 3, None, false);
        assert_eq!(p.entries[0].uuid, "u7");
        assert_eq!(p.entries.len(), 3);
        assert!(p.has_more);
        assert_eq!(p.total, 10);
    }

    #[test]
    fn before_pages_backwards_exclusive() {
        let p = paginate(entries(10), 3, Some("u7"), false);
        assert_eq!(p.entries[0].uuid, "u4");
        assert_eq!(p.entries.len(), 3);
        assert!(p.has_more);
        let p2 = paginate(entries(10), 5, Some("u4"), false);
        assert_eq!(p2.entries[0].uuid, "u0");
        assert!(!p2.has_more);
    }

    #[test]
    fn unknown_cursor_falls_back_to_newest() {
        let p = paginate(entries(10), 3, Some("nope"), false);
        assert_eq!(p.entries[0].uuid, "u7");
    }

    #[test]
    fn file_truncation_counts_as_more() {
        let p = paginate(entries(3), 3, None, true);
        assert!(p.has_more); // 窗口被截断 = 前面还有
    }
}
