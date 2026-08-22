use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
pub struct WireRequest<'a, P: Serialize> {
    pub id: String,
    pub method: &'a str,
    pub params: P,
}

#[derive(Debug, Deserialize)]
pub struct WireError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Deserialize)]
pub struct PongResult {
    pub version: String,
    pub protocol: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentStatus {
    Idle,
    Working,
    Blocked,
    Done,
    Unknown,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct SessionSnapshot {
    pub version: String,
    pub protocol: u32,
    pub focused_workspace_id: Option<String>,
    pub focused_tab_id: Option<String>,
    pub focused_pane_id: Option<String>,
    pub workspaces: Vec<WorkspaceInfo>,
    pub tabs: Vec<TabInfo>,
    pub panes: Vec<PaneInfo>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceInfo {
    pub workspace_id: String,
    pub number: u32,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub focused: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TabInfo {
    pub tab_id: String,
    pub workspace_id: String,
    pub number: u32,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub focused: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaneScrollInfo {
    pub offset_from_bottom: u64,
    pub max_offset_from_bottom: u64,
    pub viewport_rows: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AgentSessionInfo {
    pub agent: Option<String>,
    pub kind: String, // "id" | "path"
    pub value: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaneInfo {
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    #[serde(default)]
    pub focused: bool,
    pub agent_status: AgentStatus,
    #[serde(default)]
    pub revision: u64,
    pub cwd: Option<String>,
    pub label: Option<String>,
    pub agent: Option<String>,
    pub agent_session: Option<AgentSessionInfo>,
    pub scroll: Option<PaneScrollInfo>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaneReadResult {
    pub text: String,
    #[serde(default)]
    pub truncated: bool,
    #[serde(default)]
    pub revision: u64,
}

// 各 list 方法的响应包装（result.type 不同、内层字段名不同）：
#[derive(Debug, Deserialize)]
pub struct SnapshotResult { pub snapshot: SessionSnapshot }
#[derive(Debug, Deserialize)]
pub struct WorkspaceListResult { pub workspaces: Vec<WorkspaceInfo> }
#[derive(Debug, Deserialize)]
pub struct TabListResult { pub tabs: Vec<TabInfo> }
#[derive(Debug, Deserialize)]
pub struct PaneListResult { pub panes: Vec<PaneInfo> }
#[derive(Debug, Deserialize)]
pub struct PaneReadResponse { pub read: PaneReadResult }
