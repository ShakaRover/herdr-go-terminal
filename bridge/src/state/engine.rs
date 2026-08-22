use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::watch;

use crate::herdr::client::HerdrClient;
use crate::herdr::types::SessionSnapshot;
use super::activity::ActivityLedger;
use super::session_name;
use super::view::EngineView;

pub struct StateEngine {
    client: HerdrClient,
    poll_ms: u64,
    poll_idle_ms: u64,
    // 本 engine 绑定的 herdr session 名：activity 账本与 session_names 缓存
    // 的 pane 键统一带 `{session}\u{1f}` 前缀，多 session 共享一份账本互不干扰。
    session: String,
    activity: ActivityLedger,
    inner: Mutex<Inner>,
    // claude pane 的 session 名缓存（paneId → name），sticky：有缓存不再重读，
    // pane 消失才清。std Mutex：仅覆盖同步 map 读写，pane_read 的 IO 在锁外。
    // 键同样带 session 前缀，session_names() 返回时解掉。
    session_names: Mutex<HashMap<String, String>>,
    poke_tx: tokio::sync::mpsc::Sender<()>,
    // tokio Mutex：guard 需跨 .await 持有（select! 分支内 recv），
    // std MutexGuard 非 Send，无法用于 tokio::spawn 的 run。
    poke_rx: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<()>>,
}

struct Inner {
    view: EngineView,
    use_fallback: bool, // unknown variant → 永久三路 list
    stream_healthy: bool,
}

impl StateEngine {
    pub fn new(client: HerdrClient, poll_ms: u64, poll_idle_ms: u64,
               activity: ActivityLedger, session: String) -> Arc<Self> {
        let (poke_tx, poke_rx) = tokio::sync::mpsc::channel(1);
        Arc::new(StateEngine {
            client,
            poll_ms,
            poll_idle_ms,
            session,
            activity,
            inner: Mutex::new(Inner {
                view: EngineView { connected: false, panes: vec![], workspaces: vec![], tabs: vec![] },
                use_fallback: false,
                stream_healthy: false,
            }),
            session_names: Mutex::new(HashMap::new()),
            poke_tx,
            poke_rx: tokio::sync::Mutex::new(poke_rx),
        })
    }

    pub fn activity(&self) -> &ActivityLedger {
        &self.activity
    }

    /// 本 session 的 activity 键前缀拼接。
    fn prefixed(&self, pane_id: &str) -> String {
        format!("{}{}{}", self.session, super::activity::SEP, pane_id)
    }

    /// 解前缀后的本 session activity 视图（paneId -> (activeAt, seenAt)）。
    pub fn activity_snapshot(&self) -> HashMap<String, (u64, u64)> {
        self.activity.snapshot_scoped(&self.session)
    }

    /// 解前缀后的 session 名缓存（paneId → name）。
    pub fn session_names(&self) -> HashMap<String, String> {
        let needle = self.prefixed("");
        self.session_names.lock().unwrap().iter()
            .filter_map(|(k, v)| k.strip_prefix(needle.as_str())
                .map(|k| (k.to_string(), v.clone())))
            .collect()
    }

    pub fn current(&self) -> EngineView {
        self.inner.lock().unwrap().view.clone()
    }

    pub fn mark_seen(&self, pane_id: &str) {
        self.activity.note_seen(&self.prefixed(pane_id), crate::http::routes::now_ms());
    }

    pub fn set_stream_healthy(&self, healthy: bool) {
        self.inner.lock().unwrap().stream_healthy = healthy;
    }

    /// 事件 poke：200ms 尾随去抖后 poll 一次。channel 容量 1，满了即已有排队。
    pub fn poke(&self) {
        let _ = self.poke_tx.try_send(());
    }

    async fn poll_once(&self) {
        let use_fallback = self.inner.lock().unwrap().use_fallback;
        let result = if use_fallback {
            self.poll_via_lists().await
        } else {
            match self.client.snapshot().await {
                Ok(s) => Ok(s),
                Err(e) if e.is_unknown_variant() => {
                    self.inner.lock().unwrap().use_fallback = true;
                    self.poll_via_lists().await
                }
                Err(e) => Err(e),
            }
        };
        match result {
            Ok(snap) => {
                let now = crate::http::routes::now_ms();
                let live: HashSet<String> = snap.panes.iter()
                    .map(|p| self.prefixed(&p.pane_id)).collect();
                let claude_panes: Vec<(String, String)> = snap.panes.iter()
                    .filter(|p| p.agent.as_deref() == Some("claude"))
                    .map(|p| (p.pane_id.clone(), self.prefixed(&p.pane_id)))
                    .collect();
                // transition 检测：对比旧 view 的 agent_status。
                // 首见由 reconcile 的 or_insert 种子化（不产生 transition）。
                // 检测在独立作用域完成并释放 inner 锁，再 reconcile、再更新 view，避免锁交叉。
                {
                    let inner = self.inner.lock().unwrap();
                    for p in &snap.panes {
                        let prev = inner.view.panes.iter().find(|o| o.pane_id == p.pane_id);
                        if let Some(prev) = prev {
                            if prev.agent_status != p.agent_status {
                                self.activity.note_transition(&self.prefixed(&p.pane_id), now);
                            }
                        }
                    }
                }
                self.activity.reconcile(&self.session.clone(), &live, now);
                // 顺带清 names 里消失的 pane（有缓存不重读，pane 消失才清）
                self.session_names.lock().unwrap().retain(|k, _| live.contains(k));
                {
                    let mut inner = self.inner.lock().unwrap();
                    inner.view = EngineView {
                        connected: true,
                        panes: snap.panes,
                        workspaces: snap.workspaces,
                        tabs: snap.tabs,
                    };
                } // 提取循环要 await，锁作用域到此为止
                // 对无缓存的 claude pane 顺序发 visible read（40 行，text 格式；
                // 绝不能 recent——会滚动操作者的终端）提取 ── name ── 横线名。
                // pane_id 发原值给 herdr；缓存键用带前缀值。失败静默跳过，下轮 poll 重试。
                for (pane_id, pane_key) in claude_panes {
                    if self.session_names.lock().unwrap().contains_key(&pane_key) { continue; }
                    if let Ok(read) = self.client.pane_read(&pane_id, "visible", Some(40), "text").await {
                        if let Some(name) = session_name::extract_claude_session_name(&read.text) {
                            self.session_names.lock().unwrap().insert(pane_key, name);
                        }
                    }
                }
            }
            Err(e) => {
                tracing::warn!("poll failed: {e}");
                self.inner.lock().unwrap().view.connected = false;
            }
        }
    }

    async fn poll_via_lists(&self) -> Result<SessionSnapshot, crate::herdr::client::HerdrError> {
        let workspaces = self.client.list_workspaces().await?;
        let tabs = self.client.list_tabs().await?;
        let panes = self.client.list_panes().await?;
        Ok(SessionSnapshot {
            version: String::new(), protocol: 0,
            focused_workspace_id: None, focused_tab_id: None, focused_pane_id: None,
            workspaces, tabs, panes,
        })
    }

    pub async fn run(self: &Arc<Self>, mut shutdown: watch::Receiver<bool>) {
        loop {
            self.poll_once().await;
            let idle = {
                let inner = self.inner.lock().unwrap();
                if inner.stream_healthy { self.poll_idle_ms } else { self.poll_ms }
            };
            // poke 等待与周期等待取先到者；poke 做 200ms 尾随去抖。
            let mut rx = self.poke_rx.lock().await;
            tokio::select! {
                _ = shutdown.changed() => {
                    // shutdown flush：去抖间隔内的账本更新在退出前落盘。
                    self.activity.flush();
                    return;
                }
                _ = tokio::time::sleep(Duration::from_millis(idle)) => {}
                _ = async {
                    rx.recv().await;
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    while rx.try_recv().is_ok() {} // 排空尾随 poke
                } => {}
            }
            drop(rx);
        }
    }
}
