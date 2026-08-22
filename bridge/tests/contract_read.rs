mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

async fn test_app(script: serde_json::Map<String, serde_json::Value>)
    -> (common::MockHerdr, axum::Router, tokio::sync::watch::Sender<bool>)
{
    let mock = common::MockHerdr::start(script).await;
    let mut cfg = herdr_bridge::config::Config::from_cli(&herdr_bridge::config::Cli::from_process_env());
    cfg.socket_path = mock.socket_path.clone();
    // 审计落在 tempdir（函数返回即清理），避免 cargo test 写进真实 state dir。
    let state_dir = tempfile::tempdir().unwrap();
    cfg.state_dir = state_dir.path().to_path_buf();
    let (state, shutdown) = herdr_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    (mock, herdr_bridge::http::build_router(state), shutdown)
}

#[tokio::test]
async fn config_endpoint() {
    let (_m, app, _sd) = test_app(serde_json::Map::new()).await;
    let res = app.oneshot(Request::builder().uri("/api/v1/config")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert!(res.headers().get("x-bridge-build").is_some());
    let body = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["push"], false);
    assert_eq!(v["vapidPublicKey"], "");
    assert!(v["build"].as_str().unwrap().contains('.'));
}

#[tokio::test]
async fn snapshot_endpoint_triage_and_fields() {
    let (_m, app, _sd) = test_app(engine_script()).await; // 复用 Task 3 的 snapshot 脚本（抽到 common）
    // 等 engine 首轮 poll
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    let res = app.clone().oneshot(Request::builder().uri("/api/v1/snapshot")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["bridge"], "connected");
    assert_eq!(v["agents"][0]["paneId"], "w1:p1");
    assert_eq!(v["agents"][0]["status"], "blocked");
    assert_eq!(v["agents"][0]["readableLines"], 64);
    assert_eq!(v["shellPanes"][0]["agent"], "shell");
    assert_eq!(v["sessions"][0]["name"], "default");
    assert_eq!(v["sessions"][0]["isPrimary"], true);
    assert!(v["device"].is_null()); // 未启用 device gate 时字段缺席
    assert!(v["ts"].is_u64());
    // 方法检查：POST 必须 405 JSON 错误
    let res2 = app.oneshot(Request::builder().method("POST").uri("/api/v1/snapshot")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res2.status(), StatusCode::METHOD_NOT_ALLOWED);
    let b2 = axum::body::to_bytes(res2.into_body(), usize::MAX).await.unwrap();
    let e2: serde_json::Value = serde_json::from_slice(&b2).unwrap();
    assert_eq!(e2["code"], "method_not_allowed");
}

#[tokio::test]
async fn pane_read_passthrough_and_errors() {
    let mut script = serde_json::Map::new();
    script.insert("session.snapshot".into(), empty_snapshot());
    script.insert("pane.read".into(), serde_json::json!({
        "type": "pane_read",
        "read": {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                 "source": "recent", "format": "ansi",
                 "text": "hello \u{1b}[31mred\u{1b}[0m", "revision": 0, "truncated": false}
    }));
    let (mock, app, _sd) = test_app(script).await;
    let res = app.clone().oneshot(Request::builder()
        .uri("/api/v1/pane/w1:p1?lines=50").body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["paneId"], "w1:p1");
    assert!(v["text"].as_str().unwrap().contains("red"));
    // 发给 herdr 的参数正确
    let reqs = mock.received("pane.read");
    assert_eq!(reqs[0]["params"]["source"], "recent");
    assert_eq!(reqs[0]["params"]["format"], "ansi");
    assert_eq!(reqs[0]["params"]["lines"], 50);
    // 未知 pane：herdr pane_not_found → 404
    let mut script2 = serde_json::Map::new();
    script2.insert("pane.read".into(), serde_json::json!({
        "__error__": {"code": "pane_not_found", "message": "pane w9:p9 not found"}}));
    let (_m2, app2, _sd2) = test_app(script2).await;
    let res2 = app2.oneshot(Request::builder().uri("/api/v1/pane/w9:p9")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res2.status(), StatusCode::NOT_FOUND);
    let b = axum::body::to_bytes(res2.into_body(), usize::MAX).await.unwrap();
    let e: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(e["code"], "pane_not_found");
    // 未知 session → 404 session_not_found
    let res3 = app.oneshot(Request::builder().uri("/api/v1/snapshot?session=nope")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res3.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn pane_read_etag_roundtrip() {
    let mut script = serde_json::Map::new();
    script.insert("pane.read".into(), serde_json::json!({
        "type": "pane_read",
        "read": {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                 "source": "recent", "format": "ansi", "text": "stable", "revision": 0,
                 "truncated": false}}));
    let (_m, app, _sd) = test_app(script).await;
    let res = app.clone().oneshot(Request::builder().uri("/api/v1/pane/w1:p1")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let etag = res.headers().get("etag").unwrap().to_str().unwrap().to_string();
    assert!(etag.starts_with('"') && etag.ends_with('"'));
    let res2 = app.oneshot(Request::builder().uri("/api/v1/pane/w1:p1")
        .header("if-none-match", &etag)
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res2.status(), StatusCode::NOT_MODIFIED);
    assert_eq!(res2.headers().get("etag").unwrap().to_str().unwrap(), etag);
    let b = axum::body::to_bytes(res2.into_body(), usize::MAX).await.unwrap();
    assert!(b.is_empty());
}

fn empty_snapshot() -> serde_json::Value {
    serde_json::json!({"type": "session_snapshot", "snapshot": {
        "version": "0.8.0", "protocol": 19, "workspaces": [], "tabs": [],
        "panes": [], "layouts": [], "agents": []}})
}

fn engine_script() -> serde_json::Map<String, serde_json::Value> {
    // 与 Task 3 相同的脚本，复制到 common::engine_script() 共享。
    common::engine_script()
}
