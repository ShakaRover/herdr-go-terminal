use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::watch;

use crate::herdr::client::HerdrClient;
use crate::state::engine::StateEngine;

const GLOBAL_SUBSCRIPTIONS: &[&str] = &[
    "workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed",
    "workspace.focused", "tab.created", "tab.closed", "tab.focused", "tab.renamed",
    "pane.created", "pane.closed", "pane.focused", "pane.moved", "pane.exited",
    "pane.agent_detected",
];
const BACKOFF_MS: &[u64] = &[1000, 2000, 5000, 15000];
const ACK_TIMEOUT: Duration = Duration::from_secs(5);

pub struct EventPoker {
    client: HerdrClient,
    engine: std::sync::Arc<StateEngine>,
}

impl EventPoker {
    pub fn new(client: HerdrClient, engine: std::sync::Arc<StateEngine>) -> Self {
        EventPoker { client, engine }
    }

    fn subscription_set(&self) -> serde_json::Value {
        let mut subs: Vec<serde_json::Value> = GLOBAL_SUBSCRIPTIONS.iter()
            .map(|t| serde_json::json!({"type": t})).collect();
        for p in &self.engine.current().panes {
            if p.agent.as_ref().is_some_and(|a| !a.is_empty()) {
                subs.push(serde_json::json!({
                    "type": "pane.agent_status_changed", "pane_id": p.pane_id,
                }));
            }
        }
        serde_json::json!({"subscriptions": subs})
    }

    pub async fn run(self, mut shutdown: watch::Receiver<bool>) {
        // 等 engine 首轮 poll 成功再订阅：首订阅集即含当前 agent panes
        // （否则首轮订阅先于 view 填充，per-pane 订阅要等 2s 检查补上）。
        // herdr 不可达时 connected 恒 false，此处空转等 herdr 恢复即可。
        while !self.engine.current().connected {
            tokio::select! {
                _ = shutdown.changed() => return,
                _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            }
        }
        let mut attempts = 0usize;
        let mut subscribed_agents: Vec<String> = Vec::new();
        loop {
            if *shutdown.borrow() { return; }
            match self.connect_once(&mut shutdown, &mut subscribed_agents).await {
                Ok(()) => attempts = 0, // 对端正常关闭
                Err(e) => {
                    tracing::debug!("event stream down: {e}");
                }
            }
            self.engine.set_stream_healthy(false);
            let wait = BACKOFF_MS[attempts.min(BACKOFF_MS.len() - 1)];
            attempts = attempts.saturating_add(1);
            tokio::select! {
                _ = shutdown.changed() => return,
                _ = tokio::time::sleep(Duration::from_millis(wait)) => {}
            }
        }
    }

    async fn connect_once(
        &self, shutdown: &mut watch::Receiver<bool>, subscribed_agents: &mut Vec<String>,
    ) -> Result<(), String> {
        let stream = UnixStream::connect(self.client.socket_path()).await
            .map_err(|e| e.to_string())?;
        let (r, mut w) = stream.into_split();
        let req = serde_json::json!({
            "id": "es1", "method": "events.subscribe", "params": self.subscription_set(),
        });
        *subscribed_agents = self.engine.current().panes.iter()
            .filter(|p| p.agent.as_ref().is_some_and(|a| !a.is_empty()))
            .map(|p| p.pane_id.clone()).collect();
        let mut line = serde_json::to_string(&req).unwrap();
        line.push('\n');
        w.write_all(line.as_bytes()).await.map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(r);
        // 等 ack
        let mut ack = Vec::new();
        let n = tokio::time::timeout(ACK_TIMEOUT, reader.read_until(b'\n', &mut ack))
            .await.map_err(|_| "ack timeout".to_string())?
            .map_err(|e| e.to_string())?;
        if n == 0 { return Err("closed before ack".into()); }
        let v: serde_json::Value = serde_json::from_slice(&ack).map_err(|e| e.to_string())?;
        if v.get("error").is_some() { return Err(format!("subscribe rejected: {v}")); }
        self.engine.set_stream_healthy(true);
        // 事件循环：任意行 → poke；agent 集合变化 → 主动断开重订阅
        loop {
            let mut buf = Vec::new();
            tokio::select! {
                _ = shutdown.changed() => return Ok(()),
                n = reader.read_until(b'\n', &mut buf) => {
                    match n {
                        Ok(0) => return Ok(()),
                        Ok(_) => self.engine.poke(),
                        Err(e) => return Err(e.to_string()),
                    }
                }
                _ = tokio::time::sleep(Duration::from_millis(2000)) => {
                    let now: Vec<String> = self.engine.current().panes.iter()
                        .filter(|p| p.agent.as_ref().is_some_and(|a| !a.is_empty()))
                        .map(|p| p.pane_id.clone()).collect();
                    if now != *subscribed_agents { return Ok(()); } // 触发重订阅
                }
            }
        }
    }
}
