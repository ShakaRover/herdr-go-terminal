use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;

/// 脚本化 mock herdr server：每连接读一行请求，按 method 查脚本回一行。
/// 脚本键为 method 名；未命中回 invalid_request。
pub struct MockHerdr {
    pub socket_path: PathBuf,
    // 各测试二进制按需使用（如 contract_read）；未用者保持静默。
    #[allow(dead_code)]
    pub requests: std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
    _dir: tempfile::TempDir,
    // stop()/shutdown 由后续任务的写路径测试使用。
    #[allow(dead_code)]
    shutdown: tokio::sync::watch::Sender<bool>,
}

impl MockHerdr {
    /// script: method 名 → 返回的 result JSON（error 用 {"__error__": {code,message}}；
    /// 订阅流用 {"__stream__": [event...]}：ack 后逐行发事件并保持连接）。
    pub async fn start(script: serde_json::Map<String, serde_json::Value>) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("herdr.sock");
        let (requests, shutdown) = Self::serve(&path, script).await;
        MockHerdr { socket_path: path, requests, _dir: dir, shutdown }
    }

    /// bind 到调用方指定的 socket 路径（tempdir 由调用方持有）：
    /// 多 session 发现测试需要在固定布局下放多个 socket。
    #[allow(dead_code)]
    pub async fn start_at(path: &std::path::Path, script: serde_json::Map<String, serde_json::Value>) -> Self {
        let (requests, shutdown) = Self::serve(path, script).await;
        // 生命周期占位：调用方指定路径时 socket 清理由调用方目录负责。
        let dir = tempfile::tempdir().unwrap();
        MockHerdr { socket_path: path.to_path_buf(), requests, _dir: dir, shutdown }
    }

    async fn serve(path: &std::path::Path, script: serde_json::Map<String, serde_json::Value>)
        -> (std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>, tokio::sync::watch::Sender<bool>)
    {
        let listener = UnixListener::bind(path).unwrap();
        let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let (tx, mut rx) = tokio::sync::watch::channel(false);
        let reqs = requests.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = rx.changed() => break,
                    accept = listener.accept() => {
                        let (stream, _) = accept.unwrap();
                        let script = script.clone();
                        let reqs = reqs.clone();
                        tokio::spawn(async move {
                            let (r, mut w) = stream.into_split();
                            let mut reader = BufReader::new(r);
                            let mut line = String::new();
                            if reader.read_line(&mut line).await.is_err() { return; }
                            let req: serde_json::Value = match serde_json::from_str(&line) {
                                Ok(v) => v, Err(_) => return,
                            };
                            reqs.lock().unwrap().push(req.clone());
                            let id = req["id"].clone();
                            let method = req["method"].as_str().unwrap_or("").to_string();
                            // 特化键：先查 `<method>:<params.source>`（如
                            // "pane.read:visible"），未命中再回退 `<method>`。
                            let specialized = req["params"]["source"].as_str()
                                .map(|s| format!("{method}:{s}"))
                                .filter(|k| script.contains_key(k));
                            let key = specialized.as_deref().unwrap_or(&method);
                            match script.get(key) {
                                // 订阅流：先回 ack，再逐行发事件，之后保持连接
                                // 直到客户端断开（读到 EOF）。
                                Some(v) if v.get("__stream__").is_some() => {
                                    let ack = serde_json::json!({
                                        "id": id, "result": {"type": "subscription_started"}
                                    });
                                    let mut s = serde_json::to_string(&ack).unwrap();
                                    s.push('\n');
                                    if w.write_all(s.as_bytes()).await.is_err() { return; }
                                    if let Some(events) = v["__stream__"].as_array() {
                                        for ev in events {
                                            let mut s = serde_json::to_string(ev).unwrap();
                                            s.push('\n');
                                            if w.write_all(s.as_bytes()).await.is_err() { return; }
                                        }
                                    }
                                    loop {
                                        let mut l = String::new();
                                        match reader.read_line(&mut l).await {
                                            Ok(0) | Err(_) => return,
                                            Ok(_) => {}
                                        }
                                    }
                                }
                                other => {
                                    let resp = match other {
                                        Some(v) if v.get("__error__").is_some() => {
                                            serde_json::json!({"id": id, "error": v["__error__"]})
                                        }
                                        Some(v) => serde_json::json!({"id": id, "result": v}),
                                        None => serde_json::json!({"id": "", "error": {
                                            "code": "invalid_request",
                                            "message": format!(
                                                "invalid request: unknown variant `{method}`"),
                                        }}),
                                    };
                                    let mut s = serde_json::to_string(&resp).unwrap();
                                    s.push('\n');
                                    let _ = w.write_all(s.as_bytes()).await;
                                    // 一连接一请求：写完即关。
                                }
                            }
                        });
                    }
                }
            }
        });
        (requests, tx)
    }

    #[allow(dead_code)]
    pub fn stop(&self) { let _ = self.shutdown.send(true); }

    #[allow(dead_code)]
    pub fn received(&self, method: &str) -> Vec<serde_json::Value> {
        self.requests.lock().unwrap().iter()
            .filter(|r| r["method"].as_str() == Some(method)).cloned().collect()
    }

    /// 按 method 与 params.source 查收到的请求（与脚本特化键同规则）。
    #[allow(dead_code)]
    pub fn received_with_source(&self, method: &str, source: &str) -> Vec<serde_json::Value> {
        self.requests.lock().unwrap().iter()
            .filter(|r| r["method"].as_str() == Some(method)
                && r["params"]["source"].as_str() == Some(source))
            .cloned().collect()
    }
}

/// Task 3 的 snapshot 脚本：两 workspace、三 pane（blocked claude + working codex + idle shell）。
#[allow(dead_code)]
pub fn engine_script() -> serde_json::Map<String, serde_json::Value> {
    let mut script = serde_json::Map::new();
    script.insert("session.snapshot".into(), serde_json::json!({
        "type": "session_snapshot",
        "snapshot": {
            "version": "0.8.0", "protocol": 19,
            "workspaces": [
                {"workspace_id": "w1", "number": 1, "label": "one", "focused": true,
                 "pane_count": 2, "tab_count": 1, "active_tab_id": "w1:t1",
                 "agent_status": "blocked"},
                {"workspace_id": "w2", "number": 2, "label": "two", "focused": false,
                 "pane_count": 1, "tab_count": 1, "active_tab_id": "w2:t1",
                 "agent_status": "working"}
            ],
            "tabs": [
                {"tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "",
                 "focused": true, "pane_count": 2, "agent_status": "blocked"},
                {"tab_id": "w2:t1", "workspace_id": "w2", "number": 1, "label": "build",
                 "focused": false, "pane_count": 1, "agent_status": "working"}
            ],
            "panes": [
                {"pane_id": "w1:p2", "terminal_id": "t2", "workspace_id": "w1",
                 "tab_id": "w1:t1", "focused": false, "cwd": "/a", "agent": "codex",
                 "agent_status": "working", "revision": 3},
                {"pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1",
                 "tab_id": "w1:t1", "focused": true, "cwd": "/b", "agent": "claude",
                 "agent_status": "blocked", "revision": 9,
                 "scroll": {"offset_from_bottom": 0, "max_offset_from_bottom": 40,
                            "viewport_rows": 24}},
                {"pane_id": "w2:p1", "terminal_id": "t3", "workspace_id": "w2",
                 "tab_id": "w2:t1", "focused": false, "cwd": "/c",
                 "agent_status": "idle", "revision": 1}
            ],
            "layouts": [], "agents": []
        }
    }));
    script
}
