mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

async fn write_app(script: serde_json::Map<String, serde_json::Value>)
    -> (common::MockHerdr, axum::Router, tokio::sync::watch::Sender<bool>)
{
    let mock = common::MockHerdr::start(script).await;
    let mut cfg = herdr_bridge::config::Config::from_cli(&herdr_bridge::config::Cli::from_process_env());
    cfg.socket_path = mock.socket_path.clone();
    // 审计落在 tempdir（函数返回即清理），避免 cargo test 写进真实 state dir。
    let state_dir = tempfile::tempdir().unwrap();
    cfg.state_dir = state_dir.path().to_path_buf();
    let (state, sd) = herdr_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    (mock, herdr_bridge::http::build_router(state), sd)
}

fn post_json(uri: &str, body: &str) -> Request<Body> {
    Request::builder().method("POST").uri(uri)
        .header("content-type", "application/json")
        .header("host", "127.0.0.1:8787")
        .body(Body::from(body.to_string())).unwrap()
}

#[tokio::test]
async fn reply_sends_text_then_enter() {
    let mut script = serde_json::Map::new();
    script.insert("session.snapshot".into(), serde_json::json!({
        "type": "session_snapshot", "snapshot": {"version": "0.8.0", "protocol": 19,
            "workspaces": [], "tabs": [], "panes": [], "layouts": [], "agents": []}}));
    script.insert("pane.send_text".into(), serde_json::json!({"type": "ok"}));
    script.insert("pane.send_keys".into(), serde_json::json!({"type": "ok"}));
    let (mock, app, _sd) = write_app(script).await;
    let res = app.oneshot(post_json("/api/v1/pane/w1:p1/reply",
        "{\"text\":\"hello\",\"submit\":true}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&b).unwrap()["ok"], true);
    let texts = mock.received("pane.send_text");
    assert_eq!(texts[0]["params"]["text"], "hello");
    let keys = mock.received("pane.send_keys");
    assert_eq!(keys[0]["params"]["keys"][0], "Enter");
}

#[tokio::test]
async fn reply_submit_failure_marks_text_delivered() {
    let mut script = serde_json::Map::new();
    script.insert("pane.send_text".into(), serde_json::json!({"type": "ok"}));
    script.insert("pane.send_keys".into(), serde_json::json!({
        "__error__": {"code": "invalid_key", "message": "unsupported key Enter"}}));
    let (_m, app, _sd) = write_app(script).await;
    let res = app.oneshot(post_json("/api/v1/pane/w1:p1/reply",
        "{\"text\":\"hello\",\"submit\":true}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_GATEWAY);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(v["code"], "text_delivered");
    assert_eq!(v["textDelivered"], true);
}

#[tokio::test]
async fn reply_send_text_failure_is_plain_502() {
    let mut script = serde_json::Map::new();
    script.insert("pane.send_text".into(), serde_json::json!({
        "__error__": {"code": "pane_not_found", "message": "pane w1:p1 not found"}}));
    let (_m, app, _sd) = write_app(script).await;
    let res = app.oneshot(post_json("/api/v1/pane/w1:p1/reply",
        "{\"text\":\"x\",\"submit\":false}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND); // pane_not_found → 404
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert!(v.get("textDelivered").is_none());
}

#[tokio::test]
async fn keys_validation_and_passthrough() {
    let mut script = serde_json::Map::new();
    script.insert("pane.send_keys".into(), serde_json::json!({"type": "ok"}));
    let (mock, app, _sd) = write_app(script).await;
    // 空 keys → 400
    let res = app.clone().oneshot(post_json("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[]}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    // 正常 keys 透传
    let res2 = app.clone().oneshot(post_json("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"esc\",\"ctrl+c\"]}")).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    let sent = mock.received("pane.send_keys");
    assert_eq!(sent[0]["params"]["keys"][1], "ctrl+c");
    // expectedPrompt 超长 → 400
    let long = "x".repeat(9000);
    let res3 = app.clone().oneshot(post_json("/api/v1/pane/w1:p1/keys",
        &format!("{{\"keys\":[\"esc\"],\"expectedPrompt\":\"{long}\"}}"))).await.unwrap();
    assert_eq!(res3.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn keys_with_expected_prompt_409_when_screen_changed() {
    let mut script = serde_json::Map::new();
    script.insert("pane.read".into(), serde_json::json!({
        "type": "pane_read",
        "read": {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                 "source": "recent", "format": "ansi", "text": "totally different screen",
                 "revision": 0, "truncated": false}}));
    script.insert("pane.send_keys".into(), serde_json::json!({"type": "ok"}));
    let (mock, app, _sd) = write_app(script).await;
    let res = app.oneshot(post_json("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"1\"],\"expectedPrompt\":\"❯ 1. Yes\\n  2. No\"}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&b).unwrap()["code"], "prompt_changed");
    assert!(mock.received("pane.send_keys").is_empty()); // 未写入
}

#[tokio::test]
async fn keys_with_expected_prompt_passes_and_sends() {
    let mut script = serde_json::Map::new();
    script.insert("pane.read".into(), serde_json::json!({
        "type": "pane_read",
        "read": {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                 "source": "recent", "format": "ansi",
                 "text": "\u{1b}[1m❯ 1. Yes\u{1b}[0m\r\n  2. No\r\n",
                 "revision": 0, "truncated": false}}));
    script.insert("pane.send_keys".into(), serde_json::json!({"type": "ok"}));
    let (mock, app, _sd) = write_app(script).await;
    let res = app.oneshot(post_json("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"1\"],\"expectedPrompt\":\"❯ 1. Yes\\n  2. No\"}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(mock.received("pane.send_keys").len(), 1);
}

#[tokio::test]
async fn close_and_rename_passthrough() {
    let mut script = serde_json::Map::new();
    script.insert("pane.close".into(), serde_json::json!({"type": "ok"}));
    script.insert("pane.rename".into(), serde_json::json!({"type": "pane_info"}));
    let (mock, app, _sd) = write_app(script).await;
    let res = app.clone().oneshot(post_json("/api/v1/pane/w1:p1/close", "")).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res2 = app.clone().oneshot(post_json("/api/v1/pane/w1:p1/rename",
        "{\"label\":\"  review-2  \"}")).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    let renames = mock.received("pane.rename");
    assert_eq!(renames[0]["params"]["label"], "review-2");
    // 空串 → null（清除标签）
    let res3 = app.clone().oneshot(post_json("/api/v1/pane/w1:p1/rename",
        "{\"label\":\"   \"}")).await.unwrap();
    assert_eq!(res3.status(), StatusCode::OK);
    let renames = mock.received("pane.rename");
    assert_eq!(renames[1]["params"]["label"], serde_json::Value::Null);
    // label 类型错 → 400
    let res4 = app.oneshot(post_json("/api/v1/pane/w1:p1/rename",
        "{\"label\":42}")).await.unwrap();
    assert_eq!(res4.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn writes_are_audited() {
    let mut script = serde_json::Map::new();
    script.insert("pane.send_text".into(), serde_json::json!({"type": "ok"}));
    script.insert("pane.send_keys".into(), serde_json::json!({"type": "ok"}));
    let mock = common::MockHerdr::start(script).await;
    let state_dir = tempfile::tempdir().unwrap();
    let mut cfg = herdr_bridge::config::Config::from_cli(&herdr_bridge::config::Cli::from_process_env());
    cfg.socket_path = mock.socket_path.clone();
    cfg.state_dir = state_dir.path().to_path_buf();
    let (state, _sd) = herdr_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    let app = herdr_bridge::http::build_router(state);
    let res = app.oneshot(post_json("/api/v1/pane/w1:p1/reply",
        "{\"text\":\"ship it\",\"submit\":false}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let log = std::fs::read_to_string(state_dir.path().join("audit.log")).unwrap();
    let line: serde_json::Value = serde_json::from_str(log.lines().next().unwrap()).unwrap();
    assert_eq!(line["action"], "reply");
    assert_eq!(line["paneId"], "w1:p1");
    assert_eq!(line["detail"], "ship it");
}
