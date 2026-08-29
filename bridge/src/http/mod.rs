pub mod auth;
pub mod etag;   // Task 20 填充，本任务放空文件占位
pub mod routes;

use std::sync::Arc;
use axum::Router;
use tower_http::compression::CompressionLayer;

use crate::audit::AuditLog;
use crate::config::Config;
use crate::herdr::client::HerdrClient;
use crate::journal::JournalRegistry;
use crate::sessions::SessionRegistry;
use crate::state::engine::StateEngine;
use crate::terminal_resize::TerminalLeaseManager;

pub struct SessionRuntime {
    pub name: String,
    pub client: HerdrClient,
    pub engine: Arc<StateEngine>,
}

// 测试的 unwrap_err 需要 Debug；只报 name，client/engine 无有意义状态可打。
impl std::fmt::Debug for SessionRuntime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionRuntime").field("name", &self.name).finish()
    }
}

#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    pub registry: Arc<SessionRegistry>,
    pub audit: Arc<AuditLog>,
    pub journal: Arc<JournalRegistry>,
    pub terminal_leases: TerminalLeaseManager,
}

impl AppState {
    pub fn runtime(&self, session: Option<&str>) -> Result<Arc<SessionRuntime>, crate::error::ApiError> {
        self.registry.runtime(session)
    }
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/api/v1/config", axum::routing::get(routes::get_config))
        .route("/api/v1/snapshot", axum::routing::get(routes::get_snapshot))
        .route("/api/v1/agents/kinds", axum::routing::get(routes::get_agent_kinds))
        .route("/api/v1/agents", axum::routing::post(routes::create_agent))
        .route("/api/v1/pane/{id}", axum::routing::get(routes::read_pane))
        .route("/api/v1/pane/{id}/stream", axum::routing::get(routes::stream_pane))
        .route("/api/v1/pane/{id}/history", axum::routing::get(routes::pane_history))
        .route("/api/v1/pane/{id}/reply", axum::routing::post(routes::reply_pane))
        .route("/api/v1/pane/{id}/keys", axum::routing::post(routes::keys_pane))
        .route("/api/v1/pane/{id}/resize", axum::routing::post(routes::resize_pane))
        .route(
            "/api/v1/pane/{id}/resize/{lease_id}",
            axum::routing::delete(routes::release_pane_resize),
        )
        .route("/api/v1/pane/{id}/close", axum::routing::post(routes::close_pane))
        .route("/api/v1/pane/{id}/rename", axum::routing::post(routes::rename_pane))
        .route("/api/v1/pane/{id}/upload", axum::routing::post(routes::upload_pane))
        .fallback(routes::not_found)
        .method_not_allowed_fallback(routes::method_not_allowed)
        .layer(axum::extract::DefaultBodyLimit::max(12 * 1024 * 1024))
        .layer(CompressionLayer::new())
        .with_state(state)
}

/// 测试辅助：起单 session registry（primary = mock socket），返回 state 与 shutdown。
pub async fn test_app_state(cfg: Arc<Config>) -> (AppState, tokio::sync::watch::Sender<bool>) {
    let (tx, rx) = tokio::sync::watch::channel(false);
    std::fs::create_dir_all(&cfg.state_dir).ok();
    let audit = Arc::new(AuditLog::new(&cfg.state_dir));
    let activity = crate::state::activity::ActivityLedger::load(&cfg.state_dir.join("activity.json"));
    let registry = SessionRegistry::new(cfg.clone(), activity);
    let registry_loop = registry.clone();
    tokio::spawn(async move { registry_loop.refresh_loop(rx).await });
    let journal = Arc::new(JournalRegistry::new(&cfg));
    let terminal_leases = TerminalLeaseManager::new(cfg.herdr_bin_path.clone());
    let state = AppState { cfg, registry, audit, journal, terminal_leases };
    (state, tx)
}
