mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

const UUID: &str = "123e4567-e89b-42d3-a456-426614174000";

// 偏离 brief：返回并持有 MockHerdr——helper 内 drop 会连 TempDir 一起删掉
// socket，engine 永远连不上，断言无法成立（现有测试同以 `_m` 持有）。
// state_dir 指 tempdir 与 contract_read.rs 同因：避免测试写真实 state dir。
async fn history_app(claude_root: &std::path::Path)
    -> (common::MockHerdr, axum::Router, tokio::sync::watch::Sender<bool>)
{
    let mut script = serde_json::Map::new();
    script.insert("session.snapshot".into(), serde_json::json!({
        "type": "session_snapshot", "snapshot": {
            "version": "0.8.0", "protocol": 19, "workspaces": [], "tabs": [],
            "panes": [{
                "pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1",
                "tab_id": "w1:t1", "focused": true, "cwd": "/x", "agent": "claude",
                "agent_status": "idle", "revision": 1,
                "agent_session": {"source": "hooks", "agent": "claude",
                                  "kind": "id", "value": UUID}
            }],
            "layouts": [], "agents": []}}));
    let mock = common::MockHerdr::start(script).await;
    let mut cfg = herdrgo_bridge::config::Config::from_cli(&herdrgo_bridge::config::Cli::from_process_env());
    cfg.socket_path = mock.socket_path.clone();
    cfg.transcript_roots = vec![claude_root.to_path_buf()];
    let state_dir = tempfile::tempdir().unwrap();
    cfg.state_dir = state_dir.path().to_path_buf();
    let (state, sd) = herdrgo_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    (mock, herdrgo_bridge::http::build_router(state), sd)
}

#[tokio::test]
async fn history_pages_and_flags() {
    let dir = tempfile::tempdir().unwrap();
    let sub = dir.path().join("proj");
    std::fs::create_dir_all(&sub).unwrap();
    let mut lines = Vec::new();
    for i in 0..5 {
        lines.push(serde_json::json!({"uuid": format!("u{i}"), "type": "user",
            "timestamp": "2026-01-01T00:00:00Z",
            "message": {"content": format!("msg {i}")}}).to_string());
    }
    std::fs::write(sub.join(format!("{UUID}.jsonl")), lines.join("\n") + "\n").unwrap();
    let (_m, app, _sd) = history_app(dir.path()).await;
    tokio::time::sleep(std::time::Duration::from_millis(400)).await; // 等首轮 poll
    // 最新页 limit=2
    let res = app.clone().oneshot(Request::builder()
        .uri("/api/v1/pane/w1:p1/history?limit=2")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(v["available"], true);
    assert_eq!(v["entries"][0]["uuid"], "u3");
    assert_eq!(v["hasMore"], true);
    assert_eq!(v["total"], 5);
    // before=u3 翻页
    let res2 = app.clone().oneshot(Request::builder()
        .uri("/api/v1/pane/w1:p1/history?limit=2&before=u3")
        .body(Body::empty()).unwrap()).await.unwrap();
    let b2 = axum::body::to_bytes(res2.into_body(), usize::MAX).await.unwrap();
    let v2: serde_json::Value = serde_json::from_slice(&b2).unwrap();
    assert_eq!(v2["entries"][0]["uuid"], "u1");
    // snapshot 的 hasSession
    let res3 = app.oneshot(Request::builder().uri("/api/v1/snapshot")
        .body(Body::empty()).unwrap()).await.unwrap();
    let b3 = axum::body::to_bytes(res3.into_body(), usize::MAX).await.unwrap();
    let v3: serde_json::Value = serde_json::from_slice(&b3).unwrap();
    assert_eq!(v3["agents"][0]["hasSession"], true);
}

#[tokio::test]
async fn history_unknown_pane_is_no_session() {
    let dir = tempfile::tempdir().unwrap();
    let (_m, app, _sd) = history_app(dir.path()).await;
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    let res = app.oneshot(Request::builder().uri("/api/v1/pane/w9:p9/history")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(v["available"], false);
    assert_eq!(v["reason"], "no-session");
}
