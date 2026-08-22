use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use axum::http::StatusCode;
use tokio::sync::watch;

use crate::config::Config;
use crate::error::ApiError;
use crate::herdr::client::HerdrClient;
use crate::herdr::events::EventPoker;
use crate::herdr::types::AgentStatus;
use crate::http::SessionRuntime;
use crate::state::activity::ActivityLedger;
use crate::state::engine::StateEngine;
use crate::state::view::{build_pane_wires, SessionSummary};

struct RuntimeEntry {
    runtime: Arc<SessionRuntime>,
    shutdown: watch::Sender<bool>,
}

/// 多 session 注册表：config root 下每个 herdr.sock（含 sessions/<name>/）一个
/// 独立 client/engine/poker runtime。客户端提供的 session 名只做 HashMap 查找，
/// 绝不拼进文件系统路径。
pub struct SessionRegistry {
    cfg: Arc<Config>,
    activity: ActivityLedger,
    primary_name: String,
    entries: Mutex<HashMap<String, RuntimeEntry>>,
}

/// socket 含 `/sessions/<name>/` → 其前缀；否则 socket 的父目录。
pub fn derive_config_root(socket_path: &Path) -> PathBuf {
    let s = socket_path.to_string_lossy();
    if let Some(idx) = s.find("/sessions/") {
        return PathBuf::from(&s[..idx]);
    }
    socket_path.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."))
}

/// socket 是命名 session（含 `/sessions/<name>/`）→ 该 name，否则 "default"。
pub fn session_name_for(socket_path: &Path) -> String {
    let s = socket_path.to_string_lossy();
    if let Some(idx) = s.find("/sessions/") {
        let rest = &s[idx + "/sessions/".len()..];
        if let Some(end) = rest.find('/') {
            return rest[..end].to_string();
        }
    }
    "default".to_string()
}

impl SessionRegistry {
    /// 构造即 eagerly 起 primary runtime（cfg.socket_path 指向的那个）。
    pub fn new(cfg: Arc<Config>, activity: ActivityLedger) -> Arc<Self> {
        let primary_name = session_name_for(&cfg.socket_path);
        let socket = cfg.socket_path.clone();
        let registry = Arc::new(SessionRegistry {
            cfg, activity, primary_name: primary_name.clone(),
            entries: Mutex::new(HashMap::new()),
        });
        registry.spawn_runtime(&primary_name, socket);
        registry
    }

    fn spawn_runtime(&self, name: &str, socket: PathBuf) {
        let (tx, rx) = watch::channel(false);
        let client = HerdrClient::new(socket);
        let engine = StateEngine::new(
            client.clone(), self.cfg.poll_ms, self.cfg.poll_idle_ms,
            self.activity.clone(), name.to_string());
        {
            let e = engine.clone();
            let rx2 = rx.clone();
            tokio::spawn(async move { e.run(rx2).await });
        }
        {
            let poker = EventPoker::new(client.clone(), engine.clone());
            tokio::spawn(async move { poker.run(rx).await });
        }
        let rt = Arc::new(SessionRuntime { name: name.to_string(), client, engine });
        self.entries.lock().unwrap()
            .insert(name.to_string(), RuntimeEntry { runtime: rt, shutdown: tx });
    }

    /// 空/缺席 → primary；未知名 → 404 session_not_found。
    /// 安全不变量：name 只做 HashMap 查找，绝不拼路径。
    pub fn runtime(&self, name: Option<&str>) -> Result<Arc<SessionRuntime>, ApiError> {
        let name = name.map(str::trim).filter(|s| !s.is_empty())
            .unwrap_or(&self.primary_name);
        self.entries.lock().unwrap().get(name)
            .map(|e| e.runtime.clone())
            .ok_or_else(|| ApiError::new(
                StatusCode::NOT_FOUND, "session_not_found",
                format!("unknown session: {name}")))
    }

    /// primary 第一，其余按 name 字典序；unreachable 时 agents/working/blocked 为 0。
    /// has_adapter 由调用方注入（journal 判定），registry 不依赖 journal 模块。
    pub fn summaries(&self, has_adapter: &dyn Fn(&str) -> bool) -> Vec<SessionSummary> {
        let entries = self.entries.lock().unwrap();
        let mut out: Vec<SessionSummary> = entries.iter().map(|(name, e)| {
            let view = e.runtime.engine.current();
            let activity = e.runtime.engine.activity_snapshot();
            let names = e.runtime.engine.session_names();
            let (agents, _) = build_pane_wires(&view, &activity, &names, has_adapter);
            let reachable = view.connected;
            SessionSummary {
                name: name.clone(),
                is_primary: *name == self.primary_name,
                reachable,
                agents: if reachable { agents.len() as u32 } else { 0 },
                working: if reachable {
                    agents.iter().filter(|a| a.status == AgentStatus::Working).count() as u32
                } else { 0 },
                blocked: if reachable {
                    agents.iter().filter(|a| a.status == AgentStatus::Blocked).count() as u32
                } else { 0 },
            }
        }).collect();
        drop(entries);
        out.sort_by(|a, b| b.is_primary.cmp(&a.is_primary).then(a.name.cmp(&b.name)));
        out
    }

    /// refresh_loop 的单次迭代（测试用）：扫 config root，新 socket 起 runtime，
    /// 消失的 dispose（shutdown + 移除；primary 例外）。multi_session == false 时只看 primary。
    pub async fn refresh_once(&self) {
        if !self.cfg.multi_session {
            return;
        }
        let root = derive_config_root(&self.cfg.socket_path);
        let mut found: Vec<(String, PathBuf)> = Vec::new();
        let default_sock = root.join("herdr.sock");
        if default_sock.exists() {
            found.push((session_name_for(&default_sock), default_sock));
        }
        if let Ok(rd) = std::fs::read_dir(root.join("sessions")) {
            for entry in rd.flatten() {
                let sock = entry.path().join("herdr.sock");
                if sock.exists() {
                    found.push((session_name_for(&sock), sock));
                }
            }
        }
        let found_names: std::collections::HashSet<String> =
            found.iter().map(|(n, _)| n.clone()).collect();
        // 新增
        for (name, sock) in found {
            if !self.entries.lock().unwrap().contains_key(&name) {
                tracing::info!(session = %name, "discovered herdr session");
                self.spawn_runtime(&name, sock);
            }
        }
        // 消失
        let gone: Vec<String> = self.entries.lock().unwrap().keys()
            .filter(|k| !found_names.contains(*k) && **k != self.primary_name)
            .cloned().collect();
        for name in gone {
            if let Some(e) = self.entries.lock().unwrap().remove(&name) {
                let _ = e.shutdown.send(true);
                tracing::info!(session = %name, "session gone, disposed");
            }
        }
    }

    /// 信号处理路径：flush 共享账本（所有 session 共用一个 ledger，一次落盘即可）。
    pub fn flush_activity(&self) {
        self.activity.flush();
    }

    pub async fn refresh_loop(self: &Arc<Self>, mut shutdown: watch::Receiver<bool>) {        loop {
            self.refresh_once().await;
            tokio::select! {
                _ = shutdown.changed() => return,
                _ = tokio::time::sleep(std::time::Duration::from_secs(15)) => {}
            }
        }
    }
}
