use std::collections::HashMap;

use serde::Serialize;
use crate::herdr::types::{AgentStatus, PaneInfo, TabInfo, WorkspaceInfo};

#[derive(Debug, Clone)]
pub struct EngineView {
    pub connected: bool,
    pub panes: Vec<PaneInfo>,
    pub workspaces: Vec<WorkspaceInfo>,
    pub tabs: Vec<TabInfo>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneWire {
    pub pane_id: String,
    pub workspace_id: String,
    pub workspace_label: String,
    pub workspace_number: u32,
    pub tab_id: String,
    pub agent: String,
    pub status: AgentStatus,
    pub cwd: Option<String>,
    pub focused: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub readable_lines: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tab_label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_active_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<u64>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub has_session: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkspaceView {
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
    pub number: u32,
    pub label: String,
    pub focused: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct TabView {
    #[serde(rename = "tabId")]
    pub tab_id: String,
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
    pub number: u32,
    pub label: String,
    pub focused: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub name: String,
    pub is_primary: bool,
    pub reachable: bool,
    pub agents: u32,
    pub working: u32,
    pub blocked: u32,
}

fn status_rank(s: &AgentStatus) -> u8 {
    match s {
        AgentStatus::Blocked => 0,
        AgentStatus::Working => 1,
        AgentStatus::Unknown => 2,
        AgentStatus::Idle => 3,
        AgentStatus::Done => 4,
    }
}

/// collie meaningfulTabLabel：空串与纯位置序号（如 "1"、"Tab 2"）视为无意义。
fn meaningful_tab_label(label: &str) -> Option<String> {
    let t = label.trim();
    if t.is_empty() { return None; }
    if t.chars().all(|c| c.is_ascii_digit()) { return None; }
    Some(t.to_string())
}

pub fn pane_wire(
    pane: &PaneInfo, workspaces: &[WorkspaceInfo], tabs: &[TabInfo],
    activity: &HashMap<String, (u64, u64)>, names: &HashMap<String, String>,
    has_adapter: &dyn Fn(&str) -> bool,
) -> PaneWire {
    let ws = workspaces.iter().find(|w| w.workspace_id == pane.workspace_id);
    let tab = tabs.iter().find(|t| t.tab_id == pane.tab_id);
    let is_agent = pane.agent.as_ref().is_some_and(|a| !a.is_empty());
    let mut w = PaneWire {
        pane_id: pane.pane_id.clone(),
        workspace_id: pane.workspace_id.clone(),
        workspace_label: ws.map(|w| w.label.clone()).unwrap_or_else(|| pane.workspace_id.clone()),
        workspace_number: ws.map(|w| w.number).unwrap_or(0),
        tab_id: pane.tab_id.clone(),
        agent: if is_agent { pane.agent.clone().unwrap() } else { "shell".into() },
        status: pane.agent_status,
        cwd: pane.cwd.clone(),
        focused: pane.focused,
        kind: Some(if is_agent { "agent" } else { "shell" }.into()),
        pane_label: pane.label.clone(),
        session_name: names.get(&pane.pane_id).cloned(),
        readable_lines: pane.scroll.as_ref().map(|s| s.max_offset_from_bottom + s.viewport_rows),
        tab_label: tab.and_then(|t| meaningful_tab_label(&t.label)),
        last_active_at: None, // 下方由账本填充
        last_seen_at: None,   // 下方由账本填充
        has_session: pane.agent_session.as_ref().is_some_and(|s| {
            s.agent.as_deref().is_none_or(|a| a == pane.agent.as_deref().unwrap_or(""))
                && has_adapter(pane.agent.as_deref().unwrap_or(""))
        }),
    };
    if let Some((a, s)) = activity.get(&w.pane_id).copied() {
        w.last_active_at = Some(a);
        w.last_seen_at = Some(s);
    }
    w
}

/// 返回 (agents, shellPanes)：agents 按 status rank → workspaceNumber → paneId；
/// shellPanes 按 workspaceNumber → paneId。
pub fn build_pane_wires(
    view: &EngineView, activity: &HashMap<String, (u64, u64)>,
    names: &HashMap<String, String>, has_adapter: &dyn Fn(&str) -> bool,
) -> (Vec<PaneWire>, Vec<PaneWire>) {
    let mut agents: Vec<PaneWire> = Vec::new();
    let mut shells: Vec<PaneWire> = Vec::new();
    for p in &view.panes {
        let w = pane_wire(p, &view.workspaces, &view.tabs, activity, names, has_adapter);
        if p.agent.as_ref().is_some_and(|a| !a.is_empty()) { agents.push(w) } else { shells.push(w) }
    }
    agents.sort_by(|a, b| status_rank(&a.status).cmp(&status_rank(&b.status))
        .then(a.workspace_number.cmp(&b.workspace_number))
        .then(a.pane_id.cmp(&b.pane_id)));
    shells.sort_by(|a, b| a.workspace_number.cmp(&b.workspace_number)
        .then(a.pane_id.cmp(&b.pane_id)));
    (agents, shells)
}
