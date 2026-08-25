mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

async fn write_app(script: serde_json::Map<String, serde_json::Value>)
    -> (common::MockHerdr, axum::Router, tokio::sync::watch::Sender<bool>)
{
    let mock = common::MockHerdr::start(script).await;
    let mut cfg = herdrgo_bridge::config::Config::from_cli(&herdrgo_bridge::config::Cli::from_process_env());
    cfg.socket_path = mock.socket_path.clone();
    // 审计落在 tempdir（函数返回即清理），避免 cargo test 写进真实 state dir。
    let state_dir = tempfile::tempdir().unwrap();
    cfg.state_dir = state_dir.path().to_path_buf();
    let (state, sd) = herdrgo_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    (mock, herdrgo_bridge::http::build_router(state), sd)
}

fn post_json(uri: &str, body: &str) -> Request<Body> {
    Request::builder().method("POST").uri(uri)
        .header("content-type", "application/json")
        .header("host", "127.0.0.1:8787")
        .body(Body::from(body.to_string())).unwrap()
}

fn get(uri: &str) -> Request<Body> {
    Request::builder().method("GET").uri(uri)
        .header("host", "127.0.0.1:8787")
        .body(Body::empty()).unwrap()
}

fn agent_manifests(kinds: &[&str]) -> serde_json::Value {
    serde_json::json!({
        "type": "agent_manifest_status",
        "manifests": kinds.iter().map(|kind| serde_json::json!({"agent": kind})).collect::<Vec<_>>(),
    })
}

fn pane(pane_id: &str, workspace_id: &str, tab_id: &str) -> serde_json::Value {
    serde_json::json!({
        "pane_id": pane_id,
        "workspace_id": workspace_id,
        "tab_id": tab_id,
        "focused": false,
        "agent_status": "idle",
        "revision": 1,
        "cwd": "/repo",
        "label": null,
        "agent": null,
        "agent_session": null,
        "scroll": null,
    })
}

fn tab_created() -> serde_json::Value {
    serde_json::json!({
        "type": "tab_created",
        "tab": {
            "tab_id": "w1:t2", "workspace_id": "w1", "number": 2,
            "label": "codex-1", "focused": false,
        },
        "root_pane": pane("w1:p2", "w1", "w1:t2"),
    })
}

fn workspace_created() -> serde_json::Value {
    serde_json::json!({
        "type": "workspace_created",
        "workspace": {
            "workspace_id": "w2", "number": 2, "label": "repo", "focused": false,
        },
        "tab": {
            "tab_id": "w2:t1", "workspace_id": "w2", "number": 1,
            "label": "", "focused": false,
        },
        "root_pane": pane("w2:p1", "w2", "w2:t1"),
    })
}

fn agent_started() -> serde_json::Value {
    serde_json::json!({
        "type": "agent_started",
        "agent": {"name": "codex-1", "pane_id": "w1:p2"},
        "argv": ["codex"],
    })
}

#[tokio::test]
async fn agent_kinds_are_sorted_and_deduplicated() {
    let mut script = serde_json::Map::new();
    script.insert("server.agent_manifests".into(), agent_manifests(&["codex", "claude", "codex"]));
    let (mock, app, _sd) = write_app(script).await;

    let res = app.oneshot(get("/api/v1/agents/kinds?session=default")).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["agents"], serde_json::json!(["claude", "codex"]));
    assert_eq!(mock.received("server.agent_manifests").len(), 1);
}

#[tokio::test]
async fn create_agent_in_existing_workspace_starts_and_prompts() {
    let mut script = serde_json::Map::new();
    script.insert("server.agent_manifests".into(), agent_manifests(&["codex"]));
    script.insert("tab.create".into(), tab_created());
    script.insert("agent.start".into(), agent_started());
    script.insert("pane.send_text".into(), serde_json::json!({"type": "ok"}));
    script.insert("pane.send_keys".into(), serde_json::json!({"type": "ok"}));
    let (mock, app, _sd) = write_app(script).await;

    let res = app.oneshot(post_json("/api/v1/agents?session=default", r#"{
        "name":"codex-1","kind":"codex","cwd":"/repo","workspaceId":"w1",
        "initialPrompt":"  review this patch  "
    }"#)).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let body = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["paneId"], "w1:p2");
    assert_eq!(json["agentName"], "codex-1");

    let tabs = mock.received("tab.create");
    assert_eq!(tabs[0]["params"], serde_json::json!({
        "workspace_id": "w1", "cwd": "/repo", "label": "codex-1",
        "env": {}, "focus": false,
    }));
    let starts = mock.received("agent.start");
    assert_eq!(starts[0]["params"], serde_json::json!({
        "name": "codex-1", "kind": "codex", "pane_id": "w1:p2",
        "args": [], "timeout_ms": 20000,
    }));
    assert_eq!(mock.received("pane.send_text")[0]["params"]["text"], "review this patch");
    assert_eq!(mock.received("pane.send_keys")[0]["params"]["keys"][0], "Enter");
}

#[tokio::test]
async fn create_agent_without_workspace_creates_unfocused_workspace() {
    let mut script = serde_json::Map::new();
    script.insert("server.agent_manifests".into(), agent_manifests(&["claude"]));
    script.insert("workspace.create".into(), workspace_created());
    script.insert("agent.start".into(), agent_started());
    let (mock, app, _sd) = write_app(script).await;

    let res = app.oneshot(post_json("/api/v1/agents", r#"{
        "name":"claude-1","kind":"claude","cwd":"/repo","workspaceLabel":"repo"
    }"#)).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    assert_eq!(mock.received("workspace.create")[0]["params"], serde_json::json!({
        "cwd": "/repo", "label": "repo", "env": {}, "focus": false,
    }));
    assert!(mock.received("tab.create").is_empty());
}

#[tokio::test]
async fn agent_start_failure_returns_created_pane_without_closing_it() {
    let mut script = serde_json::Map::new();
    script.insert("server.agent_manifests".into(), agent_manifests(&["codex"]));
    script.insert("tab.create".into(), tab_created());
    script.insert("agent.start".into(), serde_json::json!({
        "__error__": {"code": "agent_start_timeout", "message": "not ready"}
    }));
    let (mock, app, _sd) = write_app(script).await;

    let res = app.oneshot(post_json("/api/v1/agents", r#"{
        "name":"codex-1","kind":"codex","cwd":"/repo","workspaceId":"w1"
    }"#)).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_GATEWAY);
    let body = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["code"], "agent_start_failed");
    assert_eq!(json["created"]["paneId"], "w1:p2");
    assert!(mock.received("pane.close").is_empty());
    assert!(mock.received("tab.close").is_empty());
}

#[tokio::test]
async fn initial_prompt_submit_failure_reports_text_and_keeps_pane() {
    let mut script = serde_json::Map::new();
    script.insert("server.agent_manifests".into(), agent_manifests(&["codex"]));
    script.insert("tab.create".into(), tab_created());
    script.insert("agent.start".into(), agent_started());
    script.insert("pane.send_text".into(), serde_json::json!({"type": "ok"}));
    script.insert("pane.send_keys".into(), serde_json::json!({
        "__error__": {"code": "invalid_key", "message": "submit failed"}
    }));
    let (mock, app, _sd) = write_app(script).await;

    let res = app.oneshot(post_json("/api/v1/agents", r#"{
        "name":"codex-1","kind":"codex","cwd":"/repo","workspaceId":"w1",
        "initialPrompt":"review this"
    }"#)).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_GATEWAY);
    let body = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["code"], "text_delivered");
    assert_eq!(json["textDelivered"], true);
    assert_eq!(json["created"]["paneId"], "w1:p2");
    assert!(mock.received("pane.close").is_empty());
    assert!(mock.received("tab.close").is_empty());
}

#[tokio::test]
async fn create_agent_validates_before_mutating_herdr() {
    let (mock, app, _sd) = write_app(serde_json::Map::new()).await;
    let bad_name = app.clone().oneshot(post_json("/api/v1/agents", r#"{
        "name":"Bad Name","kind":"codex","cwd":"/repo","workspaceId":"w1"
    }"#)).await.unwrap();
    assert_eq!(bad_name.status(), StatusCode::BAD_REQUEST);
    let bad_cwd = app.oneshot(post_json("/api/v1/agents", r#"{
        "name":"codex-1","kind":"codex","cwd":"relative/path","workspaceId":"w1"
    }"#)).await.unwrap();
    assert_eq!(bad_cwd.status(), StatusCode::BAD_REQUEST);
    assert!(mock.received("server.agent_manifests").is_empty());
    assert!(mock.received("tab.create").is_empty());
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
async fn resize_rejects_sizes_outside_the_phone_viewport_bounds() {
    let (_mock, app, _sd) = write_app(serde_json::Map::new()).await;

    let too_narrow = app
        .clone()
        .oneshot(post_json(
            "/api/v1/pane/w1:p1/resize",
            r#"{"cols":19,"rows":30}"#,
        ))
        .await
        .unwrap();
    assert_eq!(too_narrow.status(), StatusCode::BAD_REQUEST);

    let too_tall = app
        .oneshot(post_json(
            "/api/v1/pane/w1:p1/resize",
            r#"{"cols":48,"rows":201}"#,
        ))
        .await
        .unwrap();
    assert_eq!(too_tall.status(), StatusCode::BAD_REQUEST);
}

#[cfg(unix)]
#[tokio::test]
async fn resize_uses_short_lived_controller_and_audits_success() {
    use std::os::unix::fs::PermissionsExt;

    let controller_dir = tempfile::tempdir().unwrap();
    let herdr_bin = controller_dir.path().join("herdr");
    std::fs::write(
        &herdr_bin,
        r#"#!/bin/sh
capture=$(dirname -- "$0")/capture
printf 'socket=%s\n' "$HERDR_SOCKET_PATH" > "$capture"
for argument in "$@"; do printf 'arg=%s\n' "$argument" >> "$capture"; done
printf '%s\n' '{"type":"terminal.frame","data":""}'
IFS= read -r command
printf 'stdin=%s\n' "$command" >> "$capture"
"#,
    )
    .unwrap();
    std::fs::set_permissions(
        &herdr_bin,
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    let mock = common::MockHerdr::start(serde_json::Map::new()).await;
    let state_dir = tempfile::tempdir().unwrap();
    let mut cfg = herdrgo_bridge::config::Config::from_cli(
        &herdrgo_bridge::config::Cli::from_process_env(),
    );
    cfg.socket_path = mock.socket_path.clone();
    cfg.herdr_bin_path = herdr_bin;
    cfg.state_dir = state_dir.path().to_path_buf();
    let (state, _sd) =
        herdrgo_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    let app = herdrgo_bridge::http::build_router(state);

    let response = app
        .oneshot(post_json(
            "/api/v1/pane/w1:p1/resize?session=default",
            r#"{"cols":48,"rows":31}"#,
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let capture =
        std::fs::read_to_string(controller_dir.path().join("capture")).unwrap();
    assert!(capture.contains(&format!("socket={}", mock.socket_path.display())));
    assert!(capture.contains("arg=w1:p1\n"));
    assert!(capture.contains("arg=--cols\narg=48\narg=--rows\narg=31\n"));
    assert!(!capture.contains("arg=--takeover\n"));
    assert!(capture.contains("stdin={\"type\":\"terminal.release\"}\n"));

    let audit = std::fs::read_to_string(state_dir.path().join("audit.log")).unwrap();
    let line: serde_json::Value =
        serde_json::from_str(audit.lines().next().unwrap()).unwrap();
    assert_eq!(line["action"], "resize");
    assert_eq!(line["paneId"], "w1:p1");
    assert_eq!(line["detail"], "48x31");
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
    let mut cfg = herdrgo_bridge::config::Config::from_cli(&herdrgo_bridge::config::Cli::from_process_env());
    cfg.socket_path = mock.socket_path.clone();
    cfg.state_dir = state_dir.path().to_path_buf();
    let (state, _sd) = herdrgo_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    let app = herdrgo_bridge::http::build_router(state);
    let res = app.oneshot(post_json("/api/v1/pane/w1:p1/reply",
        "{\"text\":\"ship it\",\"submit\":false}")).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let log = std::fs::read_to_string(state_dir.path().join("audit.log")).unwrap();
    let line: serde_json::Value = serde_json::from_str(log.lines().next().unwrap()).unwrap();
    assert_eq!(line["action"], "reply");
    assert_eq!(line["paneId"], "w1:p1");
    assert_eq!(line["detail"], "ship it");
}
