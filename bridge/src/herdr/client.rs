use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use super::types::*;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);
const SLOW_READ_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_CONCURRENT: usize = 8;

#[derive(Debug)]
pub enum HerdrError {
    Rpc { code: String, message: String },
    Io(String),
    Timeout,
    Closed,
}

impl HerdrError {
    pub fn is_unknown_variant(&self) -> bool {
        matches!(self, HerdrError::Rpc { code, message }
            if code == "invalid_request" && message.contains("unknown variant"))
    }
    pub fn is_pane_not_found(&self) -> bool {
        matches!(self, HerdrError::Rpc { code, .. } if code == "pane_not_found")
    }
    pub fn code(&self) -> Option<&str> {
        match self { HerdrError::Rpc { code, .. } => Some(code), _ => None }
    }
}

impl std::fmt::Display for HerdrError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HerdrError::Rpc { code, message } => write!(f, "{code}: {message}"),
            HerdrError::Io(m) => write!(f, "io: {m}"),
            HerdrError::Timeout => write!(f, "timeout"),
            HerdrError::Closed => write!(f, "connection closed"),
        }
    }
}
impl std::error::Error for HerdrError {}

#[derive(Clone)]
pub struct HerdrClient {
    socket_path: Arc<PathBuf>,
    counter: Arc<AtomicU64>,
    limiter: Arc<tokio::sync::Semaphore>,
}

impl HerdrClient {
    pub fn new(socket_path: PathBuf) -> Self {
        HerdrClient {
            socket_path: Arc::new(socket_path),
            counter: Arc::new(AtomicU64::new(0)),
            limiter: Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT)),
        }
    }

    /// 订阅类长连接（events.subscribe）不走 `call`，由调用方直连该路径。
    pub fn socket_path(&self) -> &Path {
        self.socket_path.as_ref()
    }

    pub async fn call<R, P>(&self, method: &str, params: &P, timeout: Duration)
        -> Result<R, HerdrError>
    where
        R: serde::de::DeserializeOwned,
        P: Serialize + ?Sized,
    {
        let _permit = self.limiter.acquire().await.map_err(|_| HerdrError::Closed)?;
        let id = format!("b{}", self.counter.fetch_add(1, Ordering::Relaxed));
        let req = serde_json::json!({"id": id, "method": method, "params": params});
        let mut line = serde_json::to_string(&req).map_err(|e| HerdrError::Io(e.to_string()))?;
        line.push('\n');
        debug_assert!(line.len() <= 1024 * 1024, "request line exceeds 1MB");

        let work = async {
            let stream = UnixStream::connect(self.socket_path.as_ref().as_path())
                .await
                .map_err(|e| HerdrError::Io(e.to_string()))?;
            let (r, mut w) = stream.into_split();
            w.write_all(line.as_bytes()).await.map_err(|e| HerdrError::Io(e.to_string()))?;
            // 流式 UTF-8：BufReader::read_line 内部按 chunk 读且保证只在
            // 完整 UTF-8 边界切（into_string 前是 Vec<u8>，read_line 对
            // 非 UTF-8 会报错而非截断乱码）。
            let mut reader = BufReader::new(r);
            let mut resp_line = Vec::new();
            let n = reader.read_until(b'\n', &mut resp_line).await
                .map_err(|e| HerdrError::Io(e.to_string()))?;
            if n == 0 { return Err(HerdrError::Closed); }
            let v: serde_json::Value = serde_json::from_slice(&resp_line)
                .map_err(|e| HerdrError::Io(format!("bad json: {e}")))?;
            if let Some(err) = v.get("error") {
                let e: WireError = serde_json::from_value(err.clone())
                    .map_err(|e| HerdrError::Io(e.to_string()))?;
                return Err(HerdrError::Rpc { code: e.code, message: e.message });
            }
            let result = v.get("result").cloned().ok_or(HerdrError::Closed)?;
            serde_json::from_value(result).map_err(|e| HerdrError::Io(format!("decode: {e}")))
        };
        match tokio::time::timeout(timeout, work).await {
            Ok(r) => r,
            Err(_) => Err(HerdrError::Timeout),
        }
    }

    pub async fn ping(&self) -> Result<PongResult, HerdrError> {
        self.call("ping", &serde_json::json!({}), DEFAULT_TIMEOUT).await
    }

    pub async fn snapshot(&self) -> Result<SessionSnapshot, HerdrError> {
        let r: SnapshotResult =
            self.call("session.snapshot", &serde_json::json!({}), DEFAULT_TIMEOUT).await?;
        Ok(r.snapshot)
    }

    pub async fn list_workspaces(&self) -> Result<Vec<WorkspaceInfo>, HerdrError> {
        let r: WorkspaceListResult =
            self.call("workspace.list", &serde_json::json!({}), DEFAULT_TIMEOUT).await?;
        Ok(r.workspaces)
    }

    pub async fn list_tabs(&self) -> Result<Vec<TabInfo>, HerdrError> {
        let r: TabListResult =
            self.call("tab.list", &serde_json::json!({}), DEFAULT_TIMEOUT).await?;
        Ok(r.tabs)
    }

    pub async fn list_panes(&self) -> Result<Vec<PaneInfo>, HerdrError> {
        let r: PaneListResult =
            self.call("pane.list", &serde_json::json!({}), DEFAULT_TIMEOUT).await?;
        Ok(r.panes)
    }

    /// `source`: "visible" | "recent" | "recent_unwrapped"（snake_case）。
    /// 慢读（recent 大 lines 可能触发 herdr 端滚动采集）由调用方用 slow=true。
    pub async fn pane_read(
        &self, pane_id: &str, source: &str, lines: Option<u32>, format: &str,
    ) -> Result<PaneReadResult, HerdrError> {
        let mut params = serde_json::json!({"pane_id": pane_id, "source": source, "format": format});
        if let Some(l) = lines { params["lines"] = l.into(); }
        let slow = source == "recent" && lines.unwrap_or(0) > 1000;
        let r: PaneReadResponse = self
            .call("pane.read", &params, if slow { SLOW_READ_TIMEOUT } else { DEFAULT_TIMEOUT })
            .await?;
        Ok(r.read)
    }

    pub async fn pane_send_text(&self, pane_id: &str, text: &str) -> Result<(), HerdrError> {
        self.call::<serde_json::Value, _>(
            "pane.send_text",
            &serde_json::json!({"pane_id": pane_id, "text": text}),
            DEFAULT_TIMEOUT,
        )
        .await?;
        Ok(())
    }

    pub async fn pane_send_keys(&self, pane_id: &str, keys: &[String]) -> Result<(), HerdrError> {
        self.call::<serde_json::Value, _>(
            "pane.send_keys",
            &serde_json::json!({"pane_id": pane_id, "keys": keys}),
            DEFAULT_TIMEOUT,
        )
        .await?;
        Ok(())
    }

    pub async fn pane_close(&self, pane_id: &str) -> Result<(), HerdrError> {
        self.call::<serde_json::Value, _>(
            "pane.close", &serde_json::json!({"pane_id": pane_id}), DEFAULT_TIMEOUT,
        )
        .await?;
        Ok(())
    }

    pub async fn pane_rename(&self, pane_id: &str, label: Option<&str>) -> Result<(), HerdrError> {
        self.call::<serde_json::Value, _>(
            "pane.rename",
            &serde_json::json!({"pane_id": pane_id, "label": label}),
            DEFAULT_TIMEOUT,
        )
        .await?;
        Ok(())
    }

    pub async fn agent_kinds(&self) -> Result<Vec<String>, HerdrError> {
        let r: AgentManifestStatusResult = self
            .call("server.agent_manifests", &serde_json::json!({}), DEFAULT_TIMEOUT)
            .await?;
        Ok(r.manifests.into_iter().map(|manifest| manifest.agent).collect())
    }

    pub async fn create_workspace(
        &self, cwd: &str, label: &str,
    ) -> Result<CreatedPane, HerdrError> {
        let r: WorkspaceCreatedResult = self
            .call(
                "workspace.create",
                &serde_json::json!({
                    "cwd": cwd,
                    "label": label,
                    "env": {},
                    "focus": false,
                }),
                DEFAULT_TIMEOUT,
            )
            .await?;
        Ok(CreatedPane {
            workspace_id: r.workspace.workspace_id,
            tab_id: r.tab.tab_id,
            pane_id: r.root_pane.pane_id,
        })
    }

    pub async fn create_tab(
        &self, workspace_id: &str, cwd: &str, label: &str,
    ) -> Result<CreatedPane, HerdrError> {
        let r: TabCreatedResult = self
            .call(
                "tab.create",
                &serde_json::json!({
                    "workspace_id": workspace_id,
                    "cwd": cwd,
                    "label": label,
                    "env": {},
                    "focus": false,
                }),
                DEFAULT_TIMEOUT,
            )
            .await?;
        Ok(CreatedPane {
            workspace_id: r.tab.workspace_id,
            tab_id: r.tab.tab_id,
            pane_id: r.root_pane.pane_id,
        })
    }

    pub async fn start_agent(
        &self, name: &str, kind: &str, pane_id: &str, timeout_ms: u64,
    ) -> Result<(), HerdrError> {
        self.call::<serde_json::Value, _>(
            "agent.start",
            &serde_json::json!({
                "name": name,
                "kind": kind,
                "pane_id": pane_id,
                "args": [],
                "timeout_ms": timeout_ms,
            }),
            Duration::from_millis(timeout_ms + 5_000),
        )
        .await?;
        Ok(())
    }
}
